/* global ethers task */
require('@nomicfoundation/hardhat-toolbox')
require("dotenv").config();
require("hardhat-contract-sizer");

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task('accounts', 'Prints the list of accounts', async () => {
  const accounts = await ethers.getSigners()

  for (const account of accounts) {
    console.log(account.address)
  }
})

const POLYGON_RPC_URL = process.env.POLYGON_RPC_URL;
const AMOY_RPC_URL = process.env.AMOY_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const PRIVATEKEYMAINNET = process.env.PRIVATEKEYMAINNET;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY;
const INFURA_API_KEY = process.env.INFURA_API_KEY;

// Only use a key if it looks like a valid 64-char hex string. Guarded so the
// config loads cleanly even when no secrets are present (e.g. in CI / compile).
const isHexKey = (k) => typeof k === "string" && /^[0-9a-fA-F]{64}$/.test(k.replace(/^0x/, ""));
// Testnet / dev key (sepolia, amoy). Mainnet uses a dedicated, separate EOA.
const testnetAccounts = isHexKey(PRIVATE_KEY) ? [PRIVATE_KEY] : [];
// Dedicated Polygon mainnet owner key — NEVER reuse the testnet/dev key here.
const mainnetAccounts = isHexKey(PRIVATEKEYMAINNET) ? [PRIVATEKEYMAINNET] : [];

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: "0.8.22",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      // Keep user-supplied require strings; omit compiler-generated debug strings
      // to reduce mainnet bytecode size and deploy gas.
      debug: {
        revertStrings: "default"
      }
    }
  },
  networks: {
    sepolia: {
      url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
      accounts: testnetAccounts,
      chainId: 11155111,
    },
    hardhat: {
      chainId: 1337, // default is 31337
      initialBaseFeePerGas: 0,
      allowUnlimitedContractSize: true, // hardhat network only; real nets enforce the 24.576KiB EIP-170 limit
    },
    polygon: {
      url: POLYGON_RPC_URL || "https://polygon-rpc.com",
      accounts: mainnetAccounts, // dedicated mainnet owner key (PRIVATEKEYMAINNET) — never the dev key
      chainId: 137,
    },
    amoy: {
      url: AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
      accounts: testnetAccounts,
      chainId: 80002,
    },
    localhost: {
      url: "http://127.0.0.1:8545/",
      chainId: 1337,
    },
  },
  // Etherscan V2 unified API: one key verifies all chains (incl. Polygon) via chainid.
  etherscan: {
    apiKey: ETHERSCAN_API_KEY || "",
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    outputFile: "gas-report.txt",
    noColors: true,
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: false, // warn only — VoxGovernanceFacet (~23.2KiB) is closest to the 24.576KiB limit
  },
}
