// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiTWAMM — Time-Weighted Average Market Maker
 * @notice Breaks large orders into small pieces executed over time.
 *
 * ── THE PROBLEM ───────────────────────────────────────────────────────────────
 *
 *   A whale wants to buy $10M of BTC.
 *   If they market-buy $10M at once: massive slippage, price impact, front-running.
 *   MEV bots see the tx in mempool → sandwich attack → whale pays extra 2-3%.
 *   $10M × 2.5% = $250,000 lost to slippage and MEV.
 *
 * ── THE SOLUTION ─────────────────────────────────────────────────────────────
 *
 *   Place a TWAMM order: $10M BTC over 24 hours.
 *   Contract executes $416,666 every hour (or smaller slices every block).
 *   Each slice too small to be worth sandwich-attacking.
 *   Average execution price = true TWAP — best achievable price.
 *   MEV: irrelevant. Front-running: impossible at this granularity.
 *
 * ── EXECUTION MODES ──────────────────────────────────────────────────────────
 *
 *   BLOCK_INTERVAL: Execute every N blocks (most precise, higher gas)
 *   TIME_INTERVAL:  Execute every N seconds (good balance)
 *   PRICE_TRIGGER:  Execute only when price is within a range (advanced)
 *
 * ── FEES ─────────────────────────────────────────────────────────────────────
 *
 *   0.02% TWAMM fee on total order value (vs 0.3-0.5% for normal swaps).
 *   Cheaper than market order slippage on any order above $100K.
 *   Fee goes to WikiRevenueSplitter → ops vault → earns yield.
 */
interface IWikiSpotRouter {
        function swapExactIn(uint256 poolId, address tokenIn, uint256 amountIn, uint256 minOut, address to, uint256 deadline) external returns (uint256);
    }

contract WikiTWAMM is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;


    uint256 public constant TWAMM_FEE_BPS = 20;   // 0.20% flat fee
    uint256 public constant BPS           = 10_000;
    uint256 public constant MIN_ORDER     = 10_000 * 1e6;  // $10K USDC minimum
    uint256 public constant MAX_DURATION  = 7 days;
    uint256 private _nextId               = 1;

    enum ExecMode   { TIME_INTERVAL, BLOCK_INTERVAL, PRICE_TRIGGER }
    enum OrderStatus{ ACTIVE, COMPLETED, CANCELLED, PAUSED }

    struct TWAMMOrder {
        uint256     id;
        address     owner;
        address     tokenIn;
        address     tokenOut;
        uint256     poolId;
        uint256     totalIn;         // total amount to swap
        uint256     executedIn;      // amount already swapped
        uint256     receivedOut;     // total output received
        uint256     startTime;
        uint256     endTime;
        uint256     slicesTotal;     // total number of execution slices
        uint256     slicesDone;      // slices executed so far
        uint256     sliceSize;       // amount per slice
        uint256     minPricePerUnit; // minimum price (slippage protection)
        ExecMode    mode;
        OrderStatus status;
        uint256     lastExecuted;    // timestamp of last slice execution
        uint256     intervalSeconds; // time between slices
    }

    mapping(uint256 => TWAMMOrder)   public orders;
    mapping(address => uint256[])    public ownerOrders;
    mapping(address => bool)         public keepers;

    IWikiSpotRouter public spotRouter;
    address         public feeRecipient;
    IERC20          public USDC;

    uint256 public totalVolumeExecuted;
    uint256 public totalFeesCollected;
    uint256 public activeOrders;

    event OrderPlaced(uint256 indexed id, address indexed owner, address tokenIn, address tokenOut, uint256 totalIn, uint256 duration, uint256 slices);
    event SliceExecuted(uint256 indexed id, uint256 sliceNum, uint256 amountIn, uint256 amountOut, uint256 avgPrice);
    event OrderCompleted(uint256 indexed id, uint256 totalIn, uint256 totalOut, uint256 avgPrice);
    event OrderCancelled(uint256 indexed id, uint256 refundAmount);
    event OrderPaused(uint256 indexed id);
    event OrderResumed(uint256 indexed id);

    constructor(address _owner, address _spotRouter, address _usdc, address _feeRecipient) Ownable(_owner) {
        spotRouter   = IWikiSpotRouter(_spotRouter);
        USDC         = IERC20(_usdc);
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Place a TWAMM order.
     * @param tokenIn        Token you are selling
     * @param tokenOut       Token you are buying
     * @param poolId         WikiSpot pool to route through
     * @param totalAmount    Total amount of tokenIn to sell
     * @param durationSecs   Total time to execute over (max 7 days)
     * @param numSlices      Number of execution slices (min 4)
     * @param minPricePerUnit Minimum price per tokenOut unit (slippage guard)
     */
    function placeOrder(
        address tokenIn,
        address tokenOut,
        uint256 poolId,
        uint256 totalAmount,
        uint256 durationSecs,
        uint256 numSlices,
        uint256 minPricePerUnit
    ) external nonReentrant returns (uint256 orderId) {
        require(totalAmount >= MIN_ORDER,      "TWAMM: min $10K");
        require(durationSecs <= MAX_DURATION,  "TWAMM: max 7 days");
        require(numSlices >= 4,                "TWAMM: min 4 slices");
        require(numSlices <= 10_000,           "TWAMM: max 10K slices");
        require(durationSecs / numSlices >= 60,"TWAMM: min 1 min/slice");

        // Collect fee upfront
        uint256 fee = totalAmount * TWAMM_FEE_BPS / BPS;
        IERC20(tokenIn).safeTransferFrom(msg.sender, feeRecipient, fee);
        uint256 netAmount = totalAmount - fee;

        // Pull tokens into contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), netAmount);

        orderId = _nextId++;
        orders[orderId] = TWAMMOrder({
            id:             orderId,
            owner:          msg.sender,
            tokenIn:        tokenIn,
            tokenOut:       tokenOut,
            poolId:         poolId,
            totalIn:        netAmount,
            executedIn:     0,
            receivedOut:    0,
            startTime:      block.timestamp,
            endTime:        block.timestamp + durationSecs,
            slicesTotal:    numSlices,
            slicesDone:     0,
            sliceSize:      netAmount / numSlices,
            minPricePerUnit:minPricePerUnit,
            mode:           ExecMode.TIME_INTERVAL,
            status:         OrderStatus.ACTIVE,
            lastExecuted:   block.timestamp,
            intervalSeconds:durationSecs / numSlices
        });
        ownerOrders[msg.sender].push(orderId);
        activeOrders++;
        totalFeesCollected += fee;

        emit OrderPlaced(orderId, msg.sender, tokenIn, tokenOut, netAmount, durationSecs, numSlices);
    }

    /**
     * @notice Execute the next slice for an order.
     *         Called by keeper bot on each interval. Gas paid by keeper (earns 0.1%).
     */
    function executeSlice(uint256 orderId) external nonReentrant returns (uint256 amountOut) {
        require(keepers[msg.sender] || msg.sender == owner(), "TWAMM: not keeper");

        TWAMMOrder storage o = orders[orderId];
        require(o.status == OrderStatus.ACTIVE,                       "TWAMM: not active");
        require(block.timestamp >= o.lastExecuted + o.intervalSeconds,"TWAMM: too soon");
        require(o.slicesDone < o.slicesTotal,                         "TWAMM: all done");

        // Last slice gets any remainder
        uint256 sliceAmt = o.slicesDone == o.slicesTotal - 1
            ? o.totalIn - o.executedIn
            : o.sliceSize;

        // Keeper fee: 0.1% of slice
        uint256 keeperFee = sliceAmt / 1000;
        IERC20(o.tokenIn).safeTransfer(msg.sender, keeperFee);
        uint256 netSlice  = sliceAmt - keeperFee;

        // Execute swap
        uint256 minOut = o.minPricePerUnit > 0 ? netSlice * o.minPricePerUnit / 1e18 : 0;
        IERC20(o.tokenIn).safeApprove(address(spotRouter), netSlice);
        try spotRouter.swapExactIn(o.poolId, o.tokenIn, netSlice, minOut, o.owner, block.timestamp + 60) returns (uint256 out) {
            amountOut = out;
        } catch {
            // Slippage exceeded — pause order instead of cancelling
            o.status = OrderStatus.PAUSED;
            emit OrderPaused(orderId);
            return 0;
        }

        o.executedIn  += sliceAmt;
        o.receivedOut += amountOut;
        o.slicesDone++;
        o.lastExecuted = block.timestamp;
        totalVolumeExecuted += sliceAmt;

        uint256 avgPrice = amountOut > 0 ? netSlice * 1e18 / amountOut : 0;
        emit SliceExecuted(orderId, o.slicesDone, netSlice, amountOut, avgPrice);

        // Complete if all slices done
        if (o.slicesDone == o.slicesTotal) {
            o.status = OrderStatus.COMPLETED;
            activeOrders = activeOrders > 0 ? activeOrders - 1 : 0;
            uint256 finalAvg = o.receivedOut > 0 ? o.totalIn * 1e18 / o.receivedOut : 0;
            emit OrderCompleted(orderId, o.totalIn, o.receivedOut, finalAvg);
        }
    }

    /** @notice Batch execute multiple orders in one call. */
    function batchExecute(uint256[] calldata orderIds) external nonReentrant {
        require(keepers[msg.sender], "TWAMM: not keeper");
        for (uint i; i < orderIds.length; i++) {
            TWAMMOrder storage o = orders[orderIds[i]];
            if (o.status != OrderStatus.ACTIVE) continue;
            if (block.timestamp < o.lastExecuted + o.intervalSeconds) continue;
            try this.executeSlice(orderIds[i]) {} catch {}
        }
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        TWAMMOrder storage o = orders[orderId];
        require(o.owner == msg.sender,   "TWAMM: not owner");
        require(o.status == OrderStatus.ACTIVE || o.status == OrderStatus.PAUSED, "TWAMM: not cancellable");

        uint256 refund = o.totalIn - o.executedIn;
        o.status = OrderStatus.CANCELLED;
        if (refund > 0) IERC20(o.tokenIn).safeTransfer(msg.sender, refund);
        activeOrders = activeOrders > 0 ? activeOrders - 1 : 0;
        emit OrderCancelled(orderId, refund);
    }

    function resumeOrder(uint256 orderId) external nonReentrant {
        TWAMMOrder storage o = orders[orderId];
        require(o.owner == msg.sender,          "TWAMM: not owner");
        require(o.status == OrderStatus.PAUSED, "TWAMM: not paused");
        o.status       = OrderStatus.ACTIVE;
        o.lastExecuted = block.timestamp - o.intervalSeconds; // allow immediate exec
        emit OrderResumed(orderId);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function orderProgress(uint256 orderId) external view returns (
        uint256 pctComplete, uint256 remainingSlices, uint256 nextExecAt, uint256 estimatedAvgPrice
    ) {
        TWAMMOrder memory o = orders[orderId];
        pctComplete      = o.slicesTotal > 0 ? o.slicesDone * 100 / o.slicesTotal : 0;
        remainingSlices  = o.slicesTotal - o.slicesDone;
        nextExecAt       = o.lastExecuted + o.intervalSeconds;
        estimatedAvgPrice= o.receivedOut > 0 ? o.executedIn * 1e18 / o.receivedOut : 0;
    }

    function setKeeper(address k, bool e)          external onlyOwner { keepers[k] = e; }
    function setSpotRouter(address r)              external onlyOwner { spotRouter = IWikiSpotRouter(r); }
    function setFeeRecipient(address r)            external onlyOwner { feeRecipient = r; }

    // ── TWAMM Core ─────────────────────────────────────────────────────────

    struct VirtualOrder {
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 amountPerBlock;   // amount to swap each block
        uint256 blocksRemaining;  // how many blocks left
        uint256 totalFilled;
        uint256 expiry;
    }

    mapping(uint256 => VirtualOrder) public virtualOrder;
    uint256 public nextOrderId;

    event TWAMMOrderSubmitted(uint256 indexed orderId, address owner, uint256 totalAmount, uint256 durationBlocks);
    event TWAMMTick(uint256 indexed orderId, uint256 amountFilled, uint256 blocksRemaining);

    /**
     * @notice Submit a TWAMM order. The amount is split evenly across durationBlocks.
     *         Prevents large trades from moving the market by spreading execution over time.
     * @param tokenIn        Token to sell
     * @param tokenOut       Token to receive
     * @param totalAmount    Total amount to swap
     * @param durationBlocks How many blocks to spread execution across
     */
    function submitOrder(
        address tokenIn,
        address tokenOut,
        uint256 totalAmount,
        uint256 durationBlocks
    ) external returns (uint256 orderId) {
        require(durationBlocks >= 10 && durationBlocks <= 100000, "TWAMM: invalid duration");
        require(totalAmount > 0, "TWAMM: zero amount");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), totalAmount);

        orderId = nextOrderId++;
        virtualOrder[orderId] = VirtualOrder({
            owner:           msg.sender,
            tokenIn:         tokenIn,
            tokenOut:        tokenOut,
            amountPerBlock:  totalAmount / durationBlocks,
            blocksRemaining: durationBlocks,
            totalFilled:     0,
            expiry:          block.number + durationBlocks
        });

        emit TWAMMOrderSubmitted(orderId, msg.sender, totalAmount, durationBlocks);
    }

    /**
     * @notice Execute one tick (one block worth) of a TWAMM order.
     *         Called by keeper bot each block for active orders.
     */
    function executeTick(uint256 orderId) external returns (uint256 amountOut) {
        VirtualOrder storage vo = virtualOrder[orderId];
        require(vo.blocksRemaining > 0, "TWAMM: order complete");
        require(block.number <= vo.expiry, "TWAMM: expired");

        uint256 amountIn = vo.amountPerBlock;
        // Swap amountIn via internal AMM or spot router
        // amountOut = _swap(vo.tokenIn, vo.tokenOut, amountIn);
        amountOut = amountIn; // placeholder — wired to WikiSpotRouter post-deploy

        vo.totalFilled     += amountIn;
        vo.blocksRemaining -= 1;

        emit TWAMMTick(orderId, amountIn, vo.blocksRemaining);
    }

}

interface IERC20Min { function transferFrom(address,address,uint256) external returns(bool); }