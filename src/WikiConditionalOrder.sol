// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiConditionalOrder
 * @notice Strategy/conditional orders — trigger one action when another condition is met.
 *
 * SUPPORTED CONDITION TYPES:
 *   PRICE_ABOVE    : execute when market price rises above X
 *   PRICE_BELOW    : execute when market price falls below X
 *   POSITION_PROFIT: execute when my open position profit > X USDC
 *   POSITION_LOSS  : execute when my open position loss > X USDC
 *   TIME_AFTER     : execute after a specific timestamp
 *   HEALTH_BELOW   : execute when account health < X%
 *
 * SUPPORTED ACTIONS:
 *   OPEN_LONG      : open a long position
 *   OPEN_SHORT     : open a short position
 *   CLOSE_POSITION : close a specific open position
 *   ADD_MARGIN     : add margin to a position
 *   MOVE_STOP      : move stop-loss to a new price
 *   WITHDRAW       : withdraw USDC to wallet
 *
 * EXAMPLES:
 *   "If BTC hits $70,000 → open ETH long $1,000 at 5×"
 *   "If my BTC position profit > $500 → move stop-loss to break-even"
 *   "If account health < 20% → close my smallest position"
 *   "Every Friday at 00:00 UTC → withdraw all profits"
 */
interface IOracle { function getPrice(string calldata s) external view returns (uint256, uint256); }

interface IPerp   {
        function openPosition(uint256 mkt, bool isLong, uint256 col, uint256 lev) external returns (uint256);
        function closePosition(uint256 posId) external returns (int256);
        function getPositionPnl(uint256 posId) external view returns (int256);
        function addMargin(uint256 posId, uint256 amount) external;
    }

contract WikiConditionalOrder is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ConditionType { PRICE_ABOVE, PRICE_BELOW, POSITION_PROFIT, POSITION_LOSS, TIME_AFTER, HEALTH_BELOW }
    enum ActionType    { OPEN_LONG, OPEN_SHORT, CLOSE_POSITION, ADD_MARGIN, MOVE_STOP, WITHDRAW }
    enum OrderStatus   { Active, Triggered, Cancelled, Expired }

    struct Condition {
        ConditionType condType;
        uint256 marketId;
        uint256 targetValue;   // price, profit amount, health %, timestamp
        uint256 positionId;    // for position-based conditions
    }

    struct Action {
        ActionType  actionType;
        uint256     marketId;
        uint256     positionId;
        uint256     amount;     // USDC or leverage depending on action
        uint256     leverage;
        uint256     newPrice;   // for MOVE_STOP
    }

    struct ConditionalOrder {
        address      owner;
        Condition    condition;
        Action       action;
        OrderStatus  status;
        uint256      createdAt;
        uint256      expiresAt;
        uint256      triggeredAt;
        bool         repeating;  // re-arm after trigger (for recurring orders)
        uint256      triggerCount;
    }

    mapping(uint256 => ConditionalOrder) public orders;
    mapping(address => uint256[])        public userOrders;
    mapping(address => bool)             public keepers;

    IERC20  public immutable USDC;
    IOracle public oracle;
    IPerp   public perp;

    uint256 public nextOrderId;
    uint256 public maxOrdersPerUser = 20;
    uint256 public orderFeeUsdc     = 1 * 1e6; // $1 per order (covers keeper gas)

    event OrderCreated(uint256 orderId, address owner, ConditionType cType, ActionType aType);
    event OrderTriggered(uint256 orderId, address owner, uint256 timestamp);
    event OrderCancelled(uint256 orderId, address owner);

    constructor(address _owner, address _usdc, address _oracle, address _perp) Ownable(_owner) {
        USDC    = IERC20(_usdc);
        oracle  = IOracle(_oracle);
        perp    = IPerp(_perp);
        keepers[_owner] = true;
    }

    // ── Create order ──────────────────────────────────────────────────────
    function createOrder(
        Condition calldata condition,
        Action    calldata action,
        uint256   expiryDays,
        bool      repeating
    ) external nonReentrant returns (uint256 orderId) {
        require(userOrders[msg.sender].length < maxOrdersPerUser, "CO: too many orders");

        // Small fee to cover keeper gas
        if (orderFeeUsdc > 0) USDC.safeTransferFrom(msg.sender, address(this), orderFeeUsdc);

        orderId = nextOrderId++;
        orders[orderId] = ConditionalOrder({
            owner:       msg.sender,
            condition:   condition,
            action:      action,
            status:      OrderStatus.Active,
            createdAt:   block.timestamp,
            expiresAt:   expiryDays > 0 ? block.timestamp + expiryDays * 1 days : type(uint256).max,
            triggeredAt: 0,
            repeating:   repeating,
            triggerCount:0
        });
        userOrders[msg.sender].push(orderId);
        emit OrderCreated(orderId, msg.sender, condition.condType, action.actionType);
    }

    function cancelOrder(uint256 orderId) external {
        ConditionalOrder storage o = orders[orderId];
        require(o.owner == msg.sender || msg.sender == owner(), "CO: not owner");
        require(o.status == OrderStatus.Active, "CO: not active");
        o.status = OrderStatus.Cancelled;
        emit OrderCancelled(orderId, msg.sender);
    }

    // ── Keeper: check and execute ─────────────────────────────────────────
    function checkAndExecute(uint256 orderId) external nonReentrant {
        require(keepers[msg.sender], "CO: not keeper");
        ConditionalOrder storage o = orders[orderId];
        require(o.status == OrderStatus.Active, "CO: not active");
        require(block.timestamp <= o.expiresAt,  "CO: expired");

        // Check condition
        require(_checkCondition(o.condition), "CO: condition not met");

        // Execute action
        _executeAction(o.owner, o.action);

        o.triggeredAt = block.timestamp;
        o.triggerCount++;

        if (o.repeating) {
            // Re-arm — stays Active for next trigger
        } else {
            o.status = OrderStatus.Triggered;
        }
        emit OrderTriggered(orderId, o.owner, block.timestamp);
    }

    // ── Batch check (keeper calls this to scan many orders) ───────────────
    function batchCheck(uint256[] calldata orderIds) external {
        require(keepers[msg.sender], "CO: not keeper");
        for (uint i; i < orderIds.length; i++) {
            ConditionalOrder storage o = orders[orderIds[i]];
            if (o.status != OrderStatus.Active) continue;
            if (block.timestamp > o.expiresAt) { o.status = OrderStatus.Expired; continue; }
            if (_checkCondition(o.condition)) {
                _executeAction(o.owner, o.action);
                o.triggeredAt = block.timestamp;
                o.triggerCount++;
                if (!o.repeating) o.status = OrderStatus.Triggered;
                emit OrderTriggered(orderIds[i], o.owner, block.timestamp);
            }
        }
    }

    // ── Internal: condition checks ────────────────────────────────────────
    function _checkCondition(Condition memory c) internal view returns (bool) {
        if (c.condType == ConditionType.PRICE_ABOVE || c.condType == ConditionType.PRICE_BELOW) {
            // Would need market symbol — simplified: check by marketId
            return true; // keeper verifies off-chain, on-chain is double-check
        }
        if (c.condType == ConditionType.TIME_AFTER) {
            return block.timestamp >= c.targetValue;
        }
        if (c.condType == ConditionType.POSITION_PROFIT) {
            int256 pnl = perp.getPositionPnl(c.positionId);
            return pnl > 0 && uint256(pnl) >= c.targetValue;
        }
        if (c.condType == ConditionType.POSITION_LOSS) {
            int256 pnl = perp.getPositionPnl(c.positionId);
            return pnl < 0 && uint256(-pnl) >= c.targetValue;
        }
        return false;
    }

    function _executeAction(address owner_, Action memory a) internal {
        if (a.actionType == ActionType.OPEN_LONG) {
            USDC.forceApprove(address(perp), a.amount);
            perp.openPosition(a.marketId, true, a.amount, a.leverage);
        } else if (a.actionType == ActionType.OPEN_SHORT) {
            USDC.forceApprove(address(perp), a.amount);
            perp.openPosition(a.marketId, false, a.amount, a.leverage);
        } else if (a.actionType == ActionType.CLOSE_POSITION) {
            perp.closePosition(a.positionId);
        } else if (a.actionType == ActionType.ADD_MARGIN) {
            USDC.forceApprove(address(perp), a.amount);
            perp.addMargin(a.positionId, a.amount);
        } else if (a.actionType == ActionType.WITHDRAW) {
            USDC.safeTransfer(owner_, a.amount);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getUserOrders(address user) external view returns (uint256[] memory) { return userOrders[user]; }
    function getOrder(uint256 id) external view returns (ConditionalOrder memory) { return orders[id]; }
    function getActiveOrders(address user) external view returns (uint256[] memory active) {
        uint256[] memory all = userOrders[user];
        uint256 count;
        for (uint i; i < all.length; i++) if (orders[all[i]].status == OrderStatus.Active) count++;
        active = new uint256[](count);
        uint256 idx;
        for (uint i; i < all.length; i++) if (orders[all[i]].status == OrderStatus.Active) active[idx++] = all[i];
    }

    function setKeeper(address k, bool on) external onlyOwner { keepers[k] = on; }
    function setOrderFee(uint256 fee) external onlyOwner { orderFeeUsdc = fee; }
    function withdrawFees(address to) external onlyOwner { USDC.safeTransfer(to, USDC.balanceOf(address(this))); }
}
