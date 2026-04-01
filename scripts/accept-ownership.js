// accept-ownership.js
// Run from your TREASURY wallet AFTER transfer-ownership.js completes
// Usage: npx hardhat run scripts/accept-ownership.js --network arbitrum
//
// This completes the Ownable2Step handshake — treasury becomes owner of all contracts

require('dotenv').config();
const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

async function main() {
  const [treasury] = await ethers.getSigners();
  console.log('\n🔐 Accept Ownership — Wikicious Contracts');
  console.log(`   Treasury wallet: ${treasury.address}\n`);

  // Load transfer results to know which contracts to accept
  const transferPath = path.join(__dirname, '../ownership-transfer.json');
  const deploymentsPath = path.join(__dirname, '../deployments.arbitrum.json');

  let contractAddresses = {};

  if (fs.existsSync(transferPath)) {
    const transfer = JSON.parse(fs.readFileSync(transferPath, 'utf8'));
    console.log(`📄 Loaded transfer log — initiated by ${transfer.from.slice(0,10)}… → ${transfer.to.slice(0,10)}…\n`);
    // Verify treasury address matches
    if (transfer.to.toLowerCase() !== treasury.address.toLowerCase()) {
      console.error(`❌ Mismatch: transfer was to ${transfer.to}`);
      console.error(`   But connected wallet is ${treasury.address}`);
      console.error('   Make sure you are using the TREASURY private key in .env\n');
      process.exit(1);
    }
    transfer.results.forEach(r => {
      if (r.address) contractAddresses[r.name] = r.address;
    });
  } else if (fs.existsSync(deploymentsPath)) {
    console.log('⚠️  No ownership-transfer.json found — using deployments.arbitrum.json');
    const d = JSON.parse(fs.readFileSync(deploymentsPath, 'utf8'));
    contractAddresses = d.contracts;
  } else {
    console.error('❌ No deployments found. Run transfer-ownership.js first.\n');
    process.exit(1);
  }

  const OWNABLE2STEP_ABI = [
    'function owner() view returns (address)',
    'function pendingOwner() view returns (address)',
    'function acceptOwnership() external',
  ];

  const results = [];

  for (const [name, address] of Object.entries(contractAddresses)) {
    if (!address) continue;
    try {
      const contract = new ethers.Contract(address, OWNABLE2STEP_ABI, treasury);

      const pending = await contract.pendingOwner().catch(() => ethers.ZeroAddress);
      const current = await contract.owner().catch(() => ethers.ZeroAddress);

      // Already owner
      if (current.toLowerCase() === treasury.address.toLowerCase()) {
        console.log(`   ✅ ${name.padEnd(22)} Already owner — nothing to do`);
        results.push({ name, status: 'already_owner' });
        continue;
      }

      // Not pending owner
      if (pending.toLowerCase() !== treasury.address.toLowerCase()) {
        console.log(`   ⚠️  ${name.padEnd(22)} Not pending owner — run transfer-ownership.js first`);
        results.push({ name, status: 'not_pending' });
        continue;
      }

      // Accept ownership
      const tx = await contract.acceptOwnership();
      await tx.wait();
      console.log(`   ✅ ${name.padEnd(22)} Ownership ACCEPTED  (tx: ${tx.hash.slice(0, 18)}…)`);
      results.push({ name, status: 'accepted', txHash: tx.hash });

    } catch (e) {
      console.log(`   ❌ ${name.padEnd(22)} FAILED — ${e.message.slice(0, 60)}`);
      results.push({ name, status: 'failed', error: e.message });
    }
  }

  // ── Summary ─────────────────────────────────────────────────
  const accepted = results.filter(r => r.status === 'accepted' || r.status === 'already_owner');
  const failed   = results.filter(r => r.status === 'failed');
  const pending  = results.filter(r => r.status === 'not_pending');

  console.log('\n─────────────────────────────────────────────────');
  console.log(`✅ Accepted:    ${accepted.length} contracts`);
  console.log(`⚠️  Pending:    ${pending.length} contracts (re-run transfer script)`);
  console.log(`❌ Failed:      ${failed.length} contracts`);
  console.log('─────────────────────────────────────────────────');

  if (accepted.length > 0 && failed.length === 0 && pending.length === 0) {
    console.log('\n🎉 SUCCESS — Treasury wallet is now owner of all contracts!');
    console.log(`   Owner: ${treasury.address}`);
    console.log('\n   You can now:');
    console.log('   • Withdraw fees via the Admin Dashboard');
    console.log('   • Pause/unpause contracts if needed');
    console.log('   • Update oracle guardians and keepers');
    console.log('\n   🔒 Keep your treasury private key OFFLINE (hardware wallet)');
  }

  if (failed.length > 0) {
    console.log('\n⚠️  Some contracts failed. Re-run this script to retry.');
  }

  // Save final ownership record
  const outPath = path.join(__dirname, '../ownership-accepted.json');
  fs.writeFileSync(outPath, JSON.stringify({
    treasury: treasury.address,
    timestamp: new Date().toISOString(),
    results,
  }, null, 2));
  console.log(`\n📄 Record saved to ownership-accepted.json\n`);
}

main().catch(e => { console.error(e); process.exit(1); });
