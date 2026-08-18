/**
 * Comprehensive test suite for VoxTokenFacet
 *
 * This suite verifies:
 * - Initialization and token minting
 * - Token transfer mechanics
 * - Flash loan protection (2-block cooldown)
 * - Oracle address management (USDC, price feed, OpenAdverts)
 * - Token metadata and view functions
 * - Reward distribution (POL and USDC)
 * - OpenAdverts integration
 * - Edge cases and security validations
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { mine } = require("@nomicfoundation/hardhat-network-helpers");

// Hardhat test account #0
const GOVERNANCE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOVERNANCE_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

describe("VoxTokenFacet - Initialization", function () {
  let deployer, owner, user, other;
  let tokenFacet, governanceFacet, diamond, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [deployer, owner, user, other] = await ethers.getSigners();

    // Deploy mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    // Deploy Diamond
    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    // Deploy facets
    const FacetNames = [
      "DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];

    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      // Ã¢Å“â€¦ FIXED: Pass contract directly, no wrapper
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());
  });

  /**
   * Test: Successful initialization
   * 
   * Verifies that:
   * 1. Token is initialized with correct name, symbol, decimals
   * 2. Total supply is minted to owner
   * 3. Oracle addresses are set correctly
   * 4. Initialization flag is set
   */
  it("initializes successfully with valid addresses", async () => {

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    const name = await tokenFacet.name();
    const symbol = await tokenFacet.symbol();
    const decimals = await tokenFacet.decimals();
    expect(name).to.equal("Vox");
    expect(symbol).to.equal("VOX");
    expect(decimals).to.equal(18);

    const totalSupply = await tokenFacet.totalSupply();
    const expectedSupply = ethers.parseEther("21000000"); // 100M tokens
    expect(totalSupply).to.equal(expectedSupply);

    const ownerBalance = await tokenFacet.balanceOf(await owner.getAddress());
    expect(ownerBalance).to.equal(expectedSupply);

    const usdcAddress = await tokenFacet.getUSDCAddress();
    const priceFeedAddress = await tokenFacet.getPriceFeedAddress();

    expect(usdcAddress).to.equal(await mockUSDC.getAddress());
    expect(priceFeedAddress).to.equal(await mockPriceFeed.getAddress());

  });

  /**
   * Test: Double initialization prevention
   */
  it("prevents double initialization", async () => {

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    await expect(
      tokenFacet.connect(owner).initialize(
        await diamond.getAddress(),
        await mockUSDC.getAddress(),
        await mockPriceFeed.getAddress(),
        "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
      )
    ).to.be.revertedWith("Already initialized");

  });

  /**
   * Test: Owner-only initialization
   */
  it("only allows owner to initialize", async () => {

    await expect(
      tokenFacet.connect(user).initialize(
        await diamond.getAddress(),
        await mockUSDC.getAddress(),
        await mockPriceFeed.getAddress(),
        "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
      )
    ).to.be.revertedWith("LibDiamond: Must be contract owner");

  });

  /**
   * Test: Zero address validation
   */
  it("rejects zero addresses during initialization", async () => {

    await expect(
      tokenFacet.connect(owner).initialize(
        await diamond.getAddress(),
        ethers.ZeroAddress,
        await mockPriceFeed.getAddress(),
        "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
      )
    ).to.be.reverted;

    await expect(
      tokenFacet.connect(owner).initialize(
        await diamond.getAddress(),
        await mockUSDC.getAddress(),
        ethers.ZeroAddress,
        "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
      )
    ).to.be.reverted;

  });
});

describe("VoxTokenFacet - Token Transfers", function () {
  let deployer, owner, user, other, recipient;
  let tokenFacet, governanceFacet, diamond, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [deployer, owner, user, other, recipient] = await ethers.getSigners();

    // Deploy and setup (same as previous beforeEach)
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = [
      "DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];

    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());

    // Initialize token facet
    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    // Initialize governance facet
    const quotas = {
      voxClaimPercentage: 20,
      viewerClaimPercentage: 20,
      thirdParty1ClaimPercentage: 20,
      thirdParty2ClaimPercentage: 20,
      thirdParty3ClaimPercentage: 20,
      thirdParty4ClaimPercentage: 0,
      thirdParty5ClaimPercentage: 0,
      thirdParty6ClaimPercentage: 0,
      voxAdminClaimPercentage: 10,
      voxAdminChangeQuorum: 51,
      QuotaProposalQuorum: 51,
      FacetProposalQuorum: 51,
      storageProviderPercentage: 1,
      adminApplicantFeeInPolWei: ethers.parseEther("100"),
      adminVoteDeadlineInBlocks: 100,
      minQuotaProposalDuration: 43200,        // Ã¢Å“â€¦ ADDED
      maxQuotaProposalDuration: 1296000,      // Ã¢Å“â€¦ ADDED
      minFacetProposalDuration: 43200,        // Ã¢Å“â€¦ ADDED
      maxFacetProposalDuration: 1296000       // Ã¢Å“â€¦ ADDED
    };

    await (await governanceFacet.connect(owner).initialize(
      quotas,
      GOVERNANCE_ADDRESS,
      await owner.getAddress()
    )).wait();

    // Clear flash loan protection from initialization
    await mine(3);
  });

  /**
   * Test: Basic transfer
   */
  it("transfers tokens successfully", async () => {

    const transferAmount = ethers.parseEther("1000");

    const ownerBalanceBefore = await tokenFacet.balanceOf(await owner.getAddress());
    const userBalanceBefore = await tokenFacet.balanceOf(await user.getAddress());

    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), transferAmount)).wait();

    const ownerBalanceAfter = await tokenFacet.balanceOf(await owner.getAddress());
    const userBalanceAfter = await tokenFacet.balanceOf(await user.getAddress());
    
    expect(ownerBalanceAfter).to.equal(ownerBalanceBefore - transferAmount);
    expect(userBalanceAfter).to.equal(userBalanceBefore + transferAmount);

  });

  /**
   * Test: Flash loan protection on transfer
   */
  it("records transfer block for flash loan protection", async () => {

    const transferAmount = ethers.parseEther("1000");

    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), transferAmount)).wait();

    const canVote = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVote).to.equal(false);

    await mine(2);

    const canVoteAfter = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteAfter).to.equal(true);

  });

  /**
   * Test: First-time recipient initialization
   */
  it("initializes reward tracking for first-time recipients", async () => {

    const transferAmount = ethers.parseEther("1000");

    const recipientBalance = await tokenFacet.balanceOf(await recipient.getAddress());
    expect(recipientBalance).to.equal(0);

    await (await tokenFacet.connect(owner).transfer(await recipient.getAddress(), transferAmount)).wait();

    const recipientBalanceAfter = await tokenFacet.balanceOf(await recipient.getAddress());
    expect(recipientBalanceAfter).to.equal(transferAmount);

  });

  /**
   * Test: Transfer validations
   */
  it("validates transfer requirements", async () => {

    await expect(
      tokenFacet.connect(owner).transfer(ethers.ZeroAddress, ethers.parseEther("1000"))
    ).to.be.revertedWith("ERC20: Invalid receiver address"); // CHANGED ERROR MESSAGE

    const totalSupply = await tokenFacet.totalSupply();
    const excessAmount = totalSupply + 1n;

    await expect(
      tokenFacet.connect(owner).transfer(await user.getAddress(), excessAmount)
    ).to.be.revertedWith("Amount exceeds account balance");

  });

  /**
   * Test: Transfer to self
   */
  it("allows transfer to self", async () => {

    const transferAmount = ethers.parseEther("1000");

    const balanceBefore = await tokenFacet.balanceOf(await owner.getAddress());

    await (await tokenFacet.connect(owner).transfer(await owner.getAddress(), transferAmount)).wait();

    const balanceAfter = await tokenFacet.balanceOf(await owner.getAddress());
    expect(balanceAfter).to.equal(balanceBefore);

  });

  /**
   * Test: Zero amount transfer
   */
  it("allows zero amount transfer", async () => {

    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), 0)).wait();

    const userBalance = await tokenFacet.balanceOf(await user.getAddress());
    expect(userBalance).to.equal(0);

  });
});

describe("VoxTokenFacet - Flash Loan Protection", function () {
  let deployer, owner, user, other;
  let tokenFacet, governanceFacet, diamond, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [deployer, owner, user, other] = await ethers.getSigners();

    // Full setup (same as previous test suites)
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = [
      "DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];

    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      // Ã¢Å“â€¦ FIXED: Pass contract directly, no wrapper
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    // Ã¢Å“â€¦ FIXED: Add missing quota fields
    const quotas = {
      voxClaimPercentage: 20,
      viewerClaimPercentage: 20,
      thirdParty1ClaimPercentage: 20,
      thirdParty2ClaimPercentage: 20,
      thirdParty3ClaimPercentage: 20,
      thirdParty4ClaimPercentage: 0,
      thirdParty5ClaimPercentage: 0,
      thirdParty6ClaimPercentage: 0,
      voxAdminClaimPercentage: 10,
      voxAdminChangeQuorum: 51,
      QuotaProposalQuorum: 51,
      FacetProposalQuorum: 51,
      storageProviderPercentage: 1,
      adminApplicantFeeInPolWei: ethers.parseEther("100"),
      adminVoteDeadlineInBlocks: 100,
      minQuotaProposalDuration: 43200,        // Ã¢Å“â€¦ ADDED
      maxQuotaProposalDuration: 1296000,      // Ã¢Å“â€¦ ADDED
      minFacetProposalDuration: 43200,        // Ã¢Å“â€¦ ADDED
      maxFacetProposalDuration: 1296000       // Ã¢Å“â€¦ ADDED
    };

    await (await governanceFacet.connect(owner).initialize(
      quotas,
      GOVERNANCE_ADDRESS,
      await owner.getAddress()
    )).wait();

    await mine(3);
  });

  /**
   * Test: canVoteThisBlock function
   */
  it("canVoteThisBlock returns correct status", async () => {

    const canVoteBefore = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteBefore).to.equal(true);

    await (await tokenFacet.connect(user).recordVoteActivity(await user.getAddress())).wait(); // user calls for themselves

    const canVoteAfter = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteAfter).to.equal(false);

    await mine(2);

    const canVoteAfterCooldown = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteAfterCooldown).to.equal(true);

  });

  /**
   * Test: recordVoteActivity function
   */
  it("recordVoteActivity updates last vote block", async () => {

    const currentBlock = await ethers.provider.getBlockNumber();

    await (await tokenFacet.connect(user).recordVoteActivity(await user.getAddress())).wait(); // user calls for themselves

    const canVote = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVote).to.equal(false);

  });

  /**
   * Test: Transfer triggers flash loan protection
   */
  it("transfer triggers flash loan protection for both sender and recipient", async () => {

    const transferAmount = ethers.parseEther("1000");

    const ownerCanVoteBefore = await tokenFacet.canVoteThisBlock(await owner.getAddress());
    const userCanVoteBefore = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(ownerCanVoteBefore).to.equal(true);
    expect(userCanVoteBefore).to.equal(true);

    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), transferAmount)).wait();

    const ownerCanVoteAfter = await tokenFacet.canVoteThisBlock(await owner.getAddress());
    const userCanVoteAfter = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(ownerCanVoteAfter).to.equal(false);
    expect(userCanVoteAfter).to.equal(false);

  });

  /**
   * Test: 2-block cooldown period
   */
  it("enforces 2-block cooldown after transfer", async () => {

    const transferAmount = ethers.parseEther("1000");

    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), transferAmount)).wait();

    await mine(1);
    const canVoteAfter1Block = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteAfter1Block).to.equal(false);

    await mine(1);
    const canVoteAfter2Blocks = await tokenFacet.canVoteThisBlock(await user.getAddress());
    expect(canVoteAfter2Blocks).to.equal(true);

  });
});

describe("VoxTokenFacet - Oracle Address Management", function () {
  let deployer, owner, user;
  let tokenFacet, diamond, mockUSDC, mockPriceFeed, mockUSDC2, mockPriceFeed2;

  beforeEach(async () => {
    [deployer, owner, user] = await ethers.getSigners();

    // Deploy mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();
    mockUSDC2 = await MockUSDC.deploy();
    await mockUSDC2.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();
    mockPriceFeed2 = await MockV3Aggregator.deploy(8, 60000000);
    await mockPriceFeed2.waitForDeployment();

    // Setup diamond (abbreviated)
    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxTokenFacet"];
    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      // Ã¢Å“â€¦ FIXED: Pass contract directly, no wrapper
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();
  });

  /**
   * Test: Set USDC address (owner only)
   */
  it("allows owner to set USDC address", async () => {

    const currentUSDC = await tokenFacet.getUSDCAddress();

    expect(currentUSDC).to.equal(await mockUSDC.getAddress());

    const newUSDCAddress = await mockUSDC2.getAddress();

    await (await tokenFacet.connect(owner).setUSDCAddress(newUSDCAddress)).wait();

    const updatedUSDC = await tokenFacet.getUSDCAddress();

    expect(updatedUSDC).to.equal(newUSDCAddress);

  });

  /**
   * Test: Set price feed address (owner only)
   */
  it("allows owner to set price feed address", async () => {

    const currentPriceFeed = await tokenFacet.getPriceFeedAddress();

    expect(currentPriceFeed).to.equal(await mockPriceFeed.getAddress());

    const newPriceFeedAddress = await mockPriceFeed2.getAddress();

    await (await tokenFacet.connect(owner).setPriceFeedAddress(newPriceFeedAddress)).wait();

    const updatedPriceFeed = await tokenFacet.getPriceFeedAddress();

    expect(updatedPriceFeed).to.equal(newPriceFeedAddress);

  });

  /**
   * Test: Non-owner cannot set addresses
   */
  it("prevents non-owner from setting oracle addresses", async () => {

    await expect(
      tokenFacet.connect(user).setUSDCAddress(await mockUSDC2.getAddress())
    ).to.be.revertedWith("LibDiamond: Must be contract owner");

    await expect(
      tokenFacet.connect(user).setPriceFeedAddress(await mockPriceFeed2.getAddress())
    ).to.be.revertedWith("LibDiamond: Must be contract owner");

  });

  /**
   * Test: Zero address validation for oracle updates
   */
  it("rejects zero addresses for oracle updates", async () => {

    await expect(
      tokenFacet.connect(owner).setUSDCAddress(ethers.ZeroAddress)
    ).to.be.reverted;

    await expect(
      tokenFacet.connect(owner).setPriceFeedAddress(ethers.ZeroAddress)
    ).to.be.reverted;

  });
});

describe("VoxTokenFacet - Token Metadata", function () {
  let owner, diamond, tokenFacet, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [owner] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxTokenFacet"];
    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      // Ã¢Å“â€¦ FIXED: Pass contract directly, no wrapper
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();
  });

  /**
   * Test: Token metadata getters
   */
  it("returns correct token metadata", async () => {

    const name = await tokenFacet.name();
    expect(name).to.equal("Vox");

    const symbol = await tokenFacet.symbol();
    expect(symbol).to.equal("VOX");

    const decimals = await tokenFacet.decimals();
    expect(decimals).to.equal(18);

    const totalSupply = await tokenFacet.totalSupply();
    const expectedSupply = ethers.parseEther("21000000");
    expect(totalSupply).to.equal(expectedSupply);

  });

  /**
   * Test: Balance queries
   */
  it("balanceOf returns correct balances", async () => {

    const ownerBalance = await tokenFacet.balanceOf(await owner.getAddress());
    const expectedBalance = ethers.parseEther("21000000");
    expect(ownerBalance).to.equal(expectedBalance);

    const zeroBalance = await tokenFacet.balanceOf(ethers.ZeroAddress);
    expect(zeroBalance).to.equal(0);

  });
});

describe("VoxTokenFacet - Reward Distribution", function () {
  let owner, user, user2, diamond, tokenFacet, governanceFacet, voxFacet, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [owner, user, user2] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];
    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());
    voxFacet = await ethers.getContractAt("VoxFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    const quotas = {
      voxClaimPercentage: 20,
      viewerClaimPercentage: 20,
      thirdParty1ClaimPercentage: 20,
      thirdParty2ClaimPercentage: 20,
      thirdParty3ClaimPercentage: 20,
      thirdParty4ClaimPercentage: 0,
      thirdParty5ClaimPercentage: 0,
      thirdParty6ClaimPercentage: 0,
      voxAdminClaimPercentage: 10,
      voxAdminChangeQuorum: 51,
      QuotaProposalQuorum: 51,
      FacetProposalQuorum: 51,
      storageProviderPercentage: 1,
      adminApplicantFeeInPolWei: ethers.parseEther("100"),
      adminVoteDeadlineInBlocks: 100,
      minQuotaProposalDuration: 43200,
      maxQuotaProposalDuration: 1296000,
      minFacetProposalDuration: 43200,
      maxFacetProposalDuration: 1296000
    };

    await (await governanceFacet.connect(owner).initialize(
      quotas,
      GOVERNANCE_ADDRESS,
      await owner.getAddress()
    )).wait();

    await mine(3);
  });

  it("routes storage-provider USDC to storageProviderAddress and keeps the deposit watermark synced", async () => {
    // Use a dedicated storage-provider destination distinct from the owner.
    await (await governanceFacet.connect(owner).setStorageProviderAddress(user2.address)).wait();

    const diamondAddr = await diamond.getAddress();
    const oneUSDC = 1_000_000n; // 6 decimals
    const D1 = 100n * oneUSDC;

    // Deposit D1 USDC, then trigger deposit detection via a VOX transfer (runs _accrue).
    await (await mockUSDC.connect(owner).transfer(diamondAddr, D1)).wait();
    await (await tokenFacet.connect(owner).transfer(user.address, ethers.parseEther("1000"))).wait();

    const [, trancheUSDC1] = await tokenFacet.getStorageProviderTranche();
    expect(trancheUSDC1).to.equal(D1 / 100n); // 1% storage-provider cut

    // Withdraw the full USDC tranche: it must go to storageProviderAddress (user2), not the owner.
    const spBefore = await mockUSDC.balanceOf(user2.address);
    await (await tokenFacet.connect(owner).withdrawStorageProviderFunds(0, trancheUSDC1)).wait();
    expect((await mockUSDC.balanceOf(user2.address)) - spBefore).to.equal(trancheUSDC1);

    const [, trancheUSDCAfter] = await tokenFacet.getStorageProviderTranche();
    expect(trancheUSDCAfter).to.equal(0n);

    // Second deposit must be fully detected (proves the watermark was synced by the withdrawal).
    const D2 = 50n * oneUSDC;
    await (await mockUSDC.connect(owner).transfer(diamondAddr, D2)).wait();
    await (await tokenFacet.connect(owner).transfer(user.address, ethers.parseEther("1000"))).wait();

    const [, trancheUSDC2] = await tokenFacet.getStorageProviderTranche();
    expect(trancheUSDC2).to.equal(D2 / 100n); // full 1% of D2, not under-counted
  });

  /**
   * Test: calculateRewardPOL returns zero for accounts with no balance
   */
  it("calculates zero POL rewards for accounts with no balance", async () => {
    const reward = await tokenFacet.calculateRewardPOL(await user.getAddress());
    expect(reward).to.equal(0);
  });

  /**
   * Test: calculateRewardUSDC returns zero for accounts with no balance
   */
  it("calculates zero USDC rewards for accounts with no balance", async () => {
    const reward = await tokenFacet.calculateRewardUSDC(await user.getAddress());
    expect(reward).to.equal(0);
  });

  /**
   * Test: POL reward calculation after receiving revenue
   */
  it("calculates POL rewards proportionally based on token holdings", async () => {
    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), ethers.parseEther("2100000"))).wait();
    await mine(3);

    const revenueAmount = ethers.parseEther("10");
    await owner.sendTransaction({
      to: await diamond.getAddress(),
      value: revenueAmount
    });

    const userReward = await tokenFacet.calculateRewardPOL(await user.getAddress());
    const ownerReward = await tokenFacet.calculateRewardPOL(await owner.getAddress());

    expect(userReward).to.be.gt(0);
    expect(ownerReward).to.be.gt(0);
  });

  /**
   * Test: Pull-model reward claim
   */
  it("distributes POL rewards when user calls claimRewards()", async () => {
    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), ethers.parseEther("2100000"))).wait();
    await mine(3);

    const revenueAmount = ethers.parseEther("5");
    await owner.sendTransaction({
      to: await diamond.getAddress(),
      value: revenueAmount
    });

    const userBalanceBefore = await ethers.provider.getBalance(await user.getAddress());
    
    await (await tokenFacet.connect(user).claimRewards()).wait();

    const userBalanceAfter = await ethers.provider.getBalance(await user.getAddress());
    expect(userBalanceAfter).to.be.gt(userBalanceBefore);
  });



  /**
   * Test: Multiple users receive proportional rewards
   */
  it("distributes rewards proportionally to multiple holders", async () => {
    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), ethers.parseEther("10500000"))).wait();
    await (await tokenFacet.connect(owner).transfer(await user2.getAddress(), ethers.parseEther("5250000"))).wait();
    await mine(3);

    const revenueAmount = ethers.parseEther("30");
    await owner.sendTransaction({
      to: await diamond.getAddress(),
      value: revenueAmount
    });

    const ownerReward = await tokenFacet.calculateRewardPOL(await owner.getAddress());
    const userReward = await tokenFacet.calculateRewardPOL(await user.getAddress());
    const user2Reward = await tokenFacet.calculateRewardPOL(await user2.getAddress());

    expect(userReward).to.be.approximately(ownerReward * 2n, ethers.parseEther("0.1"));
    expect(user2Reward).to.be.approximately(ownerReward, ethers.parseEther("0.1"));
  });
});

describe("VoxTokenFacet - OpenAdverts Integration", function () {
  let owner, user, diamond, tokenFacet, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxTokenFacet"];
    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();
  });

  /**
   * Test: Set OpenAdverts contract address (owner only)
   */
  it("allows owner to set OpenAdverts contract address", async () => {
    const currentOpenAdverts = await tokenFacet.getOpenAdvertsContractAddress();
    expect(currentOpenAdverts).to.equal("0x5FC8d32690cc91D4c39d9d3abcBD16989F875707");

    const newOpenAdvertsAddress = await user.getAddress();
    await (await tokenFacet.connect(owner).setOpenAdvertsContractAddress(newOpenAdvertsAddress)).wait();

    const updatedOpenAdverts = await tokenFacet.getOpenAdvertsContractAddress();
    expect(updatedOpenAdverts).to.equal(newOpenAdvertsAddress);
  });

  /**
   * Test: Non-owner cannot set OpenAdverts address
   */
  it("prevents non-owner from setting OpenAdverts address", async () => {
    await expect(
      tokenFacet.connect(user).setOpenAdvertsContractAddress(await user.getAddress())
    ).to.be.revertedWith("LibDiamond: Must be contract owner");
  });

  /**
   * Test: Rejects zero address for OpenAdverts
   */
  it("rejects zero address for OpenAdverts contract", async () => {
    await expect(
      tokenFacet.connect(owner).setOpenAdvertsContractAddress(ethers.ZeroAddress)
    ).to.be.reverted;
  });

});

describe("VoxTokenFacet - View Functions", function () {
  let owner, user, diamond, tokenFacet, governanceFacet, voxFacet, mockUSDC, mockPriceFeed;

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    mockPriceFeed = await MockV3Aggregator.deploy(8, 50000000);
    await mockPriceFeed.waitForDeployment();

    const { getSelectors, FacetCutAction } = require("../scripts/libraries/diamond.js");

    const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
    const diamondCutFacet = await DiamondCutFacet.deploy();
    await diamondCutFacet.waitForDeployment();

    const Diamond = await ethers.getContractFactory("Diamond");
    diamond = await Diamond.deploy(await owner.getAddress(), await diamondCutFacet.getAddress());
    await diamond.waitForDeployment();

    const DiamondInit = await ethers.getContractFactory("DiamondInit");
    const diamondInit = await DiamondInit.deploy();
    await diamondInit.waitForDeployment();

    const FacetNames = ["DiamondLoupeFacet", "OwnershipFacet", "VoxFacet", "VoxGovernanceFacet", "VoxTokenFacet", "GovernanceLensFacet", "VoxAssistantFacet", "TokenLensFacet"];
    const cut = [];
    for (const FacetName of FacetNames) {
      const Facet = await ethers.getContractFactory(FacetName);
      const facetInstance = await Facet.deploy(await diamond.getAddress());
      await facetInstance.waitForDeployment();
      
      cut.push({
        facetAddress: await facetInstance.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facetInstance)
      });
    }

    const diamondCut = await ethers.getContractAt("IDiamondCut", await diamond.getAddress());
    const functionCall = diamondInit.interface.encodeFunctionData("init");
    await (await diamondCut.connect(owner).diamondCut(cut, await diamondInit.getAddress(), functionCall)).wait();

    tokenFacet = await ethers.getContractAt("VoxTokenFacet", await diamond.getAddress());
    governanceFacet = await ethers.getContractAt("VoxGovernanceFacet", await diamond.getAddress());
    voxFacet = await ethers.getContractAt("VoxFacet", await diamond.getAddress());

    await (await tokenFacet.connect(owner).initialize(
      await diamond.getAddress(),
      await mockUSDC.getAddress(),
      await mockPriceFeed.getAddress(),
      "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"
    )).wait();

    const quotas = {
      voxClaimPercentage: 20,
      viewerClaimPercentage: 20,
      thirdParty1ClaimPercentage: 20,
      thirdParty2ClaimPercentage: 20,
      thirdParty3ClaimPercentage: 20,
      thirdParty4ClaimPercentage: 0,
      thirdParty5ClaimPercentage: 0,
      thirdParty6ClaimPercentage: 0,
      voxAdminClaimPercentage: 10,
      voxAdminChangeQuorum: 51,
      QuotaProposalQuorum: 51,
      FacetProposalQuorum: 51,
      storageProviderPercentage: 1,
      adminApplicantFeeInPolWei: ethers.parseEther("100"),
      adminVoteDeadlineInBlocks: 100,
      minQuotaProposalDuration: 43200,
      maxQuotaProposalDuration: 1296000,
      minFacetProposalDuration: 43200,
      maxFacetProposalDuration: 1296000
    };

    await (await governanceFacet.connect(owner).initialize(
      quotas,
      GOVERNANCE_ADDRESS,
      await owner.getAddress()
    )).wait();

    await mine(3);
  });

  /**
   * Test: getTotalValue returns contract POL balance
   */
  it("returns total POL value held by contract", async () => {
    const revenueAmount = ethers.parseEther("15");
    await owner.sendTransaction({
      to: await diamond.getAddress(),
      value: revenueAmount
    });

    const totalValue = await tokenFacet.getTotalValue();
    expect(totalValue).to.be.gt(0);
  });

  /**
   * Test: getTotalValueAndRewardDue returns comprehensive data
   */
  it("returns total value and individual reward amounts", async () => {
    await (await tokenFacet.connect(owner).transfer(await user.getAddress(), ethers.parseEther("2100000"))).wait();
    await mine(3);

    const revenueAmount = ethers.parseEther("20");
    await owner.sendTransaction({
      to: await diamond.getAddress(),
      value: revenueAmount
    });

    const [totalPOL, totalUSDC, polReward, usdcReward] = await tokenFacet.connect(user).getTotalValueAndRewardDue();

    expect(totalPOL).to.be.gt(0);
    expect(polReward).to.be.gt(0);
    expect(totalUSDC).to.equal(0);
    expect(usdcReward).to.equal(0);
  });

  /**
   * Test: getClaimPercentages returns governance quotas
   */
  it("returns claim percentages from governance", async () => {
    const [affiliate, viewer, tpCount, thirdParties] = await tokenFacet.getClaimPercentages();

    expect(affiliate).to.equal(20);
    expect(viewer).to.equal(20);
    expect(tpCount).to.equal(3);
    expect(thirdParties[0]).to.equal(20);
    expect(thirdParties[1]).to.equal(20);
    expect(thirdParties[2]).to.equal(20);
  });

  /**
   * Test: getOpenAdvertsContractAddress returns correct address
   */
  it("returns OpenAdverts contract address", async () => {
    const openAdvertsAddress = await tokenFacet.getOpenAdvertsContractAddress();
    expect(openAdvertsAddress).to.equal("0x5FC8d32690cc91D4c39d9d3abcBD16989F875707");
  });
});

