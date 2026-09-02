/* global ethers */
/* eslint prefer-const: "off" */

const { getSelectors, FacetCutAction } = require('./libraries/diamond.js')
const { verify } = require("../utils/verify");
const { ethers, network, artifacts } = require("hardhat");
const fs = require("fs");

// The well-known Hardhat dev account #0 (from the "test test ... junk" mnemonic).
// This address must NEVER own a real (non-local) deployment.
const HARDHAT_DEV_ACCOUNT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
// Hardhat dev account #4 used as a local-only OpenAdverts stand-in; MUST never reach mainnet.
const DEV_OPENADVERTS_FALLBACK = "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707";

// Read a JSON file, returning {} if it is missing or unparseable. Never throws.
function readJsonSafe(filePath) {
  try {
    if (!fs.existsSync(filePath)) return {};
    const raw = fs.readFileSync(filePath, "utf8");
    if (!raw.trim()) return {};
    return JSON.parse(raw);
  } catch (e) {
    console.warn(`readJsonSafe: could not parse ${filePath}, treating as empty ({}). ${e.message}`);
    return {};
  }
}

// Merge a value under its chainId key, preserving every other network's entry,
// then write back. This makes per-network writes non-destructive across chains.
function mergeJsonByChainId(filePath, chainId, value) {
  const existing = readJsonSafe(filePath);
  existing[String(chainId)] = value;
  fs.writeFileSync(filePath, JSON.stringify(existing, null, 2));
}

async function deployDiamond (finalizeBootstrapAtEnd = false) {
  // Fail-fast mainnet gates that need no RPC/account access. Checked before we ever
  // touch the provider, so a misconfigured mainnet run stops with a clear message
  // instead of an opaque "No unlocked accounts" / RPC-auth error.
  if (network.config.chainId === 137) {
    // Deliberate human opt-in (set in .env.prod, loaded via `npm run deploy:mainnet`).
    if (process.env.I_UNDERSTAND_MAINNET !== "1") {
      throw new Error(
        'Refusing to deploy to Polygon mainnet: I_UNDERSTAND_MAINNET is not set to "1". ' +
        'Set it (in .env.prod) only when you intend to broadcast to mainnet.'
      );
    }
    // Dedicated mainnet owner key — shell-injected for this command only, never in a file.
    if (!process.env.PRIVATEKEYMAINNET) {
      throw new Error(
        'Refusing to deploy to Polygon mainnet: PRIVATEKEYMAINNET env var is not set. ' +
        'Provide the dedicated mainnet owner EOA private key (env only — never in source).'
      );
    }
  }
  const accounts = await ethers.getSigners()
  if (!accounts || accounts.length === 0) {
    throw new Error(
      `No unlocked accounts available on network "${network.name}". 
Start a local node (npx hardhat node) and re-run with --network localhost, 
or run without --network to use the in-process Hardhat network.`
    );
  }
  const contractOwner = accounts[0]
  // Frontend signing address is consumed by voxGovernanceFacet.initialize() and
  // persisted into on-chain governance state, so a wrong/empty value corrupts a
  // real deployment. Require it from the environment and fail fast if missing or
  // malformed rather than deploying with an undefined/garbage address.
  const signingAddressFE = process.env.SIGNING_ADDRESS_FE
  if (!signingAddressFE || !ethers.isAddress(signingAddressFE)) {
    throw new Error(
      `SIGNING_ADDRESS_FE is missing or not a valid address (got: ${signingAddressFE ?? "undefined"}). ` +
      `Set SIGNING_ADDRESS_FE in your .env before deploying.`
    );
  }
  // Public requestKey published on-chain via VoxRequestKeyFacet.setRequestKey after governance init.
  // It is the signing service's request-auth identity and rotates atomically with ownership. It MUST
  // differ from the signing address (separation of duties) and from the deployer/owner, mirroring the
  // on-chain checks, so a misconfigured value fails fast here instead of reverting mid-deploy.
  const requestKeyAddressFE = process.env.REQUEST_KEY_ADDRESS_FE
  if (!requestKeyAddressFE || !ethers.isAddress(requestKeyAddressFE)) {
    throw new Error(
      `REQUEST_KEY_ADDRESS_FE is missing or not a valid address (got: ${requestKeyAddressFE ?? "undefined"}). ` +
      `Set REQUEST_KEY_ADDRESS_FE in your .env before deploying.`
    );
  }
  if (requestKeyAddressFE.toLowerCase() === signingAddressFE.toLowerCase()) {
    throw new Error("REQUEST_KEY_ADDRESS_FE must differ from SIGNING_ADDRESS_FE (separation of duties).");
  }
  if (requestKeyAddressFE.toLowerCase() === contractOwner.address.toLowerCase()) {
    throw new Error("REQUEST_KEY_ADDRESS_FE must differ from the deployer/owner address.");
  }
  const chainId = network.config.chainId
  const isPolygonMainnet = chainId === 137
  const isLocalNetwork = network.name === "hardhat" || network.name === "localhost"
  // Storage-provider address receives the on-chain storage-provider payout share and, for
  // KMS/Aegis deployments, IS the Irys uploader wallet (so the share offsets its funding cost).
  // Required on mainnet; on a local/dev chain it defaults to the deployer/owner (prior behaviour).
  const storageProviderAddressRaw = process.env.STORAGE_PROVIDER_ADDRESS
  if (isPolygonMainnet && !storageProviderAddressRaw) {
    throw new Error(
      "STORAGE_PROVIDER_ADDRESS must be set for a mainnet deploy (the Irys uploader/storage-provider address)."
    );
  }
  const storageProviderAddressFE = storageProviderAddressRaw || contractOwner.address
  if (!ethers.isAddress(storageProviderAddressFE)) {
    throw new Error(
      `STORAGE_PROVIDER_ADDRESS is not a valid address (got: ${storageProviderAddressRaw ?? "undefined"}).`
    );
  }
  // Etherscan V2 unified API: a single ETHERSCAN_API_KEY verifies all chains via chainid.
  const verifyApiKey = process.env.ETHERSCAN_API_KEY
  const canVerify = !isLocalNetwork && !!verifyApiKey
  // Polygon mainnet USDC: use NATIVE USDC (Circle-issued, 6 decimals), NOT bridged
  // USDC.e (0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174 — deprecated, thinner liquidity).
  // Both are 6-decimal ERC-20s so the wrong one passes local tests and only breaks
  // real funding in production — hence the explicit choice documented here.
  const polygonMainnetUSDC = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
  const polygonMainnetPriceFeed = process.env.POLYGON_POL_USD_FEED
  // OpenAdverts address: on mainnet this MUST be supplied via env (no dev fallback).
  const openAdvertsAddress = isPolygonMainnet
    ? process.env.OPENADVERTS_ADDRESS
    : (process.env.OPENADVERTS_ADDRESS || DEV_OPENADVERTS_FALLBACK)
  let usdcAddress
  let mockUSDC
  let priceFeedAddress
  const facetAddressMap = {};

  // --- Production safety guards -------------------------------------------------
  // Never let the Hardhat dev account own a real deployment.
  if (!isLocalNetwork && contractOwner.address.toLowerCase() === HARDHAT_DEV_ACCOUNT.toLowerCase()) {
    throw new Error(
      `Refusing to deploy to "${network.name}": resolved deployer is the Hardhat dev account ` +
      `(${HARDHAT_DEV_ACCOUNT}). Set a real signing key for this network before deploying.`
    );
  }
  // Mainnet requires an explicit OpenAdverts address (no dev fallback).
  if (isPolygonMainnet && !openAdvertsAddress) {
    throw new Error('Missing OPENADVERTS_ADDRESS env var for Polygon mainnet deployment.');
  }
  // Fail fast on a malformed mainnet address (e.g. a leftover placeholder) rather
  // than reverting deep inside voxTokenFacet.initialize().
  if (isPolygonMainnet && !ethers.isAddress(openAdvertsAddress)) {
    throw new Error(
      `OPENADVERTS_ADDRESS is not a valid address (got: ${openAdvertsAddress}). ` +
      `Set the real OpenAdverts contract address in .env.prod.`
    );
  }
  // Guard against a stale dev OpenAdverts address leaking into a mainnet run.
  if (isPolygonMainnet && openAdvertsAddress.toLowerCase() === DEV_OPENADVERTS_FALLBACK.toLowerCase()) {
    throw new Error(
      `Refusing to deploy to Polygon mainnet: OPENADVERTS_ADDRESS is the dev fallback ` +
      `(${DEV_OPENADVERTS_FALLBACK}). Set the real OpenAdverts contract address in .env.prod.`
    );
  }
  // -----------------------------------------------------------------------------

  console.log('Deploying with account:', contractOwner.address)
  if (!canVerify) {
    console.log('Verification skipped (local network or missing verification API key).')
  }

  // Deploy MockUSDC on dev/test networks, use real USDC on Polygon mainnet
  console.log('')
  if (isPolygonMainnet) {
    usdcAddress = polygonMainnetUSDC
    console.log('Using Polygon mainnet USDC:', usdcAddress)
  } else {
    console.log('Deploying MockUSDC...')
    const MockUSDC = await ethers.getContractFactory('MockUSDC')
    mockUSDC = await MockUSDC.deploy()
    await mockUSDC.waitForDeployment()
    usdcAddress = await mockUSDC.getAddress()
    console.log('MockUSDC deployed:', usdcAddress)
    facetAddressMap['MockUSDC'] = usdcAddress;
    if (canVerify) {
      await verify(usdcAddress, [])
    }
  }

  // Price feed: mock on dev/test, Chainlink on Polygon mainnet
  console.log('')
  if (isPolygonMainnet) {
    if (!polygonMainnetPriceFeed) {
      throw new Error("Missing POLYGON_POL_USD_FEED env var for Polygon mainnet price feed");
    }
    priceFeedAddress = polygonMainnetPriceFeed
    console.log('Using Polygon mainnet Chainlink price feed:', priceFeedAddress)
  } else {
    console.log('Deploying MockV3Aggregator...')
    const MockV3Aggregator = await ethers.getContractFactory('MockV3Aggregator')
    const mockPriceFeed = await MockV3Aggregator.deploy(
      8, // decimals
      50000000 // initial price: $0.50 (with 8 decimals)
    )
    await mockPriceFeed.waitForDeployment()
    priceFeedAddress = await mockPriceFeed.getAddress()
    console.log('MockV3Aggregator deployed:', priceFeedAddress)
    facetAddressMap['MockV3Aggregator'] = priceFeedAddress;
    if (canVerify) {
      await verify(priceFeedAddress, [8, 50000000])
    }
  }

  // deploy DiamondCutFacet
  console.log('')
  const DiamondCutFacet = await ethers.getContractFactory('DiamondCutFacet')
  const diamondCutFacet = await DiamondCutFacet.deploy()
  await diamondCutFacet.waitForDeployment()
  const diamondCutFacetAddress = await diamondCutFacet.getAddress()
  console.log('DiamondCutFacet deployed:', diamondCutFacetAddress)
  facetAddressMap['DiamondCutFacet'] = diamondCutFacetAddress;
  if (canVerify) {
    await verify(diamondCutFacetAddress, [])
  }

  // deploy Diamond
  const Diamond = await ethers.getContractFactory('Diamond')
  const diamond = await Diamond.deploy(contractOwner.address, diamondCutFacetAddress)
  await diamond.waitForDeployment()
  const diamondAddress = await diamond.getAddress()
  console.log('Diamond deployed:', diamondAddress)
  facetAddressMap['Diamond'] = diamondAddress;
  if (canVerify) {
    await verify(diamondAddress, [contractOwner.address, diamondCutFacetAddress])
  }

  // deploy DiamondInit
  const DiamondInit = await ethers.getContractFactory('DiamondInit')
  const diamondInit = await DiamondInit.deploy()
  await diamondInit.waitForDeployment()
  const diamondInitAddress = await diamondInit.getAddress()
  console.log('DiamondInit deployed:', diamondInitAddress)
  if (canVerify) {
    await verify(diamondInitAddress, [])
  }

  // deploy facets
  console.log('')
  console.log('Deploying facets')
  const FacetNames = [
    'DiamondLoupeFacet',
    'OwnershipFacet',
    'VoxFacet',
    'VoxGovernanceFacet',
    'VoxTokenFacet',
    'ChapterLensFacet',
    'VoxAssistantFacet',
    'GovernanceLensFacet',
    'TokenLensFacet',
    'VoxRequestKeyFacet'
  ]
  const cut = [];
  let voxTokenFacetAddress = "";

  for (const FacetName of FacetNames) {
    const Facet = await ethers.getContractFactory(FacetName)
    const facet = await Facet.deploy(diamondAddress)
    await facet.waitForDeployment()
    const facetAddress = await facet.getAddress()
    console.log(`${FacetName} deployed: ${facetAddress}`)
    facetAddressMap[FacetName] = facetAddress;
    if (canVerify) {
      await verify(facetAddress, [diamondAddress])
    }
    cut.push({
      facetAddress: facetAddress,
      action: FacetCutAction.Add,
      functionSelectors: getSelectors(facet)
    })
    if (FacetName === 'VoxTokenFacet') {
      voxTokenFacetAddress = facetAddress;
    }
  }

  // upgrade diamond with facets
  console.log('')
  console.log('Diamond Cut:', cut)
  const diamondCut = await ethers.getContractAt('IDiamondCut', diamondAddress)
  let tx
  let receipt
  // call to init function
  let functionCall = diamondInit.interface.encodeFunctionData('init')
  tx = await diamondCut.diamondCut(cut, await diamondInit.getAddress(), functionCall)
  console.log('Diamond cut tx: ', tx.hash)
  receipt = await tx.wait()
  if (!receipt.status) {
    throw Error(`Diamond upgrade failed: ${tx.hash}`)
  }
  console.log('Completed diamond cut')

  // Deploy VoxChapter Implementation
  console.log('')
  console.log('Deploying VoxChapter Implementation (Master)...')
  const VoxChapter = await ethers.getContractFactory('VoxChapter')
  const chapterImplementation = await VoxChapter.deploy()
  await chapterImplementation.waitForDeployment()
  const chapterImplAddress = await chapterImplementation.getAddress()
  console.log('VoxChapter Implementation deployed:', chapterImplAddress)
  facetAddressMap['VoxChapter'] = chapterImplAddress;
  if (canVerify) {
    await verify(chapterImplAddress, [])
  }

  // Set Chapter Implementation in Diamond
  const voxFacet = await ethers.getContractAt('VoxFacet', diamondAddress);
  console.log('')
  console.log('Setting Chapter Implementation in Diamond...');
  const setImplTx = await voxFacet.setChapterImplementation(chapterImplAddress);
  console.log('Set implementation tx:', setImplTx.hash);
  await setImplTx.wait();
  console.log('✓ Chapter Implementation set in Diamond');

  // Initialize VoxTokenFacet
  const voxTokenFacet = await ethers.getContractAt('VoxTokenFacet', diamondAddress);
  console.log('')
  console.log('Initializing VoxTokenFacet...');
  console.log('  Diamond Address:', diamondAddress);
  console.log('  USDC Address:', usdcAddress);
  console.log('  Price Feed Address:', priceFeedAddress);
  console.log('  OpenAdverts Address:', openAdvertsAddress);
  const initializeTx1 = await voxTokenFacet.initialize(
    diamondAddress,
    usdcAddress,
    priceFeedAddress,
    openAdvertsAddress
  );
  console.log('VoxTokenFacet initialized:', initializeTx1.hash);
  await initializeTx1.wait();

  // Initialize VoxGovernanceFacet
  const voxGovernanceFacet = await ethers.getContractAt('VoxGovernanceFacet', diamondAddress);
  console.log('')
  console.log('Initializing VoxGovernanceFacet...');

  const quotas = {
    voxClaimPercentage: 10,
    viewerClaimPercentage: 70,
    thirdParty1ClaimPercentage: 5,
    thirdParty2ClaimPercentage: 10,
    thirdParty3ClaimPercentage: 5,
    thirdParty4ClaimPercentage: 0,
    thirdParty5ClaimPercentage: 0,
    thirdParty6ClaimPercentage: 0,
    voxAdminClaimPercentage: 10,
    voxAdminChangeQuorum: 51,
    QuotaProposalQuorum: 51,
    FacetProposalQuorum: 51,
    storageProviderPercentage: 1,
    adminApplicantFeeInPolWei: ethers.parseEther("1000"),
    adminVoteDeadlineInBlocks: 604800,
    // ✅ NEW: Proposal duration constraints
    minQuotaProposalDuration: 43200,      // ~1 day (minimum)
    maxQuotaProposalDuration: 1296000,    // ~30 days (maximum)
    minFacetProposalDuration: 43200,      // ~1 day (minimum)
    maxFacetProposalDuration: 1296000     // ~30 days (maximum)
  };

  const initializeTx2 = await voxGovernanceFacet.initialize(
    quotas,
    signingAddressFE,
    storageProviderAddressFE
  );
  console.log('VoxGovernanceFacet initialized:', initializeTx2.hash);
  await initializeTx2.wait();

  // Seed the requestKey AFTER the signing address is set (so the on-chain `!= signingAddress` check is
  // meaningful) and BEFORE finalizeBootstrap. Runs as owner (deployer); validates nonzero, != owner,
  // != current(0) and != signingAddress on-chain.
  const voxRequestKeyFacet = await ethers.getContractAt('VoxRequestKeyFacet', diamondAddress);
  console.log('')
  console.log('Seeding requestKey via VoxRequestKeyFacet.setRequestKey...');
  console.log('  RequestKey:', requestKeyAddressFE);
  const setRequestKeyTx = await voxRequestKeyFacet.setRequestKey(requestKeyAddressFE);
  await setRequestKeyTx.wait();
  console.log('✓ requestKey seeded:', setRequestKeyTx.hash);

  // Close the bootstrap latch: after this, direct owner diamondCut is permanently
  // disabled and all upgrades must go through governance (FacetProposal). Done last,
  // after every deployment cut + all initializers have run.
  if (finalizeBootstrapAtEnd) {
    const ownershipFacet = await ethers.getContractAt('OwnershipFacet', diamondAddress);
    console.log('')
    console.log('Finalizing bootstrap (closing direct owner diamondCut backdoor)...');
    const finalizeTx = await ownershipFacet.finalizeBootstrap();
    await finalizeTx.wait();
    console.log('✓ Bootstrap finalized:', finalizeTx.hash);
  }

  console.log('')
  console.log('=== Deployment Summary ===')
  console.log('Diamond:', diamondAddress)
  console.log('USDC:', usdcAddress)
  console.log('PriceFeed:', priceFeedAddress)
  console.log('VoxTokenFacet:', voxTokenFacetAddress)
  console.log('VoxChapter Implementation:', chapterImplAddress)
  console.log('==========================')

  // Export all contract addresses to a local JSON file
  const deployedAddresses = {
    chainId: chainId,
    network: network.name,
    deployer: contractOwner.address,
    deployedAt: new Date().toISOString(),
    signingAddress: signingAddressFE,
    requestKey: requestKeyAddressFE,
    storageProvider: storageProviderAddressFE,
    contracts: {
      Diamond: diamondAddress,
      DiamondInit: diamondInitAddress,
      USDC: usdcAddress,
      PriceFeed: priceFeedAddress,
      VoxChapterImplementation: chapterImplAddress,
      ...facetAddressMap
    }
  };
  const deploymentPath = `deployments-${chainId}.json`;
  fs.writeFileSync(deploymentPath, JSON.stringify(deployedAddresses, null, 2));
  console.log(`\nContract addresses exported to ${deploymentPath}`);

  await updateFrontend(
    diamondAddress, 
    voxTokenFacetAddress,
    usdcAddress,
    priceFeedAddress,
    chapterImplAddress,
    facetAddressMap
  );

  return diamondAddress
}

async function updateFrontend(diamondAddress, tokenAddress, usdcAddress, priceFeedAddress, chapterImplAddress, facetAddressMap) {
  const paths = {
    diamondAddress: "../fevoxnet/src/constants/diamondAddress.json",
    tokenAddress:  "../fevoxnet/src/constants/tokenAddress.json",
    usdcAddress: "../fevoxnet/src/constants/usdcAddress.json",
    priceFeedAddress: "../fevoxnet/src/constants/priceFeedAddress.json",
    chapterImplAddress: "../fevoxnet/src/constants/chapterImplAddress.json", // ✅ Added
    facetAddresses: "../fevoxnet/src/constants/facetAddresses.json",
    facetsABI: "../fevoxnet/src/constants/facetsABI.json",
    ABIs: {
      voxMain: "../fevoxnet/src/constants/voxMain.json",
      voxToken: "../fevoxnet/src/constants/voxToken.json",
      voxGovernance: "../fevoxnet/src/constants/voxGovernance.json",
      loupe: "../fevoxnet/src/constants/loupeABI.json",
      ownership: "../fevoxnet/src/constants/ownershipABI.json",
      mockUSDC: "../fevoxnet/src/constants/mockUSDCABI.json",
      priceFeed: "../fevoxnet/src/constants/priceFeedABI.json",
      voxChapter: "../fevoxnet/src/constants/voxChapterABI.json", // ✅ Added
      chapterLens: "../fevoxnet/src/constants/chapterLensABI.json",
      voxAssistant: "../fevoxnet/src/constants/voxAssistantABI.json",
      governanceLens: "../fevoxnet/src/constants/governanceLensABI.json",
      tokenLens: "../fevoxnet/src/constants/tokenLensABI.json",
    }
  };

  await Promise.all([
    updateAddresses(paths, diamondAddress, tokenAddress, usdcAddress, priceFeedAddress, chapterImplAddress, facetAddressMap),
    updateFacetABIs(paths.ABIs, diamondAddress, usdcAddress, priceFeedAddress, chapterImplAddress),
  ]);

  async function updateAddresses(paths, diamondAddress, tokenAddress, usdcAddress, priceFeedAddress, chapterImplAddress, facetAddressMap) {
    try {
      const chainId = network.config.chainId;
      console.log('Network Chain ID:', chainId);

      // All writes below merge by chainId so deploying to one network never wipes
      // another network's entry in the shared frontend constant files.

      // Update Diamond Address
      mergeJsonByChainId(paths.diamondAddress, chainId, diamondAddress);
      console.log("Diamond contract address updated in frontend.");

      // Update Token Address
      mergeJsonByChainId(paths.tokenAddress, chainId, tokenAddress);
      console.log("VoxTokenFacet contract address updated in frontend.");

      // Update USDC Address
      mergeJsonByChainId(paths.usdcAddress, chainId, usdcAddress);
      console.log("USDC contract address updated in frontend.");

      // Update Price Feed Address
      mergeJsonByChainId(paths.priceFeedAddress, chainId, priceFeedAddress);
      console.log("Price feed contract address updated in frontend.");

      // ✅ Update Chapter Implementation Address
      mergeJsonByChainId(paths.chapterImplAddress, chainId, chapterImplAddress);
      console.log("VoxChapter Implementation address updated in frontend.");

      // ✅ Write combined facet addresses file
      mergeJsonByChainId(paths.facetAddresses, chainId, facetAddressMap);
      console.log("Facet addresses updated in frontend.");

    } catch (error) {
      console.error("Error updating addresses:", error);
    }
  }

  async function updateFacetABIs(ABIPaths, diamondAddress, usdcAddress, priceFeedAddress, chapterImplAddress) {
    const facets = [
      { name: "DiamondLoupeFacet", path: ABIPaths.loupe },
      { name: "OwnershipFacet", path: ABIPaths.ownership },
      { name: "VoxFacet", path: ABIPaths.voxMain },
      { name: "VoxTokenFacet", path: ABIPaths.voxToken },
      { name: "VoxGovernanceFacet", path: ABIPaths.voxGovernance },
      { name: "MockUSDC", path: ABIPaths.mockUSDC },
      { name: "MockV3Aggregator", path: ABIPaths.priceFeed },
      { name: "VoxChapter", path: ABIPaths.voxChapter },
      { name: "ChapterLensFacet", path: ABIPaths.chapterLens },
      { name: "VoxAssistantFacet", path: ABIPaths.voxAssistant },
      { name: "GovernanceLensFacet", path: ABIPaths.governanceLens },
      { name: "TokenLensFacet", path: ABIPaths.tokenLens },
    ];

    for (const facet of facets) {
      try {
        // Read ABI as parsed JSON objects from Hardhat artifacts
        const artifact = await artifacts.readArtifact(facet.name);
        fs.writeFileSync(facet.path, JSON.stringify(artifact.abi, null, 2));
        console.log(`ABI for ${facet.name} updated at ${facet.path}`);
      } catch (error) {
        console.error(`Error updating ABI for ${facet.name}:`, error);
      }
    }
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
if (require.main === module) {
  deployDiamond(true)
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error)
      process.exit(1)
    })
}

exports.deployDiamond = deployDiamond
