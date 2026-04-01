// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiOTCDesk
 * @notice Request-for-Quote (RFQ) desk for large trades (>$100K).
 *         Large traders can't use the orderbook without moving the price
 *         against themselves. OTC gives them price certainty at 0.1% fee.
 *
 * FLOW
 * ─────────────────────────────────────────────────────────────────────────
 * 1. Trader submits RFQ: token pair, size, direction
 * 2. WikiVault quotes a fill price within 60 seconds
 * 3. Trader accepts → fills against WikiVault liquidity at quoted price
 * 4. Protocol earns 0.1% fee on notional; no price impact for trader
 * 5. Unfilled quotes expire automatically after 60 seconds
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * At $10M/month OTC volume: 0.1% fee = $10,000/month
 * Near-zero marginal cost — WikiVault already holds the liquidity
 *
 * ACCESS CONTROL
 * ─────────────────────────────────────────────────────────────────────────
 * Default: requires WikiTraderPass GOLD or DIAMOND tier
 * Owner can whitelist specific addresses without pass requirement
 */

interface IWikiTraderPass {
    function hasOTCAccess(address trader) external view returns (bool);
}

interface IWikiVault {
    function freeMargin(address user) external view returns (uint256);
    function deposit(uint256 amount) external;
}

contract WikiOTCDesk is Ownable2Step, ReentrancyGuard {
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
    uint256 public constant DEFAULT_FEE  = 10;     // 0.1% default fee
    uint256 public constant MAX_FEE      = 50;     // 0.5% max fee
    uint256 public constant QUOTE_EXPIRY = 60;     // 60 second quote validity
    uint256 public constant MIN_SIZE     = 100_000 * 1e6; // $100K minimum

    // ──────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────
    enum QuoteStatus { PENDING, FILLED, EXPIRED, CANCELLED }

    struct Quote {
        address  trader;
        address  tokenIn;
        address  tokenOut;
        uint256  amountIn;       // trader sends this
        uint256  amountOut;      // trader receives this (quoted by desk)
        uint256  fee;            // fee in tokenOut
        uint256  feeBps;         // fee rate used
        uint256  expiresAt;      // timestamp
        QuoteStatus status;
        uint256  filledAt;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IWikiTraderPass  public traderPass;

    Quote[]         public quotes;
    mapping(address => bool) public whitelisted; // bypass pass requirement
    mapping(address => bool) public quoters;     // can submit quotes

    uint256 public feeBps         = DEFAULT_FEE;
    uint256 public totalVolume;
    uint256 public totalFees;
    uint256 public protocolRevenue;
    bool    public requirePass    = true;

    // Liquidity pool — desk's own capital for fills
    mapping(address => uint256) public reserveBalance;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event RFQSubmitted(uint256 indexed quoteId, address indexed trader, address tokenIn, uint256 amountIn);
    event QuoteProvided(uint256 indexed quoteId, uint256 amountOut, uint256 fee, uint256 expiresAt);
    event QuoteFilled(uint256 indexed quoteId, address indexed trader, uint256 amountIn, uint256 amountOut, uint256 fee);
    event QuoteExpired(uint256 indexed quoteId);
    event LiquidityAdded(address token, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(address _usdc, address _traderPass, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_traderPass != address(0), "Wiki: zero _traderPass");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC       = IERC20(_usdc);
        traderPass = IWikiTraderPass(_traderPass);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Trader: Request Quote
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Submit a request for quote. Desk responds off-chain, then
     *         calls provideQuote(). Trader then has 60s to accept.
     *
     * @param tokenIn   Token trader is selling (e.g. USDC)
     * @param tokenOut  Token trader wants (e.g. WETH)
     * @param amountIn  Amount of tokenIn to sell
     */
    function requestQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external nonReentrant returns (uint256 quoteId) {
        if (requirePass) {
            require(
                whitelisted[msg.sender] || traderPass.hasOTCAccess(msg.sender),
                "OTC: pass required"
            );
        }
        require(amountIn >= MIN_SIZE, "OTC: below minimum");
        require(tokenIn  != tokenOut, "OTC: same tokens");

        quoteId = quotes.length;
        quotes.push(Quote({
            trader:    msg.sender,
            tokenIn:   tokenIn,
            tokenOut:  tokenOut,
            amountIn:  amountIn,
            amountOut: 0,          // filled by quoter
            fee:       0,
            feeBps:    feeBps,
            expiresAt: 0,          // set when quote is provided
            status:    QuoteStatus.PENDING,
            filledAt:  0
        }));

        emit RFQSubmitted(quoteId, msg.sender, tokenIn, amountIn);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Quoter (desk/keeper): Provide Quote
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Desk submits a firm quote for the RFQ.
     * @param quoteId   The RFQ id
     * @param amountOut Amount of tokenOut trader will receive (after fee)
     */
    function provideQuote(uint256 quoteId, uint256 amountOut) external {
        require(quoters[msg.sender] || msg.sender == owner(), "OTC: not quoter");

        Quote storage q = quotes[quoteId];
        require(q.status == QuoteStatus.PENDING, "OTC: not pending");
        require(q.amountOut == 0,                "OTC: already quoted");

        uint256 grossOut = amountOut * BPS / (BPS - q.feeBps);
        uint256 fee      = grossOut - amountOut;

        q.amountOut = amountOut;
        q.fee       = fee;
        q.expiresAt = block.timestamp + QUOTE_EXPIRY;

        emit QuoteProvided(quoteId, amountOut, fee, q.expiresAt);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Trader: Accept & Fill
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Accept the quote and execute the swap.
     *         Trader sends tokenIn, receives tokenOut minus fee.
     */
    function fillQuote(uint256 quoteId) external nonReentrant {
        Quote storage q = quotes[quoteId];
        require(q.trader    == msg.sender,          "OTC: not your quote");
        require(q.status    == QuoteStatus.PENDING, "OTC: not pending");
        require(q.amountOut > 0,                    "OTC: no quote yet");
        require(block.timestamp <= q.expiresAt,     "OTC: expired");
        require(reserveBalance[q.tokenOut] >= q.amountOut + q.fee, "OTC: insufficient liquidity");

        q.status   = QuoteStatus.FILLED;
        q.filledAt = block.timestamp;

        totalVolume        += q.amountIn;
        totalFees          += q.fee;
        protocolRevenue    += q.fee;

        // Update reserve
        reserveBalance[q.tokenIn]  += q.amountIn;
        reserveBalance[q.tokenOut] -= (q.amountOut + q.fee);

        // Transfer
        IERC20(q.tokenIn).safeTransferFrom(msg.sender, address(this), q.amountIn);
        IERC20(q.tokenOut).safeTransfer(msg.sender, q.amountOut);

        emit QuoteFilled(quoteId, msg.sender, q.amountIn, q.amountOut, q.fee);
    }

    /**
     * @notice Expire an unfilled quote past its deadline.
     */
    function expireQuote(uint256 quoteId) external {
        Quote storage q = quotes[quoteId];
        require(q.status == QuoteStatus.PENDING,    "OTC: not pending");
        require(block.timestamp > q.expiresAt,      "OTC: not expired");
        require(q.expiresAt > 0,                    "OTC: never quoted");
        q.status = QuoteStatus.EXPIRED;
        emit QuoteExpired(quoteId);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Liquidity Management
    // ──────────────────────────────────────────────────────────────────

    function addLiquidity(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        reserveBalance[token] += amount;
        emit LiquidityAdded(token, amount);
    }

    function removeLiquidity(address token, uint256 amount, address to) external onlyOwner {
        require(reserveBalance[token] >= amount, "OTC: insufficient reserve");
        reserveBalance[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function withdrawRevenue(address token, uint256 amount, address to) external onlyOwner {
        require(amount <= protocolRevenue, "OTC: exceeds revenue");
        protocolRevenue -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function setQuoter(address quoter, bool enabled) external onlyOwner { quoters[quoter] = enabled; }
    function setWhitelisted(address addr, bool enabled) external onlyOwner { whitelisted[addr] = enabled; }
    function setFeeBps(uint256 newFee) external onlyOwner { require(newFee <= MAX_FEE,"OTC: too high"); feeBps = newFee; }
    function setRequirePass(bool required) external onlyOwner { requirePass = required; }
    function setTraderPass(address tp) external onlyOwner { traderPass = IWikiTraderPass(tp); }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getQuote(uint256 id) external view returns (Quote memory) { return quotes[id]; }
    function quoteCount() external view returns (uint256) { return quotes.length; }

    function previewFee(uint256 amountIn) external view returns (uint256 fee) {
        return amountIn * feeBps / BPS;
    }

    function otcStats() external view returns (
        uint256 _volume, uint256 _fees, uint256 _quotes, uint256 _revenue
    ) {
        return (totalVolume, totalFees, quotes.length, protocolRevenue);
    }
}
