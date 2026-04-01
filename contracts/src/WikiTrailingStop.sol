// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiTrailingStop
 * @notice Trailing Stop-Loss + OCO (One-Cancels-the-Other) order engine.
 *
 * ── TRAILING STOP-LOSS ────────────────────────────────────────────────────────
 *
 *   A trailing stop follows the market price at a fixed % distance.
 *   It NEVER moves against the trader — only locks in more profit.
 *
 *   Example (Long BTC, 5% trail):
 *     BTC  = $60,000 → stop at $57,000
 *     BTC  = $70,000 → stop moves up to $66,500   ← locked in $6,500 profit
 *     BTC  = $66,000 → TRIGGERS → position closed at market
 *     BTC never drops 5% from the peak → position stays open forever
 *
 *   Example (Short BTC, 5% trail):
 *     BTC  = $60,000 → stop at $63,000
 *     BTC  = $50,000 → stop moves down to $52,500  ← locked in $7,500 profit
 *     BTC  = $53,000 → TRIGGERS → short covered at market
 *
 * ── OCO (ONE-CANCELS-THE-OTHER) ───────────────────────────────────────────────
 *
 *   Two orders placed simultaneously. When one fills, the other auto-cancels.
 *   Standard professional setup: Take-Profit ORDER linked to Stop-Loss ORDER.
 *   If TP hits → profit taken, SL auto-cancelled.
 *   If SL hits → loss limited, TP auto-cancelled.
 *   Without OCO: trader must manually cancel the remaining order.
 */
interface IWikiOrderBook { function cancelOrder(uint256 orderId) external; }

interface IWikiPerp    { function closePosition(address trader, uint256 marketId, uint256 size, uint256 minOut) external returns (uint256); }

interface IWikiOracle  { function getPrice(uint256 marketId) external view returns (uint256, uint256); }

contract WikiTrailingStop is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;


    // ── State ─────────────────────────────────────────────────────────────
    IWikiOracle   public oracle;
    IWikiPerp     public perp;
    IWikiOrderBook public orderBook;

    uint256 public constant MIN_TRAIL_BPS = 50;    // 0.5% minimum
    uint256 public constant MAX_TRAIL_BPS = 5000;  // 50% maximum
    uint256 public constant BPS           = 10_000;
    uint256 private _nextId               = 1;

    enum OrderStatus { ACTIVE, TRIGGERED, CANCELLED, EXPIRED }

    struct TrailingStop {
        uint256     id;
        address     trader;
        uint256     marketId;
        bool        isLong;            // long position = sell trailing stop
        uint256     positionSize;      // size to close when triggered
        uint256     trailBps;          // trail distance in BPS
        uint256     peakPrice;         // best price seen (high for long, low for short)
        uint256     currentStopPrice;  // current trigger price
        uint256     createdAt;
        uint256     expiresAt;         // 0 = no expiry
        OrderStatus status;
        uint256     ocoLinkedId;       // linked order ID for OCO (0 = standalone)
    }

    struct OCOPair {
        uint256 tpOrderId;   // take-profit order ID
        uint256 slOrderId;   // stop-loss order ID
        bool    active;
    }

    mapping(uint256 => TrailingStop) public stops;
    mapping(address => uint256[])    public traderStops;
    mapping(uint256 => OCOPair)      public ocoPairs;
    mapping(address => bool)         public keepers;

    uint256 public totalTriggered;
    uint256 public totalCancelled;

    // ── Events ─────────────────────────────────────────────────────────────
    event TrailingStopPlaced(uint256 indexed id, address indexed trader, uint256 marketId, bool isLong, uint256 trailBps, uint256 initialStop);
    event TrailingStopUpdated(uint256 indexed id, uint256 newPeak, uint256 newStop);
    event TrailingStopTriggered(uint256 indexed id, address indexed trader, uint256 triggerPrice, uint256 sizeClose);
    event TrailingStopCancelled(uint256 indexed id, address indexed trader);
    event OCOPlaced(uint256 indexed pairId, uint256 tpId, uint256 slId);
    event OCOTriggered(uint256 indexed pairId, uint256 triggeredId, uint256 cancelledId);

    constructor(address _owner, address _oracle, address _perp, address _orderBook) Ownable(_owner) {
        oracle    = IWikiOracle(_oracle);
        perp      = IWikiPerp(_perp);
        orderBook = IWikiOrderBook(_orderBook);
    }

    // ── Place trailing stop ───────────────────────────────────────────────

    /**
     * @notice Place a trailing stop on an open position.
     * @param marketId     Market to monitor (BTC=0, ETH=1, EUR/USD=100, etc.)
     * @param isLong       true = long position (stop sells), false = short (stop buys)
     * @param positionSize Size to close when triggered
     * @param trailBps     Trail distance (50 = 0.5%, 500 = 5%)
     * @param expiresIn    Seconds until expiry (0 = no expiry)
     */
    function placeTrailingStop(
        uint256 marketId,
        bool    isLong,
        uint256 positionSize,
        uint256 trailBps,
        uint256 expiresIn
    ) external nonReentrant returns (uint256 stopId) {
        require(trailBps >= MIN_TRAIL_BPS && trailBps <= MAX_TRAIL_BPS, "TS: trail 0.5-50%");
        require(positionSize > 0, "TS: zero size");

        (uint256 price,) = oracle.getPrice(marketId);
        uint256 stopPrice = _calculateStop(price, trailBps, isLong);

        stopId = _nextId++;
        stops[stopId] = TrailingStop({
            id:               stopId,
            trader:           msg.sender,
            marketId:         marketId,
            isLong:           isLong,
            positionSize:     positionSize,
            trailBps:         trailBps,
            peakPrice:        price,
            currentStopPrice: stopPrice,
            createdAt:        block.timestamp,
            expiresAt:        expiresIn > 0 ? block.timestamp + expiresIn : 0,
            status:           OrderStatus.ACTIVE,
            ocoLinkedId:      0
        });
        traderStops[msg.sender].push(stopId);

        emit TrailingStopPlaced(stopId, msg.sender, marketId, isLong, trailBps, stopPrice);
    }

    /**
     * @notice Place an OCO pair: TP order + SL trailing stop.
     *         When one triggers, the other auto-cancels.
     */
    function placeOCO(
        uint256 marketId,
        bool    isLong,
        uint256 positionSize,
        uint256 tpPrice,
        uint256 slTrailBps,
        uint256 expiresIn
    ) external nonReentrant returns (uint256 pairId, uint256 tpId, uint256 slId) {
        (uint256 price,) = oracle.getPrice(marketId);

        // Validate TP makes sense
        if (isLong) require(tpPrice > price, "TS: TP must be above market for long");
        else        require(tpPrice < price, "TS: TP must be below market for short");

        // Create trailing SL
        uint256 slStop = _calculateStop(price, slTrailBps, isLong);
        slId = _nextId++;
        stops[slId] = TrailingStop({
            id: slId, trader: msg.sender, marketId: marketId, isLong: isLong,
            positionSize: positionSize, trailBps: slTrailBps, peakPrice: price,
            currentStopPrice: slStop, createdAt: block.timestamp,
            expiresAt: expiresIn > 0 ? block.timestamp + expiresIn : 0,
            status: OrderStatus.ACTIVE, ocoLinkedId: 0
        });
        traderStops[msg.sender].push(slId);

        // Create TP order (stored as a separate trailing stop at fixed price)
        tpId = _nextId++;
        stops[tpId] = TrailingStop({
            id: tpId, trader: msg.sender, marketId: marketId, isLong: isLong,
            positionSize: positionSize, trailBps: 0, peakPrice: tpPrice,
            currentStopPrice: tpPrice, createdAt: block.timestamp,
            expiresAt: expiresIn > 0 ? block.timestamp + expiresIn : 0,
            status: OrderStatus.ACTIVE, ocoLinkedId: slId
        });
        traderStops[msg.sender].push(tpId);

        // Link them
        stops[slId].ocoLinkedId = tpId;

        pairId = _nextId++;
        ocoPairs[pairId] = OCOPair({ tpOrderId: tpId, slOrderId: slId, active: true });

        emit OCOPlaced(pairId, tpId, slId);
    }

    // ── Keeper: update trailing prices ────────────────────────────────────

    /**
     * @notice Called by keeper bot on every price update.
     *         Updates all active trailing stops for a market.
     */
    function updateMarket(uint256 marketId, uint256[] calldata stopIds) external {
        require(keepers[msg.sender] || msg.sender == owner(), "TS: not keeper");
        (uint256 price,) = oracle.getPrice(marketId);

        for (uint i; i < stopIds.length; i++) {
            TrailingStop storage s = stops[stopIds[i]];
            if (s.status != OrderStatus.ACTIVE) continue;
            if (s.marketId != marketId) continue;
            if (s.expiresAt > 0 && block.timestamp > s.expiresAt) {
                s.status = OrderStatus.EXPIRED;
                continue;
            }

            // Update peak and stop price
            if (s.trailBps > 0) {
                bool newPeak = s.isLong ? price > s.peakPrice : price < s.peakPrice;
                if (newPeak) {
                    s.peakPrice        = price;
                    s.currentStopPrice = _calculateStop(price, s.trailBps, s.isLong);
                    emit TrailingStopUpdated(s.id, price, s.currentStopPrice);
                }
            }

            // Check if triggered
            bool triggered = s.isLong
                ? price <= s.currentStopPrice   // long: stop below market
                : price >= s.currentStopPrice;  // short: stop above market

            if (triggered) _triggerStop(s, price);
        }
    }

    function _triggerStop(TrailingStop storage s, uint256 price) internal {
        s.status = OrderStatus.TRIGGERED;
        totalTriggered++;

        // Cancel OCO linked order
        if (s.ocoLinkedId > 0 && stops[s.ocoLinkedId].status == OrderStatus.ACTIVE) {
            stops[s.ocoLinkedId].status = OrderStatus.CANCELLED;
            totalCancelled++;
            emit OCOTriggered(0, s.id, s.ocoLinkedId);
        }

        // Execute close on WikiPerp
        try perp.closePosition(s.trader, s.marketId, s.positionSize, 0) {} catch {}
        emit TrailingStopTriggered(s.id, s.trader, price, s.positionSize);
    }

    function cancelStop(uint256 stopId) external nonReentrant {
        TrailingStop storage s = stops[stopId];
        require(s.trader == msg.sender || keepers[msg.sender], "TS: not owner");
        require(s.status == OrderStatus.ACTIVE, "TS: not active");
        s.status = OrderStatus.CANCELLED;
        totalCancelled++;
        emit TrailingStopCancelled(stopId, msg.sender);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getActiveStops(address trader) external view returns (uint256[] memory active) {
        uint256[] memory all = traderStops[trader];
        uint count;
        for (uint i; i < all.length; i++) if (stops[all[i]].status == OrderStatus.ACTIVE) count++;
        active = new uint256[](count);
        uint j;
        for (uint i; i < all.length; i++) if (stops[all[i]].status == OrderStatus.ACTIVE) active[j++] = all[i];
    }

    function distanceToTrigger(uint256 stopId) external view returns (uint256 distanceBps, bool willTriggerUp) {
        TrailingStop memory s = stops[stopId];
        (uint256 price,) = oracle.getPrice(s.marketId);
        if (s.isLong) {
            distanceBps    = price > s.currentStopPrice ? (price - s.currentStopPrice) * BPS / price : 0;
            willTriggerUp  = false;
        } else {
            distanceBps    = s.currentStopPrice > price ? (s.currentStopPrice - price) * BPS / price : 0;
            willTriggerUp  = true;
        }
    }

    function _calculateStop(uint256 price, uint256 trailBps, bool isLong) internal pure returns (uint256) {
        return isLong
            ? price * (BPS - trailBps) / BPS
            : price * (BPS + trailBps) / BPS;
    }

    function setKeeper(address k, bool e) external onlyOwner { keepers[k] = e; }
    function setContracts(address _oracle, address _perp, address _ob) external onlyOwner {
        if (_oracle != address(0)) oracle    = IWikiOracle(_oracle);
        if (_perp   != address(0)) perp      = IWikiPerp(_perp);
        if (_ob     != address(0)) orderBook = IWikiOrderBook(_ob);
    }

    // trailing stop parameters stored per order
    mapping(uint256 => uint256) public trailOffsetBps;  // orderId → offset in BPS
    mapping(uint256 => uint256) public trailPeak;        // orderId → highest/lowest price seen

    /**
     * @notice Keeper updates trailing stop prices as market moves.
     */
    function updateTrailingStops(uint256[] calldata orderIds, uint256[] calldata newPrices) external {
        require(msg.sender == keeper || msg.sender == owner(), "TS: not keeper");
        for (uint i; i < orderIds.length; i++) {
            uint256 oid  = orderIds[i];
            uint256 peak = trailPeak[oid];
            bool isLong  = !orders[oid].isBuy; // sell stop for longs
            if (isLong && newPrices[i] > peak) {
                trailPeak[oid]    = newPrices[i];
                uint256 offset    = trailOffsetBps[oid];
                orders[oid].price = newPrices[i] * (10000 - offset) / 10000;
            } else if (!isLong && newPrices[i] < peak) {
                trailPeak[oid]    = newPrices[i];
                uint256 offset    = trailOffsetBps[oid];
                orders[oid].price = newPrices[i] * (10000 + offset) / 10000;
            }
        }
    }

}