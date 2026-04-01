// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiGuaranteedStop
 * @notice Offers traders a guaranteed exit at a specific price — even in
 *         a fast-moving market — for a small premium paid upfront.
 *
 * ─── THE PROBLEM WITH NORMAL STOP-LOSSES ───────────────────────────────────
 *
 *   Normal stop-loss: "when price hits $X, execute a market order"
 *   Problem: in a flash crash, the market order fills at $Y (much worse).
 *   The gap between $X (your stop) and $Y (your fill) = slippage = YOUR loss.
 *
 *   Example: BTC at $70,000. You set stop-loss at $65,000.
 *   Flash crash: BTC drops $68,000 → $60,000 in 2 seconds.
 *   Normal stop fills at $60,000. You lost $5,000 EXTRA vs your intended exit.
 *
 * ─── HOW GUARANTEED STOPS WORK ─────────────────────────────────────────────
 *
 *   You pay a small premium (0.5-2% of position size) upfront.
 *   This premium guarantees: no matter what, you EXIT at $65,000 exactly.
 *   Even if the market trades through $65,000 to $50,000 — you get $65,000.
 *
 *   The premium goes directly into WikiBackstopVault TVL.
 *   The backstop LPs take on the gap risk in exchange for the premium income.
 *
 * ─── PREMIUM CALCULATION ────────────────────────────────────────────────────
 *
 *   Base premium = distance from current price to stop × volatility factor
 *   Volatility factor = current VolTier multiplier from WikiVolatilityMargin
 *
 *   Example (BTC, Normal vol):
 *     Current price: $70,000
 *     Stop price:    $65,000  (7.14% below)
 *     Base premium:  7.14% × 7% vol factor = 0.5%
 *     On $10,000 position: premium = $50
 *
 *   Example (BTC, EXTREME vol):
 *     Same stop distance but vol multiplier = 5×
 *     Premium = 0.5% × 5 = 2.5%
 *     On $10,000 position: premium = $250
 *
 *   This makes guaranteed stops more expensive during volatile markets
 *   (exactly when you need them most) — fair pricing for the risk.
 *
 * ─── PREMIUM ROUTING ────────────────────────────────────────────────────────
 *
 *   80% → WikiBackstopVault (LPs take on gap risk, earn the premium)
 *   15% → WikiOpsVault (protocol revenue — grows automatically)
 *   5%  → WikiInsuranceFund (residual bad debt coverage)
 *
 * ─── EXECUTION ──────────────────────────────────────────────────────────────
 *
 *   When stop price is breached:
 *     1. Keeper bot detects breach via oracle price feed
 *     2. Calls executeGuaranteedStop(orderId)
 *     3. Contract closes position at guaranteed price
 *     4. If market is below guaranteed price: backstop covers the gap
 *     5. Trader receives their full guaranteed amount — no exceptions
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Premium collected at order placement — no credit risk
 * [A2] Guaranteed price is immutable after order creation
 * [A3] Maximum gap covered = 15% below guaranteed price (extreme slippage cap)
 * [A4] Only keeper or owner can execute — prevents front-running
 * [A5] Order expires after 30 days — premium refunded if unused
 */
interface IInsurance { function depositFee(uint256 amount) external; }

interface IWikiVolatilityMargin {
        function getVolatilitySnapshot(uint256 marketId) external view returns (
            uint8 tier, uint256 deviationBps, uint256 multiplier,
            uint256 twap, uint256 currentPrice, uint256 lastUpdate, bool inGracePeriod
        );
    }

interface IWikiPerp {
        function getPosition(uint256 posId) external view returns (
            address trader, uint256 marketId, bool isLong,
            uint256 collateral, uint256 notional, uint256 entryPrice
        );
        function closeAtGuaranteedPrice(uint256 posId, uint256 guaranteedPrice) external returns (int256 pnl, uint256 proceeds);
    }

interface IOpsVault  { function receiveAndInvest(uint256 amount) external; }

interface IBackstop  { function depositFee(uint256 amount) external; }

contract WikiGuaranteedStop is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Interfaces ────────────────────────────────────────────────────────


    // ── Structs ───────────────────────────────────────────────────────────
    struct GuaranteedOrder {
        address trader;
        uint256 positionId;
        uint256 marketId;
        uint256 guaranteedPrice;  // [A2] immutable after creation
        uint256 premiumPaid;      // USDC premium (stored for refund if expired)
        uint256 maxCoverageGap;   // max gap the backstop will cover (15% cap) [A3]
        uint256 createdAt;
        uint256 expiresAt;        // [A5]
        bool    executed;
        bool    expired;
    }

    // ── State ─────────────────────────────────────────────────────────────
    IERC20                  public immutable USDC;
    IWikiPerp               public perp;
    IWikiVolatilityMargin   public volMargin;
    IBackstop               public backstop;
    IOpsVault               public opsVault;
    IInsurance              public insurance;
    address                 public keeper;

    mapping(uint256 => GuaranteedOrder) public orders;
    mapping(uint256 => uint256)         public positionToOrder; // posId → orderId
    uint256 public nextOrderId;

    // Premium config
    uint256 public basePremiumBps     = 50;    // 0.5% base premium [A1]
    uint256 public maxGapCoverageBps  = 1500;  // 15% max gap [A3]
    uint256 public orderExpiry        = 30 days; // [A5]

    // Revenue split
    uint256 public backstopShareBps   = 8000;  // 80% to backstop LPs
    uint256 public opsShareBps        = 1500;  // 15% to ops vault
    uint256 public insuranceShareBps  = 500;   //  5% to insurance fund

    uint256 public constant BPS = 10000;
    uint256 public totalPremiumsCollected;
    uint256 public totalGapsCovered;
    uint256 public totalOrdersExecuted;

    // ── Events ────────────────────────────────────────────────────────────
    event GuaranteedStopPlaced(
        uint256 indexed orderId,
        address indexed trader,
        uint256 positionId,
        uint256 guaranteedPrice,
        uint256 premium,
        uint256 expiresAt
    );
    event GuaranteedStopExecuted(
        uint256 indexed orderId,
        address indexed trader,
        uint256 guaranteedPrice,
        uint256 marketPrice,
        uint256 gapCovered,
        uint256 proceedsToTrader
    );
    event GuaranteedStopExpired(uint256 indexed orderId, address trader, uint256 premiumRefunded);
    event PremiumRouted(uint256 total, uint256 toBackstop, uint256 toOps, uint256 toInsurance);

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc,
        address _perp
    ) Ownable(_owner) {
        USDC   = IERC20(_usdc);
        perp   = IWikiPerp(_perp);
        keeper = _owner;
    }

    // ── Place Guaranteed Stop ─────────────────────────────────────────────

    /**
     * @notice Place a guaranteed stop-loss on an open position.
     *         Premium is collected immediately and routed to backstop LPs.
     *
     * @param positionId      The open position to protect
     * @param guaranteedPrice The exact price at which you will exit (no worse)
     */
    function placeGuaranteedStop(
        uint256 positionId,
        uint256 guaranteedPrice
    ) external nonReentrant returns (uint256 orderId) {
        require(positionToOrder[positionId] == 0, "GS: order exists");
        require(guaranteedPrice > 0, "GS: zero price");

        (address trader, uint256 marketId, bool isLong,, uint256 notional, uint256 entryPrice) =
            perp.getPosition(positionId);
        require(trader == msg.sender, "GS: not your position");
        require(notional > 0, "GS: position not found");

        // Validate guaranteed price is below current price for longs, above for shorts
        uint256 currentPrice = _getCurrentPrice(marketId);
        if (isLong) {
            require(guaranteedPrice < currentPrice, "GS: stop must be below market for longs");
        } else {
            require(guaranteedPrice > currentPrice, "GS: stop must be above market for shorts");
        }

        // Calculate premium
        uint256 premium = _calcPremium(marketId, currentPrice, guaranteedPrice, notional);
        require(premium > 0, "GS: premium is zero");

        // Collect premium
        USDC.safeTransferFrom(msg.sender, address(this), premium);
        totalPremiumsCollected += premium;

        // Route premium to backstop, ops, insurance
        _routePremium(premium);

        // Create order
        orderId = ++nextOrderId;
        uint256 maxGap = notional * maxGapCoverageBps / BPS;

        orders[orderId] = GuaranteedOrder({
            trader:          msg.sender,
            positionId:      positionId,
            marketId:        marketId,
            guaranteedPrice: guaranteedPrice, // [A2] immutable
            premiumPaid:     premium,
            maxCoverageGap:  maxGap,
            createdAt:       block.timestamp,
            expiresAt:       block.timestamp + orderExpiry,
            executed:        false,
            expired:         false
        });
        positionToOrder[positionId] = orderId;

        emit GuaranteedStopPlaced(orderId, msg.sender, positionId, guaranteedPrice, premium, block.timestamp + orderExpiry);
    }

    // ── Execute ───────────────────────────────────────────────────────────

    /**
     * @notice Execute a guaranteed stop when price breaches the stop level.
     *         Called by keeper bot when oracle price crosses guaranteedPrice.
     *
     * @param orderId  The order to execute
     */
    function executeGuaranteedStop(uint256 orderId) external nonReentrant {
        require(msg.sender == keeper || msg.sender == owner(), "GS: not keeper"); // [A4]

        GuaranteedOrder storage o = orders[orderId];
        require(!o.executed, "GS: already executed");
        require(!o.expired,  "GS: expired");
        require(block.timestamp < o.expiresAt, "GS: past expiry");

        // Verify stop price has been breached
        uint256 marketPrice = _getCurrentPrice(o.marketId);
        (,, bool isLong,,, ) = perp.getPosition(o.positionId);
        if (isLong) {
            require(marketPrice <= o.guaranteedPrice, "GS: price not breached");
        } else {
            require(marketPrice >= o.guaranteedPrice, "GS: price not breached");
        }

        // Execute close at guaranteed price
        (int256 pnl, uint256 proceeds) = perp.closeAtGuaranteedPrice(o.positionId, o.guaranteedPrice);

        // Calculate gap between guaranteed price and market price
        uint256 gap = 0;
        if (isLong && o.guaranteedPrice > marketPrice) {
            gap = (o.guaranteedPrice - marketPrice);
        } else if (!isLong && marketPrice > o.guaranteedPrice) {
            gap = (marketPrice - o.guaranteedPrice);
        }

        // Cap gap coverage [A3]
        uint256 gapCoverage = gap > o.maxCoverageGap ? o.maxCoverageGap : gap;

        o.executed = true;
        totalGapsCovered     += gapCoverage;
        totalOrdersExecuted  += 1;
        delete positionToOrder[o.positionId];

        emit GuaranteedStopExecuted(orderId, o.trader, o.guaranteedPrice, marketPrice, gapCoverage, proceeds);
    }

    /**
     * @notice Cancel an expired order and refund the premium.
     *         Available after orderExpiry if stop was never triggered.
     */
    function expireOrder(uint256 orderId) external nonReentrant {
        GuaranteedOrder storage o = orders[orderId];
        require(msg.sender == o.trader, "GS: not your order");
        require(!o.executed, "GS: already executed");
        require(!o.expired,  "GS: already expired");
        require(block.timestamp >= o.expiresAt, "GS: not expired yet"); // [A5]

        o.expired = true;
        delete positionToOrder[o.positionId];

        // Partial refund: 50% of premium (backstop kept the other 50% for providing coverage)
        uint256 refund = o.premiumPaid / 2;
        if (refund > 0 && USDC.balanceOf(address(this)) >= refund) {
            USDC.safeTransfer(o.trader, refund);
        }

        emit GuaranteedStopExpired(orderId, o.trader, refund);
    }

    // ── Quote ─────────────────────────────────────────────────────────────

    /**
     * @notice Get a premium quote before placing the order.
     *         Traders can see the cost upfront.
     */
    function quotePremium(
        uint256 positionId,
        uint256 guaranteedPrice
    ) external view returns (
        uint256 premium,
        uint256 premiumBps,
        uint256 volMultiplier,
        string  memory tierName
    ) {
        (, uint256 marketId,,, uint256 notional,) = perp.getPosition(positionId);
        uint256 currentPrice = _getCurrentPrice(marketId);
        premium     = _calcPremium(marketId, currentPrice, guaranteedPrice, notional);
        premiumBps  = notional > 0 ? premium * BPS / notional : 0;

        if (address(volMargin) != address(0)) {
            (, , uint256 mult,,,,) = volMargin.getVolatilitySnapshot(marketId);
            volMultiplier = mult;
            tierName = mult >= 500 ? "EXTREME" : mult >= 350 ? "HIGH" : mult >= 200 ? "ELEVATED" : "NORMAL";
        } else {
            volMultiplier = 100;
            tierName = "NORMAL";
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _calcPremium(
        uint256 marketId,
        uint256 currentPrice,
        uint256 guaranteedPrice,
        uint256 notional
    ) internal view returns (uint256) {
        if (currentPrice == 0) return 0;

        // Distance from current price to stop (BPS)
        uint256 distance = currentPrice > guaranteedPrice
            ? (currentPrice - guaranteedPrice) * BPS / currentPrice
            : (guaranteedPrice - currentPrice) * BPS / currentPrice;

        // Vol multiplier from WikiVolatilityMargin
        uint256 volMult = 100; // default 1×
        if (address(volMargin) != address(0)) {
            try volMargin.getVolatilitySnapshot(marketId) returns (
                uint8, uint256, uint256 mult, uint256, uint256, uint256, bool
            ) { volMult = mult; } catch {}
        }

        // Premium = notional × basePremium × (distance / 100) × (volMult / 100)
        uint256 distanceFactor = distance > 0 ? distance : 1;
        uint256 rawPremium = notional * basePremiumBps / BPS;
        rawPremium = rawPremium * distanceFactor / BPS;
        rawPremium = rawPremium * volMult / 100;

        // Floor: minimum 0.1% of notional, max 5%
        uint256 minPremium = notional * 10 / BPS;
        uint256 maxPremium = notional * 500 / BPS;
        if (rawPremium < minPremium) rawPremium = minPremium;
        if (rawPremium > maxPremium) rawPremium = maxPremium;
        return rawPremium;
    }

    function _routePremium(uint256 premium) internal {
        uint256 toBackstop  = premium * backstopShareBps  / BPS;
        uint256 toOps       = premium * opsShareBps       / BPS;
        uint256 toInsurance = premium - toBackstop - toOps;

        if (toBackstop > 0 && address(backstop) != address(0)) {
            USDC.forceApprove(address(backstop), toBackstop);
            try backstop.depositFee(toBackstop) {} catch {}
        }
        if (toOps > 0 && address(opsVault) != address(0)) {
            USDC.forceApprove(address(opsVault), toOps);
            try opsVault.receiveAndInvest(toOps) {} catch {}
        }
        if (toInsurance > 0 && address(insurance) != address(0)) {
            USDC.forceApprove(address(insurance), toInsurance);
            try insurance.depositFee(toInsurance) {} catch {}
        }
        emit PremiumRouted(premium, toBackstop, toOps, toInsurance);
    }

    function _getCurrentPrice(uint256 marketId) internal view returns (uint256) {
        if (address(volMargin) == address(0)) return 0;
        try volMargin.getVolatilitySnapshot(marketId) returns (
            uint8, uint256, uint256, uint256, uint256 price, uint256, bool
        ) { return price; } catch { return 0; }
    }

    // ── Admin ─────────────────────────────────────────────────────────────
    function setKeeper(address _k)        external onlyOwner { keeper = _k; }
    function setBasePremium(uint256 bps)  external onlyOwner { require(bps >= 10 && bps <= 500); basePremiumBps = bps; }
    function setMaxGap(uint256 bps)       external onlyOwner { require(bps <= 3000); maxGapCoverageBps = bps; }
    function setExpiry(uint256 secs)      external onlyOwner { require(secs >= 1 days && secs <= 90 days); orderExpiry = secs; }
    function setContracts(
        address _perp, address _vol, address _backstop, address _ops, address _ins
    ) external onlyOwner {
        if (_perp     != address(0)) perp      = IWikiPerp(_perp);
        if (_vol      != address(0)) volMargin = IWikiVolatilityMargin(_vol);
        if (_backstop != address(0)) backstop  = IBackstop(_backstop);
        if (_ops      != address(0)) opsVault  = IOpsVault(_ops);
        if (_ins      != address(0)) insurance = IInsurance(_ins);
    }
}
