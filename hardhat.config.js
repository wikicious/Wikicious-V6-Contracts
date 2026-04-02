require('@nomicfoundation/hardhat-toolbox');
require('dotenv').config();


// ─── REQUIRED ENV VARS ────────────────────────────────────────────────────────
// Copy .env.example to .env and fill in before running any hardhat command.
// For CI/CD: set these as GitHub Actions secrets (see .github/workflows/).
// If your environment requires an outbound proxy for compiler downloads,
// set HTTPS_PROXY/HTTP_PROXY before running hardhat compile.
const DEPLOYER_KEY      = process.env.DEPLOYER_PRIVATE_KEY || '0'.repeat(64);
const ALCHEMY_ARBITRUM  = process.env.ALCHEMY_ARBITRUM_URL;
const ALCHEMY_SEPOLIA   = process.env.ALCHEMY_SEPOLIA_URL;
const TENDERLY_RPC      = process.env.TENDERLY_RPC_URL;
const ETHERSCAN_KEY     = process.env.ETHERSCAN_API_KEY;
const SOURCE_DIR        = process.env.CONTRACT_SOURCES_DIR || './src';

if (!ALCHEMY_ARBITRUM && process.env.HARDHAT_NETWORK === 'arbitrum_one') {
  throw new Error('ALCHEMY_ARBITRUM_URL is required in .env for mainnet deployment');
}

module.exports = {
  solidity: {
    version: '0.8.26',
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: 'cancun',
    },
  },   
  paths: {
    sources: SOURCE_DIR,
  },
  networks: {
    // ── Mainnet ──────────────────────────────────────────────────────────────
    arbitrum_one: {
      url:      ALCHEMY_ARBITRUM || 'https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY_HERE',
      accounts: [DEPLOYER_KEY],
      chainId:  42161,
      gasPrice: 'auto',
    },
    // ── Testnet ──────────────────────────────────────────────────────────────
    arbitrum_sepolia: {
      url:      ALCHEMY_SEPOLIA  || 'https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY_HERE',
      accounts: [DEPLOYER_KEY],
      chainId:  421614,
    },
    // ── Tenderly Simulation ───────────────────────────────────────────────────
    tenderly: {
      url:      TENDERLY_RPC     || 'https://arbitrum.gateway.tenderly.co/YOUR_KEY_HERE',
      accounts: [DEPLOYER_KEY],
      chainId:  42161,
    },
  },
  // ── Arbiscan verification ─────────────────────────────────────────────────
  etherscan: {
    apiKey: {
      arbitrumOne:     ETHERSCAN_KEY || 'YOUR_ARBISCAN_KEY_HERE',
      arbitrumSepolia: ETHERSCAN_KEY || 'YOUR_ARBISCAN_KEY_HERE',
    },
    customChains: [{
      network: 'arbitrumSepolia',
      chainId:  421614,
      urls: {
        apiURL:     'https://api-sepolia.arbiscan.io/api',
        browserURL: 'https://sepolia.arbiscan.io',
      },
    }],
  },
  sourcify: { enabled: false },
};
