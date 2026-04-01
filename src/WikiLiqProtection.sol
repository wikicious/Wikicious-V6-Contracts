// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiLiqProtection
 * @notice Subscription service — trader pays monthly fee, keeper auto-adds
 *         margin when health score drops below 15%, preventing liquidation.
 *
 * REVENUE MODEL:
 *   Basic  ($20/mo): protects up to $10K position, adds up to $500 margin
 *   Pro    ($50/mo): protects up to $100K, adds up to $5K margin
 *   Elite ($100/mo): unlimited, adds up to $50K margin, priority keeper
 *
 *   500 subscribers × avg $40/mo = $20,000/month pure recurring revenue
 *   + 0.1% fee on each auto-add (keeper earns, protocol earns)
 *
 * HOW IT WORKS:
 *   1. Trader subscribes + deposits protection reserve (e.g. $500 USDC)
 *   2. Keeper monitors health score every block
 *   3. Health drops below threshold (15%) → keeper calls autoAddMargin()
 *   4. USDC from protection reserve added to position margin
 *   5. Trader notified via WikiTelegramGateway alert
 *   6. Reserve refilled manually by trader
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiLiqProtection is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum SubTier { BASIC, PRO, ELITE }

    struct TierConfig {
        uint256 monthlyFee;      // USDC
        uint256 maxPositionUsdc; // max position size covered
        uint256 maxAddPerTx;     // max margin added in one keeper call
        uint256 healthThreshold; // trigger when health < this (BPS, 1500 = 15%)
        bool    priorityKeeper;
    }

    struct Subscription {
        address  trader;
        SubTier  tier;
        uint256  expiresAt;
        uint256  reserveBalance;  // USDC held for auto-adds
        uint256  totalAdded;      // lifetime margin auto-added
        uint256  addCount;        // number of times auto-added
        uint256  lastAddTs;
        bool     active;
        bool     paused;          // trader can pause auto-add
    }

    mapping(address => Subscription) public subs;
    mapping(SubTier => TierConfig)   public tiers;
    mapping(address => bool)         public keepers;

    address public revenueSplitter;
    uint256 public keeperFeeBps = 10; // 0.1% of amount added → keeper
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_RESERVE_REFILL = 50 * 1e6; // $50 min refill

    event Subscribed(address trader, SubTier tier, uint256 expiresAt);
    event ReserveDeposited(address trader, uint256 amount);
    event MarginAutoAdded(address trader, uint256 amount, uint256 healthBefore, uint256 healthAfter);
    event SubscriptionExpired(address trader);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
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

    constructor(address _owner, address _usdc, address _revenueSplitter) Ownable(_owner) {
        USDC            = IERC20(_usdc);
        revenueSplitter = _revenueSplitter;
        keepers[_owner] = true;
        _initTiers();
    }

    function _initTiers() internal {
        tiers[SubTier.BASIC] = TierConfig({
            monthlyFee:      20 * 1e6,
            maxPositionUsdc: 10_000 * 1e6,
            maxAddPerTx:     500 * 1e6,
            healthThreshold: 1500,
            priorityKeeper:  false
        });
        tiers[SubTier.PRO] = TierConfig({
            monthlyFee:      50 * 1e6,
            maxPositionUsdc: 100_000 * 1e6,
            maxAddPerTx:     5_000 * 1e6,
            healthThreshold: 1500,
            priorityKeeper:  false
        });
        tiers[SubTier.ELITE] = TierConfig({
            monthlyFee:      100 * 1e6,
            maxPositionUsdc: type(uint256).max,
            maxAddPerTx:     50_000 * 1e6,
            healthThreshold: 2000, // elite triggers at 20% for extra safety
            priorityKeeper:  true
        });
    }

    // ── Subscribe ─────────────────────────────────────────────────────────
    function subscribe(SubTier tier, uint256 months, uint256 reserveAmount) external nonReentrant {
        require(months >= 1 && months <= 12, "LP: 1-12 months");
        TierConfig storage cfg = tiers[tier];
        uint256 fee = cfg.monthlyFee * months;
        uint256 total = fee + reserveAmount;

        USDC.safeTransferFrom(msg.sender, address(this), total);

        // Fee to revenue
        USDC.safeTransfer(revenueSplitter, fee);

        Subscription storage s = subs[msg.sender];
        s.trader        = msg.sender;
        s.tier          = tier;
        s.expiresAt     = block.timestamp + months * 30 days;
        s.reserveBalance+= reserveAmount;
        s.active        = true;
        s.paused        = false;

        emit Subscribed(msg.sender, tier, s.expiresAt);
    }

    function renewSubscription(uint256 months) external nonReentrant {
        Subscription storage s = subs[msg.sender];
        require(s.active, "LP: not subscribed");
        TierConfig storage cfg = tiers[s.tier];
        uint256 fee = cfg.monthlyFee * months;
        USDC.safeTransferFrom(msg.sender, revenueSplitter, fee);
        s.expiresAt = (s.expiresAt > block.timestamp ? s.expiresAt : block.timestamp) + months * 30 days;
    }

    function depositReserve(uint256 amount) external nonReentrant {
        require(amount >= MIN_RESERVE_REFILL, "LP: below minimum refill");
        require(subs[msg.sender].active, "LP: not subscribed");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        subs[msg.sender].reserveBalance += amount;
        emit ReserveDeposited(msg.sender, amount);
    }

    function withdrawReserve(uint256 amount) external nonReentrant {
        Subscription storage s = subs[msg.sender];
        require(s.reserveBalance >= amount, "LP: insufficient reserve");
        s.reserveBalance -= amount;
        USDC.safeTransfer(msg.sender, amount);
    }

    function togglePause() external {
        subs[msg.sender].paused = !subs[msg.sender].paused;
    }

    // ── Keeper: auto-add margin ───────────────────────────────────────────
    function autoAddMargin(
        address trader,
        uint256 currentHealthBps,
        uint256 addAmount,           // how much margin to add
        address perpContract         // WikiPerp to call addMargin on
    ) external nonReentrant {
        require(keepers[msg.sender], "LP: not keeper");
        Subscription storage s = subs[trader];
        require(s.active && !s.paused, "LP: inactive or paused");
        require(block.timestamp <= s.expiresAt, "LP: expired");

        TierConfig storage cfg = tiers[s.tier];
        require(currentHealthBps < cfg.healthThreshold, "LP: health OK, no action needed");
        require(s.reserveBalance >= addAmount,           "LP: insufficient reserve");
        require(addAmount <= cfg.maxAddPerTx,            "LP: exceeds tier max");
        require(block.timestamp >= s.lastAddTs + 5 minutes, "LP: too soon");

        // Keeper fee
        uint256 keeperFee = addAmount * keeperFeeBps / BPS;
        uint256 netAdd    = addAmount - keeperFee;

        s.reserveBalance -= addAmount;
        s.totalAdded     += netAdd;
        s.addCount++;
        s.lastAddTs       = block.timestamp;

        // Pay keeper
        if (keeperFee > 0) USDC.safeTransfer(msg.sender, keeperFee);

        // Add margin to position (calls WikiPerp.addMargin)
        USDC.forceApprove(perpContract, netAdd);
        (bool ok,) = perpContract.call(abi.encodeWithSignature("addMarginForProtection(address,uint256)", trader, netAdd));

        emit MarginAutoAdded(trader, netAdd, currentHealthBps, 0);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getSubscription(address trader) external view returns (
        bool active, SubTier tier, uint256 expiresAt, uint256 reserve,
        uint256 daysLeft, uint256 totalAdded, bool paused
    ) {
        Subscription storage s = subs[trader];
        active    = s.active && block.timestamp <= s.expiresAt;
        tier      = s.tier;
        expiresAt = s.expiresAt;
        reserve   = s.reserveBalance;
        daysLeft  = s.expiresAt > block.timestamp ? (s.expiresAt - block.timestamp) / 1 days : 0;
        totalAdded= s.totalAdded;
        paused    = s.paused;
    }

    function getMonthlyRevenue() external view returns (uint256 annualised) {
        // Approximation for dashboard
        return 500 * tiers[SubTier.PRO].monthlyFee; // assume 500 avg PRO subscribers
    }

    function setKeeper(address k, bool on) external onlyOwner { keepers[k] = on; }
    function setKeeperFee(uint256 bps) external onlyOwner { require(bps <= 100); keeperFeeBps = bps; }
    function setTierFee(SubTier tier, uint256 fee) external onlyOwner { tiers[tier].monthlyFee = fee; }
}
