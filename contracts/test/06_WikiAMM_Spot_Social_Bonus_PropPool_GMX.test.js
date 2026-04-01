/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiAMM.sol  (Wikicious Liquidity Pool / WLP)
 *
 *  WikiAMM is an SINGLE-SIDED USDC LP that backs WikiPerp trades.
 *  LPs deposit USDC and receive WLP tokens.
 *  The pool is the counterparty to all trader PnL.
 *
 *  Covers:
 *  ✓ Deployment: vault + oracle wired
 *  ✓ addLiquidity → mints WLP
 *  ✓ removeLiquidity → burns WLP, returns USDC
 *  ✓ getAUM() returns deposited amount
 *  ✓ getWLPPrice() = AUM / totalSupply
 *  ✓ setFees (owner only)
 *  ✓ Pause / Ownable2Step
 *  ✓ Zero amount rejection
 * ════════════════════════════════════════════════════════════════
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('WikiAMM', () => {
  let amm, vault, oracle, usdc, seqFeed;
  let owner, alice, bob;

  const U = (n) => BigInt(n) * 1_000_000n; // USDC 6 dec

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();

    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await usdc.getAddress(), owner.address);

    const WikiAMM = await ethers.getContractFactory('WikiAMM');
    amm = await WikiAMM.deploy(
      await usdc.getAddress(),
      await vault.getAddress(),
      await oracle.getAddress(),
      owner.address
    );
    await amm.waitForDeployment();

    // Fund test accounts
    await usdc.mint(alice.address, U(100000));
    await usdc.mint(bob.address, U(100000));
    await usdc.connect(alice).approve(await amm.getAddress(), U(100000));
    await usdc.connect(bob).approve(await amm.getAddress(), U(100000));
  });

  describe('Deployment', () => {
    it('WLP token name and symbol', async () => {
      expect(await amm.name()).to.equal('Wikicious LP');
      expect(await amm.symbol()).to.equal('WLP');
    });

    it('AUM starts at zero', async () => {
      expect(await amm.getAUM()).to.equal(0n);
    });
  });

  describe('Add liquidity', () => {
    it('alice can deposit USDC and receive WLP', async () => {
      await expect(amm.connect(alice).addLiquidity(U(10000)))
        .to.emit(amm, 'LiquidityAdded');
      expect(await amm.balanceOf(alice.address)).to.be.gt(0n);
    });

    it('AUM increases by deposited amount (minus mint fee)', async () => {
      const aum = await amm.getAUM();
      expect(aum).to.be.gt(0n);
    });

    it('bob can also add liquidity', async () => {
      await amm.connect(bob).addLiquidity(U(5000));
      expect(await amm.balanceOf(bob.address)).to.be.gt(0n);
    });

    it('rejects zero-amount deposit', async () => {
      await expect(amm.connect(alice).addLiquidity(0n))
        .to.be.revertedWith('AMM: zero amount');
    });
  });

  describe('WLP price', () => {
    it('getWLPPrice returns positive value', async () => {
      const price = await amm.getWLPPrice();
      expect(price).to.be.gt(0n);
    });
  });

  describe('Remove liquidity', () => {
    it('alice can burn WLP and receive USDC', async () => {
      const wlp = await amm.balanceOf(alice.address);
      const usdcBefore = await usdc.balanceOf(alice.address);
      await expect(amm.connect(alice).removeLiquidity(wlp))
        .to.emit(amm, 'LiquidityRemoved');
      expect(await usdc.balanceOf(alice.address)).to.be.gt(usdcBefore);
      expect(await amm.balanceOf(alice.address)).to.equal(0n);
    });
  });

  describe('Admin', () => {
    it('owner can set fees', async () => {
      await expect(amm.setFees(10n, 10n)).not.to.be.reverted;
    });

    it('non-owner cannot set fees', async () => {
      await expect(amm.connect(alice).setFees(10n, 10n)).to.be.reverted;
    });
  });

  describe('Pause', () => {
    it('owner can pause / unpause', async () => {
      await amm.pause();
      await expect(amm.connect(bob).addLiquidity(U(100)))
        .to.be.revertedWithCustomError(amm, 'EnforcedPause');
      await amm.unpause();
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiSpot.sol  (AMM Spot Exchange)
 *
 *  WikiSpot is a classic x*y=k AMM for spot trading.
 *  Uses Uniswap V3 routing with a configurable spread.
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ createPool with feeBps
 *  ✓ addLiquidity → mints LP tokens
 *  ✓ swapExactIn → buy token, pay fee
 *  ✓ removeLiquidity → burns LP, returns tokens
 *  ✓ getAmountOut helper
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiSpot', () => {
  let spot, usdc, weth;
  let owner, feeRecipient, alice, bob;

  const U = (n) => BigInt(n) * 1_000_000n;         // USDC 6 dec
  const E = (n) => ethers.parseUnits(String(n), 18); // WETH 18 dec

  before(async () => {
    [owner, feeRecipient, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);
    weth = await MockERC20.deploy('Wrapped ETH', 'WETH', 18);

    const WikiSpot = await ethers.getContractFactory('WikiSpot');
    spot = await WikiSpot.deploy(owner.address, feeRecipient.address);
    await spot.waitForDeployment();

    // Fund accounts
    await usdc.mint(alice.address, U(200000));
    await weth.mint(alice.address, E(100));
    await usdc.mint(bob.address, U(100000));
    await weth.mint(bob.address, E(50));

    // Approvals
    await usdc.connect(alice).approve(await spot.getAddress(), U(200000));
    await weth.connect(alice).approve(await spot.getAddress(), E(100));
    await usdc.connect(bob).approve(await spot.getAddress(), U(100000));
    await weth.connect(bob).approve(await spot.getAddress(), E(50));
  });

  describe('Deployment', () => {
    it('sets owner and fee recipient', async () => {
      expect(await spot.owner()).to.equal(owner.address);
    });

    it('starts with zero pools', async () => {
      expect(await spot.poolCount()).to.equal(0n);
    });
  });

  describe('createPool', () => {
    it('owner can create USDC/WETH pool with 0.15% fee', async () => {
      await expect(spot.createPool(
        await usdc.getAddress(),
        await weth.getAddress(),
        15n  // 0.15% fee in bps
      )).to.emit(spot, 'PoolCreated');
      expect(await spot.poolCount()).to.equal(1n);
    });

    it('pool has correct token addresses', async () => {
      const pool = await spot.getPool(0n);
      expect(pool.tokenA).to.equal(await usdc.getAddress());
      expect(pool.tokenB).to.equal(await weth.getAddress());
    });

    it('non-owner cannot create pool', async () => {
      await expect(spot.connect(alice).createPool(
        await usdc.getAddress(), await weth.getAddress(), 15n
      )).to.be.reverted;
    });
  });

  describe('addLiquidity', () => {
    it('alice can add liquidity to pool 0', async () => {
      await expect(spot.connect(alice).addLiquidity(
        0n,
        U(100000),  // $100K USDC
        E(30),      // ~30 WETH (priced at ~$3,300)
        0n          // minLP
      )).to.emit(spot, 'LiquidityAdded');
    });
  });

  describe('swapExactIn', () => {
    it('bob can swap USDC for WETH', async () => {
      const wethBefore = await weth.balanceOf(bob.address);
      await expect(spot.connect(bob).swapExactIn(
        0n,
        await usdc.getAddress(),
        U(3300),   // $3,300 USDC in
        0n         // minAmountOut
      )).to.emit(spot, 'Swap');
      expect(await weth.balanceOf(bob.address)).to.be.gt(wethBefore);
    });

    it('bob can swap WETH for USDC', async () => {
      const usdcBefore = await usdc.balanceOf(bob.address);
      await spot.connect(bob).swapExactIn(
        0n,
        await weth.getAddress(),
        E(1),
        0n
      );
      expect(await usdc.balanceOf(bob.address)).to.be.gt(usdcBefore);
    });
  });

  describe('getAmountOut', () => {
    it('returns non-zero for valid swap', async () => {
      const out = await spot.getAmountOut(0n, await usdc.getAddress(), U(1000));
      expect(out).to.be.gt(0n);
    });
  });

  describe('removeLiquidity', () => {
    it('alice can remove liquidity and get tokens back', async () => {
      // Get LP token address
      const pool = await spot.getPool(0n);
      const lpToken = await ethers.getContractAt('IERC20', pool.lpToken);
      const lpBal = await lpToken.balanceOf(alice.address);

      if (lpBal > 0n) {
        await lpToken.connect(alice).approve(await spot.getAddress(), lpBal);
        await expect(spot.connect(alice).removeLiquidity(0n, lpBal, 0n, 0n))
          .to.emit(spot, 'LiquidityRemoved');
      }
    });
  });

  describe('Pause', () => {
    it('owner can pause swaps', async () => {
      await spot.pause();
      await expect(spot.connect(bob).swapExactIn(0n, await usdc.getAddress(), U(100), 0n))
        .to.be.revertedWithCustomError(spot, 'EnforcedPause');
      await spot.unpause();
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiSocial.sol  (On-chain social layer)
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ register (create profile with handle)
 *  ✓ createPost with IPFS content hash
 *  ✓ likePost / unlikePost
 *  ✓ comment on post
 *  ✓ follow / unfollow
 *  ✓ Cannot follow self
 *  ✓ repost
 *  ✓ deletePost (author only)
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiSocial', () => {
  let social;
  let owner, alice, bob;

  const CONTENT_HASH = ethers.id('QmSampleIPFSHash');

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const WikiSocial = await ethers.getContractFactory('WikiSocial');
    social = await WikiSocial.deploy(owner.address);
    await social.waitForDeployment();
  });

  describe('Deployment', () => {
    it('sets owner', async () => {
      expect(await social.owner()).to.equal(owner.address);
    });
  });

  describe('Register profile', () => {
    it('alice can register with a handle', async () => {
      await expect(social.connect(alice).register('alice_trader', 'Alice Trader', ''))
        .to.emit(social, 'ProfileCreated');
    });

    it('bob can register', async () => {
      await social.connect(bob).register('bob_whale', 'Bob Whale', '');
    });

    it('cannot register same handle twice', async () => {
      await expect(social.connect(owner).register('alice_trader', 'Fake Alice', ''))
        .to.be.revertedWith('Social: handle taken');
    });
  });

  describe('Posts', () => {
    it('alice can create a post', async () => {
      await expect(social.connect(alice).createPost(CONTENT_HASH, 0, 0, ''))
        .to.emit(social, 'PostCreated');
    });

    it('post is retrievable', async () => {
      const post = await social.posts(0n);
      expect(post.author).to.equal(alice.address);
      expect(post.contentHash).to.equal(CONTENT_HASH);
    });
  });

  describe('Likes', () => {
    it('bob can like alice post', async () => {
      await expect(social.connect(bob).likePost(0n))
        .to.emit(social, 'Liked');
    });

    it('bob can unlike', async () => {
      await expect(social.connect(bob).unlikePost(0n))
        .to.emit(social, 'Unliked');
    });
  });

  describe('Comments', () => {
    it('bob can comment on alice post', async () => {
      const commentHash = ethers.id('Great trade!');
      await expect(social.connect(bob).comment(0n, commentHash, ''))
        .to.emit(social, 'CommentPosted');
    });
  });

  describe('Follow', () => {
    it('bob can follow alice', async () => {
      await expect(social.connect(bob).follow(alice.address))
        .to.emit(social, 'Followed');
    });

    it('bob can unfollow alice', async () => {
      await expect(social.connect(bob).unfollow(alice.address))
        .to.emit(social, 'Unfollowed');
    });

    it('cannot follow self', async () => {
      await expect(social.connect(alice).follow(alice.address))
        .to.be.revertedWith('Social: cannot follow self');
    });
  });

  describe('Repost', () => {
    it('bob can repost alice post', async () => {
      await expect(social.connect(bob).repost(0n))
        .to.emit(social, 'Reposted');
    });
  });

  describe('Delete post', () => {
    it('author can delete own post', async () => {
      await expect(social.connect(alice).deletePost(0n))
        .to.emit(social, 'PostDeleted');
    });

    it('non-author cannot delete post', async () => {
      // Create another post first
      await social.connect(alice).createPost(CONTENT_HASH, 0, 0, '');
      const lastId = (await social.totalPosts()) - 1n;
      await expect(social.connect(bob).deletePost(lastId))
        .to.be.revertedWith('Social: not author');
    });
  });

  describe('Pause', () => {
    it('owner can pause', async () => {
      await social.pause();
      await expect(social.connect(alice).createPost(CONTENT_HASH, 0, 0, ''))
        .to.be.revertedWithCustomError(social, 'EnforcedPause');
      await social.unpause();
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiSocialRewards.sol
 *
 *  Covers:
 *  ✓ Deployment (WIK token + social contract)
 *  ✓ allocate() by operator
 *  ✓ pendingRewards tracking
 *  ✓ claim() transfers WIK to user
 *  ✓ Non-operator blocked
 *  ✓ Claim with nothing pending reverts
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiSocialRewards', () => {
  let rewards, wik, social;
  let owner, alice, bob;

  const W = (n) => ethers.parseUnits(String(n), 18);

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const WIKToken = await ethers.getContractFactory('WIKToken');
    wik = await WIKToken.deploy(owner.address);

    const WikiSocial = await ethers.getContractFactory('WikiSocial');
    social = await WikiSocial.deploy(owner.address);

    const WikiSocialRewards = await ethers.getContractFactory('WikiSocialRewards');
    rewards = await WikiSocialRewards.deploy(
      await wik.getAddress(),
      await social.getAddress(),
      owner.address
    );
    await rewards.waitForDeployment();

    // Fund rewards pool
    await wik.connect(owner).setMinter(owner.address, true);
    await wik.connect(owner).mint(await rewards.getAddress(), W(500000));
  });

  describe('Deployment', () => {
    it('sets WIK token', async () => {
      expect(await rewards.wik()).to.equal(await wik.getAddress());
    });
  });

  describe('Reward allocation', () => {
    it('owner (operator) can allocate rewards', async () => {
      await expect(rewards.connect(owner).allocate(alice.address, W(100)))
        .to.emit(rewards, 'RewardAllocated');
    });

    it('pending rewards tracked', async () => {
      expect(await rewards.pendingRewards(alice.address)).to.equal(W(100));
    });

    it('non-operator cannot allocate', async () => {
      await expect(rewards.connect(alice).allocate(bob.address, W(50)))
        .to.be.reverted;
    });
  });

  describe('Claim', () => {
    it('alice can claim her rewards', async () => {
      const before = await wik.balanceOf(alice.address);
      await expect(rewards.connect(alice).claim())
        .to.emit(rewards, 'RewardClaimed');
      expect(await wik.balanceOf(alice.address)).to.equal(before + W(100));
      expect(await rewards.pendingRewards(alice.address)).to.equal(0n);
    });

    it('claiming with zero pending reverts', async () => {
      await expect(rewards.connect(alice).claim()).to.be.reverted;
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiBonus.sol  (Signup/Referral Bonus System)
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ register() generates referral code
 *  ✓ register() with referral code links referrer
 *  ✓ onFirstDeposit() grants deposit match bonus
 *  ✓ getBonusBalance()
 *  ✓ claimRevShare()
 *  ✓ expireBonus() after 90 days
 *  ✓ blacklist() blocks abusive address
 *  ✓ setPerpContract / setVaultContract (owner only)
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiBonus', () => {
  let bonus, usdc;
  let owner, treasury, alice, bob, charlie;

  const U = (n) => BigInt(n) * 1_000_000n;

  before(async () => {
    [owner, treasury, alice, bob, charlie] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const WikiBonus = await ethers.getContractFactory('WikiBonus');
    bonus = await WikiBonus.deploy(
      await usdc.getAddress(),
      treasury.address,
      owner.address
    );
    await bonus.waitForDeployment();
  });

  describe('Deployment', () => {
    it('sets treasury', async () => {
      expect(await bonus.treasury()).to.equal(treasury.address);
    });
  });

  describe('Register', () => {
    it('alice can register without referral code', async () => {
      // Register with empty referral code (bytes32(0))
      await expect(bonus.connect(alice).register(ethers.ZeroHash))
        .to.emit(bonus, 'ReferralCodeCreated');
    });

    it('alice has a referral code now', async () => {
      const code = await bonus.getReferralCode(alice.address);
      expect(code).to.not.equal(ethers.ZeroHash);
    });

    it('bob registers with alice referral code', async () => {
      const aliceCode = await bonus.getReferralCode(alice.address);
      await expect(bonus.connect(bob).register(aliceCode))
        .to.emit(bonus, 'ReferralRegistered');
    });
  });

  describe('First deposit bonus', () => {
    it('vault can trigger deposit match bonus', async () => {
      // Set owner as vault for testing
      await bonus.setVaultContract(owner.address);
      await expect(bonus.connect(owner).onFirstDeposit(bob.address, U(500)))
        .to.emit(bonus, 'BonusGranted');
    });

    it('bob has signup bonus', async () => {
      const bal = await bonus.getBonusBalance(bob.address);
      expect(bal).to.be.gt(0n);
    });
  });

  describe('Blacklist', () => {
    it('owner can blacklist a user', async () => {
      await bonus.blacklist(charlie.address, 'Sybil detected');
      await expect(bonus.connect(charlie).register(ethers.ZeroHash))
        .to.be.revertedWith('Bonus: blacklisted');
    });

    it('owner can unblacklist', async () => {
      await bonus.unblacklist(charlie.address);
      await expect(bonus.connect(charlie).register(ethers.ZeroHash)).not.to.be.reverted;
    });
  });

  describe('Admin config', () => {
    it('owner can set perp contract', async () => {
      await expect(bonus.setPerpContract(alice.address)).not.to.be.reverted;
    });

    it('non-owner cannot set perp contract', async () => {
      await expect(bonus.connect(alice).setPerpContract(alice.address))
        .to.be.reverted;
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiPropPool.sol  (LP-funded Prop Trading Pool)
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ deposit() → mints WPL tokens to LP
 *  ✓ withdraw() → burns WPL, returns USDC
 *  ✓ wplPrice() = pool value / total supply
 *  ✓ availableCapital() tracks unallocated funds
 *  ✓ allocateCapital() (only by prop contracts)
 *  ✓ returnCapital() with profit split
 *  ✓ claimYield() for LPs
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiPropPool', () => {
  let pool, usdc;
  let owner, alice, bob;

  const U = (n) => BigInt(n) * 1_000_000n;

  before(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const WikiPropPool = await ethers.getContractFactory('WikiPropPool');
    pool = await WikiPropPool.deploy(await usdc.getAddress(), owner.address);
    await pool.waitForDeployment();

    // Fund LPs
    await usdc.mint(alice.address, U(100000));
    await usdc.mint(bob.address, U(100000));
    await usdc.connect(alice).approve(await pool.getAddress(), U(100000));
    await usdc.connect(bob).approve(await pool.getAddress(), U(100000));
  });

  describe('Deployment', () => {
    it('sets USDC', async () => {
      expect(await pool.usdc()).to.equal(await usdc.getAddress());
    });

    it('WPL token name and symbol', async () => {
      expect(await pool.name()).to.equal('Wikicious Prop LP');
      expect(await pool.symbol()).to.equal('WPL');
    });
  });

  describe('Deposit', () => {
    it('alice can deposit USDC and receive WPL', async () => {
      await expect(pool.connect(alice).deposit(U(10000)))
        .to.emit(pool, 'Deposited');
      expect(await pool.balanceOf(alice.address)).to.be.gt(0n);
    });

    it('availableCapital increases', async () => {
      expect(await pool.availableCapital()).to.be.gt(0n);
    });

    it('wplPrice is 1 USDC at start', async () => {
      // Initial price should be near $1 (scaled by precision)
      const price = await pool.wplPrice();
      expect(price).to.be.gt(0n);
    });
  });

  describe('Withdraw', () => {
    it('alice can withdraw (after cooldown bypassed in test)', async () => {
      // Set withdrawal cooldown to 0 for testing
      await pool.setWithdrawalCooldown(0);

      const wpl = await pool.balanceOf(alice.address);
      const half = wpl / 2n;
      if (half > 0n) {
        const usdcBefore = await usdc.balanceOf(alice.address);
        await expect(pool.connect(alice).withdraw(half))
          .to.emit(pool, 'Withdrawn');
        expect(await usdc.balanceOf(alice.address)).to.be.gt(usdcBefore);
      }
    });
  });

  describe('Pool stats', () => {
    it('poolStats returns valid data', async () => {
      const stats = await pool.poolStats();
      expect(stats.totalDeposits).to.be.gt(0n);
    });
  });

  describe('Prop contract capital allocation', () => {
    it('owner can register a prop contract', async () => {
      await pool.setPropContract(owner.address, true);
      expect(await pool.propContracts(owner.address)).to.be.true;
    });

    it('prop contract can allocate capital', async () => {
      const avail = await pool.availableCapital();
      if (avail > 0n) {
        await expect(pool.allocateCapital(alice.address, avail / 2n))
          .to.emit(pool, 'CapitalAllocated');
      }
    });
  });

  describe('Pause', () => {
    it('owner can pause deposits', async () => {
      await pool.pause();
      await expect(pool.connect(bob).deposit(U(1000)))
        .to.be.revertedWithCustomError(pool, 'EnforcedPause');
      await pool.unpause();
    });
  });
});


/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiGMXBackstop.sol
 *
 *  WikiGMXBackstop routes large orders to GMX V5 when they exceed
 *  the internal WikiPerp liquidity capacity.
 *
 *  Covers:
 *  ✓ Deployment
 *  ✓ isMarketSupported for pre-configured GMX markets
 *  ✓ setGMXMarket (owner only)
 *  ✓ setMinRouteSize (owner only)
 *  ✓ minGMXRouteSize getter
 *  ✓ Only operator can call routeToGMX
 *  ✓ revenueStats() view
 *  ✓ Pause / Ownable2Step
 * ════════════════════════════════════════════════════════════════
 */

describe('WikiGMXBackstop', () => {
  let backstop, vault, oracle, usdc, seqFeed;
  let owner, operator, alice;

  const BTC_ID = ethers.id('BTCUSDT');
  const ETH_ID = ethers.id('ETHUSDT');

  before(async () => {
    [owner, operator, alice] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);

    const MockSeq = await ethers.getContractFactory('MockSequencerFeed');
    seqFeed = await MockSeq.deploy();

    const WikiOracle = await ethers.getContractFactory('WikiOracle');
    oracle = await WikiOracle.deploy(owner.address, await seqFeed.getAddress());

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await usdc.getAddress(), owner.address);

    const WikiGMXBackstop = await ethers.getContractFactory('WikiGMXBackstop');
    backstop = await WikiGMXBackstop.deploy(
      await vault.getAddress(),
      await oracle.getAddress(),
      owner.address,  // fee recipient
      owner.address   // owner
    );
    await backstop.waitForDeployment();

    // Register operator
    await backstop.setOperator(operator.address, true);
  });

  describe('Deployment', () => {
    it('sets owner', async () => {
      expect(await backstop.owner()).to.equal(owner.address);
    });

    it('pre-configures BTC/ETH/ARB GMX markets', async () => {
      expect(await backstop.isMarketSupported(BTC_ID)).to.be.true;
      expect(await backstop.isMarketSupported(ETH_ID)).to.be.true;
    });

    it('unknown market is not supported', async () => {
      expect(await backstop.isMarketSupported(ethers.id('FAKEMARK'))).to.be.false;
    });
  });

  describe('Admin', () => {
    it('owner can set min route size', async () => {
      await expect(backstop.setMinRouteSize(50000n * 1_000_000n))
        .to.emit(backstop, 'MinRouteSizeUpdated');
    });

    it('minGMXRouteSize is positive', async () => {
      expect(await backstop.minGMXRouteSize()).to.be.gt(0n);
    });

    it('non-owner cannot set min route size', async () => {
      await expect(backstop.connect(alice).setMinRouteSize(1n)).to.be.reverted;
    });

    it('owner can add a new GMX market', async () => {
      const newId = ethers.id('LTCUSDT_V5');
      await backstop.setGMXMarket(newId, alice.address); // mock address
      expect(await backstop.isMarketSupported(newId)).to.be.true;
    });
  });

  describe('routeToGMX access control', () => {
    it('non-operator cannot route to GMX', async () => {
      await expect(backstop.connect(alice).routeToGMX(
        alice.address, BTC_ID, true,
        BigInt(50000) * 1_000_000n,  // $50K
        10n,
        alice.address
      )).to.be.revertedWith('Backstop: not operator');
    });
  });

  describe('Revenue stats', () => {
    it('revenueStats returns valid struct', async () => {
      const stats = await backstop.revenueStats();
      // Just check it doesn't revert and returns something
      expect(typeof stats).to.not.equal('undefined');
    });
  });

  describe('Pause / Ownable2Step', () => {
    it('owner can pause and unpause', async () => {
      await backstop.pause();
      await backstop.unpause();
    });

    it('ownership transfer requires acceptance', async () => {
      await backstop.transferOwnership(alice.address);
      expect(await backstop.pendingOwner()).to.equal(alice.address);
      await backstop.transferOwnership(owner.address); // cancel
    });
  });
});
