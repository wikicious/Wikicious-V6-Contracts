// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiKeeperService
 * @notice Keeper-as-a-Service: external DeFi protocols pay to use Wikicious's
 *         keeper network for their own liquidations, order execution, and
 *         oracle updates. Near-zero marginal cost — pure revenue.
 *
 * MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * External protocols register as clients and pay a monthly subscription
 * (in USDC) or a per-execution fee. Wikicious keepers watch client contracts
 * and execute whenever their conditions are met.
 *
 * PRICING TIERS
 * ─────────────────────────────────────────────────────────────────────────
 * BASIC     : $500/mo  — 1,000 executions/day, 1 keeper assigned
 * PRO       : $1,500/mo — 5,000 executions/day, 3 keepers, priority queue
 * ENTERPRISE: $5,000/mo — unlimited, 10 keepers, SLA guarantee, custom bots
 *
 * REVENUE SPLIT
 * ─────────────────────────────────────────────────────────────────────────
 * 70% of subscription revenue → keeper rewards (distributed via WikiStaking)
 * 30% of subscription revenue → protocol treasury
 */
contract WikiKeeperService is Ownable2Step, ReentrancyGuard {
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

    // ──────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant BPS              = 10_000;
    uint256 public constant KEEPER_SHARE_BPS = 7000; // 70% to keepers
    uint256 public constant PROTOCOL_SHARE   = 3000; // 30% to protocol

    // Monthly pricing in USDC (6 decimals)
    uint256 public constant PRICE_BASIC      = 500  * 1e6;
    uint256 public constant PRICE_PRO        = 1500 * 1e6;
    uint256 public constant PRICE_ENTERPRISE = 5000 * 1e6;

    // ──────────────────────────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────────────────────────
    enum Tier { BASIC, PRO, ENTERPRISE }

    struct Client {
        address  owner;
        string   name;
        string   website;
        Tier     tier;
        uint256  paidUntil;          // unix timestamp subscription active until
        uint256  executionsToday;    // reset daily
        uint256  lastExecutionReset;
        uint256  totalExecutions;    // all-time
        uint256  totalPaid;          // all-time USDC paid
        bool     active;
    }

    struct Execution {
        uint256  clientId;
        address  target;         // external contract called
        bytes4   selector;       // function selector executed
        address  executor;       // keeper who ran it
        uint256  gasUsed;
        bool     success;
        uint256  timestamp;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20  public immutable USDC;

    Client[]    public clients;
    Execution[] public executions;

    mapping(address => bool) public keepers;

    uint256 public keeperRewardPool;  // USDC available for keepers
    uint256 public protocolRevenue;   // USDC for treasury
    uint256 public totalRevenue;      // all-time

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event ClientRegistered(uint256 indexed clientId, address owner, string name, Tier tier);
    event SubscriptionRenewed(uint256 indexed clientId, Tier tier, uint256 paidUntil, uint256 amount);
    event ExecutionRecorded(uint256 indexed clientId, address target, address executor, bool success);
    event KeeperRewarded(address indexed keeper, uint256 amount);
    event ProtocolFeesWithdrawn(address to, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(address usdc, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Client: Register & Subscribe
    // ──────────────────────────────────────────────────────────────────

    function register(string calldata name, string calldata website, Tier tier)
        external nonReentrant returns (uint256 clientId)
    {
        uint256 price = _tierPrice(tier);
        USDC.safeTransferFrom(msg.sender, address(this), price);

        _splitRevenue(price);

        clientId = clients.length;
        clients.push(Client({
            owner:              msg.sender,
            name:               name,
            website:            website,
            tier:               tier,
            paidUntil:          block.timestamp + 30 days,
            executionsToday:    0,
            lastExecutionReset: block.timestamp,
            totalExecutions:    0,
            totalPaid:          price,
            active:             true
        }));

        emit ClientRegistered(clientId, msg.sender, name, tier);
    }

    function renewSubscription(uint256 clientId, Tier newTier) external nonReentrant {
        Client storage c = clients[clientId];
        require(c.owner == msg.sender, "KaaS: not owner");
        uint256 price = _tierPrice(newTier);
        USDC.safeTransferFrom(msg.sender, address(this), price);
        _splitRevenue(price);

        c.tier      = newTier;
        c.paidUntil = block.timestamp > c.paidUntil
            ? block.timestamp + 30 days
            : c.paidUntil + 30 days;
        c.totalPaid += price;
        c.active     = true;

        emit SubscriptionRenewed(clientId, newTier, c.paidUntil, price);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Keeper: Record Execution
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Called by Wikicious keepers after executing work for a client.
     *         Validates the client subscription is active and within limits.
     */
    function recordExecution(
        uint256 clientId,
        address target,
        bytes4  selector,
        bool    success,
        uint256 gasUsed
    ) external nonReentrant {
        require(keepers[msg.sender], "KaaS: not keeper");
        Client storage c = clients[clientId];
        require(c.active && block.timestamp <= c.paidUntil, "KaaS: subscription expired");

        // Reset daily counter
        if (block.timestamp >= c.lastExecutionReset + 1 days) {
            c.executionsToday    = 0;
            c.lastExecutionReset = block.timestamp;
        }

        uint256 dailyCap = _dailyCap(c.tier);
        require(c.executionsToday < dailyCap, "KaaS: daily limit reached");

        c.executionsToday++;
        c.totalExecutions++;

        executions.push(Execution({
            clientId:  clientId,
            target:    target,
            selector:  selector,
            executor:  msg.sender,
            gasUsed:   gasUsed,
            success:   success,
            timestamp: block.timestamp
        }));

        // Reward keeper from pool
        uint256 rewardPerExec = 100_000; // 0.1 USDC per execution
        if (keeperRewardPool >= rewardPerExec && success) {
            keeperRewardPool -= rewardPerExec;
            USDC.safeTransfer(msg.sender, rewardPerExec);
            emit KeeperRewarded(msg.sender, rewardPerExec);
        }

        emit ExecutionRecorded(clientId, target, msg.sender, success);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        keepers[keeper] = enabled;
    }

    function withdrawProtocolRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue;
        require(amt > 0, "KaaS: no revenue");
        protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
        emit ProtocolFeesWithdrawn(to, amt);
    }

    function deactivateClient(uint256 clientId) external onlyOwner {
        clients[clientId].active = false;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────────────

    function _tierPrice(Tier t) internal pure returns (uint256) {
        if (t == Tier.BASIC)      return PRICE_BASIC;
        if (t == Tier.PRO)        return PRICE_PRO;
        return PRICE_ENTERPRISE;
    }

    function _dailyCap(Tier t) internal pure returns (uint256) {
        if (t == Tier.BASIC)      return 1_000;
        if (t == Tier.PRO)        return 5_000;
        return type(uint256).max; // ENTERPRISE: unlimited
    }

    function _splitRevenue(uint256 amount) internal {
        uint256 keeperCut   = amount * KEEPER_SHARE_BPS / BPS;
        uint256 protocolCut = amount - keeperCut;
        keeperRewardPool += keeperCut;
        protocolRevenue  += protocolCut;
        totalRevenue     += amount;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getClient(uint256 clientId) external view returns (Client memory) {
        return clients[clientId];
    }

    function clientCount() external view returns (uint256) {
        return clients.length;
    }

    function isSubscriptionActive(uint256 clientId) external view returns (bool) {
        Client storage c = clients[clientId];
        return c.active && block.timestamp <= c.paidUntil;
    }

    function getRecentExecutions(uint256 limit) external view returns (Execution[] memory out) {
        uint256 len = executions.length;
        uint256 count = limit < len ? limit : len;
        out = new Execution[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = executions[len - count + i];
        }
    }

    function monthlyRunRate() external view returns (uint256) {
        // Estimate monthly revenue from active subscriptions
        uint256 total;
        for (uint256 i = 0; i < clients.length; i++) {
            Client storage c = clients[i];
            if (c.active && block.timestamp <= c.paidUntil) {
                total += _tierPrice(c.tier);
            }
        }
        return total;
    }
}
