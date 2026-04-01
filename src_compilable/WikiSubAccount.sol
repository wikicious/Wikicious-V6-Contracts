// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiSubAccount
 * @notice Sub-accounts under one master wallet. Each sub-account has
 *         isolated margin, separate P&L, and optional leverage/risk limits.
 *         Used by professional traders to separate strategies.
 *
 * USE CASES:
 *   Sub 1: "Scalping" — 50× leverage, 2% risk per trade
 *   Sub 2: "Swing"    — 10× leverage, 5% risk per trade
 *   Sub 3: "Prop"     — linked to prop challenge, isolated DD tracking
 *   Sub 4: "Bot"      — automated strategies, separate from manual trading
 *
 * KEY PROPERTIES:
 *   Isolated margin: loss in Sub 1 cannot liquidate Sub 2
 *   Separate P&L: each sub-account has its own leaderboard entry
 *   Transfer between subs: master wallet can move USDC between sub-accounts
 *   Per-sub limits: max leverage, max position size, daily loss limit
 */
contract WikiSubAccount is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct SubAccount {
        address  master;
        uint256  index;           // sub-account number (0, 1, 2, 3...)
        string   label;           // "Scalping", "Swing", etc
        uint256  balance;         // USDC balance (isolated)
        uint256  maxLeverage;     // 0 = inherit master default
        uint256  maxPositionUsdc; // 0 = unlimited
        uint256  dailyLossLimit;  // 0 = no limit
        uint256  dailyLossUsed;   // resets daily
        uint256  lastDayReset;
        bool     active;
        bool     tradingPaused;   // master can pause a sub manually
    }

    // master → subIndex → SubAccount
    mapping(address => mapping(uint256 => SubAccount)) public subAccounts;
    mapping(address => uint256) public subCount;
    // Track which sub-account is currently active for a given (master, tx context)
    mapping(address => uint256) public activeSubIndex;

    uint256 public constant MAX_SUBS = 10;

    event SubAccountCreated(address indexed master, uint256 index, string label);
    event SubAccountFunded(address indexed master, uint256 index, uint256 amount);
    event SubAccountWithdrawn(address indexed master, uint256 index, uint256 amount);
    event TransferBetweenSubs(address indexed master, uint256 from, uint256 to, uint256 amount);
    event SubAccountPaused(address indexed master, uint256 index, bool paused);

    constructor(address _owner, address _usdc) Ownable(_owner) {
        USDC = IERC20(_usdc);
    }

    // ── Sub-account management ────────────────────────────────────────────
    function createSubAccount(
        string calldata label,
        uint256 maxLeverage,
        uint256 maxPositionUsdc,
        uint256 dailyLossLimit
    ) external returns (uint256 index) {
        require(subCount[msg.sender] < MAX_SUBS, "Sub: max 10 sub-accounts");
        index = subCount[msg.sender]++;
        subAccounts[msg.sender][index] = SubAccount({
            master:          msg.sender,
            index:           index,
            label:           label,
            balance:         0,
            maxLeverage:     maxLeverage,
            maxPositionUsdc: maxPositionUsdc,
            dailyLossLimit:  dailyLossLimit,
            dailyLossUsed:   0,
            lastDayReset:    block.timestamp,
            active:          true,
            tradingPaused:   false
        });
        emit SubAccountCreated(msg.sender, index, label);
    }

    // ── Funding ───────────────────────────────────────────────────────────
    function depositToSub(uint256 subIndex, uint256 amount) external nonReentrant {
        require(subAccounts[msg.sender][subIndex].active, "Sub: not active");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        subAccounts[msg.sender][subIndex].balance += amount;
        emit SubAccountFunded(msg.sender, subIndex, amount);
    }

    function withdrawFromSub(uint256 subIndex, uint256 amount) external nonReentrant {
        SubAccount storage s = subAccounts[msg.sender][subIndex];
        require(s.balance >= amount, "Sub: insufficient balance");
        s.balance -= amount;
        USDC.safeTransfer(msg.sender, amount);
        emit SubAccountWithdrawn(msg.sender, subIndex, amount);
    }

    function transferBetweenSubs(uint256 fromIdx, uint256 toIdx, uint256 amount) external nonReentrant {
        SubAccount storage from = subAccounts[msg.sender][fromIdx];
        SubAccount storage to   = subAccounts[msg.sender][toIdx];
        require(from.active && to.active, "Sub: inactive sub");
        require(from.balance >= amount,   "Sub: insufficient balance");
        from.balance -= amount;
        to.balance   += amount;
        emit TransferBetweenSubs(msg.sender, fromIdx, toIdx, amount);
    }

    // ── Risk checks (called by WikiPerp before opening position) ─────────
    function checkAndDeductRisk(
        address master,
        uint256 subIndex,
        uint256 positionSize,
        uint256 leverage
    ) external returns (bool allowed) {
        SubAccount storage s = subAccounts[master][subIndex];
        if (!s.active || s.tradingPaused) return false;

        // Reset daily loss if new day
        if (block.timestamp >= s.lastDayReset + 1 days) {
            s.dailyLossUsed = 0;
            s.lastDayReset  = block.timestamp;
        }

        // Leverage check
        if (s.maxLeverage > 0 && leverage > s.maxLeverage) return false;

        // Position size check
        if (s.maxPositionUsdc > 0 && positionSize > s.maxPositionUsdc) return false;

        // Daily loss remaining
        if (s.dailyLossLimit > 0) {
            if (s.dailyLossUsed >= s.dailyLossLimit) return false;
        }

        return true;
    }

    function recordSubLoss(address master, uint256 subIndex, uint256 lossUsdc) external {
        SubAccount storage s = subAccounts[master][subIndex];
        s.dailyLossUsed += lossUsdc;
        if (s.balance > lossUsdc) s.balance -= lossUsdc;
        else s.balance = 0;
        // Auto-pause if daily limit hit
        if (s.dailyLossLimit > 0 && s.dailyLossUsed >= s.dailyLossLimit) {
            s.tradingPaused = true;
            emit SubAccountPaused(master, subIndex, true);
        }
    }

    function recordSubProfit(address master, uint256 subIndex, uint256 profitUsdc) external {
        subAccounts[master][subIndex].balance += profitUsdc;
    }

    // ── Controls ──────────────────────────────────────────────────────────
    function setActiveSubAccount(uint256 subIndex) external {
        require(subAccounts[msg.sender][subIndex].active, "Sub: not active");
        activeSubIndex[msg.sender] = subIndex;
    }

    function pauseSub(uint256 subIndex, bool paused) external {
        require(subAccounts[msg.sender][subIndex].master == msg.sender, "Sub: not master");
        subAccounts[msg.sender][subIndex].tradingPaused = paused;
        emit SubAccountPaused(msg.sender, subIndex, paused);
    }

    function updateSubLimits(uint256 subIndex, uint256 maxLev, uint256 maxPos, uint256 dailyLimit) external {
        SubAccount storage s = subAccounts[msg.sender][subIndex];
        require(s.master == msg.sender, "Sub: not master");
        s.maxLeverage     = maxLev;
        s.maxPositionUsdc = maxPos;
        s.dailyLossLimit  = dailyLimit;
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getAllSubAccounts(address master) external view returns (SubAccount[] memory subs) {
        uint256 n = subCount[master];
        subs = new SubAccount[](n);
        for (uint i; i < n; i++) subs[i] = subAccounts[master][i];
    }

    function getSubBalance(address master, uint256 subIndex) external view returns (uint256) {
        return subAccounts[master][subIndex].balance;
    }
}
