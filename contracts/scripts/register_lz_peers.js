'use strict';
/**
 * ════════════════════════════════════════════════════════════════
 *  WIKICIOUS — LayerZero V5 Peer Registration Script
 *
 *  Run AFTER deploying Wikicious on all chains.
 *  This registers each chain's deployed contracts as trusted
 *  peers on every other chain — enabling trustless LZ messaging.
 *
 *  Usage:
 *    ARBITRUM_RPC_URL=... OPTIMISM_RPC_URL=... DEPLOYER_PRIVATE_KEY=0x... \
 *    node scripts/register_lz_peers.js
 *
 *  What it does:
 *    For each chain pair (A, B):
 *      WikiBridge on A → setPeer(B_eid, WikiBridge_B_address)
 *      WikiBridge on B → setPeer(A_eid, WikiBridge_A_address)
 *      WikiCrossChainRouter on A → setPeer(B_eid, Router_B)
 *      WikiCrossChainRouter on B → setPeer(A_eid, Router_A)
 *      WikiCrossChainLending on A → setPeer(B_eid, CCLending_B)
 *      WikiCrossChainLending on B → setPeer(A_eid, CCLending_A)
 * ════════════════════════════════════════════════════════════════
 */

const { ethers } = require('hardhat');
const fs         = require('fs');
const path       = require('path');

// ── LayerZero V5 endpoint IDs ─────────────────────────────────────────────
const LZ_EIDS = {
  arbitrum:  30110,
  optimism:  30111,
  base:      30184,
  polygon:   30109,
  bnb:       30102,
  ethereum:  30101,
  avalanche: 30106,
};

// ── Deployed contract addresses per chain ────────────────────────────────
// Loaded from deployments.{chain}.json files written by deploy.js
function loadDeployment(chain) {
  const p = path.join(__dirname, `../deployments.${chain}.json`);
  if (!fs.existsSync(p)) {
    console.warn(`  ⚠️  No deployment file for ${chain} — skipping`);
    return null;
  }
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

// ── Minimal ABIs ──────────────────────────────────────────────────────────
const BRIDGE_ABI = [
  'function setPeer(uint32 eid, bytes32 peer) external',
  'function setPeers(uint32[] calldata eids, bytes32[] calldata peers) external',
  'function peers(uint32 eid) external view returns (bytes32)',
  'function owner() external view returns (address)',
];

const ROUTER_ABI = [
  'function setPeer(uint32 eid, bytes32 peer) external',
  'function setPeers(uint32[] calldata eids, bytes32[] calldata peers) external',
  'function peers(uint32 eid) external view returns (bytes32)',
];

const CCL_ABI = [
  'function setPeer(uint32 eid, bytes32 peer) external',
  'function setPeers(uint32[] calldata eids, bytes32[] calldata peers) external',
  'function peers(uint32 eid) external view returns (bytes32)',
];

// ── RPC URLs per chain ────────────────────────────────────────────────────
const RPC_URLS = {
  arbitrum:  process.env.ARBITRUM_RPC_URL  || 'https://arb1.arbitrum.io/rpc',
  optimism:  process.env.OPTIMISM_RPC_URL  || 'https://mainnet.optimism.io',
  base:      process.env.BASE_RPC_URL      || 'https://mainnet.base.org',
  polygon:   process.env.POLYGON_RPC_URL   || 'https://polygon-rpc.com',
  bnb:       process.env.BNB_RPC_URL       || 'https://bsc-dataseed.binance.org',
};

const CHAINS = Object.keys(RPC_URLS);

// ── Address → bytes32 (left-padded) ──────────────────────────────────────
function addrToBytes32(addr) {
  return ethers.zeroPadValue(addr.toLowerCase(), 32);
}

// ── Main ──────────────────────────────────────────────────────────────────
async function main() {
  const pk = process.env.DEPLOYER_PRIVATE_KEY;
  if (!pk) throw new Error('DEPLOYER_PRIVATE_KEY not set');

  console.log('\n══════════════════════════════════════════════════');
  console.log('  WIKICIOUS — LayerZero V5 Peer Registration');
  console.log('══════════════════════════════════════════════════\n');

  // Load all deployments
  const deployments = {};
  for (const chain of CHAINS) {
    const dep = loadDeployment(chain);
    if (dep) deployments[chain] = dep;
  }

  const activeChains = Object.keys(deployments);
  console.log(`Found deployments on: ${activeChains.join(', ')}\n`);

  // For each chain, register all other chains as peers
  for (const srcChain of activeChains) {
    const srcDep = deployments[srcChain];
    const provider = new ethers.JsonRpcProvider(RPC_URLS[srcChain]);
    const wallet   = new ethers.Wallet(pk, provider);

    console.log(`\n── Registering peers on ${srcChain} ────────────────`);

    const bridge  = new ethers.Contract(srcDep.contracts.WikiBridge,              BRIDGE_ABI, wallet);
    const router  = new ethers.Contract(srcDep.contracts.WikiCrossChainRouter,    ROUTER_ABI, wallet);
    const ccl     = new ethers.Contract(srcDep.contracts.WikiCrossChainLending,   CCL_ABI, wallet);

    const destEids   = [];
    const bridgePeers = [];
    const routerPeers = [];
    const cclPeers    = [];

    for (const destChain of activeChains) {
      if (destChain === srcChain) continue;
      const destDep = deployments[destChain];
      const eid     = LZ_EIDS[destChain];
      if (!eid) { console.log(`  ⚠️  No EID for ${destChain}`); continue; }

      destEids.push(eid);
      bridgePeers.push(addrToBytes32(destDep.contracts.WikiBridge));
      routerPeers.push(addrToBytes32(destDep.contracts.WikiCrossChainRouter));
      cclPeers.push(addrToBytes32(destDep.contracts.WikiCrossChainLending));
    }

    if (destEids.length === 0) {
      console.log(`  ℹ️  No other chains to register`);
      continue;
    }

    // Batch register all peers at once
    try {
      const tx1 = await bridge.setPeers(destEids, bridgePeers);
      await tx1.wait();
      console.log(`  ✅ WikiBridge peers set: ${destEids.length} chains | tx: ${tx1.hash.slice(0,10)}...`);
    } catch (e) {
      console.error(`  ❌ Bridge setPeers failed: ${e.message.slice(0,80)}`);
    }

    try {
      const tx2 = await router.setPeers(destEids, routerPeers);
      await tx2.wait();
      console.log(`  ✅ WikiCrossChainRouter peers set | tx: ${tx2.hash.slice(0,10)}...`);
    } catch (e) {
      console.error(`  ❌ Router setPeers failed: ${e.message.slice(0,80)}`);
    }

    try {
      const tx3 = await ccl.setPeers(destEids, cclPeers);
      await tx3.wait();
      console.log(`  ✅ WikiCrossChainLending peers set | tx: ${tx3.hash.slice(0,10)}...`);
    } catch (e) {
      console.error(`  ❌ CCLending setPeers failed: ${e.message.slice(0,80)}`);
    }
  }

  console.log('\n══════════════════════════════════════════════════');
  console.log('  Peer registration complete!');
  console.log('  Cross-chain bridging and trading is now live.');
  console.log('══════════════════════════════════════════════════\n');
}

main().catch(e => {
  console.error('Fatal error:', e);
  process.exit(1);
});
