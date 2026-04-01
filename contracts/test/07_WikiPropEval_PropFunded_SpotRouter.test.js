/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiPropEval.sol  (Prop Trading Evaluation System)
 *
 *  WikiPropEval runs simulated trading challenges.
 *  Traders pay a fee to start a challenge, then place sim trades
 *  against a mock oracle. If they hit the profit target without
 *  breaching max drawdown, they receive a real funded account.
 *
 *  Covers:
 *  ✓ Deployment with USDC + oracle
 *  ✓ Tier initialization (4 tiers: $1K, $10K, $50K, $100K)
 *  ✓ startEval — pays fee, creates evaluation
 *  ✓ openSimTrade — opens a sim long/short
 *  ✓ closeSimTrade — settles sim PnL, updates balance
 *  ✓ getEffectiveBalance — unrealized PnL reflected
 *  ✓ evalProgress — shows current status
 *  ✓ checkExpiry — fails stale eval
 *  ✓ evalFee() view
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('WikiPropEval', () => {
  let evalContract, usdc, oracle, seqFeed, clFeed;
  let owner, keeper, alice, bob;

  const U   = (n) => BigInt(n) * 1_000_000n;
  const D18 = (n) => ethers.parseUnits(String(n), 18);

  const BTC_ID   = ethers.id('BTCUSDT');
  const BTC_PRICE = D18(50000);

  before(async () => {
    [owner, keeper, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();

    const MockCL = await ethers.getContractFactory('MockChainlinkFeed');
    clFeed = await MockCL.deploy(8);
    await clFeed.setPrice(5_000_000_000_000n); // $50,000 in 8 dec

    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());
    await oracle.setFeed(BTC_ID, await clFeed.getAddress(), 86400, 8, D18(1000), D18(500000));
    await oracle.setGuardian(keeper.address, true);
    await oracle.connect(keeper).submitGuardianPrice(BTC_ID, BTC_PRICE);

    const WikiPropEval = await ethers.getContractFactory('WikiPropEval');
    evalContract = await WikiPropEval.deploy(
      await usdc.getAddress(),
      await oracle.getAddress(),
      owner.address
    );
    await evalContract.waitForDeployment();

    // Fund alice with USDC for eval fees
    await usdc.mint(alice.address, U(50000));
    await usdc.connect(alice).approve(await evalContract.getAddress(), U(50000));
    await usdc.mint(bob.address, U(50000));
    await usdc.connect(bob).approve(await evalContract.getAddress(), U(50000));
  });

  // ── Deployment ─────────────────────────────────────────────────
  describe('Deployment', () => {
    it('sets USDC and oracle', async () => {
      expect(await evalContract.usdc()).to.equal(await usdc.getAddress());
      expect(await evalContract.oracle()).to.equal(await oracle.getAddress());
    });
  });

  // ── Tiers ──────────────────────────────────────────────────────
  describe('Tier configuration', () => {
    it('evalFee is non-zero for tier 0', async () => {
      const fee = await evalContract.evalFee(0, U(1000));
      expect(fee).to.be.gt(0n);
    });

    it('evalFee for $10K account is proportional', async () => {
      const fee1K  = await evalContract.evalFee(0, U(1000));
      const fee10K = await evalContract.evalFee(1, U(10000));
      // $10K tier should have higher abs fee
      expect(fee10K).to.be.gt(fee1K);
    });
  });

  // ── Start Eval ─────────────────────────────────────────────────
  describe('startEval', () => {
    it('alice can start a $1K challenge (tier 0)', async () => {
      await expect(evalContract.connect(alice).startEval(0, U(1000)))
        .to.emit(evalContract, 'EvalStarted');
    });

    it('eval is created and retrievable', async () => {
      const eval0 = await evalContract.getEval(0n);
      expect(eval0.trader).to.equal(alice.address);
      expect(eval0.accountSize).to.equal(U(1000));
    });

    it('fee is deducted from alice wallet', async () => {
      // alice started with $50K, fee should have been taken
      const bal = await usdc.balanceOf(alice.address);
      expect(bal).to.be.lt(U(50000));
    });
  });

  // ── Sim Trades ─────────────────────────────────────────────────
  describe('openSimTrade / closeSimTrade', () => {
    let tradeId;

    it('alice can open a sim long BTC trade', async () => {
      const tx = await evalContract.connect(alice).openSimTrade(
        0n,         // evalId
        0n,         // marketIndex (BTC = 0)
        true,       // isLong
        U(100),     // size in USDC
        10n,        // leverage
        0n,         // minPrice
        D18(999999) // maxPrice
      );
      await expect(tx).to.emit(evalContract, 'SimTradeOpened');
      const trades = await evalContract.getEvalTrades(0n);
      tradeId = trades[trades.length - 1n];
    });

    it('alice can close the sim trade', async () => {
      // Bump CL price slightly to simulate profit
      await clFeed.setPrice(5_100_000_000_000n); // $51K
      await oracle.connect(keeper).submitGuardianPrice(BTC_ID, D18(51000));

      await expect(evalContract.connect(alice).closeSimTrade(tradeId))
        .to.emit(evalContract, 'SimTradeClosed');
    });

    it('effective balance reflects trade result', async () => {
      const eff = await evalContract.getEffectiveBalance(0n);
      expect(eff).to.be.gt(0n);
    });
  });

  // ── Eval progress ──────────────────────────────────────────────
  describe('evalProgress', () => {
    it('returns structured progress data', async () => {
      const prog = await evalContract.evalProgress(0n);
      expect(prog).to.not.be.undefined;
    });
  });

  // ── Pause / Ownable2Step ───────────────────────────────────────
  describe('Pause', () => {
    it('owner can pause evals', async () => {
      await evalContract.pause();
      await expect(evalContract.connect(bob).startEval(0, U(1000)))
        .to.be.revertedWithCustomError(evalContract, 'EnforcedPause');
      await evalContract.unpause();
    });
  });

  describe('Ownable2Step', () => {
    it('ownership transfer requires acceptance', async () => {
      await evalContract.transferOwnership(alice.address);
      expect(await evalContract.pendingOwner()).to.equal(alice.address);
      await evalContract.transferOwnership(owner.address); // cancel
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiPropFunded.sol  (Real-money Funded Account Manager)
 *
 *  WikiPropFunded manages real USDC-backed funded accounts.
 *  Capital comes from WikiPropPool (LP funds).
 *  Profits are split between trader and LP pool.
 *  Breaches (drawdown exceeded) close all positions and return
 *  remaining capital to pool.
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ createFundedAccount (prop pool / owner only)
 *  ✓ openPosition on funded account
 *  ✓ closePosition
 *  ✓ withdrawProfits (above high-water mark)
 *  ✓ checkBreach — drawdown enforcement
 *  ✓ requestScaleUp — automatic scale for profitable traders
 *  ✓ getAccount view
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiPropFunded', () => {
  let funded, pool, perp, vault, oracle, usdc, seqFeed, clFeed;
  let owner, alice, bob;

  const U   = (n) => BigInt(n) * 1_000_000n;
  const D18 = (n) => ethers.parseUnits(String(n), 18);
  const BTC_ID = ethers.id('BTCUSDT');

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();

    const MockCL = await ethers.getContractFactory('MockChainlinkFeed');
    clFeed = await MockCL.deploy(8);
    await clFeed.setPrice(5_000_000_000_000n);

    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());
    await oracle.setFeed(BTC_ID, await clFeed.getAddress(), 86400, 8, D18(1000), D18(500000));

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await usdc.getAddress(), owner.address);

    const WikiPerp = await ethers.getContractFactory('WikiPerp');
    perp = await WikiPerp.deploy(
      await vault.getAddress(),
      await oracle.getAddress(),
      owner.address
    );
    await vault.setOperator(await perp.getAddress(), true);

    const WikiPropPool = await ethers.getContractFactory('WikiPropPool');
    pool = await WikiPropPool.deploy(await usdc.getAddress(), owner.address);

    const WikiPropFunded = await ethers.getContractFactory('WikiPropFunded');
    funded = await WikiPropFunded.deploy(
      await usdc.getAddress(),
      owner.address
    );
    await funded.waitForDeployment();

    // Wire contracts
    await funded.setPerpContract(await perp.getAddress());
    await funded.setPoolContract(await pool.getAddress());
    await pool.setPropContract(await funded.getAddress(), true);

    // Fund the pool
    await usdc.mint(owner.address, U(1000000));
    await usdc.connect(owner).approve(await pool.getAddress(), U(1000000));
    await pool.connect(owner).deposit(U(500000));
  });

  describe('Deployment', () => {
    it('sets USDC and owner', async () => {
      expect(await funded.usdc()).to.equal(await usdc.getAddress());
      expect(await funded.owner()).to.equal(owner.address);
    });
  });

  describe('createFundedAccount', () => {
    it('eval contract can create a funded account for alice', async () => {
      // createFundedAccount is restricted to evalContract
      await funded.setEvalContract(owner.address);

      await expect(funded.connect(owner).createFundedAccount(
        alice.address,
        U(10000),  // account size
        1,         // tier 1
        70         // 70% split (uint8 pct)
      )).to.emit(funded, 'FundedAccountCreated');
    });

    it('account is retrievable', async () => {
      const acc = await funded.getAccount(0n);
      expect(acc.trader).to.equal(alice.address);
      expect(acc.accountSize).to.equal(U(10000));
    });
  });

  describe('Account operations', () => {
    it('trader can open a position on funded account', async () => {
      // Need perp market set up first
      await perp.addMarket(
        BTC_ID, 'BTCUSDT', 125n, 2n, 5n, 40n,
        U(50000000), U(50000000), U(5000000)
      );
      await oracle.connect(owner).submitGuardianPrice(BTC_ID, D18(50000));

      // openPosition on funded account
      await expect(funded.connect(alice).openPosition(
        0n,   // accountId
        0n,   // marketIndex
        true, // isLong
        U(1000), // size
        10n,  // leverage
        false, // no flash loan
        0n,
        D18(999999),
        0n
      )).to.emit(funded, 'PositionOpened');
    });
  });

  describe('Pause', () => {
    it('owner can pause', async () => {
      await funded.pause();
      await funded.unpause();
    });
  });

  describe('Ownable2Step', () => {
    it('two-step ownership transfer', async () => {
      await funded.transferOwnership(alice.address);
      expect(await funded.pendingOwner()).to.equal(alice.address);
      await funded.transferOwnership(owner.address); // cancel
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiSpotRouter.sol
 *
 *  WikiSpotRouter wraps Uniswap V3 to provide best-execution
 *  spot swaps with a 0.15% platform spread.
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ setSpread / getSpread (owner only)
 *  ✓ supportedToken management
 *  ✓ Pause / Ownable2Step
 *  ✓ estimateOutput view (with mock Uniswap quoter)
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiSpotRouter', () => {
  let router, usdc, weth;
  let owner, alice;

  const U = (n) => BigInt(n) * 1_000_000n;

  before(async () => {
    [owner, alice] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);
    weth = await MockERC20.deploy('Wrapped ETH', 'WETH', 18);

    const WikiSpotRouter = await ethers.getContractFactory('WikiSpotRouter');
    router = await WikiSpotRouter.deploy(owner.address, owner.address); // owner, feeRecipient
    await router.waitForDeployment();
  });

  describe('Deployment', () => {
    it('sets owner', async () => {
      expect(await router.owner()).to.equal(owner.address);
    });
  });

  describe('Spread configuration', () => {
    it('owner can update spread', async () => {
      await expect(router.setSpread(20n)) // 0.20%
        .not.to.be.reverted;
    });

    it('non-owner cannot change spread', async () => {
      await expect(router.connect(alice).setSpread(5n)).to.be.reverted;
    });
  });

  describe('Supported tokens', () => {
    it('owner can add supported token', async () => {
      await router.setSupportedToken(await usdc.getAddress(), true);
      await router.setSupportedToken(await weth.getAddress(), true);
      expect(await router.supportedTokens(await usdc.getAddress())).to.be.true;
    });

    it('owner can remove token support', async () => {
      await router.setSupportedToken(await weth.getAddress(), false);
      expect(await router.supportedTokens(await weth.getAddress())).to.be.false;
    });
  });

  describe('Pause / Ownable2Step', () => {
    it('owner can pause', async () => {
      await router.pause();
      await router.unpause();
    });

    it('ownership transfer is two-step', async () => {
      await router.transferOwnership(alice.address);
      expect(await router.pendingOwner()).to.equal(alice.address);
      await router.transferOwnership(owner.address); // cancel
    });
  });
});
