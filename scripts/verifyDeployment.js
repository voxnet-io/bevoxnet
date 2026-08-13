/* global ethers network */
// Standalone re-verification: reads deployments-<chainId>.json and re-runs
// Etherscan verification for every contract this repo deploys, using the same
// constructor args as scripts/deploy.js. Idempotent — already-verified contracts
// are skipped. Use as a fallback when inline verification failed mid-deploy.
//
//   npm run verify:mainnet          (Polygon mainnet, loads .env.prod)
//   npx hardhat run scripts/verifyDeployment.js --network <net>
const { ethers, network } = require("hardhat");
const fs = require("fs");
const { verify } = require("../utils/verify");

// Facets are all deployed with a single Diamond-address constructor arg.
const FACET_NAMES = [
  "DiamondLoupeFacet",
  "OwnershipFacet",
  "VoxFacet",
  "VoxGovernanceFacet",
  "VoxTokenFacet",
  "ChapterLensFacet",
  "VoxAssistantFacet",
  "GovernanceLensFacet",
  "TokenLensFacet",
];

async function main() {
  const chainId = network.config.chainId;
  const deploymentPath = `deployments-${chainId}.json`;

  if (!fs.existsSync(deploymentPath)) {
    throw new Error(
      `No deployments file at ${deploymentPath}. Deploy to "${network.name}" (chainId ${chainId}) first.`
    );
  }
  if (!process.env.ETHERSCAN_API_KEY) {
    throw new Error(
      "ETHERSCAN_API_KEY is not set — verification cannot run. " +
      "For mainnet, run `npm run verify:mainnet` (loads .env.prod)."
    );
  }

  const { deployer, contracts } = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  if (!contracts || !contracts.Diamond || !contracts.DiamondCutFacet) {
    throw new Error(`${deploymentPath} is missing Diamond/DiamondCutFacet — cannot rebuild constructor args.`);
  }
  const diamond = contracts.Diamond;

  // name -> constructor args. USDC/PriceFeed are intentionally omitted: on mainnet
  // they are external (real USDC / Chainlink) contracts we did not compile.
  const jobs = [];
  const add = (name, args) => {
    const address = contracts[name];
    if (address) jobs.push({ name, address, args });
  };

  add("DiamondCutFacet", []);
  add("Diamond", [deployer, contracts.DiamondCutFacet]);
  add("DiamondInit", []);
  add("VoxChapterImplementation", []);
  for (const facet of FACET_NAMES) add(facet, [diamond]);
  // Mocks only exist on non-mainnet test deploys (args mirror scripts/deploy.js).
  add("MockUSDC", []);
  add("MockV3Aggregator", [8, 50000000]);

  console.log(`Re-verifying ${network.name} (chainId ${chainId}) from ${deploymentPath}\n`);
  const seen = new Set();
  for (const job of jobs) {
    const key = job.address.toLowerCase();
    if (seen.has(key)) continue; // dedupe aliases (e.g. VoxChapter == VoxChapterImplementation)
    seen.add(key);
    console.log(`- ${job.name} @ ${job.address}`);
    await verify(job.address, job.args);
  }
  console.log("\nRe-verification pass complete.");
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
