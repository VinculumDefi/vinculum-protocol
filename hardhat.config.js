// ─────────────────────────────────────────────────────────────────────────────
// hardhat.config.js
// Vinculum Protocol — Hardhat Configuration
//
// Networks configured:
//   - hardhat    (local testing)
//   - base        (Base mainnet)
//   - base-sepolia (Base testnet)
//   - ethereum    (Ethereum mainnet — for Ethereum spoke)
//   - sepolia     (Ethereum testnet)
//   - bnb         (BNB Chain mainnet — for BNB spoke)
//   - bnb-testnet (BNB Chain testnet)
//
// Usage:
//   npx hardhat test
//   npx hardhat run deploy/00_deploy_vinculum.js --network base-sepolia
//   npx hardhat run deploy/00_deploy_vinculum.js --network base
//   npx hardhat verify --network base <contract_address> <constructor_args>
// ─────────────────────────────────────────────────────────────────────────────

require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();

// ── ENVIRONMENT VARIABLES ────────────────────────────────────────────────────
// All sensitive values loaded from .env — never commit .env to GitHub
//
// Required in .env:
//   DEPLOYER_PRIVATE_KEY     — wallet private key for deployment
//   BASE_RPC_URL             — Base mainnet RPC (e.g. from Coinbase Developer Platform)
//   BASE_SEPOLIA_RPC_URL     — Base Sepolia testnet RPC
//   ETHEREUM_RPC_URL         — Ethereum mainnet RPC (e.g. Alchemy/Infura)
//   SEPOLIA_RPC_URL          — Sepolia testnet RPC
//   BNB_RPC_URL              — BNB Chain mainnet RPC
//   BNB_TESTNET_RPC_URL      — BNB Chain testnet RPC
//   BASESCAN_API_KEY         — for contract verification on Basescan
//   ETHERSCAN_API_KEY        — for contract verification on Etherscan
//   BSCSCAN_API_KEY          — for contract verification on BscScan

const DEPLOYER_KEY       = process.env.DEPLOYER_PRIVATE_KEY  || "0x" + "0".repeat(64);
const BASE_RPC           = process.env.BASE_RPC_URL           || "https://mainnet.base.org";
const BASE_SEPOLIA_RPC   = process.env.BASE_SEPOLIA_RPC_URL   || "https://sepolia.base.org";
const ETHEREUM_RPC       = process.env.ETHEREUM_RPC_URL       || "https://eth.llamarpc.com";
const SEPOLIA_RPC        = process.env.SEPOLIA_RPC_URL        || "https://rpc.sepolia.org";
const BNB_RPC            = process.env.BNB_RPC_URL            || "https://bsc-dataseed.binance.org";
const BNB_TESTNET_RPC    = process.env.BNB_TESTNET_RPC_URL    || "https://data-seed-prebsc-1-s1.binance.org:8545";

const BASESCAN_KEY       = process.env.BASESCAN_API_KEY       || "";
const ETHERSCAN_KEY      = process.env.ETHERSCAN_API_KEY      || "";
const BSCSCAN_KEY        = process.env.BSCSCAN_API_KEY        || "";

// ── CONFIG ───────────────────────────────────────────────────────────────────

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {

  // ── SOLIDITY ───────────────────────────────────────────────────────────────
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true, // required for complex contracts to avoid stack too deep
      evmVersion: "cancun",
    },
  },

  // ── NETWORKS ───────────────────────────────────────────────────────────────
  networks: {

    // Local hardhat network — used for all tests
    hardhat: {
      chainId: 31337,
      gas: "auto",
      gasPrice: "auto",
      // Fork Base mainnet for integration tests (optional)
      // Uncomment to test against real on-chain state:
      // forking: {
      //   url: BASE_RPC,
      //   blockNumber: 28000000, // pin to specific block for reproducibility
      // },
    },

    // ── BASE ─────────────────────────────────────────────────────────────────
    // Home chain — canonical VCLM deployment
    "base": {
      url:      BASE_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  8453,
      gasPrice: "auto",
      verify: {
        etherscan: {
          apiUrl: "https://api.basescan.org",
          apiKey: BASESCAN_KEY,
        },
      },
    },

    "base-sepolia": {
      url:      BASE_SEPOLIA_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  84532,
      gasPrice: "auto",
    },

    // ── ETHEREUM ──────────────────────────────────────────────────────────────
    // Spoke chain — ETH, USDC, USDT, SHIB, LUNC, VOLT, KEKEC
    "ethereum": {
      url:      ETHEREUM_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  1,
      gasPrice: "auto",
    },

    "sepolia": {
      url:      SEPOLIA_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  11155111,
      gasPrice: "auto",
    },

    // ── BNB CHAIN ─────────────────────────────────────────────────────────────
    // Spoke chain — SHIB, LUNC, WKC
    "bnb": {
      url:      BNB_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  56,
      gasPrice: ethers.parseUnits("3", "gwei"), // BNB typically 3 gwei
    },

    "bnb-testnet": {
      url:      BNB_TESTNET_RPC,
      accounts: [DEPLOYER_KEY],
      chainId:  97,
      gasPrice: "auto",
    },
  },

  // ── CONTRACT VERIFICATION ─────────────────────────────────────────────────
  etherscan: {
    apiKey: {
      base:           BASESCAN_KEY,
      baseSepolia:    BASESCAN_KEY,
      mainnet:        ETHERSCAN_KEY,
      sepolia:        ETHERSCAN_KEY,
      bsc:            BSCSCAN_KEY,
      bscTestnet:     BSCSCAN_KEY,
    },
    customChains: [
      {
        network:  "base",
        chainId:  8453,
        urls: {
          apiURL:     "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network:  "baseSepolia",
        chainId:  84532,
        urls: {
          apiURL:     "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
    ],
  },

  // ── GAS REPORTER ─────────────────────────────────────────────────────────
  // Uncomment to see gas usage per function during tests
  // Useful before audit to identify expensive operations
  // gasReporter: {
  //   enabled:      true,
  //   currency:     "USD",
  //   coinmarketcap: process.env.CMC_API_KEY,
  //   token:        "ETH",
  //   gasPriceApi:  "https://api.etherscan.io/api?module=proxy&action=eth_gasPrice",
  //   outputFile:   "gas-report.txt",
  //   noColors:     true,
  // },

  // ── PATHS ─────────────────────────────────────────────────────────────────
  paths: {
    sources:   "./contracts",
    tests:     "./test",
    cache:     "./cache",
    artifacts: "./artifacts",
  },

  // ── MOCHA ─────────────────────────────────────────────────────────────────
  mocha: {
    timeout: 120000, // 2 minutes — needed for time.increase() tests
  },
};
