/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WIKToken.sol
 *
 *  Covers:
 *  ✓ Deployment & initial mint
 *  ✓ Max supply enforcement
 *  ✓ Minter access control
 *  ✓ Fee discount tiers
 *  ✓ Burn functionality
 *  ✓ ERC20Votes delegation
 * ════════════════════════════════════════════════════════════════
 */

const { expect }        = require('chai');
const { ethers }        = require('hardhat');
const { parseEther, formatEther } = ethers;

describe('WIKToken', () => {
  let wik, owner, minter, alice, bob;

  // ── Deploy fresh contract before each test ────────────────────
  beforeEach(async () => {
    [owner, minter, alice, bob] = await ethers.getSigners();
    const WIKToken = await ethers.getContractFactory('WIKToken');
    wik = await WIKToken.deploy(owner.address);
    await wik.waitForDeployment();
  });

  // ── Deployment ────────────────────────────────────────────────
  describe('Deployment', () => {
    it('has correct name and symbol', async () => {
      expect(await wik.name()).to.equal('Wikicious');
      expect(await wik.symbol()).to.equal('WIK');
    });

    it('mints 200M tokens to owner on deploy', async () => {
      const balance = await wik.balanceOf(owner.address);
      expect(balance).to.equal(parseEther('200000000')); // 200M
    });

    it('has MAX_SUPPLY of 1 billion', async () => {
      expect(await wik.MAX_SUPPLY()).to.equal(parseEther('1000000000'));
    });

    it('sets owner as initial guardian', async () => {
      // Owner can call owner-only functions
      await expect(wik.connect(owner).setMinter(alice.address, true)).not.to.be.reverted;
    });
  });

  // ── Minting ───────────────────────────────────────────────────
  describe('Minting', () => {
    beforeEach(async () => {
      await wik.connect(owner).setMinter(minter.address, true);
    });

    it('allows authorised minter to mint', async () => {
      await wik.connect(minter).mint(alice.address, parseEther('1000'));
      expect(await wik.balanceOf(alice.address)).to.equal(parseEther('1000'));
    });

    it('reverts if non-minter tries to mint', async () => {
      await expect(
        wik.connect(alice).mint(alice.address, parseEther('1000'))
      ).to.be.revertedWith('WIK: not minter');
    });

    it('enforces MAX_SUPPLY cap', async () => {
      const remaining = parseEther('1000000000') - await wik.totalSupply();
      // Mint exactly remaining — should succeed
      await wik.connect(minter).mint(alice.address, remaining);
      // One more token should fail
      await expect(
        wik.connect(minter).mint(alice.address, 1n)
      ).to.be.revertedWith('WIK: max supply exceeded');
    });

    it('owner can revoke minter', async () => {
      await wik.connect(owner).setMinter(minter.address, false);
      await expect(
        wik.connect(minter).mint(alice.address, parseEther('1'))
      ).to.be.revertedWith('WIK: not minter');
    });
  });

  // ── Fee Discount Tiers ────────────────────────────────────────
  describe('Fee discount tiers', () => {
    it('returns zero discount for holder with no WIK', async () => {
      const [maker, taker] = await wik.getDiscount(alice.address);
      expect(maker).to.equal(0n);
      expect(taker).to.equal(0n);
    });

    it('returns Tier 1 discount for 1K WIK holder', async () => {
      await wik.connect(owner).transfer(alice.address, parseEther('1000'));
      const [maker, taker] = await wik.getDiscount(alice.address);
      expect(maker).to.equal(10n); // 10 bps
      expect(taker).to.equal(5n);  // 5 bps
    });

    it('returns Tier 4 discount for 100K WIK holder', async () => {
      await wik.connect(owner).transfer(alice.address, parseEther('100000'));
      const [maker, taker] = await wik.getDiscount(alice.address);
      expect(maker).to.equal(50n); // 50 bps
      expect(taker).to.equal(30n); // 30 bps
    });
  });

  // ── Burn ──────────────────────────────────────────────────────
  describe('Burning', () => {
    it('allows token holder to burn their own tokens', async () => {
      const before = await wik.balanceOf(owner.address);
      await wik.connect(owner).burn(parseEther('1000000'));
      const after = await wik.balanceOf(owner.address);
      expect(before - after).to.equal(parseEther('1000000'));
    });

    it('reduces total supply on burn', async () => {
      const before = await wik.totalSupply();
      await wik.connect(owner).burn(parseEther('1'));
      expect(await wik.totalSupply()).to.equal(before - parseEther('1'));
    });
  });

  // ── ERC20Votes ────────────────────────────────────────────────
  describe('ERC20Votes', () => {
    it('allows delegation', async () => {
      await wik.connect(owner).delegate(alice.address);
      expect(await wik.delegates(owner.address)).to.equal(alice.address);
    });

    it('tracks voting power after delegation', async () => {
      await wik.connect(owner).delegate(owner.address); // self-delegate
      const votes = await wik.getVotes(owner.address);
      expect(votes).to.equal(await wik.balanceOf(owner.address));
    });
  });
});
