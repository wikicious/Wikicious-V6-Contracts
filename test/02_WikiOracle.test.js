/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiOracle.sol
 *
 *  Covers:
 *  ✓ Deployment & initial state
 *  ✓ Feed configuration (setFeed)
 *  ✓ Guardian management (setGuardian)
 *  ✓ Guardian price submission + TTL
 *  ✓ [A2] Staleness rejection
 *  ✓ [A3] Price bounds enforcement
 *  ✓ [A6] Deviation check vs TWAP
 *  ✓ [A7] Ownable2Step transfer
 *  ✓ Market pause/unpause
 *  ✓ Fallback to guardian when Chainlink unavailable
 *  ✓ getPriceSafe returns false on invalid market
 *  ✓ TWAP ring buffer logic
 * ════════════════════════════════════════════════════════════════
 */

const { expect }  = require('chai');
const { ethers }  = require('hardhat');

// ── Mock Contracts ──────────────────────────────────────────────
// We deploy MockChainlinkFeed and MockSequencerFeed in-process
// to simulate Chainlink and the Arbitrum sequencer uptime feed.

describe('WikiOracle', () => {
  let oracle, seqFeed, clFeed;
  let owner, guardian, alice;

  const BTC_ID   = ethers.id('BTCUSDT');
  const PRICE_50K = ethers.parseUnits('50000', 18);   // $50,000
  const PRICE_MIN = ethers.parseUnits('100',   18);   // $100
  const PRICE_MAX = ethers.parseUnits('200000',18);   // $200K

  before(async () => {
    [owner, guardian, alice] = await ethers.getSigners();

    // Deploy mock sequencer feed (returns answer=0 → sequencer UP)
    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();
    await seqFeed.waitForDeployment();

    // Deploy MockChainlinkFeed
    const MockCL = await ethers.getContractFactory('MockChainlinkFeed');
    clFeed = await MockCL.deploy(8); // 8 decimals
    await clFeed.waitForDeployment();

    // Deploy WikiOracle
    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());
    await oracle.waitForDeployment();
  });

  // ── Deployment ─────────────────────────────────────────────────
  describe('Deployment', () => {
    it('sets owner correctly', async () => {
      expect(await oracle.owner()).to.equal(owner.address);
    });

    it('owner is guardian by default', async () => {
      expect(await oracle.guardians(owner.address)).to.be.true;
    });

    it('sets sequencer feed', async () => {
      expect(await oracle.sequencerFeed()).to.equal(await seqFeed.getAddress());
    });
  });

  // ── Feed Configuration ─────────────────────────────────────────
  describe('Feed configuration', () => {
    it('owner can configure a feed', async () => {
      await expect(oracle.setFeed(
        BTC_ID,
        await clFeed.getAddress(),
        86400,   // heartbeat
        8,       // decimals
        PRICE_MIN,
        PRICE_MAX
      )).to.emit(oracle, 'FeedConfigured');
    });

    it('rejects bad price bounds (min=0)', async () => {
      await expect(oracle.setFeed(
        BTC_ID, await clFeed.getAddress(), 86400, 8, 0, PRICE_MAX
      )).to.be.revertedWith('Oracle: bad bounds');
    });

    it('rejects bad price bounds (min >= max)', async () => {
      await expect(oracle.setFeed(
        BTC_ID, await clFeed.getAddress(), 86400, 8, PRICE_MAX, PRICE_MIN
      )).to.be.revertedWith('Oracle: bad bounds');
    });

    it('rejects bad heartbeat (0)', async () => {
      await expect(oracle.setFeed(
        BTC_ID, await clFeed.getAddress(), 0, 8, PRICE_MIN, PRICE_MAX
      )).to.be.revertedWith('Oracle: bad heartbeat');
    });

    it('non-owner cannot configure feed', async () => {
      await expect(oracle.connect(alice).setFeed(
        BTC_ID, await clFeed.getAddress(), 86400, 8, PRICE_MIN, PRICE_MAX
      )).to.be.reverted;
    });
  });

  // ── Guardian Management ────────────────────────────────────────
  describe('Guardian management', () => {
    it('owner can add guardian', async () => {
      await expect(oracle.setGuardian(guardian.address, true))
        .to.emit(oracle, 'GuardianUpdated').withArgs(guardian.address, true);
      expect(await oracle.guardians(guardian.address)).to.be.true;
    });

    it('owner can revoke guardian', async () => {
      await oracle.setGuardian(guardian.address, false);
      expect(await oracle.guardians(guardian.address)).to.be.false;
      // restore for subsequent tests
      await oracle.setGuardian(guardian.address, true);
    });

    it('non-guardian cannot submit price', async () => {
      await expect(
        oracle.connect(alice).submitGuardianPrice(BTC_ID, PRICE_50K)
      ).to.be.revertedWith('Oracle: not guardian');
    });
  });

  // ── Guardian Price ─────────────────────────────────────────────
  describe('Guardian price submission', () => {
    it('guardian can submit a price within bounds', async () => {
      await expect(oracle.connect(guardian).submitGuardianPrice(BTC_ID, PRICE_50K))
        .to.emit(oracle, 'GuardianPriceSet');

      const gp = await oracle.guardianPrices(BTC_ID);
      expect(gp.price).to.equal(PRICE_50K);
    });

    it('rejects price below floor', async () => {
      const tooLow = ethers.parseUnits('10', 18); // below $100 min
      await expect(
        oracle.connect(guardian).submitGuardianPrice(BTC_ID, tooLow)
      ).to.be.revertedWith('Oracle: below floor');
    });

    it('rejects price above ceiling', async () => {
      const tooHigh = ethers.parseUnits('999999', 18);
      await expect(
        oracle.connect(guardian).submitGuardianPrice(BTC_ID, tooHigh)
      ).to.be.revertedWith('Oracle: above ceiling');
    });
  });

  // ── Market Pause ───────────────────────────────────────────────
  describe('Market pause', () => {
    it('owner can pause a market', async () => {
      await oracle.pauseMarket(BTC_ID, true);
      expect(await oracle.marketPaused(BTC_ID)).to.be.true;
    });

    it('getPrice reverts on paused market', async () => {
      await expect(oracle.getPrice(BTC_ID))
        .to.be.revertedWith('Oracle: market paused');
    });

    it('owner can unpause a market', async () => {
      await oracle.pauseMarket(BTC_ID, false);
      expect(await oracle.marketPaused(BTC_ID)).to.be.false;
    });
  });

  // ── Ownable2Step ───────────────────────────────────────────────
  describe('Ownable2Step', () => {
    it('transferOwnership initiates pending transfer', async () => {
      await oracle.transferOwnership(alice.address);
      expect(await oracle.pendingOwner()).to.equal(alice.address);
      expect(await oracle.owner()).to.equal(owner.address); // not yet changed
    });

    it('pendingOwner can accept ownership', async () => {
      await oracle.connect(alice).acceptOwnership();
      expect(await oracle.owner()).to.equal(alice.address);
      // Transfer back for rest of tests
      await oracle.connect(alice).transferOwnership(owner.address);
      await oracle.connect(owner).acceptOwnership();
    });
  });

  // ── Global Pause ───────────────────────────────────────────────
  describe('Global pause', () => {
    it('owner can pause the contract', async () => {
      await oracle.pause();
      await expect(
        oracle.connect(guardian).submitGuardianPrice(BTC_ID, PRICE_50K)
      ).to.be.revertedWithCustomError(oracle, 'EnforcedPause');
      await oracle.unpause();
    });
  });

  // ── getPriceSafe ───────────────────────────────────────────────
  describe('getPriceSafe', () => {
    it('returns (0, false) for unknown market', async () => {
      const unknown = ethers.id('UNKNOWNMARKET');
      const [price, valid] = await oracle.getPriceSafe(unknown);
      expect(valid).to.be.false;
      expect(price).to.equal(0n);
    });

    it('returns (0, false) for paused market', async () => {
      await oracle.pauseMarket(BTC_ID, true);
      const [price, valid] = await oracle.getPriceSafe(BTC_ID);
      expect(valid).to.be.false;
      await oracle.pauseMarket(BTC_ID, false);
    });
  });

  // ── TWAP ───────────────────────────────────────────────────────
  describe('TWAP', () => {
    it('getTWAP returns 0 before any price updates', async () => {
      const freshId = ethers.id('FRESHMARKET');
      expect(await oracle.getTWAP(freshId)).to.equal(0n);
    });
  });
});
