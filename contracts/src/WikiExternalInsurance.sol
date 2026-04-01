// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiExternalInsurance
 * @notice Sell liquidation backstop coverage to external DeFi protocols.
 *         Protocols pay monthly premium; Wikicious covers their shortfalls.
 *
 * REVENUE: 0.2–0.5% of covered TVL per year
 * At $100M covered: $200K–$500K/year, near-zero marginal cost.
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiExternalInsurance is Ownable2Step, ReentrancyGuard {
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

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PREMIUM_BPS = 500; // 5% max annual

    struct Client {
        address  protocol;
        string   name;
        uint256  coveredTVL;      // USDC TVL being insured
        uint256  annualPremiumBps;// e.g. 25 = 0.25% p.a.
        uint256  subscriptionEnd;
        uint256  maxPayout;       // max single claim
        uint256  totalPremiumPaid;
        uint256  totalClaimsPaid;
        bool     active;
    }

    IERC20 public immutable USDC;

    Client[]  public clients;
    mapping(address => uint256) public protocolToClient;

    uint256 public reserveFund;
    uint256 public protocolRevenue;
    uint256 public totalCovered;

    event ClientRegistered(uint256 indexed id, address protocol, uint256 tvl, uint256 premiumBps);
    event PremiumPaid(uint256 indexed id, uint256 amount, uint256 newExpiry);
    event ClaimPaid(uint256 indexed id, address protocol, uint256 amount);
    event ReserveFunded(uint256 amount);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = router;
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

    constructor(address _usdc, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC = IERC20(_usdc);
    }

    function registerClient(
        address protocol, string calldata name,
        uint256 coveredTVL, uint256 annualPremiumBps, uint256 maxPayout
    ) external onlyOwner returns (uint256 id) {
        require(annualPremiumBps <= MAX_PREMIUM_BPS, "EI: premium too high");
        require(reserveFund >= maxPayout, "EI: insufficient reserve");
        id = clients.length;
        clients.push(Client({ protocol:protocol, name:name, coveredTVL:coveredTVL,
            annualPremiumBps:annualPremiumBps, subscriptionEnd:0, maxPayout:maxPayout,
            totalPremiumPaid:0, totalClaimsPaid:0, active:true }));
        protocolToClient[protocol] = id + 1;
        totalCovered += coveredTVL;
        emit ClientRegistered(id, protocol, coveredTVL, annualPremiumBps);
    }

    function payPremium(uint256 id) external nonReentrant {
        Client storage c = clients[id];
        require(c.active, "EI: inactive");
        uint256 monthlyPremium = c.coveredTVL * c.annualPremiumBps / BPS / 12;
        USDC.safeTransferFrom(msg.sender, address(this), monthlyPremium);
        uint256 toReserve = monthlyPremium / 2;
        reserveFund += toReserve;
        protocolRevenue += monthlyPremium - toReserve;
        c.totalPremiumPaid += monthlyPremium;
        c.subscriptionEnd = block.timestamp > c.subscriptionEnd
            ? block.timestamp + 30 days : c.subscriptionEnd + 30 days;
        emit PremiumPaid(id, monthlyPremium, c.subscriptionEnd);
    }

    function processClaim(uint256 id, uint256 amount, address recipient) external onlyOwner nonReentrant {
        Client storage c = clients[id];
        require(c.active && block.timestamp <= c.subscriptionEnd, "EI: not subscribed");
        require(amount <= c.maxPayout, "EI: exceeds max payout");
        require(reserveFund >= amount, "EI: insufficient reserve");
        reserveFund -= amount;
        c.totalClaimsPaid += amount;
        USDC.safeTransfer(recipient, amount);
        emit ClaimPaid(id, c.protocol, amount);
    }

    function fundReserve(uint256 amount) external {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        reserveFund += amount;
        emit ReserveFunded(amount);
    }

    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue;
        require(amt > 0);
        protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
    }

    function clientCount() external view returns (uint256) { return clients.length; }
    function getClient(uint256 id) external view returns (Client memory) { return clients[id]; }
    function monthlyRunRate() external view returns (uint256) {
        uint256 mrr;
        for (uint i; i < clients.length; i++) {
            if (clients[i].active && block.timestamp <= clients[i].subscriptionEnd)
                mrr += clients[i].coveredTVL * clients[i].annualPremiumBps / BPS / 12;
        }
        return mrr;
    }
}
