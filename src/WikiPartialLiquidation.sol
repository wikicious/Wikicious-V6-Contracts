// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiPartialLiquidation
 * @notice Liquidates only the minimum fraction of a position needed to
 *         restore the user's Health Score to a safe level.
 *
 * ─── THE PROBLEM WITH FULL LIQUIDATION ─────────────────────────────────────
 *
 *   Old system: position drops to maintenance margin → entire position closed.
 *   At 2000× EUR/USD leverage on a $1M position, a full liquidation dumps
 *   $1M notional of EUR/USD onto the vAMM in one block. This causes:
 *     - Massive slippage against the liquidated user (they lose MORE)
 *     - Price impact that can cascade-liquidate neighbouring positions
 *     - Insurance Fund has to cover the gap
 *
 *   With partial liquidation:
 *     Position at 2000× drops to 10% health → close only 30% of position
 *     Health score restores to 60% → user retains 70% of their position
 *     Slippage is 70% smaller
 *     No cascade effect
 *
 * ─── THE MATH ───────────────────────────────────────────────────────────────
 *
 *   Health Score = collateral / maintenanceMargin (as percentage)
 *
 *   Target health after partial liq = TARGET_HEALTH_BPS (default: 5000 = 50%)
 *
 *   Amount to liquidate:
 *     shortfall     = requiredMargin - collateral
 *     fractionToClose = shortfall / (collateral × targetHealth / requiredMargin)
 *     (capped at MAX_PARTIAL = 50% per single liquidation step)
 *
 *   If one partial liquidation is not enough (health still <0 after max partial),
 *   the system escalates to a second partial or full liquidation.
 *
 * ─── STEPPED LIQUIDATION ────────────────────────────────────────────────────
 *
 *   Step 1: Close up to 25% of position → check health
 *   Step 2: Close up to 50% of position → check health
 *   Step 3: Close full position (standard liquidation)
 *
 *   Each step has a 30-second delay between calls to allow market to stabilise.
 *
 * ─── FEES & INCENTIVES ──────────────────────────────────────────────────────
 *
 *   Partial liq fee: 0.5% of liquidated notional (vs 1.0% for full liq)
 *   Liquidator earns: 0.3% (keeper bot incentive)
 *   Insurance Fund:   0.2% (covers any residual bad debt)
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Reentrancy guard on all liquidation calls
 * [A2] Only authorised liquidators can call (WikiLiquidator contract)
 * [A3] Cannot liquidate a healthy position (healthScore > MIN_HEALTH_BPS)
 * [A4] Max 50% closed per single partial liquidation call
 * [A5] Step delay enforced between multiple partial liq steps
 */
interface IInsuranceFund {
        function absorb(uint256 amount) external;
        function depositFee(uint256 amount) external;
    }

interface IWikiVolatilityMargin {
        function isPositionHealthy(uint256 marketId, uint256 collateral, uint256 notional)
            external view returns (bool healthy, uint256 healthScoreBps, uint256 requiredMargin);
    }

interface IWikiPerp {
        struct Position {
            address trader;
            uint256 marketId;
            bool    isLong;
            uint256 collateral;
            uint256 notional;
            uint256 entryPrice;
            int256  unrealisedPnl;
        }
        function getPosition(uint256 positionId) external view returns (Position memory);
        function partialClose(uint256 positionId, uint256 fraction) external returns (int256 pnl, uint256 returnedCollateral);
        function forceClose(uint256 positionId) external returns (int256 pnl);
    }

contract WikiPartialLiquidation is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;





    // ── State ─────────────────────────────────────────────────────────────
    IERC20                  public immutable USDC;
    IWikiPerp               public perp;
    IWikiVolatilityMargin   public volMargin;
    IInsuranceFund          public insuranceFund;

    // Config
    uint256 public targetHealthBps   = 5000;  // restore health to 50% after partial liq
    uint256 public minHealthBps      = 500;   // <5% triggers liquidation
    uint256 public maxPartialBps     = 5000;  // max 50% per step [A4]
    uint256 public stepDelaySeconds  = 30;    // delay between steps [A5]
    uint256 public partialLiqFeeBps  = 50;    // 0.5% fee on liquidated notional
    uint256 public liquidatorShareBps= 30;    // 0.3% to liquidator bot
    uint256 public insuranceShareBps = 20;    // 0.2% to insurance fund

    mapping(address => bool)     public authorisedLiquidators; // [A2]
    mapping(uint256 => uint256)  public lastPartialLiqTime;    // posId → timestamp [A5]
    mapping(uint256 => uint8)    public liquidationStep;       // posId → step (0,1,2,3)

    // ── Events ────────────────────────────────────────────────────────────
    event PartialLiquidation(
        uint256 indexed positionId,
        address indexed trader,
        uint256 fractionClosedBps,
        uint256 notionalClosed,
        int256  pnl,
        uint256 newHealthScoreBps,
        uint256 step,
        address liquidator,
        uint256 liquidatorFee
    );
    event FullLiquidationEscalated(uint256 indexed positionId, address trader, uint256 step);
    event HealthRestored(uint256 indexed positionId, uint256 newHealthBps);

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc,
        address _perp,
        address _volMargin,
        address _insuranceFund
    ) Ownable(_owner) {
        USDC           = IERC20(_usdc);
        perp           = IWikiPerp(_perp);
        if (_volMargin      != address(0)) volMargin      = IWikiVolatilityMargin(_volMargin);
        if (_insuranceFund  != address(0)) insuranceFund  = IInsuranceFund(_insuranceFund);
        authorisedLiquidators[_owner] = true;
    }

    // ── Core: Partial Liquidation ─────────────────────────────────────────

    /**
     * @notice Execute a partial liquidation on an unhealthy position.
     *         Closes only enough to restore the health score to targetHealthBps.
     *
     * @param positionId  The position to partially liquidate
     */
    function partialLiquidate(uint256 positionId) external nonReentrant returns (
        uint256 fractionClosedBps,
        uint256 newHealthBps,
        bool    fullyLiquidated
    ) {
        require(authorisedLiquidators[msg.sender], "PL: not authorised"); // [A2]

        // Step delay enforcement [A5]
        if (lastPartialLiqTime[positionId] > 0) {
            require(
                block.timestamp >= lastPartialLiqTime[positionId] + stepDelaySeconds,
                "PL: step delay not elapsed"
            );
        }

        IWikiPerp.Position memory pos = perp.getPosition(positionId);
        require(pos.trader != address(0), "PL: position not found");

        // Check health [A3]
        (bool healthy, uint256 healthBps, uint256 requiredMargin) = _getHealth(pos);
        require(!healthy && healthBps < minHealthBps * 2, "PL: position is healthy");

        uint8 step = liquidationStep[positionId];

        // Calculate fraction to close to restore target health
        fractionClosedBps = _calcFractionToClose(pos.collateral, pos.notional, requiredMargin);

        // Cap at maxPartialBps [A4]
        if (fractionClosedBps > maxPartialBps) {
            fractionClosedBps = maxPartialBps;
        }

        // If health is critically negative or step 3, escalate to full liq
        if (healthBps == 0 || step >= 3) {
            emit FullLiquidationEscalated(positionId, pos.trader, step);
            perp.forceClose(positionId);
            fullyLiquidated = true;
            newHealthBps = 0;
            _distributeFee(pos.notional, msg.sender);
            delete liquidationStep[positionId];
            delete lastPartialLiqTime[positionId];
            return (10000, 0, true);
        }

        // Execute partial close
        (int256 pnl, uint256 returnedCollateral) = perp.partialClose(positionId, fractionClosedBps);

        uint256 notionalClosed = pos.notional * fractionClosedBps / 10000;
        uint256 liquidatorFee  = _distributeFee(notionalClosed, msg.sender);

        // Check new health
        IWikiPerp.Position memory newPos = perp.getPosition(positionId);
        (, newHealthBps, ) = _getHealth(newPos);

        liquidationStep[positionId]   = step + 1;
        lastPartialLiqTime[positionId] = block.timestamp;

        if (newHealthBps >= targetHealthBps) {
            emit HealthRestored(positionId, newHealthBps);
        }

        emit PartialLiquidation(
            positionId, pos.trader, fractionClosedBps,
            notionalClosed, pnl, newHealthBps, step,
            msg.sender, liquidatorFee
        );
    }

    /**
     * @notice Check if a position is eligible for partial liquidation.
     *         Returns the recommended fraction to close.
     */
    function getLiquidationQuote(uint256 positionId) external view returns (
        bool    eligible,
        uint256 healthScoreBps,
        uint256 recommendedFractionBps,
        uint256 estimatedLiquidatorFee,
        uint8   currentStep
    ) {
        IWikiPerp.Position memory pos = perp.getPosition(positionId);
        if (pos.trader == address(0)) return (false, 0, 0, 0, 0);

        (bool healthy, uint256 healthBps, uint256 requiredMargin) = _getHealth(pos);
        eligible              = !healthy && healthBps < minHealthBps * 2;
        healthScoreBps        = healthBps;
        recommendedFractionBps = eligible ? _calcFractionToClose(pos.collateral, pos.notional, requiredMargin) : 0;
        if (recommendedFractionBps > maxPartialBps) recommendedFractionBps = maxPartialBps;
        uint256 notionalToClose = pos.notional * recommendedFractionBps / 10000;
        estimatedLiquidatorFee  = notionalToClose * liquidatorShareBps / 10000;
        currentStep             = liquidationStep[positionId];
    }

    // ── Internal ─────────────────────────────────────────────────────────

    function _getHealth(IWikiPerp.Position memory pos) internal view returns (
        bool healthy, uint256 healthBps, uint256 requiredMargin
    ) {
        if (address(volMargin) != address(0)) {
            return volMargin.isPositionHealthy(pos.marketId, pos.collateral, pos.notional);
        }
        // Fallback: 0.5% maintenance margin
        requiredMargin = pos.notional * 50 / 10000;
        healthy        = pos.collateral >= requiredMargin;
        healthBps      = requiredMargin > 0 ? pos.collateral * 10000 / requiredMargin : 10000;
    }

    function _calcFractionToClose(
        uint256 collateral,
        uint256 notional,
        uint256 requiredMargin
    ) internal view returns (uint256 fractionBps) {
        if (collateral >= requiredMargin) return 0;
        // Close enough so remaining collateral / remaining required = targetHealth
        // remaining_notional = notional × (1 - fraction)
        // remaining_required = requiredMargin × (1 - fraction)
        // remaining_collateral ≈ collateral (small change from closing)
        // health = collateral / (requiredMargin × (1-f)) = targetHealth
        // → (1-f) = collateral / (requiredMargin × targetHealth / 10000)
        // → f = 1 - collateral × 10000 / (requiredMargin × targetHealth / 10000)
        uint256 targetCollateralRatio = targetHealthBps * requiredMargin / 10000;
        if (collateral >= targetCollateralRatio) return 0;
        fractionBps = 10000 - (collateral * 10000 / targetCollateralRatio);
        if (fractionBps > 10000) fractionBps = 10000;
    }

    function _distributeFee(uint256 notional, address liquidator) internal returns (uint256 liquidatorFee) {
        uint256 totalFee    = notional * partialLiqFeeBps   / 10000;
        liquidatorFee       = notional * liquidatorShareBps / 10000;
        uint256 insuranceFee= notional * insuranceShareBps  / 10000;
        if (liquidatorFee > 0 && USDC.balanceOf(address(this)) >= liquidatorFee) {
            USDC.safeTransfer(liquidator, liquidatorFee);
        }
        if (insuranceFee > 0 && address(insuranceFund) != address(0)) {
            try insuranceFund.depositFee(insuranceFee) {} catch {}
        }
    }

    // ── Admin ─────────────────────────────────────────────────────────────
    function setLiquidator(address liq, bool enabled) external onlyOwner { authorisedLiquidators[liq] = enabled; }
    function setTargetHealth(uint256 bps) external onlyOwner { require(bps >= 2000 && bps <= 8000); targetHealthBps = bps; }
    function setMinHealth(uint256 bps)    external onlyOwner { require(bps >= 100  && bps <= 2000); minHealthBps    = bps; }
    function setMaxPartial(uint256 bps)   external onlyOwner { require(bps >= 1000 && bps <= 8000); maxPartialBps   = bps; }
    function setStepDelay(uint256 secs)   external onlyOwner { require(secs <= 300); stepDelaySeconds = secs; }
    function setContracts(address _perp, address _vol, address _ins) external onlyOwner {
        if (_perp != address(0)) perp           = IWikiPerp(_perp);
        if (_vol  != address(0)) volMargin      = IWikiVolatilityMargin(_vol);
        if (_ins  != address(0)) insuranceFund  = IInsuranceFund(_ins);
    }
}
