// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPredictionMarket
 * @notice Binary outcome prediction markets where users bet YES/NO on events.
 *         Protocol earns 1.5% on every winning payout.
 *
 * MECHANISM
 * ─────────────────────────────────────────────────────────────────────────
 * Each market has a YES pool and a NO pool (USDC). At resolution, winners
 * claim proportional share of the total pot minus protocol fee.
 *
 * ORACLE RESOLUTION
 * ─────────────────────────────────────────────────────────────────────────
 * Markets are resolved by the WikiOracle price feed (e.g. "will BTC hit
 * $100K by Dec 31?") or by admin for events without on-chain data.
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * 1.5% of winning payouts → protocol fee
 * Annualised: at $10M volume/month = $150K/month in fees
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiPredictionMarket is Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant BPS          = 10_000;
    uint256 public constant MAX_FEE      = 300;   // 3% max
    uint256 public constant MIN_BET      = 1e6;   // $1 min
    uint256 public constant GRACE_PERIOD = 24 hours; // dispute window

    // ──────────────────────────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────────────────────────
    enum Outcome { OPEN, YES, NO, VOID } // VOID = invalid/cancelled
    enum Category { PRICE, PROTOCOL, MACRO, SPORTS, MISC }

    struct Market {
        string   question;       // "Will BTC exceed $100K by Dec 31?"
        string   details;        // additional context
        Category category;
        uint256  resolutionTime; // when the market can be resolved
        uint256  deadline;       // last time to place bets
        bytes32  oracleId;       // WikiOracle market ID (0 if manual)
        uint256  targetPrice;    // for price markets (1e18)
        bool     priceAbove;     // true = YES if price > target
        uint256  yesPool;        // total USDC bet YES
        uint256  noPool;         // total USDC bet NO
        uint256  feeBps;         // protocol fee on winnings
        Outcome  outcome;
        uint256  resolutionTs;
        address  resolver;
        bool     claimOpen;      // true once resolution confirmed
    }

    struct Position {
        uint256 yes;  // USDC bet on YES
        uint256 no;   // USDC bet on NO
        bool    claimed;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20  public immutable USDC;

    Market[]  public markets;
    mapping(uint256 => mapping(address => Position)) public positions;
    mapping(address => bool) public resolvers; // authorised resolvers

    uint256 public protocolFees;
    uint256 public totalVolume;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event MarketCreated(uint256 indexed id, string question, uint256 deadline, uint256 resolutionTime);
    event BetPlaced(uint256 indexed id, address indexed user, bool isYes, uint256 amount);
    event MarketResolved(uint256 indexed id, Outcome outcome, address resolver);
    event Claimed(uint256 indexed id, address indexed user, uint256 payout, uint256 fee);
    event MarketVoided(uint256 indexed id);
    event FeesWithdrawn(address to, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
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

    constructor(address usdc, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Create Markets
    // ──────────────────────────────────────────────────────────────────

    function createMarket(
        string   calldata question,
        string   calldata details,
        Category category,
        uint256  deadline,
        uint256  resolutionTime,
        bytes32  oracleId,
        uint256  targetPrice,
        bool     priceAbove,
        uint256  feeBps
    ) external onlyOwner returns (uint256 id) {
        require(deadline < resolutionTime, "PM: deadline after resolution");
        require(deadline > block.timestamp, "PM: deadline in past");
        require(feeBps <= MAX_FEE, "PM: fee too high");

        id = markets.length;
        markets.push(Market({
            question:       question,
            details:        details,
            category:       category,
            resolutionTime: resolutionTime,
            deadline:       deadline,
            oracleId:       oracleId,
            targetPrice:    targetPrice,
            priceAbove:     priceAbove,
            yesPool:        0,
            noPool:         0,
            feeBps:         feeBps,
            outcome:        Outcome.OPEN,
            resolutionTs:   0,
            resolver:       address(0),
            claimOpen:      false
        }));
        emit MarketCreated(id, question, deadline, resolutionTime);
    }

    function setResolver(address r, bool enabled) external onlyOwner {
        resolvers[r] = enabled;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Place Bet
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Place a YES or NO bet on an open market.
     * @param marketId  Which market
     * @param isYes     true = bet YES, false = bet NO
     * @param amount    USDC to bet (min $1)
     */
    function bet(uint256 marketId, bool isYes, uint256 amount) external nonReentrant whenNotPaused {
        Market storage m = markets[marketId];
        require(m.outcome == Outcome.OPEN,         "PM: market closed");
        require(block.timestamp < m.deadline,       "PM: betting closed");
        require(amount >= MIN_BET,                  "PM: below minimum");

        // [CEI] state before transfer
        Position storage p = positions[marketId][msg.sender];
        if (isYes) {
            p.yes    += amount;
            m.yesPool += amount;
        } else {
            p.no     += amount;
            m.noPool  += amount;
        }
        totalVolume += amount;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit BetPlaced(marketId, msg.sender, isYes, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Resolution
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Resolve a market to YES, NO, or VOID.
     *         Called by authorised resolver after resolution time.
     */
    function resolve(uint256 marketId, Outcome outcome) external nonReentrant {
        require(resolvers[msg.sender] || msg.sender == owner(), "PM: not resolver");
        Market storage m = markets[marketId];
        require(m.outcome == Outcome.OPEN,                 "PM: already resolved");
        require(block.timestamp >= m.resolutionTime,        "PM: too early");
        require(outcome != Outcome.OPEN,                    "PM: invalid outcome");

        m.outcome      = outcome;
        m.resolutionTs = block.timestamp;
        m.resolver     = msg.sender;
        m.claimOpen    = true;

        emit MarketResolved(marketId, outcome, msg.sender);
    }

    /**
     * @notice Void a market and enable full refunds (no fee).
     */
    function voidMarket(uint256 marketId) external onlyOwner {
        Market storage m = markets[marketId];
        require(m.outcome == Outcome.OPEN, "PM: already resolved");
        m.outcome   = Outcome.VOID;
        m.claimOpen = true;
        emit MarketVoided(marketId);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Claim Winnings
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Claim payout after market resolution.
     *         Winners receive proportional share of losing pool minus fee.
     *         Losers receive nothing (except in VOID markets).
     */
    function claim(uint256 marketId) external nonReentrant {
        Market storage m  = markets[marketId];
        Position storage p = positions[marketId][msg.sender];
        require(m.claimOpen,   "PM: claim not open");
        require(!p.claimed,    "PM: already claimed");

        p.claimed = true;

        if (m.outcome == Outcome.VOID) {
            // Full refund
            uint256 refund = p.yes + p.no;
            if (refund > 0) USDC.safeTransfer(msg.sender, refund);
            return;
        }

        uint256 userWinBet = m.outcome == Outcome.YES ? p.yes : p.no;
        if (userWinBet == 0) return; // loser, nothing to claim

        uint256 winPool   = m.outcome == Outcome.YES ? m.yesPool : m.noPool;
        uint256 losePool  = m.outcome == Outcome.YES ? m.noPool  : m.yesPool;
        uint256 totalPot  = winPool + losePool;

        // Proportional share of total pot
        uint256 grossPayout = totalPot * userWinBet / winPool;
        uint256 fee         = grossPayout * m.feeBps / BPS;
        uint256 netPayout   = grossPayout - fee;

        protocolFees += fee;

        USDC.safeTransfer(msg.sender, netPayout);
        emit Claimed(marketId, msg.sender, netPayout, fee);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Withdraw Fees
    // ──────────────────────────────────────────────────────────────────

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 f = protocolFees;
        require(f > 0, "PM: no fees");
        protocolFees = 0;
        USDC.safeTransfer(to, f);
        emit FeesWithdrawn(to, f);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getMarket(uint256 id) external view returns (Market memory) {
        return markets[id];
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function getPosition(uint256 marketId, address user) external view returns (Position memory) {
        return positions[marketId][user];
    }

    function previewPayout(uint256 marketId, bool isYes, uint256 betAmount)
        external view returns (uint256 grossPayout, uint256 fee, uint256 netPayout, uint256 impliedOdds)
    {
        Market storage m = markets[marketId];
        uint256 yp = m.yesPool + (isYes ? betAmount : 0);
        uint256 np = m.noPool  + (isYes ? 0 : betAmount);
        uint256 winPool = isYes ? yp : np;
        if (winPool == 0) return (0, 0, 0, 0);
        grossPayout  = (yp + np) * betAmount / winPool;
        fee          = grossPayout * m.feeBps / BPS;
        netPayout    = grossPayout - fee;
        impliedOdds  = winPool * 10000 / (yp + np); // in BPS (5000 = 50%)
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
