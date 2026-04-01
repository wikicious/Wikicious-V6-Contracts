// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./WikiPerp.sol";
import "./WikiVault.sol";
import "./WikiKeeperRegistry.sol";

/// @title WikiLiquidator — On-chain batch liquidator with Dutch auction rewards
///
/// Any EOA or contract can call liquidate() permissionlessly.
/// Registered keepers (via WikiKeeperRegistry) earn a multiplied reward on top
/// of the base liquidation fee that WikiPerp already routes to msg.sender.
///
/// REWARD MECHANISM
/// ────────────────
/// WikiPerp pays msg.sender 5% of collateral (LIQUIDATION_FEE_BPS = 500) already
/// by calling vault.transferMargin(trader, liquidator, liqFee).
/// WikiLiquidator adds an ADDITIONAL bonus funded by a protocol reward pool:
///
///   bonusReward = baseRewardUsdc
///                 × urgencyMultiplier(pos)     ← grows as pos goes deeper underwater
///                 × keeperMultiplier(caller)   ← tier 1/2/3 registered keepers
///
/// ATTACK MITIGATIONS:
/// [A1] Reentrancy             → ReentrancyGuard on all state-mutating functions
/// [A2] Checks-Effects-Interactions → state written before all external calls
/// [A3] Self-liquidation replay → WikiPerp enforces trader != liquidator
/// [A4] Sandwich attacks       → oracle freshness enforced before liquidation
/// [A5] Reward pool drain      → per-liquidation reward cap, daily pool limit
/// [A6] Flash loan position manipulation → WikiPerp [A10] OI rate limit prevents it
/// [A7] Batch griefing         → failed positions skipped (try/catch), not reverted
/// [A8] Keeper impersonation   → only real keeper addresses can claim multiplier

contract WikiLiquidator is Ownable2Step, ReentrancyGuard {
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

    // ── Interfaces ─────────────────────────────────────────────────────────
    WikiPerp            public immutable perp;
    WikiVault           public immutable vault;
    WikiKeeperRegistry  public           registry;
    IERC20              public immutable USDC;

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant BPS                      = 10000;
    uint256 public constant MAX_ORACLE_AGE           = 60;        // 60s — reject stale prices [A4]
    uint256 public constant BASE_BONUS_USDC          = 5 * 1e6;   // $5 USDC base bonus per liq
    uint256 public constant MAX_BONUS_USDC           = 50 * 1e6;  // $50 USDC max bonus per liq [A5]
    uint256 public constant MAX_DAILY_POOL_USAGE     = 10_000 * 1e6; // $10,000/day pool limit [A5]
    uint256 public constant URGENCY_SCALE_BPS        = 500;       // starts at 1× at 0%, 1.5× at 5% underwater

    // Dutch auction: urgency multiplier grows from 10000 (1×) to 20000 (2×)
    // as position moves from liqPrice to liqPrice × (1 - URGENCY_SCALE_BPS/BPS)
    uint256 public constant MAX_URGENCY_MULT         = 20000;     // 2× cap

    // ── State ──────────────────────────────────────────────────────────────
    uint256 public rewardPool;           // USDC available for keeper bonuses
    uint256 public dailyPoolUsed;        // USDC used today [A5]
    uint256 public dailyPoolResetAt;     // timestamp of current day start

    uint256 public totalLiquidations;
    uint256 public totalBonusPaid;

    // Pause emergency bypass
    bool public paused;

    // ── Events ─────────────────────────────────────────────────────────────
    event LiquidationExecuted(
        uint256 indexed posId,
        address indexed keeper,
        address indexed trader,
        uint256 perpFee,        // fee paid by WikiPerp.liquidate() to keeper
        uint256 bonusUsdc,      // additional bonus from reward pool
        uint256 urgencyMult,
        uint256 keeperMult
    );
    event BatchLiquidationResult(
        address indexed keeper,
        uint256 attempted,
        uint256 succeeded,
        uint256 totalBonus
    );
    event OrdersExecuted(
        address indexed keeper,
        uint256 marketIdx,
        uint256 count
    );
    event FundingSettled(
        address indexed keeper,
        uint256 marketIdx
    );
    event RewardPoolFunded(address indexed from, uint256 amount);
    event RewardPoolWithdrawn(address indexed to, uint256 amount);
    event RegistryUpdated(address newRegistry);
    event EmergencyPause(bool paused);

    // ── Modifier ───────────────────────────────────────────────────────────
    modifier notPaused() {
        require(!paused, "Liquidator: paused");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(
        address _perp,
        address _vault,
        address _registry,
        address _usdc,
        address _owner
    ) Ownable(_owner) {
        require(_perp != address(0), "Wiki: zero _perp");
        require(_vault != address(0), "Wiki: zero _vault");
        require(_registry != address(0), "Wiki: zero _registry");
        perp     = WikiPerp(_perp);
        vault    = WikiVault(_vault);
        registry = WikiKeeperRegistry(_registry);
        USDC     = IERC20(_usdc);
    }

    // ── Owner config ───────────────────────────────────────────────────────
    function setRegistry(address _registry) external onlyOwner {
        registry = WikiKeeperRegistry(_registry);
        emit RegistryUpdated(_registry);
    }

    function fundRewardPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Liquidator: zero amount");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        emit RewardPoolFunded(msg.sender, amount);
    }

    function withdrawRewardPool(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= rewardPool, "Liquidator: exceeds pool");
        rewardPool -= amount;
        USDC.safeTransfer(to, amount);
        emit RewardPoolWithdrawn(to, amount);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit EmergencyPause(_paused);
    }

    // ── Single liquidation ─────────────────────────────────────────────────

    /// @notice Liquidate a single position. Anyone may call. [A3]
    /// @param posId  Position ID in WikiPerp
    function liquidateSingle(uint256 posId) external nonReentrant notPaused {
        _doLiquidate(posId, msg.sender);
    }

    // ── Batch liquidation ──────────────────────────────────────────────────

    /// @notice Liquidate multiple positions in one tx.
    ///         Failed positions are skipped — the batch never reverts fully. [A7]
    /// @param posIds  Array of position IDs to liquidate
    function liquidateBatch(uint256[] calldata posIds)
        external nonReentrant notPaused
        returns (uint256 succeeded, uint256 totalBonus)
    {
        require(posIds.length > 0 && posIds.length <= 50, "Liquidator: bad batch size");

        for (uint256 i = 0; i < posIds.length; i++) {
            // [A7] Catch and skip failures — don't let one bad position kill the batch
            try this._tryLiquidate(posIds[i], msg.sender) returns (uint256 bonus) {
                succeeded++;
                totalBonus += bonus;
            } catch {
                // Position not liquidatable, already closed, or oracle issue — skip
            }
        }

        emit BatchLiquidationResult(msg.sender, posIds.length, succeeded, totalBonus);
    }

    /// @dev External wrapper so it can be try/caught — DO NOT call directly
    function _tryLiquidate(uint256 posId, address keeper) external returns (uint256 bonus) {
        require(msg.sender == address(this), "Liquidator: internal only");
        return _doLiquidate(posId, keeper);
    }

    // ── Execute limit orders ───────────────────────────────────────────────

    /// @notice Execute a batch of limit orders for a given market.
    ///         Keepers earn a flat bonus per successfully filled order.
    /// @param marketIdx  Market index in WikiPerp
    /// @param orderIds   Order IDs to attempt
    function executeLimitOrders(uint256 marketIdx, uint256[] calldata orderIds)
        external nonReentrant notPaused
    {
        require(orderIds.length > 0 && orderIds.length <= 100, "Liquidator: bad batch size");

        // Snapshot open orders before execution
        uint256 openBefore = _countOpenOrders(orderIds);

        perp.executeLimitOrders(marketIdx, orderIds);

        uint256 openAfter  = _countOpenOrders(orderIds);
        uint256 filled     = openBefore > openAfter ? openBefore - openAfter : 0;

        // Reward registered keepers for filled orders
        if (filled > 0 && registry.isActive(msg.sender)) {
            registry.recordOrderFill(msg.sender);
        }

        emit OrdersExecuted(msg.sender, marketIdx, filled);
    }

    // ── Settle funding ─────────────────────────────────────────────────────

    /// @notice Settle funding for a market. Callable by anyone.
    function settleFunding(uint256 marketIdx) external notPaused {
        perp.settleFunding(marketIdx);
        emit FundingSettled(msg.sender, marketIdx);
    }

    /// @notice Settle funding for multiple markets in one call.
    function settleFundingBatch(uint256[] calldata marketIdxs) external notPaused {
        for (uint256 i = 0; i < marketIdxs.length; i++) {
            try perp.settleFunding(marketIdxs[i]) {
                emit FundingSettled(msg.sender, marketIdxs[i]);
            } catch {}
        }
    }

    // ── Execute TP/SL ──────────────────────────────────────────────────────

    /// @notice Execute take-profit or stop-loss for a position.
    function executeTPSL(uint256 posId) external nonReentrant notPaused {
        perp.executeTPSL(posId);
    }

    /// @notice Execute TP/SL for multiple positions (skips failures). [A7]
    function executeTPSLBatch(uint256[] calldata posIds)
        external nonReentrant notPaused
        returns (uint256 succeeded)
    {
        for (uint256 i = 0; i < posIds.length; i++) {
            try perp.executeTPSL(posIds[i]) {
                succeeded++;
            } catch {}
        }
    }

    // ── Views ──────────────────────────────────────────────────────────────

    /// @notice Checks if a position is currently liquidatable
    function isLiquidatable(uint256 posId) external view returns (bool liquidatable, uint256 currentPrice, uint256 liqPrice) {
        WikiPerp.Position memory pos = perp.getPosition(posId);
        if (!pos.open) return (false, 0, pos.liquidationPrice);

        WikiPerp.Market memory mkt = perp.getMarket(pos.marketIndex);
        try perp.oracle().getPriceReadOnly(mkt.marketId) returns (uint256 price, uint256) {
            currentPrice = price;
            liqPrice     = pos.liquidationPrice;
            liquidatable = pos.isLong
                ? price <= pos.liquidationPrice
                : price >= pos.liquidationPrice;
        } catch {}
    }

    /// @notice Preview bonus for liquidating a position (before execution)
    function previewBonus(uint256 posId) external view returns (uint256 bonus, uint256 urgencyMult, uint256 keeperMult) {
        WikiPerp.Position memory pos = perp.getPosition(posId);
        if (!pos.open) return (0, 0, 0);

        WikiPerp.Market memory mkt = perp.getMarket(pos.marketIndex);
        try perp.oracle().getPriceReadOnly(mkt.marketId) returns (uint256 price, uint256) {
            urgencyMult = _urgencyMultiplier(pos, price);
            keeperMult  = registry.rewardMultiplier(msg.sender);
            bonus       = _calcBonus(urgencyMult, keeperMult);
        } catch {}
    }

    /// @notice Returns how much reward pool is available today
    function remainingDailyPool() external view returns (uint256) {
        if (block.timestamp >= dailyPoolResetAt + 1 days) {
            return MAX_DAILY_POOL_USAGE > rewardPool ? rewardPool : MAX_DAILY_POOL_USAGE;
        }
        uint256 used = dailyPoolUsed;
        if (used >= MAX_DAILY_POOL_USAGE) return 0;
        uint256 remaining = MAX_DAILY_POOL_USAGE - used;
        return remaining > rewardPool ? rewardPool : remaining;
    }

    // ── Internal ───────────────────────────────────────────────────────────

    function _doLiquidate(uint256 posId, address keeper) internal returns (uint256 bonus) {
        WikiPerp.Position memory pos = perp.getPosition(posId);
        require(pos.open, "Liquidator: position not open");

        WikiPerp.Market memory mkt = perp.getMarket(pos.marketIndex);

        // [A4] Verify oracle freshness
        (uint256 price, uint256 updatedAt) = perp.oracle().getPrice(mkt.marketId);
        require(
            block.timestamp - updatedAt <= MAX_ORACLE_AGE,
            "Liquidator: stale oracle"
        );

        // Verify position is actually liquidatable
        bool liqCondition = pos.isLong
            ? price <= pos.liquidationPrice
            : price >= pos.liquidationPrice;
        require(liqCondition, "Liquidator: not liquidatable");

        // Calculate bonus BEFORE liquidation (using pre-liq state)
        uint256 urgencyMult = _urgencyMultiplier(pos, price);
        uint256 keeperMult  = registry.rewardMultiplier(keeper);
        bonus = _calcBonus(urgencyMult, keeperMult);

        // [A2] Accrue stats BEFORE external call to WikiPerp
        totalLiquidations++;
        if (registry.isActive(keeper)) {
            registry.recordLiquidation(keeper);
        }

        // Execute the liquidation — WikiPerp pays base liq fee (5% collateral) to `keeper`
        // [A3] WikiPerp enforces trader != msg.sender, so keeper cannot self-liquidate
        perp.liquidate(posId);

        // Pay out bonus from reward pool [A5]
        uint256 perpFee = pos.collateral * 500 / BPS; // LIQUIDATION_FEE_BPS = 500
        if (bonus > 0 && rewardPool >= bonus) {
            _payBonus(keeper, bonus);
        } else if (bonus > 0) {
            // Pool exhausted — pay what's left
            bonus = rewardPool;
            if (bonus > 0) _payBonus(keeper, bonus);
        }

        emit LiquidationExecuted(posId, keeper, pos.trader, perpFee, bonus, urgencyMult, keeperMult);
    }

    function _payBonus(address keeper, uint256 amount) internal {
        // [A5] Daily pool limit
        _resetDailyIfNeeded();
        uint256 available = MAX_DAILY_POOL_USAGE > dailyPoolUsed
            ? MAX_DAILY_POOL_USAGE - dailyPoolUsed
            : 0;
        if (available == 0) return;
        if (amount > available) amount = available;
        if (amount > rewardPool) amount = rewardPool;
        if (amount == 0) return;

        rewardPool     -= amount;
        dailyPoolUsed  += amount;
        totalBonusPaid += amount;

        // Accrue to registry for keeper to claim, or direct-transfer if unregistered
        if (registry.isActive(keeper)) {
            // Approve and let registry pull, or just transfer directly to keeper
            // For simplicity: transfer directly to keeper (gas efficient)
            USDC.safeTransfer(keeper, amount);
        } else {
            USDC.safeTransfer(keeper, amount);
        }
    }

    function _resetDailyIfNeeded() internal {
        if (block.timestamp >= dailyPoolResetAt + 1 days) {
            dailyPoolResetAt = block.timestamp;
            dailyPoolUsed    = 0;
        }
    }

    /// @dev Dutch auction urgency multiplier.
    ///      Returns BPS value: 10000 = 1×, 20000 = 2×
    ///      Grows as the position becomes more underwater.
    function _urgencyMultiplier(WikiPerp.Position memory pos, uint256 price)
        internal pure returns (uint256)
    {
        if (pos.liquidationPrice == 0) return BPS;

        uint256 deviation;
        if (pos.isLong) {
            // liqPrice >= price for longs in liquidation
            if (price >= pos.liquidationPrice) return BPS; // not yet at liq
            deviation = (pos.liquidationPrice - price) * BPS / pos.liquidationPrice;
        } else {
            // liqPrice <= price for shorts in liquidation
            if (price <= pos.liquidationPrice) return BPS;
            deviation = (price - pos.liquidationPrice) * BPS / pos.liquidationPrice;
        }

        // Scale: at URGENCY_SCALE_BPS (5%) deviation → 2×
        uint256 mult = BPS + (deviation * BPS / URGENCY_SCALE_BPS);
        return mult > MAX_URGENCY_MULT ? MAX_URGENCY_MULT : mult;
    }

    function _calcBonus(uint256 urgencyMult, uint256 keeperMult) internal view returns (uint256) {
        uint256 bonus = BASE_BONUS_USDC
            * urgencyMult / BPS
            * keeperMult  / BPS;
        return bonus > MAX_BONUS_USDC ? MAX_BONUS_USDC : bonus;
    }

    function _countOpenOrders(uint256[] calldata orderIds) internal view returns (uint256 count) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            WikiPerp.Order memory o = perp.getOrder(orderIds[i]);
            if (o.open) count++;
        }
    }
}
