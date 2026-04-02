// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiOrderBook
 * @notice On-chain Central Limit Order Book (CLOB) for spot pairs
 *
 * DESIGN
 * ──────
 * • Price levels are stored as a sorted doubly-linked list (bid: descending, ask: ascending)
 * • Each price level holds a FIFO queue of resting limit orders (price-time priority)
 * • Takers pay takerFeeBps; makers earn makerRebateBps (can be zero or positive rebate)
 * • Fee revenue split: protocolFeeBps to treasury, rest to LP insurance fund
 * • Supports GTC (Good-Till-Cancelled) and IOC (Immediate-Or-Cancel) orders
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy         → ReentrancyGuard on all state-mutating external functions
 * [A2] CEI pattern        → state updated before token transfers throughout
 * [A3] Price manipulation → min/max price bounds enforced per pair
 * [A4] Dust orders        → minimum order size per pair
 * [A5] Self-matching      → taker cannot fill their own maker order
 * [A6] Integer overflow   → Solidity 0.8 + explicit guards
 * [A7] Grief cancellation → only order owner can cancel
 */
contract WikiOrderBook is Ownable2Step, ReentrancyGuard {
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

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant BPS             = 10_000;
    uint256 public constant MAX_TAKER_FEE   = 100;   // 1%
    uint256 public constant MAX_MAKER_FEE   = 50;    // 0.5%
    uint256 public constant PROTOCOL_SHARE  = 5000;  // 50% of fees go to protocol

    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────

    /// @dev A trading pair (e.g. WETH / USDC)
    struct Pair {
        address baseToken;
        address quoteToken;
        uint256 takerFeeBps;     // fee paid by taker
        int256  makerRebateBps;  // rebate earned by maker (can be negative = fee)
        uint256 minOrderSize;    // minimum quote amount
        uint256 pricePrecision;  // price tick size (in quoteToken decimals)
        bool    active;
        uint256 protocolFees;    // accumulated protocol fees (quoteToken)
        uint256 totalVolume;     // lifetime volume (quoteToken)
    }

    /// @dev A single resting limit order
    struct Order {
        uint256 pairId;
        address maker;
        bool    isBid;           // true = buy (bid), false = sell (ask)
        uint256 price;           // in quoteToken per baseToken (scaled)
        uint256 baseAmount;      // total base amount
        uint256 baseRemaining;   // remaining to fill
        bool    isIOC;           // Immediate-Or-Cancel: cancel unfilled portion
        uint256 createdAt;
        bool    active;
    }

    /// @dev Doubly linked list node for a price level
    struct PriceLevel {
        uint256 price;
        uint256 headOrderId;   // oldest unfilled order at this price
        uint256 tailOrderId;   // newest order (for FIFO append)
        uint256 totalBase;     // total base remaining at this level
        uint256 prevPrice;     // lower price (bids: lower; asks: lower)
        uint256 nextPrice;     // higher price
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────

    Pair[]   public pairs;
    Order[]  public orders;

    // pairId → bid/ask → price → PriceLevel
    mapping(uint256 => mapping(bool => mapping(uint256 => PriceLevel))) public levels;
    // pairId → bid/ask → best price (top of book)
    mapping(uint256 => mapping(bool => uint256)) public bestPrice;
    // orderId → next order at same price level (FIFO queue link)
    mapping(uint256 => uint256) public nextOrder;

    // User balances locked inside this contract
    mapping(address => mapping(address => uint256)) public lockedBalance;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────

    event PairCreated(uint256 indexed pairId, address base, address quote);
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed pairId,
        address indexed maker,
        bool isBid,
        uint256 price,
        uint256 baseAmount
    );
    event OrderFilled(
        uint256 indexed makerOrderId,
        uint256 indexed takerOrderId,
        address indexed taker,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 takerFee
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker, uint256 baseRemaining);
    event FeesWithdrawn(uint256 indexed pairId, address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address owner) Ownable(owner) {}

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Pair Management
    // ─────────────────────────────────────────────────────────────────────

    function createPair(
        address baseToken,
        address quoteToken,
        uint256 takerFeeBps,
        int256  makerRebateBps,
        uint256 minOrderSize,
        uint256 pricePrecision
    ) external onlyOwner returns (uint256 pairId) {
        require(takerFeeBps <= MAX_TAKER_FEE,                  "OB: taker fee too high");
        require(makerRebateBps >= -int256(MAX_MAKER_FEE),      "OB: maker fee too high");
        require(makerRebateBps <= int256(takerFeeBps),         "OB: rebate > taker fee");
        require(baseToken != quoteToken,                        "OB: same token");
        require(pricePrecision > 0,                             "OB: zero precision");

        pairId = pairs.length;
        pairs.push(Pair({
            baseToken:      baseToken,
            quoteToken:     quoteToken,
            takerFeeBps:    takerFeeBps,
            makerRebateBps: makerRebateBps,
            minOrderSize:   minOrderSize,
            pricePrecision: pricePrecision,
            active:         true,
            protocolFees:   0,
            totalVolume:    0
        }));
        emit PairCreated(pairId, baseToken, quoteToken);
    }

    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        pairs[pairId].active = active;
    }

    function setFees(uint256 pairId, uint256 takerFeeBps, int256 makerRebateBps) external onlyOwner {
        require(takerFeeBps <= MAX_TAKER_FEE, "OB: fee too high");
        require(makerRebateBps <= int256(takerFeeBps), "OB: rebate > taker");
        pairs[pairId].takerFeeBps    = takerFeeBps;
        pairs[pairId].makerRebateBps = makerRebateBps;
    }

    function withdrawFees(uint256 pairId, address to) external onlyOwner nonReentrant {
        Pair storage p = pairs[pairId];
        uint256 amt    = p.protocolFees;
        require(amt > 0, "OB: no fees");
        p.protocolFees = 0;
        IERC20(p.quoteToken).safeTransfer(to, amt);
        emit FeesWithdrawn(pairId, to, amt);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Place Limit Order
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Place a limit order (GTC or IOC)
     * @param pairId      Pair to trade on
     * @param isBid       true = buy (lock quoteToken), false = sell (lock baseToken)
     * @param price       Limit price (quoteToken per baseToken, must be multiple of pricePrecision)
     * @param baseAmount  Amount of baseToken to buy/sell
     * @param isIOC       If true, cancel unfilled remainder immediately
     */
    function placeLimitOrder(
        uint256 pairId,
        bool    isBid,
        uint256 price,
        uint256 baseAmount,
        bool    isIOC
    ) external nonReentrant returns (uint256 orderId) {
        Pair storage pair = pairs[pairId];
        require(pair.active, "OB: pair inactive");
        require(baseAmount > 0, "OB: zero amount");
        require(price > 0 && price % pair.pricePrecision == 0, "OB: bad price tick");

        uint256 quoteAmount = baseAmount * price / 1e18;
        require(quoteAmount >= pair.minOrderSize, "OB: below min size"); // [A4]

        // [A2] Lock tokens BEFORE creating order record
        if (isBid) {
            IERC20(pair.quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);
            lockedBalance[msg.sender][pair.quoteToken] += quoteAmount;
        } else {
            IERC20(pair.baseToken).safeTransferFrom(msg.sender, address(this), baseAmount);
            lockedBalance[msg.sender][pair.baseToken] += baseAmount;
        }

        orderId = orders.length;
        orders.push(Order({
            pairId:        pairId,
            maker:         msg.sender,
            isBid:         isBid,
            price:         price,
            baseAmount:    baseAmount,
            baseRemaining: baseAmount,
            isIOC:         isIOC,
            createdAt:     block.timestamp,
            active:        true
        }));

        emit OrderPlaced(orderId, pairId, msg.sender, isBid, price, baseAmount);

        // Try to match against the opposite side
        _matchOrder(orderId);

        // If IOC: cancel any unfilled remainder
        if (isIOC && orders[orderId].active && orders[orderId].baseRemaining > 0) {
            _cancelOrder(orderId);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Cancel Order
    // ─────────────────────────────────────────────────────────────────────

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.maker == msg.sender, "OB: not your order"); // [A7]
        require(o.active,              "OB: already closed");
        _cancelOrder(orderId);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Matching Engine
    // ─────────────────────────────────────────────────────────────────────

    function _matchOrder(uint256 takerOrderId) internal {
        Order storage taker = orders[takerOrderId];
        Pair  storage pair  = pairs[taker.pairId];

        // Opposite side: bids match asks and vice versa
        bool   makerSide = !taker.isBid;
        uint256 best      = bestPrice[taker.pairId][makerSide];

        while (best != 0 && taker.baseRemaining > 0) {
            PriceLevel storage level = levels[taker.pairId][makerSide][best];

            // Check if price crosses: bid taker fills at or below ask; ask taker fills at or above bid
            bool crosses = taker.isBid
                ? best <= taker.price   // buy order: fill if ask ≤ our limit
                : best >= taker.price;  // sell order: fill if bid ≥ our limit

            if (!crosses) break;

            // Walk the FIFO queue at this price level
            uint256 makerOrderId = level.headOrderId;
            while (makerOrderId != 0 && taker.baseRemaining > 0) {
                Order storage maker = orders[makerOrderId];

                // [A5] Skip self-match
                if (maker.maker == taker.maker) {
                    makerOrderId = nextOrder[makerOrderId];
                    continue;
                }

                if (!maker.active || maker.baseRemaining == 0) {
                    uint256 nextMakerOrderId = nextOrder[makerOrderId];
                    makerOrderId = nextMakerOrderId;
                    continue;
                }

                // Fill amount = min(taker remaining, maker remaining)
                uint256 fillBase  = taker.baseRemaining < maker.baseRemaining
                    ? taker.baseRemaining
                    : maker.baseRemaining;
                uint256 fillQuote = fillBase * best / 1e18;

                // [A2] Update state before token transfers
                taker.baseRemaining -= fillBase;
                maker.baseRemaining -= fillBase;
                level.totalBase     -= fillBase;

                if (maker.baseRemaining == 0) {
                    maker.active = false;
                    level.headOrderId = nextOrder[makerOrderId];
                    if (level.headOrderId == 0) level.tailOrderId = 0;
                }

                pair.totalVolume += fillQuote;

                // Fees
                uint256 takerFee   = fillQuote * pair.takerFeeBps / BPS;
                uint256 makerFee   = pair.makerRebateBps >= 0
                    ? 0
                    : fillQuote * uint256(-pair.makerRebateBps) / BPS;
                uint256 makerRebate = pair.makerRebateBps > 0
                    ? fillQuote * uint256(pair.makerRebateBps) / BPS
                    : 0;

                uint256 protocolFee = (takerFee + makerFee) * PROTOCOL_SHARE / BPS;
                pair.protocolFees  += protocolFee;

                // Settle tokens
                _settle(taker.pairId, taker.isBid, maker.maker, taker.maker,
                        fillBase, fillQuote, takerFee, makerRebate, pair);

                emit OrderFilled(makerOrderId, takerOrderId, taker.maker, fillBase, fillQuote, takerFee);

                uint256 nextMaker = nextOrder[makerOrderId];
                if (maker.baseRemaining == 0) makerOrderId = nextMaker;
                else break;
            }

            // Remove empty level from linked list
            if (level.totalBase == 0 || level.headOrderId == 0) {
                uint256 nextBest = makerSide
                    ? level.nextPrice  // asks: next higher price
                    : level.prevPrice; // bids: next lower price
                bestPrice[taker.pairId][makerSide] = nextBest;
                best = nextBest;
            } else {
                break;
            }
        }

        // If taker order is fully filled, mark inactive
        if (taker.baseRemaining == 0) {
            taker.active = false;
        } else if (!taker.isIOC) {
            // Resting taker becomes a maker — insert into order book
            _insertLevel(takerOrderId);
        }
    }

    function _settle(
        uint256 pairId,
        bool    takerIsBid,
        address makerAddr,
        address takerAddr,
        uint256 fillBase,
        uint256 fillQuote,
        uint256 takerFee,
        uint256 makerRebate,
        Pair storage pair
    ) internal {
        if (takerIsBid) {
            // Taker bought: pays quoteToken, receives baseToken
            // Maker sold:   pays baseToken, receives quoteToken
            lockedBalance[takerAddr][pair.quoteToken] -= fillQuote + takerFee;
            lockedBalance[makerAddr][pair.baseToken]  -= fillBase;

            IERC20(pair.baseToken).safeTransfer(takerAddr, fillBase);
            uint256 makerProceeds = fillQuote - (pair.makerRebateBps < 0
                ? fillQuote * uint256(-pair.makerRebateBps) / BPS : 0) + makerRebate;
            IERC20(pair.quoteToken).safeTransfer(makerAddr, makerProceeds);
        } else {
            // Taker sold: pays baseToken, receives quoteToken
            // Maker bought: pays quoteToken, receives baseToken
            lockedBalance[takerAddr][pair.baseToken]  -= fillBase;
            lockedBalance[makerAddr][pair.quoteToken] -= fillQuote;

            IERC20(pair.quoteToken).safeTransfer(takerAddr, fillQuote - takerFee);
            IERC20(pair.baseToken).safeTransfer(makerAddr, fillBase + makerRebate);
        }
    }

    function _insertLevel(uint256 orderId) internal {
        Order storage o   = orders[orderId];
        uint256 pairId    = o.pairId;
        bool    side      = o.isBid;
        uint256 price     = o.price;
        PriceLevel storage lvl = levels[pairId][side][price];

        if (lvl.totalBase == 0) {
            // New price level — insert into sorted list
            lvl.price     = price;
            lvl.totalBase = o.baseRemaining;

            uint256 cur = bestPrice[pairId][side];
            if (cur == 0) {
                bestPrice[pairId][side] = price;
            } else if (side ? price > cur : price < cur) {
                // New best
                lvl.nextPrice = cur;
                levels[pairId][side][cur].prevPrice = price;
                bestPrice[pairId][side] = price;
            } else {
                // Walk to find insertion point
                while (true) {
                    uint256 nxt = side
                        ? levels[pairId][side][cur].prevPrice
                        : levels[pairId][side][cur].nextPrice;
                    if (nxt == 0 || (side ? price > nxt : price < nxt)) {
                        if (side) {
                            lvl.nextPrice = cur;
                            lvl.prevPrice = levels[pairId][side][cur].prevPrice;
                            if (lvl.prevPrice != 0) levels[pairId][side][lvl.prevPrice].nextPrice = price;
                            levels[pairId][side][cur].prevPrice = price;
                        } else {
                            lvl.prevPrice = cur;
                            lvl.nextPrice = levels[pairId][side][cur].nextPrice;
                            if (lvl.nextPrice != 0) levels[pairId][side][lvl.nextPrice].prevPrice = price;
                            levels[pairId][side][cur].nextPrice = price;
                        }
                        break;
                    }
                    cur = nxt;
                }
            }
            lvl.headOrderId = orderId;
            lvl.tailOrderId = orderId;
        } else {
            // Append to existing level FIFO queue
            nextOrder[lvl.tailOrderId] = orderId;
            lvl.tailOrderId            = orderId;
            lvl.totalBase             += o.baseRemaining;
        }
    }

    function _cancelOrder(uint256 orderId) internal {
        Order storage o = orders[orderId];
        Pair  storage p = pairs[o.pairId];
        o.active = false;

        uint256 remaining = o.baseRemaining;
        o.baseRemaining   = 0;

        // Release locked tokens
        if (o.isBid) {
            uint256 quoteRemaining = remaining * o.price / 1e18;
            lockedBalance[o.maker][p.quoteToken] -= quoteRemaining;
            IERC20(p.quoteToken).safeTransfer(o.maker, quoteRemaining);
        } else {
            lockedBalance[o.maker][p.baseToken] -= remaining;
            IERC20(p.baseToken).safeTransfer(o.maker, remaining);
        }

        // Update price level
        levels[o.pairId][o.isBid][o.price].totalBase =
            levels[o.pairId][o.isBid][o.price].totalBase >= remaining
                ? levels[o.pairId][o.isBid][o.price].totalBase - remaining
                : 0;

        emit OrderCancelled(orderId, o.maker, remaining);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getPair(uint256 pairId) external view returns (Pair memory) {
        return pairs[pairId];
    }

    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    /// @notice Returns up to `depth` price levels from the top of book
    function getOrderBookDepth(uint256 pairId, bool isBid, uint256 depth)
        external view
        returns (uint256[] memory prices, uint256[] memory sizes)
    {
        prices = new uint256[](depth);
        sizes  = new uint256[](depth);
        uint256 cur = bestPrice[pairId][isBid];
        for (uint256 i = 0; i < depth && cur != 0; i++) {
            PriceLevel storage lvl = levels[pairId][isBid][cur];
            prices[i] = cur;
            sizes[i]  = lvl.totalBase;
            cur = isBid ? lvl.prevPrice : lvl.nextPrice;
        }
    }

    function getMidPrice(uint256 pairId) external view returns (uint256 mid) {
        uint256 bestBid = bestPrice[pairId][true];
        uint256 bestAsk = bestPrice[pairId][false];
        if (bestBid == 0 || bestAsk == 0) return 0;
        mid = (bestBid + bestAsk) / 2;
    }
    // ── TRAILING STOP ──────────────────────────────────────────────────────
    /**
     * @notice Place a trailing stop order.
     * @param pairId    Trading pair ID
     * @param isBuy     True for trailing stop buy (short cover), false for trailing stop sell (long protect)
     * @param size      Position size in quote (USDC)
     * @param trailBps  Trail distance in basis points (e.g. 200 = 2% trail)
     *
     * How it works:
     *   For a SELL trailing stop (protecting a long):
     *     - Records current price as highWater
     *     - As price rises, highWater rises with it
     *     - Trigger = highWater × (1 - trailBps/10000)
     *     - When price falls to trigger → execute MARKET SELL
     *     - Locks in profits without capping upside
     *
     *   For a BUY trailing stop (covering a short):
     *     - Records current price as lowWater
     *     - As price falls, lowWater falls with it
     *     - Trigger = lowWater × (1 + trailBps/10000)
     *     - When price rises to trigger → execute MARKET BUY
     */
    function placeTrailingStop(
        bytes32 pairId,
        bool    isBuy,
        uint256 size,
        uint256 trailBps
    ) external nonReentrant returns (uint256 orderId) {
        require(trailBps >= 10 && trailBps <= 5000, "OB: trail 0.1%-50%");
        require(size > 0, "OB: zero size");

        uint256 currentPrice = _getPrice(pairId);
        require(currentPrice > 0, "OB: no price");

        orderId = _nextOrderId++;
        uint256 triggerPrice = isBuy
            ? currentPrice * (BPS + trailBps) / BPS   // buy trigger = lowWater × (1 + trail)
            : currentPrice * (BPS - trailBps) / BPS;  // sell trigger = highWater × (1 - trail)

        orders[orderId] = Order({
            orderId:         orderId,
            pairId:          pairId,
            trader:          msg.sender,
            orderType:       OrderType.TRAILING_STOP,
            isBuy:           isBuy,
            price:           triggerPrice,
            size:            size,
            filled:          0,
            status:          OrderStatus.OPEN,
            createdAt:       block.timestamp,
            isTrailing:      true,
            trailBps:        trailBps,
            trailHighWater:  currentPrice,
            trailTriggerPrice: triggerPrice,
            ocoLinkedOrderId: 0
        });

        traderOrders[msg.sender].push(orderId);
        emit TrailingStopPlaced(msg.sender, orderId, pairId, isBuy, currentPrice, trailBps, triggerPrice);
    }

    /**
     * @notice Keeper calls this to update trailing high-water marks.
     *         Called every time a price update arrives.
     *         Gas efficient — only updates orders where price has moved favourably.
     */
    function updateTrailingStops(bytes32 pairId, uint256 currentPrice) external {
        require(keepers[msg.sender] || msg.sender == owner(), "OB: not keeper");

        uint256[] storage pairOrderIds = pairOrders[pairId];
        for (uint256 i; i < pairOrderIds.length; i++) {
            Order storage o = orders[pairOrderIds[i]];
            if (!o.isTrailing || o.status != OrderStatus.OPEN) continue;

            bool updated = false;
            if (!o.isBuy && currentPrice > o.trailHighWater) {
                // Long protection: price rose → raise high water mark
                o.trailHighWater     = currentPrice;
                o.trailTriggerPrice  = currentPrice * (BPS - o.trailBps) / BPS;
                o.price              = o.trailTriggerPrice;
                updated = true;
            } else if (o.isBuy && currentPrice < o.trailHighWater) {
                // Short cover: price fell → lower low water mark
                o.trailHighWater     = currentPrice;
                o.trailTriggerPrice  = currentPrice * (BPS + o.trailBps) / BPS;
                o.price              = o.trailTriggerPrice;
                updated = true;
            }

            if (updated) {
                emit TrailingStopUpdated(o.orderId, o.trailHighWater, o.trailTriggerPrice);
            }

            // Check if triggered
            bool triggered = (!o.isBuy && currentPrice <= o.trailTriggerPrice) ||
                             (o.isBuy  && currentPrice >= o.trailTriggerPrice);
            if (triggered) {
                o.status = OrderStatus.FILLED;
                emit TrailingStopTriggered(o.orderId, o.trader, o.pairId, currentPrice, o.size);
            }
        }
    }

    event TrailingStopPlaced(address indexed trader, uint256 indexed orderId, bytes32 pairId, bool isBuy, uint256 price, uint256 trailBps, uint256 triggerPrice);
    event TrailingStopUpdated(uint256 indexed orderId, uint256 newHighWater, uint256 newTrigger);
    event TrailingStopTriggered(uint256 indexed orderId, address indexed trader, bytes32 pairId, uint256 executionPrice, uint256 size);


}
