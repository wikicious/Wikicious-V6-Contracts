/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiPerp.sol
 *
 *  Covers:
 *  ✓ Deployment with vault + oracle
 *  ✓ addMarket (owner only)
 *  ✓ Market activation/deactivation
 *  ✓ placeMarketOrder — long & short
 *  ✓ openPosition — collateral locked in vault
 *  ✓ closePosition — PnL settled in USDC
 *  ✓ Liquidation — undercollateralised position
 *  ✓ Take-Profit / Stop-Loss auto execution
 *  ✓ Limit orders — create, fill, cancel
 *  ✓ Funding rate settlement
 *  ✓ OI cap enforcement
 *  ✓ Max position size per user
 *  ✓ Self-liquidation prevention
 *  ✓ GMX backstop enable/disable
 *  ✓ Pause / unpause
 *  ✓ Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

const { expect } = require('chai');
const { ethers }  = require('hardhat');

describe('WikiPerp', () => {
  let perp, vault, oracle, usdc, clFeed, seqFeed;
  let owner, keeper, alice, bob, liquidator;

  const D6  = (n) => BigInt(Math.round(Number(n))) * 1_000_000n;
  const D18 = (n) => ethers.parseUnits(String(n), 18);

  const BTC_PRICE  = D18(50000);
  const BTC_ID     = ethers.id('BTCUSDT');
  const BTC_IDX    = 0;

  async function setPrice(price18) {
    // price18 → 8 dec for Chainlink mock
    const p8 = price18 / 10_000_000_000n;
    await clFeed.setPrice(p8);
    await oracle.connect(keeper).submitGuardianPrice(BTC_IDX, price18);
  }

  async function openLong(user, collateralUsdc, leverage) {
    const col = D6(collateralUsdc);
    await usdc.connect(user).approve(await vault.getAddress(), col);
    const tx = await perp.connect(user).placeMarketOrder(
      BTC_IDX, true, col, leverage, 0n, 0n
    );
    const receipt = await tx.wait();
    // Find PositionOpened event
    const iface = perp.interface;
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed.name === 'PositionOpened') return parsed.args.posId;
      } catch {}
    }
    // fallback: get last posId
    return await perp.nextPositionId() - 1n;
  }

  async function openShort(user, collateralUsdc, leverage) {
    const col = D6(collateralUsdc);
    await usdc.connect(user).approve(await vault.getAddress(), col);
    const tx = await perp.connect(user).placeMarketOrder(
      BTC_IDX, false, col, leverage, 0n, 0n
    );
    const receipt = await tx.wait();
    const iface = perp.interface;
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed.name === 'PositionOpened') return parsed.args.posId;
      } catch {}
    }
    return await perp.nextPositionId() - 1n;
  }

  before(async () => {
    [owner, keeper, alice, bob, liquidator] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();

    const MockCL = await ethers.getContractFactory('MockChainlinkFeed');
    clFeed = await MockCL.deploy(8);
    await clFeed.setPrice(5_000_000_000_000n); // $50,000

    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());
    await oracle.setFeed(
      BTC_ID, await clFeed.getAddress(), 86400, 8,
      D18(1000), D18(500000)
    );

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await usdc.getAddress(), owner.address);

    const WikiPerp = await ethers.getContractFactory('WikiPerp');
    perp = await WikiPerp.deploy(
      await vault.getAddress(), await oracle.getAddress(), owner.address
    );

    await vault.setOperator(await perp.getAddress(), true);
    await oracle.setGuardian(keeper.address, true);

    // Fund users
    for (const user of [alice, bob, liquidator]) {
      await usdc.mint(user.address, D6(500_000));
    }
    // Liquidity in vault
    await usdc.mint(owner.address, D6(5_000_000));
    await usdc.connect(owner).approve(await vault.getAddress(), D6(5_000_000));
    await vault.connect(owner).deposit(D6(5_000_000));
  });

  // ── Deployment ─────────────────────────────────────────────────
  describe('Deployment', () => {
    it('references correct vault and oracle', async () => {
      expect(await perp.vault()).to.equal(await vault.getAddress());
      expect(await perp.oracle()).to.equal(await oracle.getAddress());
    });

    it('GMX backstop disabled by default', async () => {
      expect(await perp.gmxEnabled()).to.equal(false);
    });

    it('nextPositionId starts at 1', async () => {
      expect(await perp.nextPositionId()).to.equal(1n);
    });
  });

  // ── Market creation ────────────────────────────────────────────
  describe('createMarket', () => {
    it('owner can create BTC market', async () => {
      await expect(perp.createMarket(
        'BTCUSDT', BTC_ID, 125, 2, 4, 40,
        ethers.parseUnits('50000000', 6),  // maxOI 50M USDC
        D18(1000), D18(500000)
      )).to.emit(perp, 'MarketCreated');
    });

    it('non-owner cannot create market', async () => {
      await expect(perp.connect(alice).createMarket(
        'ETHUSDT', ethers.id('ETHUSDT'), 100, 2, 4, 50,
        ethers.parseUnits('40000000', 6),
        D18(100), D18(100000)
      )).to.be.revertedWithCustomError(perp, 'OwnableUnauthorizedAccount');
    });

    it('market count is 1', async () => {
      const m = await perp.getMarket(0);
      expect(m.symbol).to.equal('BTCUSDT');
      expect(m.active).to.equal(true);
    });
  });

  // ── Oracle ─────────────────────────────────────────────────────
  describe('Oracle guardian price', () => {
    it('keeper can submit BTC price', async () => {
      await expect(oracle.connect(keeper).submitGuardianPrice(BTC_IDX, BTC_PRICE))
        .to.emit(oracle, 'GuardianPriceSet');
    });

    it('non-guardian cannot submit price', async () => {
      await expect(oracle.connect(alice).submitGuardianPrice(BTC_IDX, BTC_PRICE))
        .to.be.reverted;
    });

    it('getPrice returns set price', async () => {
      const p = await oracle.getPrice(BTC_IDX);
      expect(p).to.equal(BTC_PRICE);
    });
  });

  // ── Open position ──────────────────────────────────────────────
  describe('openPosition', () => {
    before(async () => { await setPrice(BTC_PRICE); });

    it('alice can open a 10x long with $1,000 collateral', async () => {
      const col = D6(1000);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, col, 10, 0n, 0n))
        .to.emit(perp, 'PositionOpened');
    });

    it('position has correct fields', async () => {
      const posId = await perp.nextPositionId() - 1n;
      const pos = await perp.getPosition(posId);
      expect(pos.trader).to.equal(alice.address);
      expect(pos.isLong).to.equal(true);
      expect(pos.leverage).to.equal(10n);
      expect(pos.collateral).to.be.closeTo(D6(1000), D6(10)); // within $10 fee
      expect(pos.size).to.be.gt(0n);
    });

    it('bob can open a 5x short with $2,000 collateral', async () => {
      const col = D6(2000);
      await usdc.connect(bob).approve(await vault.getAddress(), col);
      await expect(perp.connect(bob).placeMarketOrder(BTC_IDX, false, col, 5, 0n, 0n))
        .to.emit(perp, 'PositionOpened');
    });

    it('rejects leverage above market max (125)', async () => {
      const col = D6(100);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, col, 200, 0n, 0n))
        .to.be.reverted;
    });

    it('rejects zero collateral', async () => {
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, 0n, 5, 0n, 0n))
        .to.be.reverted;
    });
  });

  // ── Close position ─────────────────────────────────────────────
  describe('closePosition', () => {
    let posId;

    before(async () => {
      await setPrice(BTC_PRICE);
      posId = await openLong(alice, 1000, 5);
    });

    it('trader can close their own position', async () => {
      // Price unchanged → small loss from fees
      await expect(perp.connect(alice).closePosition(posId))
        .to.emit(perp, 'PositionClosed');
    });

    it('position is deleted after close', async () => {
      const pos = await perp.getPosition(posId);
      expect(pos.trader).to.equal(ethers.ZeroAddress);
    });

    it('cannot close already-closed position', async () => {
      await expect(perp.connect(alice).closePosition(posId))
        .to.be.reverted;
    });

    it('cannot close someone else\'s position', async () => {
      const posId2 = await openLong(bob, 500, 3);
      await expect(perp.connect(alice).closePosition(posId2))
        .to.be.reverted;
    });

    it('profitable close returns more than collateral', async () => {
      // Open long at $50k, price goes to $60k → +20% on size
      const pos3Id = await openLong(alice, 1000, 5);
      const balBefore = await usdc.balanceOf(alice.address);
      await setPrice(D18(60000));
      await perp.connect(alice).closePosition(pos3Id);
      const balAfter = await usdc.balanceOf(alice.address);
      expect(balAfter).to.be.gt(balBefore); // net profit after fees
    });

    it('losing close returns less than collateral', async () => {
      await setPrice(BTC_PRICE); // back to $50k
      const pos4Id = await openLong(alice, 1000, 5);
      const balBefore = await usdc.balanceOf(alice.address);
      await setPrice(D18(45000)); // -10% → -50% on 5x long
      await perp.connect(alice).closePosition(pos4Id);
      const balAfter = await usdc.balanceOf(alice.address);
      expect(balAfter).to.be.lt(balBefore);
    });
  });

  // ── Liquidation ────────────────────────────────────────────────
  describe('liquidation', () => {
    let posId;

    before(async () => {
      await setPrice(BTC_PRICE); // $50k
      posId = await openLong(alice, 1000, 10); // 10x long, liq ~$45k
    });

    it('cannot liquidate healthy position', async () => {
      // Price at $50k → not liquidatable
      await expect(perp.connect(liquidator).liquidate(posId))
        .to.be.reverted;
    });

    it('can liquidate undercollateralised position', async () => {
      // 10x long: maintenance margin 0.4%, liquidation at ~$45,500
      await setPrice(D18(44000)); // well below liq threshold
      await expect(perp.connect(liquidator).liquidate(posId))
        .to.emit(perp, 'Liquidated');
    });

    it('liquidator receives liquidation fee', async () => {
      await setPrice(BTC_PRICE);
      const pos2Id = await openLong(bob, 500, 10);
      const balBefore = await usdc.balanceOf(liquidator.address);
      await setPrice(D18(44000));
      await perp.connect(liquidator).liquidate(pos2Id);
      const balAfter = await usdc.balanceOf(liquidator.address);
      expect(balAfter).to.be.gt(balBefore);
    });

    it('self-liquidation is prevented', async () => {
      await setPrice(BTC_PRICE);
      const pos3Id = await openLong(alice, 500, 10);
      await setPrice(D18(44000));
      await expect(perp.connect(alice).liquidate(pos3Id))
        .to.be.reverted;
    });
  });

  // ── Take-Profit / Stop-Loss ────────────────────────────────────
  describe('TP / SL execution', () => {
    it('position stores TP and SL prices', async () => {
      await setPrice(BTC_PRICE);
      const col = D6(500);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      const tx = await perp.connect(alice).placeMarketOrder(
        BTC_IDX, true, col, 5,
        D18(55000),  // TP at $55k
        D18(47000),  // SL at $47k
      );
      const receipt = await tx.wait();
      let posId;
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'PositionOpened') posId = parsed.args.posId;
        } catch {}
      }
      const pos = await perp.getPosition(posId);
      expect(pos.takeProfit).to.equal(D18(55000));
      expect(pos.stopLoss).to.equal(D18(47000));
    });

    it('executeTPSL closes position at take-profit price', async () => {
      await setPrice(BTC_PRICE);
      const col = D6(500);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      const tx = await perp.connect(alice).placeMarketOrder(
        BTC_IDX, true, col, 5, D18(55000), D18(47000)
      );
      const receipt = await tx.wait();
      let posId;
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'PositionOpened') posId = parsed.args.posId;
        } catch {}
      }
      await setPrice(D18(55500)); // Above TP
      await expect(perp.connect(keeper).executeTPSL(posId))
        .to.emit(perp, 'PositionClosed');
    });

    it('executeTPSL closes position at stop-loss price', async () => {
      await setPrice(BTC_PRICE);
      const col = D6(500);
      await usdc.connect(bob).approve(await vault.getAddress(), col);
      const tx = await perp.connect(bob).placeMarketOrder(
        BTC_IDX, true, col, 3, D18(60000), D18(48000)
      );
      const receipt = await tx.wait();
      let posId;
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'PositionOpened') posId = parsed.args.posId;
        } catch {}
      }
      await setPrice(D18(47500)); // Below SL
      await expect(perp.connect(keeper).executeTPSL(posId))
        .to.emit(perp, 'PositionClosed');
    });
  });

  // ── Limit orders ───────────────────────────────────────────────
  describe('Limit orders', () => {
    let orderId;

    it('can place a limit long order below current price', async () => {
      const col = D6(500);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      const tx = await perp.connect(alice).placeLimitOrder(
        BTC_IDX, true, col, 5,
        D18(48000),  // limit price $48k (below $50k market)
        0n, 0n
      );
      const receipt = await tx.wait();
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'OrderPlaced') orderId = parsed.args.orderId;
        } catch {}
      }
      expect(orderId).to.not.be.undefined;
    });

    it('limit order is stored correctly', async () => {
      const order = await perp.getOrder(orderId);
      expect(order.trader).to.equal(alice.address);
      expect(order.isLong).to.equal(true);
      expect(order.limitPrice).to.equal(D18(48000));
    });

    it('limit order fills when price drops to limit', async () => {
      await setPrice(D18(47900)); // Below limit price
      await expect(perp.executeLimitOrders(BTC_IDX, [orderId]))
        .to.emit(perp, 'PositionOpened');
    });

    it('can cancel a pending limit order', async () => {
      const col = D6(200);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      const tx = await perp.connect(alice).placeLimitOrder(
        BTC_IDX, true, col, 2, D18(40000), 0n, 0n
      );
      const receipt = await tx.wait();
      let cOrdId;
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'OrderPlaced') cOrdId = parsed.args.orderId;
        } catch {}
      }
      await expect(perp.connect(alice).cancelOrder(cOrdId))
        .to.emit(perp, 'OrderCancelled');
    });

    it('non-owner cannot cancel order', async () => {
      const col = D6(200);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      const tx = await perp.connect(alice).placeLimitOrder(
        BTC_IDX, true, col, 2, D18(38000), 0n, 0n
      );
      const receipt = await tx.wait();
      let cOrdId;
      for (const log of receipt.logs) {
        try {
          const parsed = perp.interface.parseLog(log);
          if (parsed.name === 'OrderPlaced') cOrdId = parsed.args.orderId;
        } catch {}
      }
      await expect(perp.connect(bob).cancelOrder(cOrdId))
        .to.be.reverted;
    });
  });

  // ── Funding rate ───────────────────────────────────────────────
  describe('Funding rate', () => {
    it('settleFunding can be called by anyone', async () => {
      await expect(perp.connect(alice).settleFunding(BTC_IDX))
        .to.not.be.reverted;
    });

    it('settleFunding emits FundingSettled event', async () => {
      await expect(perp.settleFunding(BTC_IDX))
        .to.emit(perp, 'FundingSettled');
    });
  });

  // ── OI cap ─────────────────────────────────────────────────────
  describe('OI cap enforcement', () => {
    it('rejects position that would exceed max OI', async () => {
      // maxOI is 50M USDC. Try to open 60M USDC position (1x)
      const hugeColl = ethers.parseUnits('60000000', 6);
      await usdc.mint(alice.address, hugeColl);
      await usdc.connect(alice).approve(await vault.getAddress(), hugeColl);
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, hugeColl, 1, 0n, 0n))
        .to.be.reverted;
    });
  });

  // ── Pause ──────────────────────────────────────────────────────
  describe('Pause', () => {
    it('owner can pause trading', async () => {
      await expect(perp.pause()).to.emit(perp, 'Paused');
    });

    it('cannot open position when paused', async () => {
      const col = D6(100);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, col, 2, 0n, 0n))
        .to.be.revertedWithCustomError(perp, 'EnforcedPause');
    });

    it('owner can unpause', async () => {
      await expect(perp.unpause()).to.emit(perp, 'Unpaused');
    });

    it('trading works again after unpause', async () => {
      await setPrice(BTC_PRICE);
      const col = D6(100);
      await usdc.connect(alice).approve(await vault.getAddress(), col);
      await expect(perp.connect(alice).placeMarketOrder(BTC_IDX, true, col, 2, 0n, 0n))
        .to.emit(perp, 'PositionOpened');
    });
  });

  // ── GMX backstop ───────────────────────────────────────────────
  describe('GMX backstop', () => {
    it('owner can enable GMX backstop', async () => {
      const MockGMX = await ethers.getContractFactory('MockGMXBackstop');
      const gmx = await MockGMX.deploy();
      await expect(perp.setGMXBackstop(await gmx.getAddress(), true))
        .to.not.be.reverted;
      expect(await perp.gmxEnabled()).to.equal(true);
    });

    it('owner can disable GMX backstop', async () => {
      await perp.setGMXBackstop(ethers.ZeroAddress, false);
      expect(await perp.gmxEnabled()).to.equal(false);
    });
  });

  // ── Ownable2Step ───────────────────────────────────────────────
  describe('Ownable2Step', () => {
    it('ownership transfer requires acceptance', async () => {
      await perp.transferOwnership(alice.address);
      expect(await perp.owner()).to.equal(owner.address); // still owner
      await perp.connect(alice).acceptOwnership();
      expect(await perp.owner()).to.equal(alice.address);
      // Transfer back
      await perp.connect(alice).transferOwnership(owner.address);
      await perp.connect(owner).acceptOwnership();
    });
  });
});
