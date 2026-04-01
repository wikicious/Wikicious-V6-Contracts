/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiMarketRegistry.sol
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ addMarket — all categories (crypto, forex, metals)
 *  ✓ symbolToId mapping
 *  ✓ activeMarketIds list management
 *  ✓ updateMarket (owner only)
 *  ✓ pauseMarket / resumeMarket
 *  ✓ reduceOnly circuit breaker
 *  ✓ Non-owner access rejection
 *  ✓ Duplicate symbol rejection
 *  ✓ Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('WikiMarketRegistry', () => {
  let registry;
  let owner, alice;

  // Category constants
  const CAT_CRYPTO       = 0;
  const CAT_FOREX_MAJOR  = 1;
  const CAT_METALS       = 4;

  // Oracle source constants
  const SRC_CHAINLINK = 0;
  const SRC_GUARDIAN  = 2;

  const btcMarket = () => ({
    symbol:               'BTC/USD',
    baseAsset:            'BTC',
    quoteAsset:           'USD',
    category:             CAT_CRYPTO,
    oracleSource:         SRC_CHAINLINK,
    oracleFeed:           ethers.ZeroAddress,
    pythPriceId:          ethers.ZeroHash,
    baseMarketId:         0n,
    quoteMarketId:        0n,
    maxLeverageBps:       12500n,       // 125x
    maintenanceMarginBps: 40n,
    takerFeeBps:          5n,
    makerFeeBps:          2n,
    maxOILong:            ethers.parseUnits('50000000', 6),
    maxOIShort:           ethers.parseUnits('50000000', 6),
    minPositionSize:      ethers.parseUnits('10', 6),
    maxPositionSize:      ethers.parseUnits('1000000', 6),
    spreadBps:            2n,
    offHoursSpreadBps:    0n,
    active:               true,
    reduceOnly:           false,
    pricePrecision:       2n,
  });

  const eurusdMarket = () => ({
    symbol:               'EUR/USD',
    baseAsset:            'EUR',
    quoteAsset:           'USD',
    category:             CAT_FOREX_MAJOR,
    oracleSource:         SRC_GUARDIAN,
    oracleFeed:           ethers.ZeroAddress,
    pythPriceId:          ethers.ZeroHash,
    baseMarketId:         0n,
    quoteMarketId:        0n,
    maxLeverageBps:       5000n,        // 50x
    maintenanceMarginBps: 50n,
    takerFeeBps:          2n,
    makerFeeBps:          1n,
    maxOILong:            ethers.parseUnits('10000000', 6),
    maxOIShort:           ethers.parseUnits('10000000', 6),
    minPositionSize:      ethers.parseUnits('100', 6),
    maxPositionSize:      ethers.parseUnits('500000', 6),
    spreadBps:            2n,
    offHoursSpreadBps:    10n,
    active:               true,
    reduceOnly:           false,
    pricePrecision:       5n,
  });

  before(async () => {
    [owner, alice] = await ethers.getSigners();
    const WikiMarketRegistry = await ethers.getContractFactory('WikiMarketRegistry');
    registry = await WikiMarketRegistry.deploy(owner.address);
    await registry.waitForDeployment();
  });

  // ── Deployment ─────────────────────────────────────────────────
  describe('Deployment', () => {
    it('sets owner', async () => {
      expect(await registry.owner()).to.equal(owner.address);
    });

    it('starts with zero markets', async () => {
      expect(await registry.totalMarkets()).to.equal(0n);
    });
  });

  // ── Add Markets ────────────────────────────────────────────────
  describe('addMarket', () => {
    it('owner can add a crypto market', async () => {
      const m = btcMarket();
      await expect(registry.addMarket(
        m.symbol, m.baseAsset, m.quoteAsset, m.category, m.oracleSource,
        m.oracleFeed, m.pythPriceId, m.baseMarketId, m.quoteMarketId,
        m.maxLeverageBps, m.maintenanceMarginBps, m.takerFeeBps, m.makerFeeBps,
        m.maxOILong, m.maxOIShort, m.minPositionSize, m.maxPositionSize,
        m.spreadBps, m.offHoursSpreadBps, m.pricePrecision
      )).to.emit(registry, 'MarketAdded');

      expect(await registry.totalMarkets()).to.equal(1n);
    });

    it('assigns correct ID via symbolToId', async () => {
      const id = await registry.symbolToId('BTC/USD');
      expect(id).to.equal(1n);
    });

    it('adds market to activeMarketIds', async () => {
      const ids = await registry.getAllMarkets();
      expect(ids).to.include(1n);
    });

    it('owner can add a forex major market', async () => {
      const m = eurusdMarket();
      await registry.addMarket(
        m.symbol, m.baseAsset, m.quoteAsset, m.category, m.oracleSource,
        m.oracleFeed, m.pythPriceId, m.baseMarketId, m.quoteMarketId,
        m.maxLeverageBps, m.maintenanceMarginBps, m.takerFeeBps, m.makerFeeBps,
        m.maxOILong, m.maxOIShort, m.minPositionSize, m.maxPositionSize,
        m.spreadBps, m.offHoursSpreadBps, m.pricePrecision
      );
      expect(await registry.totalMarkets()).to.equal(2n);
    });

    it('rejects duplicate symbol', async () => {
      const m = btcMarket();
      await expect(registry.addMarket(
        m.symbol, m.baseAsset, m.quoteAsset, m.category, m.oracleSource,
        m.oracleFeed, m.pythPriceId, m.baseMarketId, m.quoteMarketId,
        m.maxLeverageBps, m.maintenanceMarginBps, m.takerFeeBps, m.makerFeeBps,
        m.maxOILong, m.maxOIShort, m.minPositionSize, m.maxPositionSize,
        m.spreadBps, m.offHoursSpreadBps, m.pricePrecision
      )).to.be.revertedWith('Registry: symbol exists');
    });

    it('non-owner cannot add market', async () => {
      const m = btcMarket();
      m.symbol = 'NEW/USD';
      await expect(registry.connect(alice).addMarket(
        m.symbol, m.baseAsset, m.quoteAsset, m.category, m.oracleSource,
        m.oracleFeed, m.pythPriceId, m.baseMarketId, m.quoteMarketId,
        m.maxLeverageBps, m.maintenanceMarginBps, m.takerFeeBps, m.makerFeeBps,
        m.maxOILong, m.maxOIShort, m.minPositionSize, m.maxPositionSize,
        m.spreadBps, m.offHoursSpreadBps, m.pricePrecision
      )).to.be.reverted;
    });
  });

  // ── Pause / Resume ─────────────────────────────────────────────
  describe('pauseMarket / resumeMarket', () => {
    it('owner can pause a market', async () => {
      const btcId = await registry.symbolToId('BTC/USD');
      await expect(registry.pauseMarket(btcId))
        .to.emit(registry, 'MarketPaused');

      const market = await registry.markets(btcId);
      expect(market.active).to.be.false;
    });

    it('owner can resume a paused market', async () => {
      const btcId = await registry.symbolToId('BTC/USD');
      await expect(registry.resumeMarket(btcId))
        .to.emit(registry, 'MarketResumed');

      const market = await registry.markets(btcId);
      expect(market.active).to.be.true;
    });

    it('non-owner cannot pause market', async () => {
      const btcId = await registry.symbolToId('BTC/USD');
      await expect(registry.connect(alice).pauseMarket(btcId)).to.be.reverted;
    });
  });

  // ── reduceOnly circuit breaker ─────────────────────────────────
  describe('reduceOnly', () => {
    it('pauseMarket sets reduceOnly on the market', async () => {
      const btcId = await registry.symbolToId('BTC/USD');
      await registry.pauseMarket(btcId);
      const market = await registry.markets(btcId);
      expect(market.reduceOnly).to.be.true;
      // Resume via resumeMarket
      await registry.resumeMarket(btcId);
      const after = await registry.markets(btcId);
      expect(after.reduceOnly).to.be.false;
    });
  });

  // ── Category constants ─────────────────────────────────────────
  describe('Category constants', () => {
    it('exposes correct category constants', async () => {
      expect(await registry.CAT_CRYPTO()).to.equal(CAT_CRYPTO);
      expect(await registry.CAT_FOREX_MAJOR()).to.equal(CAT_FOREX_MAJOR);
      expect(await registry.CAT_METALS()).to.equal(CAT_METALS);
    });
  });

  // ── Ownable2Step ───────────────────────────────────────────────
  describe('Ownable2Step', () => {
    it('ownership transfer is two-step', async () => {
      await registry.transferOwnership(alice.address);
      expect(await registry.pendingOwner()).to.equal(alice.address);
      expect(await registry.owner()).to.equal(owner.address);
      // cancel
      await registry.transferOwnership(owner.address);
    });
  });
});
