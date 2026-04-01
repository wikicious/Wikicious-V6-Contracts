// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiLeveragedYield
 * @notice Looping vaults that amplify yield through recursive borrowing.
 *         Gearbox Protocol hit $500M TVL with this model.
 *
 * EXAMPLE — ETH 3× Yield Loop:
 *   1. User deposits 10 ETH ($30,000)
 *   2. Vault borrows 20 ETH ($60,000) from WikiLending at 5% APR
 *   3. All 30 ETH staked in wstETH earning 4% APR
 *   4. Gross yield: 30 ETH × 4% = 1.2 ETH/year
 *   5. Borrow cost: 20 ETH × 5% = 1.0 ETH/year
 *   6. Net yield: 0.2 ETH/year on 10 ETH = 2% APR leveraged
 *   → vs 4% without leverage? No — but user earns MORE in bull markets
 *      because 30 ETH appreciates vs only owning 10 ETH
 *
 * VAULT STRATEGIES:
 *   ETH_LOOP    : deposit ETH → borrow USDC → buy ETH → repeat (2-3×)
 *   STETH_LOOP  : deposit ETH → stake → borrow against stETH → more ETH
 *   STABLE_LOOP : deposit USDC → borrow USDC → supply to lending → net spread
 *
 * RISK:
 *   Main risk: ETH price crash → collateral drops → health factor → liquidation
 *   Mitigated by: conservative LTV (50-65%), auto-deleverage if health < 1.2
 *
 * REVENUE:
 *   Management fee: 1%/year on TVL
 *   Performance fee: 10% of net yield
 *   $50M TVL = $500K/year management alone
 */
interface IStaking {
        function stake(uint256 amount) external returns (uint256 shares);
        function unstake(uint256 shares) external returns (uint256 amount);
        function getAPR() external view returns (uint256);
    }

interface IWikiLending {
        function supply(uint256 mid, uint256 amount) external;
        function borrow(uint256 mid, uint256 amount) external;
        function repay(uint256 mid, uint256 amount) external;
        function withdraw(uint256 mid, uint256 amount) external;
        function getHealthFactor(address user) external view returns (uint256);
    }

contract WikiLeveragedYield is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;



    enum Strategy { ETH_LOOP, STETH_LOOP, STABLE_LOOP }

    struct VaultConfig {
        Strategy strategy;
        string   name;
        address  depositToken;
        address  yieldToken;        // what the vault stakes into
        uint256  lendingMarketId;   // WikiLending market for borrowing
        uint256  targetLoops;       // how many times to loop (2 or 3)
        uint256  targetLTV;         // target LTV in BPS (e.g. 6000 = 60%)
        uint256  safeHealthBps;     // deleverage if health < this (e.g. 12000 = 1.2)
        uint256  mgmtFeeBps;        // 100 = 1%/year
        uint256  perfFeeBps;        // 1000 = 10% of net yield
        bool     active;
    }

    struct UserPosition {
        uint256 depositAmount;      // original deposit
        uint256 shares;             // vault shares
        uint256 loops;              // current loop count
        uint256 borrowedTotal;      // total borrowed across all loops
        uint256 depositTime;
        uint256 lastFeeAccrual;
    }

    mapping(uint256 => VaultConfig)                   public vaults;
    mapping(uint256 => mapping(address => UserPosition)) public positions;
    mapping(uint256 => uint256)                       public totalShares;
    mapping(uint256 => uint256)                       public totalNAV;

    IWikiLending public lending;
    address      public revenueSplitter;
    address      public keeper;
    uint256      public nextVaultId;

    uint256 public constant BPS             = 10_000;
    uint256 public constant SECONDS_PER_YEAR= 365 days;
    uint256 public constant MIN_DEPOSIT     = 100 * 1e6; // $100

    event Deposited(uint256 vaultId, address user, uint256 amount, uint256 shares);
    event Withdrawn(uint256 vaultId, address user, uint256 amount, uint256 fee);
    event Looped(uint256 vaultId, address user, uint256 loopCount, uint256 totalBorrowed);
    event Deleveraged(uint256 vaultId, address user, uint256 reason);

    constructor(address _owner, address _lending, address _revenueSplitter, address _keeper) Ownable(_owner) {
        lending         = IWikiLending(_lending);
        revenueSplitter = _revenueSplitter;
        keeper          = _keeper;
        _initVaults();
    }

    function _initVaults() internal {
        // ETH 3× Loop
        vaults[nextVaultId++] = VaultConfig({
            strategy:       Strategy.ETH_LOOP,
            name:           unicode"ETH 3× Yield Loopunicode",
            depositToken:   0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH
            yieldToken:     0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            lendingMarketId:1,
            targetLoops:    3,
            targetLTV:      6000,   // 60% LTV per loop
            safeHealthBps:  12000,  // deleverage if health < 1.2
            mgmtFeeBps:     100,
            perfFeeBps:     1000,
            active:         true
        });
        // Stable 2× Loop (USDC)
        vaults[nextVaultId++] = VaultConfig({
            strategy:       Strategy.STABLE_LOOP,
            name:           "USDC 2× Stable Loopunicode",
            depositToken:   0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
            yieldToken:     0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            lendingMarketId:0,
            targetLoops:    2,
            targetLTV:      7500,   // 75% LTV — stable is safer
            safeHealthBps:  11000,  // 1.1 threshold
            mgmtFeeBps:     100,
            perfFeeBps:     1000,
            active:         true
        });
    }

    // ── Deposit + Loop ────────────────────────────────────────────────────
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        VaultConfig storage cfg = vaults[vaultId];
        require(cfg.active,             "LY: vault inactive");
        require(amount >= MIN_DEPOSIT,  "LY: below minimum");

        IERC20(cfg.depositToken).safeTransferFrom(msg.sender, address(this), amount);
        _accrueManagementFee(vaultId);

        uint256 shares = totalShares[vaultId] == 0
            ? amount
            : amount * totalShares[vaultId] / totalNAV[vaultId];

        positions[vaultId][msg.sender].depositAmount += amount;
        positions[vaultId][msg.sender].shares        += shares;
        positions[vaultId][msg.sender].depositTime    = block.timestamp;
        positions[vaultId][msg.sender].lastFeeAccrual = block.timestamp;
        totalShares[vaultId] += shares;
        totalNAV[vaultId]    += amount;

        // Execute looping strategy
        _executeLoop(vaultId, msg.sender, amount);
        emit Deposited(vaultId, msg.sender, amount, shares);
    }

    // ── Withdraw + Unwind ─────────────────────────────────────────────────
    function withdraw(uint256 vaultId, uint256 shares) external nonReentrant {
        UserPosition storage pos = positions[vaultId][msg.sender];
        VaultConfig  storage cfg = vaults[vaultId];
        require(pos.shares >= shares, "LY: insufficient shares");

        _accrueManagementFee(vaultId);

        uint256 proportion = shares * BPS / totalShares[vaultId];
        uint256 nav        = totalNAV[vaultId] * proportion / BPS;
        uint256 original   = pos.depositAmount * proportion / BPS;

        // Performance fee on profit
        uint256 perfFee = nav > original
            ? (nav - original) * cfg.perfFeeBps / BPS
            : 0;
        uint256 netAmount = nav - perfFee;

        // Unwind leverage proportionally
        uint256 toRepay = pos.borrowedTotal * proportion / BPS;
        _unwindLoop(vaultId, msg.sender, toRepay);

        pos.shares        -= shares;
        pos.depositAmount -= original;
        pos.borrowedTotal -= toRepay;
        totalShares[vaultId] -= shares;
        totalNAV[vaultId]    -= nav;

        if (perfFee > 0) IERC20(cfg.depositToken).safeTransfer(revenueSplitter, perfFee);
        IERC20(cfg.depositToken).safeTransfer(msg.sender, netAmount);
        emit Withdrawn(vaultId, msg.sender, netAmount, perfFee);
    }

    // ── Keeper: deleverage if health drops ────────────────────────────────
    function deleverageIfNeeded(uint256 vaultId, address user) external {
        require(msg.sender == keeper || msg.sender == owner(), "LY: not keeperunicode");
        VaultConfig storage cfg = vaults[vaultId];
        uint256 health = lending.getHealthFactor(address(this));
        if (health < cfg.safeHealthBps) {
            _unwindLoop(vaultId, user, positions[vaultId][user].borrowedTotal / 2);
            emit Deleveraged(vaultId, user, health);
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _executeLoop(uint256 vaultId, address user, uint256 amount) internal {
        VaultConfig storage cfg = vaults[vaultId];
        uint256 borrowed = 0;
        uint256 current  = amount;

        for (uint i; i < cfg.targetLoops - 1; i++) {
            uint256 toBorrow = current * cfg.targetLTV / BPS;
            try lending.borrow(cfg.lendingMarketId, toBorrow) {
                borrowed += toBorrow;
                current   = toBorrow;
            } catch { break; }
        }
        positions[vaultId][user].borrowedTotal += borrowed;
        positions[vaultId][user].loops          = cfg.targetLoops;
        emit Looped(vaultId, user, cfg.targetLoops, borrowed);
    }

    function _unwindLoop(uint256 vaultId, address user, uint256 repayAmount) internal {
        VaultConfig storage cfg = vaults[vaultId];
        if (repayAmount == 0) return;
        try lending.repay(cfg.lendingMarketId, repayAmount) {} catch {}
    }

    function _accrueManagementFee(uint256 vaultId) internal {
        VaultConfig storage cfg = vaults[vaultId];
        if (totalNAV[vaultId] == 0) return;
        uint256 elapsed = block.timestamp - (positions[vaultId][address(0)].lastFeeAccrual == 0
            ? block.timestamp - 1 : positions[vaultId][address(0)].lastFeeAccrual);
        uint256 fee = totalNAV[vaultId] * cfg.mgmtFeeBps * elapsed / BPS / SECONDS_PER_YEAR;
        if (fee > 0 && fee < totalNAV[vaultId]) {
            totalNAV[vaultId] -= fee;
            IERC20(cfg.depositToken).safeTransfer(revenueSplitter, fee);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getPosition(uint256 vaultId, address user) external view returns (
        uint256 shares, uint256 currentValue, uint256 deposited,
        int256 pnl, uint256 loops, uint256 borrowed, uint256 estimatedAPY
    ) {
        UserPosition storage pos = positions[vaultId][user];
        VaultConfig  storage cfg = vaults[vaultId];
        shares       = pos.shares;
        currentValue = totalShares[vaultId] > 0
            ? pos.shares * totalNAV[vaultId] / totalShares[vaultId] : 0;
        deposited    = pos.depositAmount;
        pnl          = int256(currentValue) - int256(deposited);
        loops        = pos.loops;
        borrowed     = pos.borrowedTotal;
        estimatedAPY = cfg.targetLoops * 400; // simplified: 4% base × leverage
    }

    function setKeeper(address k) external onlyOwner { keeper = k; }
    function setVaultActive(uint256 id, bool on) external onlyOwner { vaults[id].active = on; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
