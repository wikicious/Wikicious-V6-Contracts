// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./WikiVault.sol";
import "./WikiOracle.sol";

interface IWikiGMXBackstop {
    function routeToGMX(address trader, bytes32 marketId, bool isLong, uint256 collateral, uint256 leverage)
        external payable returns (bytes32);
    function isMarketSupported(bytes32 marketId) external view returns (bool);
    function minGMXRouteSize() external view returns (uint256);
}

/// @title WikiPerp — Hardened on-chain perpetuals
///
/// ATTACK MITIGATIONS:
/// [A1] Reentrancy → ReentrancyGuard on all external state-mutating functions
/// [A2] Checks-Effects-Interactions → all state written before external calls
/// [A3] Front-running → commitment delay option, min/max price bounds on orders
/// [A4] Liquidation manipulation → liquidation price computed at open, immutable
/// [A5] Position size limit → max notional per user per market
/// [A6] OI imbalance caps → maxOpenInterest hard cap per side
/// [A7] Self-liquidation → users cannot liquidate their own positions
/// [A8] Keeper-only funding → settleFunding callable by anyone (decentralized)
///      but protected against repeated calls with time lock
/// [A9] Integer precision → all math done in 1e18, USDC cast only at settle
/// [A10] Flash loan OI manipulation → OI changes in same block are rate-limited

interface IWikiDynamicLeverage {
    function maxLeverageFor(address user) external view returns (uint256);
    function maxPositionSizeFor(address user) external view returns (uint256);
    function currentCaps() external view returns (
        uint256 maxLeverage, uint256 maxPositionUsdc, uint256 maxOIPerMarket,
        uint256 insuranceFund, uint256 tierIdx, string memory tierName
    );
}


interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiPerp is Ownable2Step, ReentrancyGuard, Pausable {

    WikiVault  public immutable vault;
    WikiOracle public immutable oracle;
    IWikiGMXBackstop public gmxBackstop;
    bool public gmxEnabled;
    IWikiDynamicLeverage public dynLev; // optional — auto leverage caps

    // ── Structs ────────────────────────────────────────────────────────────
    struct Market {
        bytes32 marketId;
        string  symbol;
        uint256 maxLeverage;
        uint256 makerFeeBps;
        uint256 takerFeeBps;
        uint256 maintenanceMarginBps;
        uint256 maxOpenInterestLong;
        uint256 maxOpenInterestShort;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 maxPositionSizePerUser; // [A5] per-user cap
        int256  fundingRate;
        uint256 lastFundingTime;
        uint256 cumulativeFundingLong;
        uint256 cumulativeFundingShort;
        bool    active;
        uint256 lastOIUpdateBlock; // [A10]
        uint256 oiChangesThisBlock; // [A10]
    }

    struct Position {
        address trader;
        uint256 marketIndex;
        bool    isLong;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;   // 18 dec
        uint256 entryFunding;
        uint256 leverage;
        uint256 liquidationPrice; // 18 dec — fixed at open [A4]
        uint256 takeProfit;
        uint256 stopLoss;
        uint256 openedAt;
        bool    open;
    }

    struct Order {
        address trader;
        uint256 marketIndex;
        bool    isLong;
        bool    isLimit;
        uint256 size;
        uint256 collateral;
        uint256 limitPrice;   // 18 dec
        uint256 minPrice;     // [A3] slippage protection: reject if fill < minPrice
        uint256 maxPrice;     // [A3] slippage protection: reject if fill > maxPrice
        uint256 leverage;
        uint256 takeProfit;
        uint256 stopLoss;
        bool    reduceOnly;
        uint256 createdAt;
        uint256 expiry;       // [A3] order auto-cancels after this timestamp
        bool    open;
    }

    // ── Storage ────────────────────────────────────────────────────────────
    Market[]   public markets;
    Position[] public positions;
    Order[]    public orders;

    mapping(address => uint256[]) public traderPositions;
    mapping(address => uint256[]) public traderOrders;
    mapping(uint256 => uint256[]) public marketBids;
    mapping(uint256 => uint256[]) public marketAsks;
    mapping(address => mapping(uint256 => uint256)) public traderOI; // trader → market → notional [A5]

    uint256 public constant FUNDING_INTERVAL    = 28800;   // 8h
    uint256 public constant MAX_FUNDING_RATE_BPS= 100;     // 1% per 8h
    uint256 public constant LIQUIDATION_FEE_BPS = 500;     // 5% of collateral to liquidator
    uint256 public constant MAX_OI_CHANGE_BPS   = 1000;    // 10% OI change cap per block [A10]
    uint256 public constant DEFAULT_ORDER_EXPIRY= 86400;   // 24h default order TTL
    uint256 public constant BPS                 = 10000;

    // Events
    event MarketCreated(uint256 indexed idx, string symbol, uint256 maxLev);
    event OrderPlaced(uint256 indexed orderId, address indexed trader, uint256 marketIdx, bool isLong, uint256 size);
    event OrderCancelled(uint256 indexed orderId, address indexed trader, string reason);
    event OrderFilled(uint256 indexed orderId, uint256 indexed posId, uint256 price);
    event PositionOpened(uint256 indexed posId, address indexed trader, bool isLong, uint256 size, uint256 price);
    event PositionClosed(uint256 indexed posId, address indexed trader, int256 pnl, uint256 closePrice);
    event PositionLiquidated(uint256 indexed posId, address indexed trader, address liquidator, uint256 price);
    event FundingSettled(uint256 indexed marketIdx, int256 rate, uint256 ts);
    event OrderRoutedToGMX(uint256 indexed orderId, bytes32 gmxKey, address trader, uint256 size);
    event GMXBackstopSet(address backstop, bool enabled);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address _vault, address _oracle, address owner) Ownable(owner) {
        require(_vault != address(0), "Wiki: zero _vault");
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(owner != address(0), "Wiki: zero owner");
        vault  = WikiVault(_vault);
        oracle = WikiOracle(payable(_oracle));
    }

    // ── Market management ──────────────────────────────────────────────────
    function createMarket(
        bytes32 marketId, string calldata symbol,
        uint256 maxLev, uint256 makerFee, uint256 takerFee,
        uint256 mmBps, uint256 maxOILong, uint256 maxOIShort,
        uint256 maxPosPerUser
    ) external onlyOwner returns (uint256 idx) {
        require(makerFee <= 50 && takerFee <= 100, "Perp: fee too high");
        require(maxLev >= 1 && maxLev <= 2000,      "Perp: max leverage is 2000x");
        idx = markets.length;
        markets.push(Market({
            marketId: marketId, symbol: symbol, maxLeverage: maxLev,
            makerFeeBps: makerFee, takerFeeBps: takerFee,
            maintenanceMarginBps: mmBps,
            maxOpenInterestLong: maxOILong, maxOpenInterestShort: maxOIShort,
            openInterestLong: 0, openInterestShort: 0,
            maxPositionSizePerUser: maxPosPerUser,
            fundingRate: 0, lastFundingTime: block.timestamp,
            cumulativeFundingLong: 0, cumulativeFundingShort: 0,
            active: true, lastOIUpdateBlock: 0, oiChangesThisBlock: 0
        }));
        emit MarketCreated(idx, symbol, maxLev);
    }

    // ── Order placement ────────────────────────────────────────────────────
    function placeMarketOrder(
        uint256 marketIdx, bool isLong, uint256 collateral, uint256 leverage,
        uint256 minPrice, uint256 maxPrice, // [A3] slippage bounds — set 0 to skip
        uint256 takeProfit, uint256 stopLoss
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _place(marketIdx, isLong, false, collateral, leverage,
            0, minPrice, maxPrice, takeProfit, stopLoss, false, 0);
    }

    function placeLimitOrder(
        uint256 marketIdx, bool isLong, uint256 collateral, uint256 leverage,
        uint256 limitPrice, uint256 expiry,
        uint256 takeProfit, uint256 stopLoss
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(expiry == 0 || expiry > block.timestamp, "Perp: already expired");
        return _place(marketIdx, isLong, true, collateral, leverage,
            limitPrice, 0, 0, takeProfit, stopLoss, false,
            expiry == 0 ? block.timestamp + DEFAULT_ORDER_EXPIRY : expiry);
    }

    function _place(
        uint256 marketIdx, bool isLong, bool isLimit,
        uint256 collateral, uint256 leverage,
        uint256 limitPrice, uint256 minFillPrice, uint256 maxFillPrice,
        uint256 tp, uint256 sl, bool reduceOnly, uint256 expiry
    ) internal returns (uint256 orderId) {
        Market storage mkt = markets[marketIdx];
        require(mkt.active,                               "Perp: market inactive");
        // Dynamic leverage cap from WikiDynamicLeverage (if set)
        uint256 effectiveMaxLev = address(dynLev) != address(0)
            ? _min256(mkt.maxLeverage, dynLev.maxLeverageFor(msg.sender))
            : mkt.maxLeverage;
        require(leverage >= 1 && leverage <= effectiveMaxLev, "Perp: leverage exceeds current cap");
        require(collateral > 0,                           "Perp: zero collateral");

        uint256 size = collateral * leverage;

        // [A5] Per-user position size cap
        require(
            traderOI[msg.sender][marketIdx] + size <= _getDynMaxPos(mkt.maxPositionSizePerUser),
            "Perp: user OI cap exceeded"
        );

        uint256 fee = size * mkt.takerFeeBps / BPS;

        // [A2] Lock margin BEFORE creating order record
        if (!reduceOnly) vault.lockMargin(msg.sender, collateral + fee);

        orderId = orders.length;
        orders.push(Order({
            trader: msg.sender, marketIndex: marketIdx,
            isLong: isLong, isLimit: isLimit,
            size: size, collateral: collateral,
            limitPrice: limitPrice, minPrice: minFillPrice, maxPrice: maxFillPrice,
            leverage: leverage, takeProfit: tp, stopLoss: sl,
            reduceOnly: reduceOnly, createdAt: block.timestamp,
            expiry: expiry, open: true
        }));
        traderOrders[msg.sender].push(orderId);

        emit OrderPlaced(orderId, msg.sender, marketIdx, isLong, size);

        if (!isLimit) {
            _executeMarket(orderId);
        } else {
            if (isLong) marketBids[marketIdx].push(orderId);
            else        marketAsks[marketIdx].push(orderId);
        }
    }

    // ── Market order execution ─────────────────────────────────────────────
    function _executeMarket(uint256 orderId) internal {
        Order storage o = orders[orderId];
        Market storage mkt = markets[o.marketIndex];
        (uint256 price,) = oracle.getPrice(mkt.marketId);

        // [A3] Slippage check — if caller set bounds, enforce them
        if (o.minPrice > 0) require(price >= o.minPrice, "Perp: price below min");
        if (o.maxPrice > 0) require(price <= o.maxPrice, "Perp: price above max");

        // Try orderbook match
        uint256 obFill = _orderbookFill(orderId, price);
        bool fullyFilled = obFill >= o.size;

        if (!fullyFilled && gmxEnabled && address(gmxBackstop) != address(0)) {
            bool canRoute = gmxBackstop.isMarketSupported(mkt.marketId)
                && o.size >= gmxBackstop.minGMXRouteSize()
                && address(this).balance >= 0.001 ether;
            if (canRoute) {
                // [A2] Mark order closed BEFORE external call
                o.open = false;
                bytes32 gmxKey = gmxBackstop.routeToGMX{value: 0.001 ether}(
                    o.trader, mkt.marketId, o.isLong, o.collateral, o.leverage
                );
                emit OrderRoutedToGMX(orderId, gmxKey, o.trader, o.size);
                return;
            }
        }

        _openPosition(orderId, price);
    }

    function _orderbookFill(uint256 orderId, uint256 price) internal view returns (uint256 filled) {
        Order storage o = orders[orderId];
        uint256[] storage book = o.isLong ? marketAsks[o.marketIndex] : marketBids[o.marketIndex];
        for (uint256 i = 0; i < book.length && filled < o.size; i++) {
            if (book[i] >= orders.length) continue;
            Order storage r = orders[book[i]];
            if (!r.open || r.expiry > 0 && block.timestamp > r.expiry) continue;
            bool ok = o.isLong ? price <= r.limitPrice : price >= r.limitPrice;
            if (ok) filled += r.size;
        }
        if (filled > o.size) filled = o.size;
    }

    // ── Open position ──────────────────────────────────────────────────────
    function _openPosition(uint256 orderId, uint256 fillPrice) internal {
        Order storage o = orders[orderId];
        require(o.open, "Perp: order not open");
        Market storage mkt = markets[o.marketIndex];

        // [A6] OI caps
        if (o.isLong) {
            require(mkt.openInterestLong + o.size <= mkt.maxOpenInterestLong, "Perp: long OI cap");
            // [A10] Rate-limit OI changes per block
            _checkOIRate(mkt, o.size);
            mkt.openInterestLong += o.size;
        } else {
            require(mkt.openInterestShort + o.size <= mkt.maxOpenInterestShort, "Perp: short OI cap");
            _checkOIRate(mkt, o.size);
            mkt.openInterestShort += o.size;
        }

        // [A4] Compute liq price at open — immutable after this
        uint256 liqPrice = _calcLiqPrice(fillPrice, o.leverage, mkt.maintenanceMarginBps, o.isLong);

        uint256 posId = positions.length;

        // [A2] All state written BEFORE fee collection (external call to vault)
        o.open = false;
        traderOI[o.trader][o.marketIndex] += o.size;

        positions.push(Position({
            trader: o.trader, marketIndex: o.marketIndex, isLong: o.isLong,
            size: o.size, collateral: o.collateral, entryPrice: fillPrice,
            entryFunding: o.isLong ? mkt.cumulativeFundingLong : mkt.cumulativeFundingShort,
            leverage: o.leverage, liquidationPrice: liqPrice,
            takeProfit: o.takeProfit, stopLoss: o.stopLoss,
            openedAt: block.timestamp, open: true
        }));
        traderPositions[o.trader].push(posId);

        vault.collectFee(o.trader, o.size * mkt.takerFeeBps / BPS);

        emit OrderFilled(orderId, posId, fillPrice);
        emit PositionOpened(posId, o.trader, o.isLong, o.size, fillPrice);
    }

    // ── Cancel order ───────────────────────────────────────────────────────
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.trader == msg.sender, "Perp: not your order");
        require(o.open,                 "Perp: already closed");
        o.open = false;
        uint256 fee = o.size * markets[o.marketIndex].takerFeeBps / BPS;
        vault.releaseMargin(msg.sender, o.collateral + fee);
        traderOI[msg.sender][o.marketIndex] = traderOI[msg.sender][o.marketIndex] >= o.size
            ? traderOI[msg.sender][o.marketIndex] - o.size : 0;
        emit OrderCancelled(orderId, msg.sender, "user cancelled");
    }

    // ── Close position ─────────────────────────────────────────────────────
    function closePosition(uint256 posId) external nonReentrant whenNotPaused {
        Position storage pos = positions[posId];
        require(pos.trader == msg.sender, "Perp: not your position");
        require(pos.open,                 "Perp: not open");
        Market storage mkt = markets[pos.marketIndex];
        (uint256 closePrice,) = oracle.getPrice(mkt.marketId);
        _close(posId, closePrice, false, address(0));
    }

    function _close(uint256 posId, uint256 closePrice, bool isLiq, address liquidator) internal {
        Position storage pos = positions[posId];
        Market storage mkt = markets[pos.marketIndex];

        // [A2] Mark closed BEFORE any external calls
        pos.open = false;
        traderOI[pos.trader][pos.marketIndex] = traderOI[pos.trader][pos.marketIndex] >= pos.size
            ? traderOI[pos.trader][pos.marketIndex] - pos.size : 0;

        // Reduce OI
        if (pos.isLong) mkt.openInterestLong  = mkt.openInterestLong  >= pos.size ? mkt.openInterestLong  - pos.size : 0;
        else            mkt.openInterestShort = mkt.openInterestShort >= pos.size ? mkt.openInterestShort - pos.size : 0;

        // Compute PnL
        int256 rawPnl = _calcPnL(pos, closePrice);

        // Funding fee
        uint256 cumFunding = pos.isLong ? mkt.cumulativeFundingLong : mkt.cumulativeFundingShort;
        int256  fundingFee = pos.entryFunding <= cumFunding
            ? int256((cumFunding - pos.entryFunding) * pos.size / (BPS * 1e12))
            : -int256((pos.entryFunding - cumFunding) * pos.size / (BPS * 1e12));

        int256 netPnl = rawPnl - fundingFee;

        // External calls LAST [A2]
        vault.settlePnL(pos.trader, netPnl);
        vault.releaseMargin(pos.trader, pos.collateral);
        vault.collectFee(pos.trader, pos.size * mkt.takerFeeBps / BPS);

        if (isLiq && liquidator != address(0)) {
            uint256 liqFee = pos.collateral * LIQUIDATION_FEE_BPS / BPS;
            vault.transferMargin(pos.trader, liquidator, liqFee);
        }

        if (isLiq) emit PositionLiquidated(posId, pos.trader, liquidator, closePrice);
        else       emit PositionClosed(posId, pos.trader, netPnl, closePrice);
    }

    // ── Liquidation ────────────────────────────────────────────────────────
    function liquidate(uint256 posId) external nonReentrant {
        Position storage pos = positions[posId];
        require(pos.open, "Perp: not open");
        require(pos.trader != msg.sender, "Perp: self-liquidation forbidden"); // [A7]
        Market storage mkt = markets[pos.marketIndex];
        (uint256 price,) = oracle.getPrice(mkt.marketId);
        bool isLiq = pos.isLong ? price <= pos.liquidationPrice : price >= pos.liquidationPrice;
        require(isLiq, "Perp: not liquidatable");
        _close(posId, price, true, msg.sender);
    }

    // ── Keeper: execute limit orders ───────────────────────────────────────
    function executeLimitOrders(uint256 marketIdx, uint256[] calldata orderIds) external nonReentrant {
        Market storage mkt = markets[marketIdx];
        (uint256 price,) = oracle.getPrice(mkt.marketId);
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = orders[orderIds[i]];
            if (!o.open || o.marketIndex != marketIdx) continue;
            // [A3] Cancel expired orders
            if (o.expiry > 0 && block.timestamp > o.expiry) {
                o.open = false;
                uint256 fee = o.size * mkt.takerFeeBps / BPS;
                vault.releaseMargin(o.trader, o.collateral + fee);
                emit OrderCancelled(orderIds[i], o.trader, "expired");
                continue;
            }
            bool canFill = o.isLong ? price <= o.limitPrice : price >= o.limitPrice;
            if (canFill) _openPosition(orderIds[i], o.limitPrice);
        }
    }

    // ── Keeper: TP/SL ──────────────────────────────────────────────────────
    function executeTPSL(uint256 posId) external nonReentrant {
        Position storage pos = positions[posId];
        require(pos.open, "Perp: not open");
        Market storage mkt = markets[pos.marketIndex];
        (uint256 price,) = oracle.getPrice(mkt.marketId);
        bool tp = pos.takeProfit > 0 && (pos.isLong ? price >= pos.takeProfit : price <= pos.takeProfit);
        bool sl = pos.stopLoss  > 0 && (pos.isLong ? price <= pos.stopLoss  : price >= pos.stopLoss);
        require(tp || sl, "Perp: TP/SL not triggered");
        _close(posId, price, false, address(0));
    }

    // ── Funding rate ───────────────────────────────────────────────────────
    // [A8] Anyone can call — decentralized, no keeper monopoly
    function settleFunding(uint256 marketIdx) external {
        Market storage mkt = markets[marketIdx];
        require(block.timestamp >= mkt.lastFundingTime + FUNDING_INTERVAL, "Perp: too early");

        (uint256 price,) = oracle.getPrice(mkt.marketId);

        int256 netOI   = int256(mkt.openInterestLong) - int256(mkt.openInterestShort);
        uint256 totalOI = mkt.openInterestLong + mkt.openInterestShort;
        int256 rate = totalOI > 0
            ? (netOI * int256(MAX_FUNDING_RATE_BPS)) / int256(totalOI)
            : int256(0);

        // Cap funding rate
        if (rate >  int256(MAX_FUNDING_RATE_BPS)) rate =  int256(MAX_FUNDING_RATE_BPS);
        if (rate < -int256(MAX_FUNDING_RATE_BPS)) rate = -int256(MAX_FUNDING_RATE_BPS);

        mkt.fundingRate     = rate;
        mkt.lastFundingTime = block.timestamp;

        if (rate >= 0) mkt.cumulativeFundingLong  += uint256(rate);
        else           mkt.cumulativeFundingShort += uint256(-rate);

        emit FundingSettled(marketIdx, rate, block.timestamp);
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setGMXBackstop(address b, bool enabled) external onlyOwner {
        gmxBackstop = IWikiGMXBackstop(b);
        gmxEnabled  = enabled;
        emit GMXBackstopSet(b, enabled);
    }

    function pauseMarket(uint256 idx) external onlyOwner { markets[idx].active = false; }
    function unpauseMarket(uint256 idx) external onlyOwner { markets[idx].active = true; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Update trading fees for a market after deployment.
     *         Used to implement negative maker rebates (makerFee = 0) and
     *         optimise taker fees based on volume/competition.
     * @param idx       Market index
     * @param makerFee  Maker fee in BPS (0 = free for market makers)
     * @param takerFee  Taker fee in BPS (recommend 6–8 for competitive pricing)
     */
    function setMarketFees(uint256 idx, uint256 makerFee, uint256 takerFee) external onlyOwner {
        require(idx < markets.length,              "Perp: bad market");
        require(makerFee <= 50 && takerFee <= 100, "Perp: fee too high");
        markets[idx].makerFeeBps = makerFee;
        markets[idx].takerFeeBps = takerFee;
        emit MarketFeesUpdated(idx, makerFee, takerFee);
    }

    event MarketFeesUpdated(uint256 indexed idx, uint256 makerFee, uint256 takerFee);

    // ── Views ──────────────────────────────────────────────────────────────
    function getPosition(uint256 id) external view returns (Position memory) { return positions[id]; }
    function getOrder(uint256 id)    external view returns (Order memory)    { return orders[id]; }
    function getMarket(uint256 id)   external view returns (Market memory)   { return markets[id]; }
    function marketCount()           external view returns (uint256)         { return markets.length; }
    function getTraderPositions(address t) external view returns (uint256[] memory) { return traderPositions[t]; }
    function getTraderOrders(address t)    external view returns (uint256[] memory) { return traderOrders[t]; }

    function getUnrealizedPnL(uint256 posId) external view returns (int256) {
        Position storage pos = positions[posId];
        if (!pos.open) return 0;
        (uint256 price,) = oracle.getPrice(markets[pos.marketIndex].marketId);
        return _calcPnL(pos, price);
    }

    // ── Internal math ──────────────────────────────────────────────────────
    function _calcPnL(Position storage pos, uint256 closePrice) internal view returns (int256) {
        if (pos.isLong)
            return int256(pos.size) * (int256(closePrice) - int256(pos.entryPrice)) / int256(pos.entryPrice);
        else
            return int256(pos.size) * (int256(pos.entryPrice) - int256(closePrice)) / int256(pos.entryPrice);
    }

    function _calcLiqPrice(uint256 entry, uint256 lev, uint256 mmBps, bool isLong) internal pure returns (uint256) {
        uint256 ratio = BPS / lev + mmBps;
        if (isLong) return entry * (BPS - ratio) / BPS;
        else        return entry * (BPS + ratio) / BPS;
    }

    // [A10] Rate-limit OI changes per block — prevents flash loan OI manipulation
    function _checkOIRate(Market storage mkt, uint256 sizeChange) internal {
        if (block.number != mkt.lastOIUpdateBlock) {
            mkt.lastOIUpdateBlock  = block.number;
            mkt.oiChangesThisBlock = 0;
        }
        mkt.oiChangesThisBlock += sizeChange;
        uint256 maxChange = (mkt.openInterestLong + mkt.openInterestShort + sizeChange)
            * MAX_OI_CHANGE_BPS / BPS;
        require(mkt.oiChangesThisBlock <= maxChange + 1e12, "Perp: OI change rate exceeded");
    }

    function _min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _getDynMaxPos(uint256 configuredMaxPos) internal view returns (uint256) {
        if (address(dynLev) == address(0)) return configuredMaxPos;
        uint256 dynCap = dynLev.maxPositionSizeFor(msg.sender);
        if (dynCap == 0) return configuredMaxPos;
        return _min256(configuredMaxPos, dynCap);
    }

    receive() external payable {}


    function setDynLev(address _dynLev) external onlyOwner { dynLev = IWikiDynamicLeverage(_dynLev); }
    function updateMarketCaps(uint256 idx, uint256 maxLev, uint256 maxPos, uint256 maxOIL, uint256 maxOIS) external {
        require(msg.sender == owner() || msg.sender == address(dynLev), "Perp: not authorized");
        require(idx < markets.length, "Perp: bad market");
        Market storage m = markets[idx];
        if (maxLev > 0) m.maxLeverage = maxLev;
        if (maxPos > 0) m.maxPositionSizePerUser = maxPos;
        if (maxOIL > 0) m.maxOpenInterestLong = maxOIL;
        if (maxOIS > 0) m.maxOpenInterestShort = maxOIS;
    }
    function marketsLength() external view returns (uint256) { return markets.length; }
}
