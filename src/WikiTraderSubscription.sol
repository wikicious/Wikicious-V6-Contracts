// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiTraderSubscription
 * @notice $99/month SaaS subscription for algorithmic traders.
 *         Gives access to private WebSocket feeds, historical data,
 *         priority order routing, and dedicated RPC endpoint.
 *
 * REVENUE: 500 subscribers × $99 = $49,500/month recurring
 * Pure SaaS — no marginal cost per subscriber.
 */
contract WikiTraderSubscription is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MONTHLY_FEE  = 99  * 1e6;  // $99 USDC
    uint256 public constant ANNUAL_FEE   = 990 * 1e6;  // $990 USDC (2 months free)
    uint256 public constant MONTH        = 30 days;
    uint256 public constant YEAR         = 365 days;

    enum Plan { MONTHLY, ANNUAL }

    struct Subscription {
        address subscriber;
        Plan    plan;
        uint256 expiresAt;
        uint256 totalPaid;
        bool    active;
        bytes32 apiKeyHash;  // keccak256(apiKey) — key stored off-chain
    }

    IERC20  public immutable USDC;

    mapping(address => Subscription) public subscriptions;
    address[] public subscribers;
    address public treasury;

    uint256 public totalRevenue;
    uint256 public activeCount;

    event Subscribed(address indexed user, Plan plan, uint256 expiresAt);
    event Renewed(address indexed user, Plan plan, uint256 newExpiry);
    event Cancelled(address indexed user);
    event APIKeySet(address indexed user, bytes32 keyHash);

    constructor(address _usdc, address _treasury, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC     = IERC20(_usdc);
        treasury = _treasury;
    }

    function subscribe(Plan plan, bytes32 apiKeyHash) external nonReentrant {
        require(subscriptions[msg.sender].expiresAt <= block.timestamp, "TS: already active");
        uint256 fee = plan == Plan.ANNUAL ? ANNUAL_FEE : MONTHLY_FEE;
        uint256 dur = plan == Plan.ANNUAL ? YEAR        : MONTH;

        USDC.safeTransferFrom(msg.sender, treasury, fee);
        totalRevenue += fee;

        if (!subscriptions[msg.sender].active) {
            subscribers.push(msg.sender);
            activeCount++;
        }

        subscriptions[msg.sender] = Subscription({
            subscriber: msg.sender, plan: plan,
            expiresAt: block.timestamp + dur, totalPaid: fee,
            active: true, apiKeyHash: apiKeyHash
        });

        emit Subscribed(msg.sender, plan, block.timestamp + dur);
        emit APIKeySet(msg.sender, apiKeyHash);
    }

    function renew(Plan plan) external nonReentrant {
        Subscription storage s = subscriptions[msg.sender];
        require(s.active, "TS: not subscribed");
        uint256 fee = plan == Plan.ANNUAL ? ANNUAL_FEE : MONTHLY_FEE;
        uint256 dur = plan == Plan.ANNUAL ? YEAR        : MONTH;
        USDC.safeTransferFrom(msg.sender, treasury, fee);
        totalRevenue += fee;
        s.plan       = plan;
        s.totalPaid += fee;
        s.expiresAt  = (s.expiresAt > block.timestamp ? s.expiresAt : block.timestamp) + dur;
        emit Renewed(msg.sender, plan, s.expiresAt);
    }

    function setAPIKey(bytes32 apiKeyHash) external {
        require(isActive(msg.sender), "TS: not active");
        subscriptions[msg.sender].apiKeyHash = apiKeyHash;
        emit APIKeySet(msg.sender, apiKeyHash);
    }

    function isActive(address user) public view returns (bool) {
        return subscriptions[user].active && subscriptions[user].expiresAt > block.timestamp;
    }

    function getSubscription(address user) external view returns (Subscription memory) { return subscriptions[user]; }
    function subscriberCount() external view returns (uint256) { return subscribers.length; }
    function mrr() external view returns (uint256) { return activeCount * MONTHLY_FEE; }
    function arr() external view returns (uint256) { return activeCount * MONTHLY_FEE * 12; }
}
