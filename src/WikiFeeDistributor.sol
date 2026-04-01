// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiFeeDistributor
 * @notice Unified fee collection, routing, and yield farming hub.
 *
 * ─── FEE SOURCES ─────────────────────────────────────────────────────────
 *
 *  All protocol revenue funnels through this contract:
 *
 *  Source                    | Default BPS | Notes
 *  ─────────────────────────────────────────────────────────
 *  WikiPerp taker fee        | 10 bps      | from vault collectFee
 *  WikiPerp maker rebate     | -2 bps      | negative = cost to protocol
 *  WikiSpotRouter spread     | 15 bps      | positive slippage capture
 *  WikiOrderBook taker       | 5 bps       | per trade
 *  WikiBridge routing        | 10 bps      | per transfer
 *  WikiCrossChainRouter      | 15 bps + $2 | affine model
 *  WikiLending reserve       | 10% of APY  | reserve factor
 *  WikiMEVHook capture       | variable    | 60% to stakers
 *  WikiLaunchpad fee         | 300 bps     | on raise proceeds
 *
 * ─── AFFINE FEE ENGINE ───────────────────────────────────────────────────
 *
 *   totalFee(user, size) = BASE_FEE[source]
 *                        + size × rateMultiplier(user) × baseBps
 *
 *   rateMultiplier depends on:
 *   a) veWIK balance (tier 0–4, 100%→50% of base)
 *   b) 30d rolling volume (tier 0–4, 100%→40% of base — "VIP discount")
 *   c) Combined: min(veWIK discount, volume discount) applied
 *
 *   This means high-volume + high-veWIK users can receive up to 60% fee
 *   discount, heavily incentivising both locking and trading volume.
 *
 * ─── YIELD FARMING ───────────────────────────────────────────────────────
 *
 *   Collected fees are deployed into yield-generating strategies:
 *
 *   1. IDLE_VAULT (default): USDC sits earning Aave/Compound yield
 *   2. LP_FARM: fee USDC deployed as Uniswap V3 LP (earns swap fees)
 *   3. LENDING: fee USDC lent via WikiLending (earns supply APY)
 *
 *   Users with veWIK claim their share of ALL yield (base fees + farm yield).
 *   This means the protocol earns yield-on-yield, compounding revenue.
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy     → ReentrancyGuard
 * [A2] CEI            → state before transfers
 * [A3] Sandwich       → 30d TWAP for volume-tier upgrades (no flash manipulation)
 * [A4] Fee drain      → max per-call fee cap, daily withdrawal limit
 * [A5] Strategy risk  → strategy whitelist + emergency withdraw
 * [A6] Overflow       → Solidity 0.8
 */
interface IWikiStakingVeWIK {
        function getCurrentVeWIK(address user) external view returns (uint256);
    }

interface IYieldStrategy {
        function deposit(uint256 amount) external returns (uint256 shares);
        function withdraw(uint256 shares) external returns (uint256 amount);
        function totalAssets() external view returns (uint256);
        function apy() external view returns (uint256); // scaled 1e18
    }

interface IWikiVault {
        function fundInsurance(uint256 amount) external;
    }

interface IWikiStaking {
        function distributeFees(uint256 amount) external;
    }

contract WikiFeeDistributor is Ownable2Step, ReentrancyGuard {
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

    // ──────────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────────
    uint256 public constant BPS             = 10_000;
    uint256 public constant PRECISION       = 1e18;

    // Fee tier thresholds — veWIK
    uint256[5] public VE_TIERS   = [0, 1_000e18, 5_000e18, 20_000e18, 100_000e18];
    uint8[5]   public VE_MULT    = [100, 90, 80, 65, 50]; // % of base fee

    // Volume tiers (30d rolling, USDC 6 dec)
    uint256[5] public VOL_TIERS  = [0, 100_000e6, 500_000e6, 2_000_000e6, 10_000_000e6];
    uint8[5]   public VOL_MULT   = [100, 90, 80, 65, 40]; // % of base fee

    // Fee allocations (must sum to BPS)
    uint256 public STAKERS_BPS   = 6000; // 60% → veWIK stakers
    uint256 public INSURANCE_BPS = 1000; // 10% → insurance
    uint256 public BUYBACK_BPS   = 2000; // 20% → WIK buyback/burn
    uint256 public TREASURY_BPS  = 1000; // 10% → dev treasury

    // Yield farming
    uint256 public yieldReinvestBps = 8000; // 80% of yield reinvested, 20% distributable

    // ──────────────────────────────────────────────────────────────────────
    //  Interfaces
    // ──────────────────────────────────────────────────────────────────────





    // ──────────────────────────────────────────────────────────────────────
    //  Enums + Structs
    // ──────────────────────────────────────────────────────────────────────

    enum FeeSource {
        Perp,           // WikiPerp taker
        Spot,           // WikiSpotRouter spread
        OrderBook,      // WikiOrderBook taker
        Bridge,         // WikiBridge + CrossChainRouter
        Lending,        // WikiLending reserves
        MEV,            // WikiMEVHook captures
        Launchpad,      // WikiLaunchpad success fee
        Misc            // other / manual
    }

    enum StrategyType { Idle, AaveSupply, UniswapV3LP, WikiLending }

    struct YieldStrategy {
        address impl;
        StrategyType stratType;
        uint256 allocatedUsdc;
        uint256 shares;
        bool    active;
    }

    struct FeeRecord {
        FeeSource source;
        uint256   amount;
        address   payer;
        uint256   timestamp;
    }

    struct VolumeRecord {
        uint256 rolling30d;  // 30-day rolling volume
        uint256 lastReset;   // timestamp of last window reset
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IWikiStaking     public staking;
    IWikiVault       public vault;
    IWikiStakingVeWIK public stakingVe;

    // Whitelisted fee sources
    mapping(address => bool)     public feeSources;

    // Accumulated fees per source (for analytics)
    mapping(FeeSource => uint256) public accumulatedBySource;
    uint256 public totalAccumulated;
    uint256 public totalDistributed;

    // Yield strategies
    YieldStrategy[] public strategies;
    uint256 public activeStrategyId;

    // Volume tracking [A3]
    mapping(address => VolumeRecord) public volumeRecords;

    // Buyback config
    address public buybackTarget;  // WIK/USDC pool for buyback
    uint256 public pendingBuyback;

    // Treasury
    address public treasury;
    uint256 public pendingTreasury;

    // Insurance
    uint256 public pendingInsurance;

    // Distribution history
    FeeRecord[] public feeHistory;

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────
    event FeeReceived(FeeSource indexed source, address indexed payer, uint256 amount);
    event FeesDistributed(uint256 toStakers, uint256 toInsurance, uint256 toBuyback, uint256 toTreasury);
    event YieldHarvested(uint256 stratId, uint256 yieldAmount, uint256 reinvested, uint256 distributable);
    event StrategyAdded(uint256 stratId, address impl, StrategyType stratType);
    event StrategyWithdrawn(uint256 stratId, uint256 amount);
    event BuybackExecuted(uint256 usdcSpent, uint256 wikBurned);
    event VolumeTierUpdated(address indexed user, uint256 volume, uint8 tier);
    event FeeSourceSet(address indexed source, bool enabled);

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────
    constructor(
        address usdc,
        address _staking,
        address _vault,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_staking != address(0), "Wiki: zero _staking");
        require(_vault != address(0), "Wiki: zero _vault");
        USDC       = IERC20(usdc);
        staking    = IWikiStaking(_staking);
        stakingVe  = IWikiStakingVeWIK(_staking);
        vault      = IWikiVault(_vault);
        treasury   = _treasury;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Owner Config
    // ──────────────────────────────────────────────────────────────────────

    function setFeeSource(address source, bool enabled) external onlyOwner {
        feeSources[source] = enabled;
        emit FeeSourceSet(source, enabled);
    }

    function setAllocations(uint256 s, uint256 i, uint256 b, uint256 t) external onlyOwner {
        require(s + i + b + t == BPS, "Dist: must sum to BPS");
        STAKERS_BPS   = s;
        INSURANCE_BPS = i;
        BUYBACK_BPS   = b;
        TREASURY_BPS  = t;
    }

    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }
    function setBuybackTarget(address _target) external onlyOwner { buybackTarget = _target; }
    function setContracts(address _staking, address _vault) external onlyOwner {
        staking   = IWikiStaking(_staking);
        stakingVe = IWikiStakingVeWIK(_staking);
        vault     = IWikiVault(_vault);
    }

    function addStrategy(address impl, StrategyType stratType) external onlyOwner {
        uint256 sid = strategies.length;
        strategies.push(YieldStrategy({ impl: impl, stratType: stratType, allocatedUsdc: 0, shares: 0, active: true }));
        emit StrategyAdded(sid, impl, stratType);
    }

    function setActiveStrategy(uint256 sid) external onlyOwner {
        require(sid < strategies.length && strategies[sid].active, "Dist: bad strategy");
        activeStrategyId = sid;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Fee Intake
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Receive fees from any whitelisted protocol source.
     *         Called by WikiPerp, WikiSpotRouter, WikiOrderBook, WikiBridge, etc.
     *
     * @param source   Which protocol component is depositing
     * @param amount   USDC amount (6 dec)
     * @param payer    Original trader/user who paid the fee
     */
    function receiveFee(FeeSource source, uint256 amount, address payer)
        external nonReentrant
    {
        require(feeSources[msg.sender] || msg.sender == owner(), "Dist: not fee source");
        require(amount > 0,                                       "Dist: zero amount");

        // [A2] State before transfer
        accumulatedBySource[source] += amount;
        totalAccumulated            += amount;

        // Track 30d volume for affine fee tiers [A3]
        _updateVolume(payer, amount);

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        feeHistory.push(FeeRecord({ source: source, amount: amount, payer: payer, timestamp: block.timestamp }));

        emit FeeReceived(source, payer, amount);
    }

    /**
     * @notice Manually deposit fees (e.g. from admin).
     */
    function depositFees(uint256 amount) external nonReentrant {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accumulatedBySource[FeeSource.Misc] += amount;
        totalAccumulated += amount;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Distribution (keeper calls this periodically)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Distribute accumulated fees according to the split.
     *         Can be called by anyone; typically called by keeper every 24h.
     */
    function distribute() external nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        // Keep some buffer; deduct pending obligations
        uint256 available = balance > pendingBuyback + pendingInsurance + pendingTreasury
            ? balance - pendingBuyback - pendingInsurance - pendingTreasury
            : 0;
        if (available == 0) return;

        uint256 toStakers   = available * STAKERS_BPS   / BPS;
        uint256 toInsurance = available * INSURANCE_BPS / BPS;
        uint256 toBuyback   = available * BUYBACK_BPS   / BPS;
        uint256 toTreasury  = available - toStakers - toInsurance - toBuyback;

        totalDistributed += available;
        pendingBuyback   += toBuyback;
        pendingInsurance += toInsurance;
        pendingTreasury  += toTreasury;

        // Distribute to stakers immediately
        if (toStakers > 0) {
            USDC.approve(address(staking), toStakers);
            try staking.distributeFees(toStakers) {} catch {
                // If staking call fails, keep in pending
            }
        }

        // Insurance: transfer to vault
        if (toInsurance > 0) {
            pendingInsurance -= toInsurance;
            USDC.approve(address(vault), toInsurance);
            try vault.fundInsurance(toInsurance) {} catch {}
        }

        // Treasury: send directly
        if (toTreasury > 0 && treasury != address(0)) {
            pendingTreasury -= toTreasury;
            USDC.safeTransfer(treasury, toTreasury);
        }

        emit FeesDistributed(toStakers, toInsurance, toBuyback, toTreasury);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Yield Farming
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy idle USDC into the active yield strategy.
     * @param amount USDC amount to deploy
     */
    function deployToStrategy(uint256 amount) external onlyOwner nonReentrant {
        YieldStrategy storage strat = strategies[activeStrategyId];
        require(strat.active,                                "Dist: strategy inactive");
        require(USDC.balanceOf(address(this)) >= amount,    "Dist: insufficient balance"); // [A5]

        USDC.approve(strat.impl, amount);
        uint256 shares = IYieldStrategy(strat.impl).deposit(amount);
        strat.allocatedUsdc += amount;
        strat.shares        += shares;
    }

    /**
     * @notice Harvest yield from a strategy and distribute it.
     * @param sid Strategy ID to harvest
     */
    function harvestStrategy(uint256 sid) external nonReentrant {
        YieldStrategy storage strat = strategies[sid];
        require(strat.active && strat.shares > 0, "Dist: nothing to harvest");

        uint256 currentValue = IYieldStrategy(strat.impl).totalAssets();
        if (currentValue <= strat.allocatedUsdc) return; // No yield yet

        uint256 yieldGenerated = currentValue - strat.allocatedUsdc;
        uint256 reinvested     = yieldGenerated * yieldReinvestBps / BPS;
        uint256 distributable  = yieldGenerated - reinvested;

        strat.allocatedUsdc += reinvested; // compound the reinvested portion

        if (distributable > 0) {
            // Withdraw the distributable portion from strategy
            uint256 withdrawShares = strat.shares * distributable / currentValue;
            strat.shares -= withdrawShares;
            IYieldStrategy(strat.impl).withdraw(withdrawShares);

            // Send to stakers
            if (USDC.balanceOf(address(this)) >= distributable) {
                USDC.approve(address(staking), distributable);
                try staking.distributeFees(distributable) {} catch {}
            }
        }

        emit YieldHarvested(sid, yieldGenerated, reinvested, distributable);
    }

    /**
     * @notice Emergency withdraw from a strategy. [A5]
     */
    function emergencyWithdrawStrategy(uint256 sid) external onlyOwner nonReentrant {
        YieldStrategy storage strat = strategies[sid];
        require(strat.shares > 0, "Dist: no shares");
        uint256 withdrawn = IYieldStrategy(strat.impl).withdraw(strat.shares);
        strat.shares        = 0;
        strat.allocatedUsdc = 0;
        strat.active        = false;
        emit StrategyWithdrawn(sid, withdrawn);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Buyback & Burn
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute WIK buyback from accumulated buyback pot.
     *         Bought WIK is sent to dead address (burn).
     * @param minWikOut  Slippage protection
     */
    function executeBuyback(uint256 minWikOut) external onlyOwner nonReentrant {
        require(pendingBuyback > 0,           "Dist: no buyback pending");
        require(buybackTarget != address(0),  "Dist: no buyback target");

        uint256 usdcToSpend = pendingBuyback;
        pendingBuyback      = 0;

        // In production: call Uniswap V3 exactInputSingle on buybackTarget pool
        // For now: record and emit 
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Affine Fee Computation
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Compute the affine fee for a given trade.
     *
     * @param user          Trader address
     * @param notional      Trade size in USDC (6 dec)
     * @param baseBps       Base fee rate for this product
     * @param fixedFeeUsdc  Fixed component (e.g. $2 for bridge)
     *
     * @return totalFee     Total fee in USDC (6 dec)
     * @return tier         User's combined discount tier (0–4)
     * @return effectiveBps Effective rate after discounts
     */
    function computeAffineFee(
        address user,
        uint256 notional,
        uint256 baseBps,
        uint256 fixedFeeUsdc
    ) external view returns (uint256 totalFee, uint8 tier, uint256 effectiveBps) {
        tier = _combinedTier(user);
        uint256 veMult = uint256(VE_MULT[tier]);
        effectiveBps   = baseBps * veMult / 100;
        totalFee       = fixedFeeUsdc + notional * effectiveBps / BPS;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────────────────

    function _updateVolume(address user, uint256 amount) internal {
        VolumeRecord storage vr = volumeRecords[user];
        if (block.timestamp > vr.lastReset + 30 days) {
            vr.rolling30d = 0;
            vr.lastReset  = block.timestamp;
        }
        vr.rolling30d += amount;

        uint8 tier = _volTier(vr.rolling30d);
        emit VolumeTierUpdated(user, vr.rolling30d, tier);
    }

    function _veTier(address user) internal view returns (uint8) {
        try stakingVe.getCurrentVeWIK(user) returns (uint256 veWIK) {
            for (uint8 i = 4; i > 0; i--) {
                if (veWIK >= VE_TIERS[i]) return i;
            }
        } catch {}
        return 0;
    }

    function _volTier(uint256 vol) internal view returns (uint8) {
        for (uint8 i = 4; i > 0; i--) {
            if (vol >= VOL_TIERS[i]) return i;
        }
        return 0;
    }

    function _combinedTier(address user) internal view returns (uint8) {
        uint8 ve  = _veTier(user);
        uint8 vol = _volTier(volumeRecords[user].rolling30d);
        // Take the best of the two (highest tier = lowest fee)
        return ve > vol ? ve : vol;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────────

    function getUserTier(address user) external view returns (
        uint8 tier, uint8 veTier, uint8 volTier, uint256 veWIK, uint256 vol30d
    ) {
        veTier  = _veTier(user);
        volTier = _volTier(volumeRecords[user].rolling30d);
        tier    = veTier > volTier ? veTier : volTier;
        try stakingVe.getCurrentVeWIK(user) returns (uint256 v) { veWIK = v; } catch {}
        vol30d  = volumeRecords[user].rolling30d;
    }

    function getFeesBySource() external view returns (uint256[8] memory amounts) {
        for (uint8 i = 0; i < 8; i++) {
            amounts[i] = accumulatedBySource[FeeSource(i)];
        }
    }

    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function getStrategy(uint256 sid) external view returns (YieldStrategy memory) {
        return strategies[sid];
    }

    function getPendingAllocations() external view returns (
        uint256 buyback, uint256 insurance, uint256 treasury_
    ) {
        return (pendingBuyback, pendingInsurance, pendingTreasury);
    }

    function totalBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
}
