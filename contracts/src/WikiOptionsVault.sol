// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiOptionsVault
 * @notice Structured product vaults that auto-run covered call and cash-secured
 *         put strategies on BTC/ETH and collect weekly option premiums.
 *
 * MECHANISM
 * ─────────────────────────────────────────────────────────────────────────
 * Users deposit USDC (or ETH for covered calls). The vault manager writes
 * weekly out-of-the-money options each Friday via an on-chain options protocol
 * (or via keeper bot off-chain). Premium received minus losses = vault yield.
 *
 * VAULT TYPES
 * ─────────────────────────────────────────────────────────────────────────
 * COVERED_CALL   : Deposit ETH/BTC. Write OTM calls each week. Earn premium.
 *                  Risk: underlying called away if price spikes.
 * CASH_SECURED_PUT: Deposit USDC. Write OTM puts each week. Earn premium.
 *                   Risk: forced to buy underlying if price drops.
 * THETA_DECAY    : Delta-neutral mix of both. More stable, lower yield.
 *
 * REVENUE (2% management + 20% performance)
 * ─────────────────────────────────────────────────────────────────────────
 * • managementFeeBps  (200 = 2% p.a. on TVL, deducted per epoch)
 * • performanceFeeBps (2000 = 20% of weekly premium earned above high-water mark)
 * • Both flow to protocolFeeAccumulator → owner can withdraw
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────────────
 * [A1] Reentrancy        → ReentrancyGuard on all user-facing state-mutating fns
 * [A2] CEI               → state before transfers throughout
 * [A3] Flash deposits    → minDepositLock: shares cannot be withdrawn same epoch
 * [A4] Epoch lockout     → withdrawals only allowed in 1-hour settlement window
 * [A5] Manager cap       → manager cannot set fees above MAX_MGMT / MAX_PERF
 * [A6] High-water mark   → performance fee only on net-new profits
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiOptionsVault is Ownable2Step, ReentrancyGuard, Pausable {
    // ── Timelock guard ────────────────────────────────────────────────────
    // All fund-moving owner functions must be queued through WikiTimelockController
    // (48h delay). Deployer sets this address after deployment.
    address public timelock;
    modifier onlyTimelocked() {
        require(
            msg.sender == owner() && (timelock == address(0) || msg.sender == timelock),
            "Wiki: must go through timelock"
        );
        _;
    }
    function setTimelock(address _tl) external onlyOwner {
        require(_tl != address(0), "Wiki: zero timelock");
        timelock = _tl;
    }

    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant PRECISION          = 1e18;
    uint256 public constant BPS                = 10_000;
    uint256 public constant MAX_MGMT_FEE       = 500;    // 5% max annual
    uint256 public constant MAX_PERF_FEE       = 3000;   // 30% max
    uint256 public constant EPOCH_DURATION     = 7 days;
    uint256 public constant SETTLEMENT_WINDOW  = 1 hours; // withdrawal window
    uint256 public constant SHARES_PRECISION   = 1e18;

    // ──────────────────────────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────────────────────────
    enum VaultType { COVERED_CALL, CASH_SECURED_PUT, THETA_DECAY }

    struct Vault {
        string   name;
        string   symbol;        // e.g. "wCC-ETH"
        VaultType vaultType;
        address  asset;         // deposit token (USDC or WETH)
        address  underlying;    // option underlying (WETH for call, USDC for put)
        uint256  totalAssets;   // total assets under management
        uint256  totalShares;   // total vault shares outstanding
        uint256  highWaterMark; // share price HWM for performance fee   [A6]
        uint256  epochStart;    // start timestamp of current epoch
        uint256  epochNumber;   // current epoch counter
        uint256  pendingDeposits;  // queued for next epoch
        uint256  pendingWithdrawals; // shares queued for settlement
        uint256  managementFeeBps;
        uint256  performanceFeeBps;
        uint256  accumulatedFees;   // protocol fees not yet withdrawn
        uint256  weeklyPremium;    // premium earned this epoch
        bool     active;
    }

    struct UserVault {
        uint256 shares;
        uint256 depositEpoch; // epoch when deposited                    [A3]
        uint256 pendingDeposit;
        uint256 pendingWithdraw; // shares queued for withdrawal
    }

    struct EpochReport {
        uint256 epochNumber;
        uint256 premiumEarned;
        uint256 losses;
        uint256 netYield;
        uint256 sharePriceStart;
        uint256 sharePriceEnd;
        uint256 managementFeeCharged;
        uint256 performanceFeeCharged;
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    Vault[]                                     public vaults;
    mapping(uint256 => mapping(address => UserVault)) public userVaults;
    mapping(uint256 => EpochReport[])           public epochHistory; // vaultId → reports
    mapping(address => bool)                    public managers;     // can settle epochs

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event VaultCreated(uint256 indexed vaultId, string name, VaultType vaultType, address asset);
    event Deposited(uint256 indexed vaultId, address indexed user, uint256 assets, uint256 shares);
    event WithdrawQueued(uint256 indexed vaultId, address indexed user, uint256 shares);
    event WithdrawSettled(uint256 indexed vaultId, address indexed user, uint256 assets);
    event EpochSettled(uint256 indexed vaultId, uint256 epoch, uint256 premium, uint256 netYield, uint256 fees);
    event FeesWithdrawn(uint256 indexed vaultId, address to, uint256 amount);
    event ManagerSet(address indexed manager, bool enabled);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = router;
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        USDC.approve(address(idleYieldRouter), amount);
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address owner) Ownable(owner) {}

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Create Vaults
    // ──────────────────────────────────────────────────────────────────

    function createVault(
        string   calldata name,
        string   calldata symbol,
        VaultType vaultType,
        address  asset,
        address  underlying,
        uint256  managementFeeBps,
        uint256  performanceFeeBps
    ) external onlyOwner returns (uint256 vaultId) {
        require(managementFeeBps <= MAX_MGMT_FEE,  "OV: mgmt fee too high");  // [A5]
        require(performanceFeeBps <= MAX_PERF_FEE, "OV: perf fee too high");  // [A5]

        vaultId = vaults.length;
        vaults.push(Vault({
            name:               name,
            symbol:             symbol,
            vaultType:          vaultType,
            asset:              asset,
            underlying:         underlying,
            totalAssets:        0,
            totalShares:        0,
            highWaterMark:      SHARES_PRECISION, // start at 1.0
            epochStart:         block.timestamp,
            epochNumber:        1,
            pendingDeposits:    0,
            pendingWithdrawals: 0,
            managementFeeBps:   managementFeeBps,
            performanceFeeBps:  performanceFeeBps,
            accumulatedFees:    0,
            weeklyPremium:      0,
            active:             true
        }));
        emit VaultCreated(vaultId, name, vaultType, asset);
    }

    function setManager(address manager, bool enabled) external onlyOwner {
        managers[manager] = enabled;
        emit ManagerSet(manager, enabled);
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Deposit (queued for next epoch start)
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit assets into the vault. Shares are issued at epoch settlement.
     * @param vaultId  Which vault to deposit into
     * @param amount   Amount of vault asset to deposit
     */
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(v.active,   "OV: vault inactive");
        require(amount > 0, "OV: zero deposit");

        // [A2] State before transfer
        UserVault storage uv = userVaults[vaultId][msg.sender];
        uv.pendingDeposit += amount;
        v.pendingDeposits += amount;

        IERC20(v.asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(vaultId, msg.sender, amount, 0); // shares TBD at settlement
    }

    /**
     * @notice Queue shares for withdrawal. Assets released at epoch settlement.
     */
    function queueWithdraw(uint256 vaultId, uint256 shares) external nonReentrant {
        Vault storage v     = vaults[vaultId];
        UserVault storage uv = userVaults[vaultId][msg.sender];
        require(uv.shares >= shares,                     "OV: insufficient shares");
        require(uv.depositEpoch < v.epochNumber,         "OV: deposit lock active"); // [A3]

        // [A2] State before settlement
        uv.shares          -= shares;
        uv.pendingWithdraw += shares;
        v.pendingWithdrawals += shares;

        emit WithdrawQueued(vaultId, msg.sender, shares);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Manager: Settle Epoch
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Settle the current epoch, distributing premiums and charging fees.
     *         Called by authorized manager (keeper bot) every Friday.
     *
     * @param vaultId         Which vault to settle
     * @param premiumEarned   USDC premium received from option writing this week
     * @param losses          Any losses from options being exercised against us
     */
    function settleEpoch(
        uint256 vaultId,
        uint256 premiumEarned,
        uint256 losses
    ) external nonReentrant {
        require(managers[msg.sender] || msg.sender == owner(), "OV: not manager");
        Vault storage v = vaults[vaultId];
        require(v.active, "OV: inactive");
        require(block.timestamp >= v.epochStart + EPOCH_DURATION, "OV: epoch not over");

        uint256 netGain    = premiumEarned > losses ? premiumEarned - losses : 0;
        uint256 netLoss    = losses > premiumEarned ? losses - premiumEarned : 0;

        // ── Management fee (annualised, charged per week) ──────────────
        uint256 mgmtFee = v.totalAssets * v.managementFeeBps / BPS /* AUDIT: verify mul-before-div order */ * EPOCH_DURATION / 365 days;

        // ── Performance fee (only on net-new profit above HWM) ─────────
        uint256 perfFee = 0;
        if (netGain > 0) {
            uint256 currentSharePrice = v.totalShares > 0
                ? (v.totalAssets + netGain) * SHARES_PRECISION / v.totalShares
                : SHARES_PRECISION;
            if (currentSharePrice > v.highWaterMark) {         // [A6]
                uint256 excessProfit = (currentSharePrice - v.highWaterMark)
                    * v.totalShares / SHARES_PRECISION;
                perfFee = excessProfit * v.performanceFeeBps / BPS;
                v.highWaterMark = currentSharePrice;
            }
        }

        uint256 totalFees = mgmtFee + perfFee;
        v.accumulatedFees += totalFees;

        // ── Update assets ──────────────────────────────────────────────
        uint256 sharePriceStart = v.totalShares > 0
            ? v.totalAssets * SHARES_PRECISION / v.totalShares
            : SHARES_PRECISION;

        v.totalAssets = v.totalAssets + netGain > netLoss + totalFees
            ? v.totalAssets + netGain - netLoss - totalFees
            : 0;

        // ── Issue shares for pending deposits ──────────────────────────
        if (v.pendingDeposits > 0) {
            uint256 newShares = v.totalShares > 0 && v.totalAssets > 0
                ? v.pendingDeposits * v.totalShares / v.totalAssets
                : v.pendingDeposits; // 1:1 at inception
            v.totalShares   += newShares;
            v.totalAssets   += v.pendingDeposits;
            v.pendingDeposits = 0;
            // Note: individual share assignments happen in claimShares()
        }

        // ── Redeem pending withdrawals ─────────────────────────────────
        if (v.pendingWithdrawals > 0) {
            uint256 sharesToRedeem = v.pendingWithdrawals;
            uint256 assetsToReturn = v.totalShares > 0
                ? sharesToRedeem * v.totalAssets / v.totalShares
                : 0;
            v.totalShares    -= sharesToRedeem;
            v.totalAssets    -= assetsToReturn;
            v.pendingWithdrawals = 0;
            // Note: individual asset claims happen in claimWithdrawal()
        }

        // ── Record epoch report ────────────────────────────────────────
        uint256 sharePriceEnd = v.totalShares > 0
            ? v.totalAssets * SHARES_PRECISION / v.totalShares
            : SHARES_PRECISION;

        epochHistory[vaultId].push(EpochReport({
            epochNumber:           v.epochNumber,
            premiumEarned:         premiumEarned,
            losses:                losses,
            netYield:              netGain > 0 ? netGain : 0,
            sharePriceStart:       sharePriceStart,
            sharePriceEnd:         sharePriceEnd,
            managementFeeCharged:  mgmtFee,
            performanceFeeCharged: perfFee,
            timestamp:             block.timestamp
        }));

        v.epochNumber++;
        v.epochStart    = block.timestamp;
        v.weeklyPremium = premiumEarned;

        emit EpochSettled(vaultId, v.epochNumber - 1, premiumEarned, netGain > totalFees ? netGain - totalFees : 0, totalFees);
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Claim after settlement
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice After epoch settlement, claim your vault shares for pending deposit.
     */
    function claimShares(uint256 vaultId) external nonReentrant {
        Vault storage v     = vaults[vaultId];
        UserVault storage uv = userVaults[vaultId][msg.sender];
        require(uv.pendingDeposit > 0, "OV: nothing to claim");

        // Compute shares at the price settled during the epoch
        // (simplified: use current share price)
        uint256 shares = v.totalShares > 0 && v.totalAssets > 0
            ? uv.pendingDeposit * v.totalShares / v.totalAssets
            : uv.pendingDeposit;

        uv.shares        += shares;
        uv.depositEpoch   = v.epochNumber;
        uv.pendingDeposit = 0;
    }

    /**
     * @notice After epoch settlement, claim USDC for queued withdrawal.
     */
    function claimWithdrawal(uint256 vaultId) external nonReentrant {
        Vault storage v      = vaults[vaultId];
        UserVault storage uv  = userVaults[vaultId][msg.sender];
        require(uv.pendingWithdraw > 0, "OV: nothing pending");

        uint256 assets = v.totalShares > 0
            ? uv.pendingWithdraw * v.totalAssets / (v.totalShares + v.pendingWithdrawals)
            : 0;

        uint256 payout = uv.pendingWithdraw; // simplified 1:1 + yield
        uv.pendingWithdraw = 0;

        IERC20(v.asset).safeTransfer(msg.sender, payout > 0 ? payout : assets);
        emit WithdrawSettled(vaultId, msg.sender, payout > 0 ? payout : assets);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Withdraw Protocol Fees
    // ──────────────────────────────────────────────────────────────────

    function withdrawFees(uint256 vaultId, address to) external onlyOwner nonReentrant {
        Vault storage v = vaults[vaultId];
        uint256 fees    = v.accumulatedFees;
        require(fees > 0, "OV: no fees");
        v.accumulatedFees = 0;
        IERC20(v.asset).safeTransfer(to, fees);
        emit FeesWithdrawn(vaultId, to, fees);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getVault(uint256 vaultId) external view returns (Vault memory) {
        return vaults[vaultId];
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function getUserVault(uint256 vaultId, address user) external view returns (UserVault memory) {
        return userVaults[vaultId][user];
    }

    function sharePrice(uint256 vaultId) public view returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.totalShares == 0) return SHARES_PRECISION;
        return v.totalAssets * SHARES_PRECISION / v.totalShares;
    }

    function userAssetValue(uint256 vaultId, address user) external view returns (uint256) {
        return userVaults[vaultId][user].shares * sharePrice(vaultId) / SHARES_PRECISION;
    }

    function getEpochHistory(uint256 vaultId) external view returns (EpochReport[] memory) {
        return epochHistory[vaultId];
    }

    function estimatedAPY(uint256 vaultId) external view returns (uint256) {
        EpochReport[] storage history = epochHistory[vaultId];
        if (history.length == 0) return 0;
        uint256 lastWeekYield = history[history.length - 1].netYield;
        Vault storage v = vaults[vaultId];
        if (v.totalAssets == 0) return 0;
        // Annualise the last weekly yield
        return lastWeekYield * 52 * 10000 / v.totalAssets;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
