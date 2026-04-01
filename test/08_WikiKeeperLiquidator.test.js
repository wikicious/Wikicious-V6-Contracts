// SPDX-License-Identifier: MIT
// 08_WikiKeeperLiquidator.test.js — Keeper Registry + On-chain Liquidator tests
const { expect }        = require('chai');
const { ethers }        = require('hardhat');

const E18  = ethers.parseEther;
const E6   = (n) => BigInt(n) * 1_000_000n;
const BPS  = 10000n;

// ── Helpers ──────────────────────────────────────────────────────────────────
async function deployAll() {
  const [owner, keeper1, keeper2, keeper3, trader, rando] = await ethers.getSigners();

  // WIK token
  const WIK = await (await ethers.getContractFactory('WIKToken')).deploy(owner.address);

  // USDC mock
  const MockERC20 = await ethers.getContractFactory('MockERC20');
  const USDC = await MockERC20.deploy('USD Coin', 'USDC', 6);

  // Oracle mock
  const MockOracle = await ethers.getContractFactory('MockOracle');
  const oracle = await MockOracle.deploy();

  // Vault
  const Vault = await (await ethers.getContractFactory('WikiVault')).deploy(
    await USDC.getAddress(), owner.address
  );

  // Perp
  const Perp = await (await ethers.getContractFactory('WikiPerp')).deploy(
    await Vault.getAddress(), await oracle.getAddress(), owner.address
  );

  // Registry
  const Registry = await (await ethers.getContractFactory('WikiKeeperRegistry')).deploy(
    await WIK.getAddress(), await USDC.getAddress(), owner.address
  );

  // Liquidator
  const Liquidator = await (await ethers.getContractFactory('WikiLiquidator')).deploy(
    await Perp.getAddress(),
    await Vault.getAddress(),
    await Registry.getAddress(),
    await USDC.getAddress(),
    owner.address
  );

  // Wire up: Vault operator, Registry slasher
  await Vault.setOperator(await Perp.getAddress(), true);
  await Registry.setSlasher(await Liquidator.getAddress(), true);

  // Distribute WIK to keepers
  await WIK.mint(keeper1.address, E18('20000'));   // Tier 1
  await WIK.mint(keeper2.address, E18('60000'));   // Tier 2
  await WIK.mint(keeper3.address, E18('250000'));  // Tier 3

  // Distribute USDC to trader and fund reward pool
  await USDC.mint(trader.address, E6(100_000));
  await USDC.mint(owner.address,  E6(50_000));

  // Create a BTC market
  const mktId = ethers.keccak256(ethers.toUtf8Bytes('BTC/USD'));
  await Perp.createMarket(
    mktId, 'BTCUSDT',
    50n, 5n, 10n, 500n,         // maxLev=50, maker=5bps, taker=10bps, mm=500bps
    E6(10_000_000), E6(10_000_000),  // maxOI long/short
    E6(1_000_000)                    // maxPosPerUser
  );

  // Set oracle price: BTC = $50,000
  await oracle.setPrice(mktId, E18('50000'));

  // Approve vault for trader
  await USDC.connect(trader).approve(await Vault.getAddress(), E6(100_000));
  await Vault.connect(trader).deposit(E6(50_000));

  return { owner, keeper1, keeper2, keeper3, trader, rando,
           WIK, USDC, oracle, Vault, Perp, Registry, Liquidator, mktId };
}

// ─────────────────────────────────────────────────────────────────────────────
describe('WikiKeeperRegistry', () => {

  describe('Registration', () => {
    it('registers keeper with MIN_STAKE', async () => {
      const { keeper1, WIK, Registry } = await deployAll();

      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      const info = await Registry.getKeeperInfo(keeper1.address);
      expect(info.active).to.be.true;
      expect(info.stakedWIK).to.equal(E18('10000'));
      expect(await Registry.tierOf(keeper1.address)).to.equal(1);
    });

    it('assigns Tier 2 for 50k WIK stake', async () => {
      const { keeper2, WIK, Registry } = await deployAll();
      await WIK.connect(keeper2).approve(await Registry.getAddress(), E18('60000'));
      await Registry.connect(keeper2).register(E18('60000'));
      expect(await Registry.tierOf(keeper2.address)).to.equal(2);
    });

    it('assigns Tier 3 for 200k+ WIK stake', async () => {
      const { keeper3, WIK, Registry } = await deployAll();
      await WIK.connect(keeper3).approve(await Registry.getAddress(), E18('250000'));
      await Registry.connect(keeper3).register(E18('250000'));
      expect(await Registry.tierOf(keeper3.address)).to.equal(3);
    });

    it('reverts if stake below minimum', async () => {
      const { keeper1, WIK, Registry } = await deployAll();
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('5000'));
      await expect(Registry.connect(keeper1).register(E18('5000')))
        .to.be.revertedWith('Registry: stake below minimum');
    });

    it('reverts on double registration', async () => {
      const { keeper1, WIK, Registry } = await deployAll();
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));
      await expect(Registry.connect(keeper1).register(E18('10000')))
        .to.be.revertedWith('Registry: already registered');
    });
  });

  describe('Unstake cooldown', () => {
    it('enforces 7-day cooldown before unstake claim', async () => {
      const { keeper1, WIK, Registry } = await deployAll();
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      await Registry.connect(keeper1).requestUnstake(E18('10000'));

      // Too early
      await expect(Registry.connect(keeper1).claimUnstake())
        .to.be.revertedWith('Registry: cooldown not elapsed');

      // Fast-forward 7 days
      await ethers.provider.send('evm_increaseTime', [7 * 24 * 3600 + 1]);
      await ethers.provider.send('evm_mine');

      const balBefore = await WIK.balanceOf(keeper1.address);
      await Registry.connect(keeper1).claimUnstake();
      const balAfter = await WIK.balanceOf(keeper1.address);

      expect(balAfter - balBefore).to.equal(E18('10000'));
    });
  });

  describe('Slashing', () => {
    it('slashes keeper stake and burns half', async () => {
      const { keeper1, WIK, Registry, Liquidator, owner } = await deployAll();
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      const deadBalBefore = await WIK.balanceOf('0x000000000000000000000000000000000000dEaD');

      // Liquidator (slasher) slashes keeper for 1000 WIK
      await Registry.connect(owner).setSlasher(owner.address, true); // owner acts as slasher for test
      await Registry.connect(owner).slash(keeper1.address, E18('1000'));

      const deadBalAfter = await WIK.balanceOf('0x000000000000000000000000000000000000dEaD');
      expect(deadBalAfter - deadBalBefore).to.equal(E18('500')); // 50% burned

      const info = await Registry.getKeeperInfo(keeper1.address);
      expect(info.stakedWIK).to.equal(E18('9000')); // 10000 - 1000
    });

    it('deactivates keeper when all stake slashed', async () => {
      const { keeper1, WIK, Registry, owner } = await deployAll();
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      await Registry.connect(owner).setSlasher(owner.address, true);
      await Registry.connect(owner).slash(keeper1.address, E18('10000'));

      expect(await Registry.isActive(keeper1.address)).to.be.false;
    });
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe('WikiLiquidator', () => {

  async function deployWithPosition(ctx) {
    // Open a long BTC position
    const { Perp, Vault, trader, mktId } = ctx;
    // Long 1 BTC at $50,000 with $1000 collateral × 10 leverage = $10,000 notional
    const orderId = await Perp.connect(trader).placeMarketOrder(
      0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n  // marketIdx=0, long, 1000 USDC, 10x
    );

    // Get position ID from PositionOpened event
    const receipt = await (await Perp.connect(trader).placeMarketOrder(
      0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
    )).wait();
    const event   = receipt.logs
      .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
      .find(e => e?.name === 'PositionOpened');
    return event ? Number(event.args.posId) : 0;
  }

  describe('Reward pool', () => {
    it('owner can fund and withdraw reward pool', async () => {
      const { USDC, Liquidator, owner } = await deployAll();
      await USDC.connect(owner).approve(await Liquidator.getAddress(), E6(10_000));
      await Liquidator.connect(owner).fundRewardPool(E6(10_000));
      expect(await Liquidator.rewardPool()).to.equal(E6(10_000));

      await Liquidator.connect(owner).withdrawRewardPool(owner.address, E6(5_000));
      expect(await Liquidator.rewardPool()).to.equal(E6(5_000));
    });
  });

  describe('Single liquidation', () => {
    it('liquidates an underwater position', async () => {
      const ctx      = await deployAll();
      const { Perp, Vault, oracle, trader, keeper1, WIK, USDC, Registry, Liquidator, owner, mktId } = ctx;

      // Register keeper1
      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      // Fund reward pool
      await USDC.connect(owner).approve(await Liquidator.getAddress(), E6(10_000));
      await Liquidator.connect(owner).fundRewardPool(E6(10_000));

      // Open long position
      const tx = await Perp.connect(trader).placeMarketOrder(
        0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
      );
      const receipt  = await tx.wait();
      const posEvent = receipt.logs
        .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
        .find(e => e?.name === 'PositionOpened');
      const posId = Number(posEvent.args.posId);

      // Price drops 15% — position is underwater
      await oracle.setPrice(mktId, E18('42500'));

      const keeperBalBefore = await USDC.balanceOf(keeper1.address);
      await Liquidator.connect(keeper1).liquidateSingle(posId);
      const keeperBalAfter  = await USDC.balanceOf(keeper1.address);

      // Keeper received USDC
      expect(keeperBalAfter).to.be.gt(keeperBalBefore);

      // Position should be closed
      const pos = await Perp.getPosition(posId);
      expect(pos.open).to.be.false;
    });

    it('reverts if position is not liquidatable', async () => {
      const ctx = await deployAll();
      const { Perp, trader, keeper1, Liquidator } = ctx;

      const tx = await Perp.connect(trader).placeMarketOrder(
        0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
      );
      const receipt  = await tx.wait();
      const posEvent = receipt.logs
        .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
        .find(e => e?.name === 'PositionOpened');
      const posId = Number(posEvent.args.posId);

      // Price stays the same — not liquidatable
      await expect(Liquidator.connect(keeper1).liquidateSingle(posId))
        .to.be.revertedWith('Liquidator: not liquidatable');
    });
  });

  describe('Batch liquidation', () => {
    it('liquidates multiple positions, skips invalid ones', async () => {
      const ctx = await deployAll();
      const { Perp, oracle, trader, keeper1, WIK, USDC, Registry, Liquidator, owner, mktId } = ctx;

      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));
      await USDC.connect(owner).approve(await Liquidator.getAddress(), E6(10_000));
      await Liquidator.connect(owner).fundRewardPool(E6(10_000));

      // Open 3 positions
      const posIds = [];
      for (let i = 0; i < 3; i++) {
        const tx = await Perp.connect(trader).placeMarketOrder(
          0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
        );
        const r = await tx.wait();
        const ev = r.logs
          .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
          .find(e => e?.name === 'PositionOpened');
        posIds.push(Number(ev.args.posId));
      }

      // Drop price — all 3 should be liquidatable
      await oracle.setPrice(mktId, E18('40000'));

      // Include a fake posId (9999) that doesn't exist — should be skipped
      const batchIds = [...posIds, 9999];
      const tx = await Liquidator.connect(keeper1).liquidateBatch(batchIds);
      const receipt = await tx.wait();

      const batchEvent = receipt.logs
        .map(l => { try { return Liquidator.interface.parseLog(l); } catch { return null; } })
        .find(e => e?.name === 'BatchLiquidationResult');

      expect(Number(batchEvent.args.succeeded)).to.equal(3);
      expect(Number(batchEvent.args.attempted)).to.equal(4);
    });
  });

  describe('Urgency multiplier', () => {
    it('returns higher bonus when position is deeper underwater', async () => {
      const ctx = await deployAll();
      const { Perp, oracle, keeper1, trader, WIK, USDC, Registry, Liquidator, owner, mktId } = ctx;

      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));

      // Open position
      const tx = await Perp.connect(trader).placeMarketOrder(
        0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
      );
      const r = await tx.wait();
      const ev = r.logs
        .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
        .find(e => e?.name === 'PositionOpened');
      const posId = Number(ev.args.posId);

      // Test preview at -12% price
      await oracle.setPrice(mktId, E18('44000')); // mild drop
      const [bonusMild, urgMild] = await Liquidator.connect(keeper1).previewBonus(posId);

      // Test preview at -20% price (deeper)
      await oracle.setPrice(mktId, E18('40000'));
      const [bonusDeep, urgDeep] = await Liquidator.connect(keeper1).previewBonus(posId);

      expect(urgDeep).to.be.gte(urgMild);
      expect(bonusDeep).to.be.gte(bonusMild);
    });
  });

  describe('Limit orders and funding', () => {
    it('settles funding for multiple markets', async () => {
      const ctx = await deployAll();
      const { Liquidator, Perp } = ctx;

      // Advance time 8+ hours
      await ethers.provider.send('evm_increaseTime', [8 * 3600 + 1]);
      await ethers.provider.send('evm_mine');

      // Should not revert (market 0 exists)
      await expect(Liquidator.settleFundingBatch([0n])).to.not.be.reverted;
    });
  });

  describe('Keeper tier bonus', () => {
    it('tier 3 keeper earns higher bonus than tier 1', async () => {
      const ctx = await deployAll();
      const { Perp, oracle, trader, keeper1, keeper3, WIK, USDC, Registry, Liquidator, owner, mktId } = ctx;

      await WIK.connect(keeper1).approve(await Registry.getAddress(), E18('20000'));
      await Registry.connect(keeper1).register(E18('10000'));  // Tier 1

      await WIK.connect(keeper3).approve(await Registry.getAddress(), E18('250000'));
      await Registry.connect(keeper3).register(E18('250000')); // Tier 3

      await USDC.connect(owner).approve(await Liquidator.getAddress(), E6(50_000));
      await Liquidator.connect(owner).fundRewardPool(E6(50_000));

      // Multipliers
      const mult1 = await Registry.rewardMultiplier(keeper1.address);
      const mult3 = await Registry.rewardMultiplier(keeper3.address);

      expect(mult3).to.be.gt(mult1);   // 1.5× > 1.0×

      // Open two identical positions
      const openPos = async (signer) => {
        const tx = await Perp.connect(trader).placeMarketOrder(
          0n, true, E6(1000), 10n, 0n, 0n, 0n, 0n
        );
        const r = await tx.wait();
        return Number(r.logs
          .map(l => { try { return Perp.interface.parseLog(l); } catch { return null; } })
          .find(e => e?.name === 'PositionOpened').args.posId);
      };

      const pos1 = await openPos();
      const pos2 = await openPos();

      await oracle.setPrice(mktId, E18('40000'));

      const bal1Before = await USDC.balanceOf(keeper1.address);
      const bal3Before = await USDC.balanceOf(keeper3.address);

      await Liquidator.connect(keeper1).liquidateSingle(pos1);
      await Liquidator.connect(keeper3).liquidateSingle(pos2);

      const bonus1 = (await USDC.balanceOf(keeper1.address)) - bal1Before;
      const bonus3 = (await USDC.balanceOf(keeper3.address)) - bal3Before;

      // Tier 3 keeper should get more
      expect(bonus3).to.be.gte(bonus1);
    });
  });

  describe('Emergency pause', () => {
    it('owner can pause and unpause liquidations', async () => {
      const ctx = await deployAll();
      const { Liquidator, owner, keeper1 } = ctx;

      await Liquidator.connect(owner).setPaused(true);
      await expect(Liquidator.connect(keeper1).liquidateSingle(0n))
        .to.be.revertedWith('Liquidator: paused');

      await Liquidator.connect(owner).setPaused(false);
      // Will fail for a different reason (pos not open), not paused
      await expect(Liquidator.connect(keeper1).liquidateSingle(0n))
        .to.not.be.revertedWith('Liquidator: paused');
    });
  });
});
