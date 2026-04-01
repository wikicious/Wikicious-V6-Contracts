/**
 * ════════════════════════════════════════════════════════════════
 *  TEST — WikiMultisigGuard + WikiTVLGuard + WikiRateLimiter
 * ════════════════════════════════════════════════════════════════
 */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time }   = require('@nomicfoundation/hardhat-network-helpers');

describe('WikiMultisigGuard', () => {
  let multisig, vault, token;
  let s1, s2, s3, nonSigner, attacker;
  const D = (n) => BigInt(n) * 1_000_000n;

  before(async () => {
    [s1, s2, s3, nonSigner, attacker] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token = await MockERC20.deploy('USDC','USDC',6);

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await token.getAddress(), s1.address);

    const WikiMultisigGuard = await ethers.getContractFactory('WikiMultisigGuard');
    multisig = await WikiMultisigGuard.deploy([s1.address, s2.address, s3.address], 2);
  });

  it('deploys with correct signers and threshold', async () => {
    expect(await multisig.threshold()).to.equal(2);
    const signers = await multisig.getSigners();
    expect(signers.length).to.equal(3);
  });

  it('signer can propose', async () => {
    const callData = vault.interface.encodeFunctionData('pause');
    await expect(
      multisig.connect(s1).propose(0, await vault.getAddress(), callData, 0, 'Pause for maintenance')
    ).to.emit(multisig, 'ProposalCreated');
  });

  it('non-signer cannot propose', async () => {
    const callData = vault.interface.encodeFunctionData('pause');
    await expect(
      multisig.connect(nonSigner).propose(0, await vault.getAddress(), callData, 0, 'Test')
    ).to.be.revertedWith('Multisig: not signer');
  });

  it('second signer approval enables execution', async () => {
    const callData = vault.interface.encodeFunctionData('pause');
    await multisig.connect(s1).propose(0, await vault.getAddress(), callData, 0, 'Pause');
    const id = await multisig.nonce();
    await multisig.connect(s2).approve(id);
    expect(await multisig.getApprovalCount(id)).to.equal(2);
  });

  it('timelocked proposal cannot execute before delay', async () => {
    const callData = vault.interface.encodeFunctionData('unpause');
    await multisig.connect(s1).propose(3, await vault.getAddress(), callData, 0, 'Remove operator');
    const id = await multisig.nonce();
    await multisig.connect(s2).approve(id);
    await expect(multisig.connect(s1).execute(id)).to.be.revertedWith('Multisig: timelock not expired');
  });

  it('timelocked proposal executes after 48h', async () => {
    const callData = vault.interface.encodeFunctionData('unpause');
    await multisig.connect(s1).propose(1, await vault.getAddress(), callData, 0, 'Unpause');
    const id = await multisig.nonce();
    await multisig.connect(s2).approve(id);
    // Immediate action (UNPAUSE = type 1) — executes without delay
    await multisig.connect(s1).execute(id);
    expect(await vault.paused()).to.equal(false);
  });

  it('cannot double-approve', async () => {
    const callData = vault.interface.encodeFunctionData('pause');
    await multisig.connect(s1).propose(0, await vault.getAddress(), callData, 0, 'X');
    const id = await multisig.nonce();
    await expect(multisig.connect(s1).approve(id)).to.be.revertedWith('Multisig: already approved');
  });

  it('cannot execute already-executed proposal', async () => {
    const callData = vault.interface.encodeFunctionData('pause');
    await multisig.connect(s1).propose(0, await vault.getAddress(), callData, 0, 'Pause');
    const id = await multisig.nonce();
    await multisig.connect(s2).approve(id);
    await multisig.connect(s1).execute(id);
    await expect(multisig.connect(s1).execute(id)).to.be.revertedWith('Multisig: already executed');
  });
});

describe('WikiTVLGuard', () => {
  let tvlGuard, vault, token;
  let owner, alice, bob, attacker;
  const D = (n) => BigInt(n) * 1_000_000n;

  before(async () => {
    [owner, alice, bob, attacker] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token = await MockERC20.deploy('USDC','USDC',6);

    const WikiVault = await ethers.getContractFactory('WikiVault');
    vault = await WikiVault.deploy(await token.getAddress(), owner.address);

    const WikiTVLGuard = await ethers.getContractFactory('WikiTVLGuard');
    tvlGuard = await WikiTVLGuard.deploy(owner.address);

    await tvlGuard.registerVault(await vault.getAddress(), D(10_000), D(5_000), D(2_000), false);
    await vault.setTVLGuard(await tvlGuard.getAddress());

    await token.mint(alice.address,    D(100_000));
    await token.mint(attacker.address, D(100_000));
  });

  it('starts at LAUNCH stage with $500K global cap', async () => {
    const [stage, cap] = await tvlGuard.getStageInfo();
    expect(stage).to.equal(0); // LAUNCH
  });

  it('deposit within vault cap succeeds', async () => {
    await token.connect(alice).approve(await vault.getAddress(), D(1_000));
    await expect(vault.connect(alice).deposit(D(1_000))).to.not.be.reverted;
  });

  it('deposit exceeding per-tx cap reverts', async () => {
    await token.connect(alice).approve(await vault.getAddress(), D(3_000));
    await expect(vault.connect(alice).deposit(D(3_000))).to.be.revertedWith('TVLGuard: exceeds per-tx cap');
  });

  it('deposit exceeding per-user cap reverts', async () => {
    await token.connect(attacker).approve(await vault.getAddress(), D(5_001));
    await vault.connect(attacker).deposit(D(2_000));
    await vault.connect(attacker).deposit(D(2_000));
    await expect(vault.connect(attacker).deposit(D(2_000))).to.be.revertedWith('TVLGuard: exceeds per-user cap');
  });

  it('owner can advance stage', async () => {
    await tvlGuard.advanceStage();
    const [stage] = await tvlGuard.getStageInfo();
    expect(stage).to.equal(1); // BETA
  });

  it('whitelist check blocks non-whitelisted in whitelistOnly vault', async () => {
    await tvlGuard.registerVault(await vault.getAddress(), D(10_000), D(5_000), D(2_000), true);
    await token.connect(bob).approve(await vault.getAddress(), D(500));
    await expect(vault.connect(bob).deposit(D(500))).to.be.revertedWith('TVLGuard: not whitelisted');

    // Whitelist and retry
    await tvlGuard.setWhitelisted(bob.address, true);
    await expect(vault.connect(bob).deposit(D(500))).to.not.be.reverted;
  });
});

describe('WikiRateLimiter', () => {
  let rateLimiter;
  let owner, alice, attacker;
  const WITHDRAW_KEY = ethers.keccak256(ethers.toUtf8Bytes('VAULT_WITHDRAW'));

  before(async () => {
    [owner, alice, attacker] = await ethers.getSigners();
    const WikiRateLimiter = await ethers.getContractFactory('WikiRateLimiter');
    rateLimiter = await WikiRateLimiter.deploy(owner.address);
  });

  it('normal operations pass rate check', async () => {
    await expect(
      rateLimiter.connect(owner).checkAndRecord(alice.address, WITHDRAW_KEY, 100_000_000n)
    ).to.not.be.reverted;
  });

  it('large op cooldown blocks second large tx immediately', async () => {
    const largeAmount = 20_000_000_000n; // $20K > $10K threshold
    await rateLimiter.connect(owner).checkAndRecord(alice.address, WITHDRAW_KEY, largeAmount);
    await expect(
      rateLimiter.connect(owner).checkAndRecord(alice.address, WITHDRAW_KEY, largeAmount)
    ).to.be.revertedWith('RateLimiter: large op cooldown active');
  });

  it('large op succeeds after cooldown expires', async () => {
    await time.increase(31); // 30s cooldown + 1s buffer
    const largeAmount = 20_000_000_000n;
    await expect(
      rateLimiter.connect(owner).checkAndRecord(alice.address, WITHDRAW_KEY, largeAmount)
    ).to.not.be.reverted;
  });

  it('global hourly flow limit blocks excess volume', async () => {
    // Flow limit for VAULT_WITHDRAW = $10M/hr
    const hugeAmount = 9_999_000_000_000n; // just under $10M
    await time.increase(3601); // reset hour
    await rateLimiter.connect(owner).checkAndRecord(attacker.address, WITHDRAW_KEY, hugeAmount);
    await expect(
      rateLimiter.connect(owner).checkAndRecord(attacker.address, WITHDRAW_KEY, 5_000_000_000n)
    ).to.be.revertedWith('RateLimiter: global hourly flow exceeded');
  });
});
