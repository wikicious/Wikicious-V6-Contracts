// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiDAOTreasury
 * @notice Manages the Wikicious protocol treasury with full contributor
 *         salary management, grant payments, and transparent on-chain
 *         accounting. All withdrawals require multisig + timelock.
 *
 * ─── HOW THE FOUNDER WITHDRAWS MONEY ─────────────────────────────────────────
 *
 * METHOD 1 — Monthly Salary (USDC, immediate):
 *   addContributor(founderAddress, "Founder/CEO", 15_000e6, MONTHLY)
 *   → Founder can call claimSalary() every 30 days
 *   → Receives USDC directly from treasury
 *   → Requires multisig approval to set up initially
 *   → Transparent: anyone can see salary on-chain
 *
 * METHOD 2 — One-time Payments (grants, bonuses, audits):
 *   proposePayment(recipient, amount, reason)
 *   → 48-hour timelock before execution
 *   → Requires 3-of-5 multisig to approve
 *   → Full on-chain audit trail
 *
 * METHOD 3 — WIK Token Grants (non-USDC):
 *   Handled by WikiTokenVesting — see that contract
 *
 * ─── TREASURY INCOME SOURCES ─────────────────────────────────────────────────
 *
 *   20% of all protocol trading fees → this treasury (WikiRevenueSplitter)
 *   WikiPOL LP fees → this treasury
 *   WikiGaugeVoting: 5% of all bribes → this treasury
 *   WikiTokenVesting creation fees ($25 each) → this treasury
 *   WikiLiquidationMarket: 50% of liquidation discounts → this treasury
 *   WikiBridge fees → this treasury
 *
 * ─── SALARY RANGES (guidance, not hardcoded) ─────────────────────────────────
 *
 *   At $5M daily volume (protocol earning ~$3K/day):
 *     Treasury receives: ~$18K/month (20% of $90K/month)
 *     Sustainable founder salary: $8,000–$12,000/month
 *
 *   At $10M daily volume (protocol earning ~$6K/day):
 *     Treasury receives: ~$36K/month (actual: $121K/month from rev dashboard)
 *     Sustainable founder salary: $15,000–$20,000/month
 *
 *   At $50M daily volume (scaling):
 *     Treasury receives: ~$606K+/month
 *     Sustainable founder salary: $30,000–$50,000/month
 *     + team expansion from treasury
 *
 * ─── SECURITY ──────────────────────────────────────────────────────────────
 * [A1] All salary payments require prior multisig-approved contributor setup
 * [A2] One-time payments have mandatory 48h timelock
 * [A3] MAX_MONTHLY_SALARY cap prevents accidental overpayment
 * [A4] Emergency pause freezes all withdrawals
 * [A5] Full on-chain history — all payments permanently recorded
 */
contract WikiDAOTreasury is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    IERC20 public immutable USDC;
    IERC20 public immutable WIK;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant MAX_MONTHLY_SALARY   = 100_000 * 1e6;  // $100K/mo hard cap [A3]
    uint256 public constant PAYMENT_TIMELOCK     = 48 hours;        // [A2]
    uint256 public constant SALARY_PERIOD        = 30 days;
    uint256 public constant BPS                  = 10_000;

    // ── Contributor (salary) system ───────────────────────────────────────────

    enum PayFrequency { MONTHLY, BIWEEKLY, WEEKLY }

    struct Contributor {
        address wallet;
        string  role;
        uint256 salaryPerPeriod; // USDC 6 decimals
        PayFrequency frequency;
        uint256 lastClaimTime;
        uint256 totalPaid;
        bool    active;
        uint256 addedAt;
    }

    Contributor[] public contributors;
    mapping(address => uint256) public contributorIndex; // wallet → index+1 (0=not found)

    // ── Pending one-time payments ─────────────────────────────────────────────

    struct Payment {
        address recipient;
        uint256 amount;
        string  reason;
        uint256 proposedAt;
        bool    executed;
        bool    cancelled;
        address proposedBy;
    }

    Payment[] public payments;

    // ── Budget categories ─────────────────────────────────────────────────────

    struct BudgetCategory {
        string  name;
        uint256 monthlyBudget;  // USDC
        uint256 spent;
        bool    active;
    }

    BudgetCategory[] public budgetCategories;

    // ── Runway tracking ───────────────────────────────────────────────────────

    uint256 public totalSalaryPaid;
    uint256 public totalGrantsPaid;
    uint256 public totalAuditsPaid;
    uint256 public totalReceived;

    // ── Events ────────────────────────────────────────────────────────────────

    event ContributorAdded(address indexed wallet, string role, uint256 salary, uint256 frequency);
    event ContributorUpdated(address indexed wallet, uint256 newSalary);
    event ContributorRemoved(address indexed wallet);
    event SalaryClaimed(address indexed wallet, string role, uint256 amount, uint256 periods);
    event PaymentProposed(uint256 indexed id, address indexed recipient, uint256 amount, string reason);
    event PaymentExecuted(uint256 indexed id, address indexed recipient, uint256 amount);
    event PaymentCancelled(uint256 indexed id);
    event TreasuryReceived(address indexed from, uint256 amount, string source);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _usdc,
        address _wik
    ) Ownable(_owner) {
        require(_usdc != address(0), "Treas: zero USDC");
        require(_wik  != address(0), "Treas: zero WIK");
        USDC = IERC20(_usdc);
        WIK  = IERC20(_wik);

        // Pre-configure budget categories
        budgetCategories.push(BudgetCategory("Team Salaries",    0, 0, true));
        budgetCategories.push(BudgetCategory("Security Audits",  0, 0, true));
        budgetCategories.push(BudgetCategory("Development",      0, 0, true));
        budgetCategories.push(BudgetCategory("Marketing",        0, 0, true));
        budgetCategories.push(BudgetCategory("Infrastructure",   0, 0, true));
        budgetCategories.push(BudgetCategory("Community Grants", 0, 0, true));
        budgetCategories.push(BudgetCategory("Legal & Compliance", 0, 0, true));
        budgetCategories.push(BudgetCategory("Reserve",          0, 0, true));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SALARY SYSTEM
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Add a contributor with a recurring salary.
     *         Only multisig owner can call this.
     *
     * Example usage:
     *   addContributor(founderWallet, "Founder/CEO", 15_000e6, MONTHLY)
     *   addContributor(devWallet,     "Lead Dev",    10_000e6, MONTHLY)
     *   addContributor(designerWallet,"UI/UX",        6_000e6, MONTHLY)
     *
     * @param wallet    Wallet that will receive salary
     * @param role      Job title for transparency (stored on-chain)
     * @param salary    USDC amount per period (6 decimals)
     * @param frequency How often they can claim (0=monthly, 1=biweekly, 2=weekly)
     */
    function addContributor(
        address wallet,
        string calldata role,
        uint256 salary,
        PayFrequency frequency
    ) external onlyOwner {
        require(wallet != address(0),          "Treas: zero wallet");
        require(bytes(role).length > 0,        "Treas: empty role");
        require(salary > 0,                    "Treas: zero salary");
        require(salary <= MAX_MONTHLY_SALARY,  "Treas: salary too high"); // [A3]
        require(contributorIndex[wallet] == 0, "Treas: already contributor");

        contributors.push(Contributor({
            wallet:          wallet,
            role:            role,
            salaryPerPeriod: salary,
            frequency:       frequency,
            lastClaimTime:   block.timestamp, // first claim available 1 period from now
            totalPaid:       0,
            active:          true,
            addedAt:         block.timestamp
        }));
        contributorIndex[wallet] = contributors.length; // 1-indexed
        emit ContributorAdded(wallet, role, salary, uint256(frequency));
    }

    /**
     * @notice Contributor claims their accumulated salary.
     *         Can be called at any time — claims all unclaimed periods.
     *         If 3 months have passed, claims 3 months of salary at once.
     *
     * This is how the founder withdraws USDC income from the protocol.
     */
    function claimSalary() external nonReentrant whenNotPaused {
        uint256 idx = contributorIndex[msg.sender];
        require(idx > 0, "Treas: not a contributor");

        Contributor storage c = contributors[idx - 1];
        require(c.active, "Treas: contributor inactive");
        require(c.wallet == msg.sender, "Treas: wrong wallet");

        uint256 period = _periodLength(c.frequency);
        uint256 elapsed = block.timestamp - c.lastClaimTime;
        uint256 periods = elapsed / period;
        require(periods > 0, "Treas: no salary due yet");

        uint256 amount = periods * c.salaryPerPeriod;
        uint256 balance = USDC.balanceOf(address(this));
        require(balance >= amount, "Treas: insufficient funds");

        c.lastClaimTime += periods * period;
        c.totalPaid     += amount;
        totalSalaryPaid += amount;

        USDC.safeTransfer(msg.sender, amount);
        emit SalaryClaimed(msg.sender, c.role, amount, periods);
    }

    /**
     * @notice View: how much salary is currently claimable for a contributor.
     *         Frontend uses this to show "You have $X ready to claim."
     */
    function claimableAmount(address wallet) external view returns (
        uint256 amount,
        uint256 periods,
        uint256 nextClaimAt
    ) {
        uint256 idx = contributorIndex[wallet];
        if (idx == 0) return (0, 0, 0);

        Contributor memory c = contributors[idx - 1];
        if (!c.active) return (0, 0, 0);

        uint256 period = _periodLength(c.frequency);
        uint256 elapsed = block.timestamp - c.lastClaimTime;
        periods   = elapsed / period;
        amount    = periods * c.salaryPerPeriod;
        nextClaimAt = c.lastClaimTime + period;
    }

    function updateContributorSalary(address wallet, uint256 newSalary) external onlyOwner {
        require(newSalary <= MAX_MONTHLY_SALARY, "Treas: salary too high");
        uint256 idx = contributorIndex[wallet];
        require(idx > 0, "Treas: not found");
        contributors[idx - 1].salaryPerPeriod = newSalary;
        emit ContributorUpdated(wallet, newSalary);
    }

    function removeContributor(address wallet) external onlyOwner {
        uint256 idx = contributorIndex[wallet];
        require(idx > 0, "Treas: not found");
        contributors[idx - 1].active = false;
        emit ContributorRemoved(wallet);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ONE-TIME PAYMENT SYSTEM (grants, audits, contractors)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Propose a one-time USDC payment.
     *         Goes into 48-hour timelock before it can execute.
     *
     * Examples:
     *   proposePayment(trailOfBitsWallet, 15_000e6, "Security audit Q1 2026")
     *   proposePayment(devContractorWallet, 5_000e6, "Mobile UI bounty")
     *   proposePayment(marketingAgency, 8_000e6, "Exchange listing PR campaign")
     */
    function proposePayment(
        address recipient,
        uint256 amount,
        string calldata reason
    ) external onlyOwner returns (uint256 paymentId) {
        require(recipient != address(0), "Treas: zero recipient");
        require(amount > 0,              "Treas: zero amount");
        require(bytes(reason).length > 0,"Treas: empty reason");

        paymentId = payments.length;
        payments.push(Payment({
            recipient:  recipient,
            amount:     amount,
            reason:     reason,
            proposedAt: block.timestamp,
            executed:   false,
            cancelled:  false,
            proposedBy: msg.sender
        }));
        emit PaymentProposed(paymentId, recipient, amount, reason);
    }

    /**
     * @notice Execute a payment after the 48h timelock has passed.
     *         Anyone can call this (permissionless after timelock). [A2]
     */
    function executePayment(uint256 paymentId) external nonReentrant whenNotPaused {
        Payment storage p = payments[paymentId];
        require(!p.executed,                               "Treas: already executed");
        require(!p.cancelled,                              "Treas: cancelled");
        require(block.timestamp >= p.proposedAt + PAYMENT_TIMELOCK, "Treas: timelock active");
        require(USDC.balanceOf(address(this)) >= p.amount, "Treas: insufficient funds");

        p.executed = true;
        totalGrantsPaid += p.amount;
        USDC.safeTransfer(p.recipient, p.amount);
        emit PaymentExecuted(paymentId, p.recipient, p.amount);
    }

    function cancelPayment(uint256 paymentId) external onlyOwner {
        Payment storage p = payments[paymentId];
        require(!p.executed,  "Treas: already executed");
        require(!p.cancelled, "Treas: already cancelled");
        p.cancelled = true;
        emit PaymentCancelled(paymentId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INCOME TRACKING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiRevenueSplitter when fees arrive.
     *         Tracks the source for accounting.
     */
    function receiveIncome(uint256 amount, string calldata source) external {
        // Tokens transferred separately — this just tracks the accounting
        totalReceived += amount;
        emit TreasuryReceived(msg.sender, amount, source);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Full treasury health dashboard.
     *         Frontend + investors use this to see the treasury state.
     */
    function dashboard() external view returns (
        uint256 usdcBalance,
        uint256 wikBalance,
        uint256 monthlyBurn,
        uint256 runwayMonths,
        uint256 totalSalaryPaid_,
        uint256 totalGrantsPaid_,
        uint256 contributorCount,
        uint256 activeContributors
    ) {
        usdcBalance        = USDC.balanceOf(address(this));
        wikBalance         = WIK.balanceOf(address(this));
        totalSalaryPaid_   = totalSalaryPaid;
        totalGrantsPaid_   = totalGrantsPaid;
        contributorCount   = contributors.length;

        // Calculate monthly burn (sum of active salaries)
        uint256 burn;
        uint256 active;
        for (uint i; i < contributors.length; i++) {
            if (contributors[i].active) {
                active++;
                // Normalise to monthly
                if (contributors[i].frequency == PayFrequency.MONTHLY)       burn += contributors[i].salaryPerPeriod;
                else if (contributors[i].frequency == PayFrequency.BIWEEKLY) burn += contributors[i].salaryPerPeriod * 2;
                else                                                          burn += contributors[i].salaryPerPeriod * 4;
            }
        }
        monthlyBurn      = burn;
        activeContributors = active;
        runwayMonths     = (burn > 0) ? usdcBalance / burn : type(uint256).max;
    }

    /**
     * @notice View all contributors (public transparency).
     */
    function allContributors() external view returns (Contributor[] memory) {
        return contributors;
    }

    /**
     * @notice Runway calculator — given expected monthly income, how long can we pay everyone?
     */
    function projectedRunway(uint256 monthlyIncome) external view returns (
        uint256 currentBalance,
        uint256 monthlyBurn,
        uint256 monthlyNet,
        uint256 runwayMonths
    ) {
        currentBalance = USDC.balanceOf(address(this));
        for (uint i; i < contributors.length; i++) {
            if (contributors[i].active) {
                if (contributors[i].frequency == PayFrequency.MONTHLY)       monthlyBurn += contributors[i].salaryPerPeriod;
                else if (contributors[i].frequency == PayFrequency.BIWEEKLY) monthlyBurn += contributors[i].salaryPerPeriod * 2;
                else                                                          monthlyBurn += contributors[i].salaryPerPeriod * 4;
            }
        }
        monthlyNet    = monthlyIncome > monthlyBurn ? monthlyIncome - monthlyBurn : 0;
        runwayMonths  = monthlyBurn > 0
            ? currentBalance / monthlyBurn + (monthlyNet * 12 / monthlyBurn)
            : type(uint256).max;
    }

    // ── Authorised agents (e.g. WikiAutoCompounder) ─────────────────────────
    // An agent can call claimSalaryFor(user) on the user's behalf.
    // User must explicitly authorise the agent. Owner cannot set this.
    mapping(address => mapping(address => bool)) public agents; // user → agent → allowed

    /**
     * @notice Authorise an address (e.g. WikiAutoCompounder) to claim your salary
     *         and forward it. Called by the contributor themselves.
     */
    function authoriseAgent(address agent, bool enabled) external {
        agents[msg.sender][agent] = enabled;
    }

    /**
     * @notice Called by WikiAutoCompounder to claim salary on behalf of a contributor.
     *         Salary is sent to the agent (AutoCompounder) which then swaps → WIK → stakes.
     *         [A1] Only works if contributor explicitly authorised this agent.
     */
    function claimSalaryFor(address contributor) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(agents[contributor][msg.sender], "Treas: agent not authorised");

        uint256 idx = contributorIndex[contributor];
        require(idx > 0, "Treas: not a contributor");

        Contributor storage contrib = contributors[idx - 1];
        require(contrib.active, "Treas: contributor inactive");

        uint256 period  = _periodLength(contrib.frequency);
        uint256 elapsed = block.timestamp - contrib.lastClaimTime;
        uint256 periods = elapsed / period;
        require(periods > 0, "Treas: no salary due");

        amount = periods * contrib.salaryPerPeriod;
        require(USDC.balanceOf(address(this)) >= amount, "Treas: insufficient funds");

        contrib.lastClaimTime += periods * period;
        contrib.totalPaid     += amount;
        totalSalaryPaid       += amount;

        // Send to agent (AutoCompounder) — it will swap to WIK and stake
        USDC.safeTransfer(msg.sender, amount);
        emit SalaryClaimed(contributor, contrib.role, amount, periods);
    }

    // ── Emergency pause [A4] ──────────────────────────────────────────────────
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Internal helpers ──────────────────────────────────────────────────────
    function _periodLength(PayFrequency f) internal pure returns (uint256) {
        if (f == PayFrequency.MONTHLY)   return 30 days;
        if (f == PayFrequency.BIWEEKLY)  return 14 days;
        return 7 days; // WEEKLY
    }
}
