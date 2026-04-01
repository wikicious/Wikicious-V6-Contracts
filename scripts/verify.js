/**
 * Wikicious V6 — Contract Verification
 * Run after deploy to verify all contracts on Etherscan (Arbitrum)
 * npx hardhat run scripts/verify.js --network arbitrum_one
 * 
 * Note: Arbiscan merged into Etherscan. 
 * Use ETHERSCAN_API_KEY from https://etherscan.io/myapikey
 */
const { run } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const deployPath = path.join(__dirname, "../deployments.arbitrum.json");
  if (!fs.existsSync(deployPath)) {
    console.error("deployments.arbitrum.json not found. Run deploy.js first.");
    process.exit(1);
  }

  const deployment = JSON.parse(fs.readFileSync(deployPath));
  const contracts   = deployment.contracts;
  const ext         = deployment.external;

  console.log("\n🔍 Verifying contracts on Etherscan (Arbitrum One)...");
  console.log("   Note: Arbiscan merged into Etherscan — using ETHERSCAN_API_KEY\n");

  let verified = 0;
  const toVerify = [
    ["WIKToken",         contracts.WIKToken,           [deployment.deployer]],
    ["WikiOracle",       contracts.WikiOracle,          [deployment.deployer, ext.SEQ_FEED]],
    ["WikiVault",        contracts.WikiVault,           [ext.USDC, deployment.deployer]],
    ["WikiPerp",         contracts.WikiPerp,            [contracts.WikiVault, contracts.WikiOracle, deployment.deployer]],
    ["WikiStaking",      contracts.WikiStaking,         [contracts.WIKToken, ext.USDC, deployment.deployer]],
    ["WikiLending",      contracts.WikiLending,         [contracts.WikiOracle, contracts.WIKToken, ext.USDC, deployment.deployer]],
    ["WikiPropPool",     contracts.WikiPropPool,        [ext.USDC, deployment.deployer]],
    ["WikiPropEval",     contracts.WikiPropEval,        [ext.USDC, contracts.WikiPropPool, deployment.deployer]],
    ["WikiUserBotFactory", contracts.WikiUserBotFactory, [ext.USDC, contracts.WikiPerp, contracts.WikiOracle, contracts.WikiRevenueSplitter, contracts.WikiKeeperRegistry, deployment.deployer]],
    ["WikiPropPoolYield", contracts.WikiPropPoolYield,  [ext.USDC, "0x794a61358D6845594F94dc1DB02A252b5b4814aD", contracts.WikiLending, contracts.WikiPropPool, deployment.deployer]],
    ["WikiIdleYieldRouter", contracts.WikiIdleYieldRouter, [ext.USDC, "0x794a61358D6845594F94dc1DB02A252b5b4814aD", contracts.WikiLending, contracts.WikiRevenueSplitter, deployment.deployer]],
  ];

  for (const [name, address, args] of toVerify) {
    if (!address) { console.log(`  ⏭  ${name} — no address`); continue; }
    try {
      await run("verify:verify", { address, constructorArguments: args });
      console.log(`  ✅ ${name}: ${address}`);
      verified++;
    } catch (e) {
      if (e.message?.includes("Already Verified")) {
        console.log(`  ✅ ${name}: already verified`);
        verified++;
      } else {
        console.log(`  ⚠  ${name}: ${e.message?.slice(0, 60)}`);
      }
    }
  }

  console.log(`\n✅ Verified: ${verified}/${toVerify.length} contracts`);
  console.log("   View at: https://arbiscan.io/address/<CONTRACT_ADDRESS>");
}

main().catch(e => { console.error(e); process.exit(1); });
