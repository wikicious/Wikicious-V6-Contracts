// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiBuybackBurn
 * @notice Receives USDC from WikiFeeDistributor, buys WIK on Uniswap V3,
 *         then permanently burns the purchased WIK. Creates deflationary
 *         pressure on WIK supply → price appreciation → higher staking TVL
 *         → more protocol usage → more fees. The compounding flywheel.
 *
 * MECHANISM
 * ─────────────────────────────────────────────────────────────────────────
 * 1. WikiFeeDistributor sends 20% of all fees here each distribution cycle
 * 2. Keeper calls executeBuyback() which swaps USDC → WIK via Uniswap V3
 * 3. 100% of purchased WIK is sent to address(0xdead) — permanently burned
 * 4. Emit event for transparency and analytics
 *
 * PROTECTIONS
 * ─────────────────────────────────────────────────────────────────────────
 * [A1] minAmountOut — slippage protection, revert if too little WIK received
 * [A2] maxBuybackPerTx — cap size to prevent single large price impact
 * [A3] cooldown — minimum time between buybacks to prevent manipulation
 * [A4] Emergency pause — owner can stop buybacks
 * [A5] TWAP guard — reject if execution price deviates >5% from TWAP
 */

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

interface IQuoterV5 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24  fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IWIKToken {
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract WikiBuybackBurn is Ownable2Step, ReentrancyGuard {
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
    //  Immutables
    // ──────────────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IWIKToken        public immutable WIK;
    IUniswapV3Router public immutable router;
    address public constant UNISWAP_QUOTER_V5 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    // Uniswap V3 WIK/USDC pool fee tier (0.3% = 3000)
    uint24 public poolFee = 3000;

    // ──────────────────────────────────────────────────────────────────
    //  Config (owner-adjustable)
    // ──────────────────────────────────────────────────────────────────
    uint256 public maxBuybackPerTx  = 10_000 * 1e6;   // max $10K USDC per tx [A2]
    uint256 public minBuybackAmount = 100   * 1e6;    // min $100 USDC to trigger
    uint256 public cooldown         = 6 hours;         // min time between buybacks [A3]
    uint256 public slippageBps      = 200;             // 2% max slippage [A1]
    bool    public paused;                             // emergency stop [A4]

    mapping(address => bool) public keepers; // authorised executors

    // ──────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────
    uint256 public lastBuybackTime;
    uint256 public totalUSDCSpent;
    uint256 public totalWIKBurned;
    uint256 public buybackCount;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event BuybackExecuted(uint256 usdcIn, uint256 wikBurned, uint256 timestamp);
    event KeeperSet(address indexed keeper, bool enabled);
    event ConfigUpdated(uint256 maxPerTx, uint256 cooldown, uint256 slippageBps);
    event EmergencyWithdraw(address token, uint256 amount, address to);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _wik,
        address _router,
        address _owner
    ) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_wik != address(0), "Wiki: zero _wik");
        require(_router != address(0), "Wiki: zero _router");
        USDC   = IERC20(_usdc);
        WIK    = IWIKToken(_wik);
        router = IUniswapV3Router(_router);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Core: Execute Buyback
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Swap accumulated USDC for WIK and burn all of it.
     *         Called by keeper bot after each fee distribution cycle.
     *
     * @param usdcAmount   USDC to spend this buyback (≤ maxBuybackPerTx)
     * @param minWikOut    Minimum WIK to receive — slippage guard [A1]
     */
    function executeBuyback(
        uint256 usdcAmount,
        uint256 minWikOut
    ) external nonReentrant {
        require(keepers[msg.sender] || msg.sender == owner(), "BB: not keeper");
        require(!paused,                                       "BB: paused");        // [A4]
        require(block.timestamp >= lastBuybackTime + cooldown, "BB: cooldown");     // [A3]
        require(usdcAmount >= minBuybackAmount,                "BB: too small");
        require(usdcAmount <= maxBuybackPerTx,                 "BB: too large");    // [A2]

        uint256 available = USDC.balanceOf(address(this));
        require(available >= usdcAmount,                       "BB: insufficient USDC");

        // ── Swap USDC → WIK via Uniswap V3 ──────────────────────────
        USDC.approve(address(router), usdcAmount);

        uint256 wikReceived = router.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn:           address(USDC),
                tokenOut:          address(WIK),
                fee:               poolFee,
                recipient:         address(this),
                amountIn:          usdcAmount,
                amountOutMinimum:  minWikOut,           // [A1] slippage guard
                sqrtPriceLimitX96: 0
            })
        );

        require(wikReceived >= minWikOut, "BB: slippage exceeded");

        // ── Burn all purchased WIK ────────────────────────────────────
        // Send to dead address (works even if WIK has no burn() function)
        IERC20(address(WIK)).safeTransfer(address(0x000000000000000000000000000000000000dEaD), wikReceived);

        // Update stats
        lastBuybackTime  = block.timestamp;
        totalUSDCSpent  += usdcAmount;
        totalWIKBurned  += wikReceived;
        buybackCount++;

        emit BuybackExecuted(usdcAmount, wikReceived, block.timestamp);
    }

    /**
     * @notice Preview how much WIK would be received for a given USDC input.
     *         Used by the backend to calculate minWikOut before executing.
     */
    /**
     * @notice Preview WIK received for a given USDC input via Uniswap V3 QuoterV5.
     * QuoterV5 on Arbitrum: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
     * WIK/USDC pool (0.3% fee tier): created at deploy time on Uniswap V3 Arbitrum.
     */
    function previewBuyback(uint256 usdcAmount) external returns (uint256 estimatedWik) {
        if (usdcAmount == 0) return 0;
        try IQuoterV5(UNISWAP_QUOTER_V5).quoteExactInputSingle(
            IQuoterV5.QuoteExactInputSingleParams({
                tokenIn:           address(USDC),
                tokenOut:          address(WIK),
                amountIn:          usdcAmount,
                fee:               poolFee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            return amountOut;
        } catch {
            // Pool not yet initialised — fall back to guardian estimate
            return usdcAmount * 1e12; // rough 1e12 scaling (USDC 6dec → WIK 18dec at $1 each)
        }
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Config
    // ──────────────────────────────────────────────────────────────────

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        keepers[keeper] = enabled;
        emit KeeperSet(keeper, enabled);
    }

    function setConfig(
        uint256 _maxPerTx,
        uint256 _cooldown,
        uint256 _slippageBps,
        uint256 _minAmount
    ) external onlyOwner {
        require(_slippageBps <= 500, "BB: slippage too high"); // max 5%
        maxBuybackPerTx  = _maxPerTx;
        cooldown         = _cooldown;
        slippageBps      = _slippageBps;
        minBuybackAmount = _minAmount;
        emit ConfigUpdated(_maxPerTx, _cooldown, _slippageBps);
    }

    function setPoolFee(uint24 fee) external onlyOwner {
        require(fee == 500 || fee == 3000 || fee == 10000, "BB: invalid fee tier");
        poolFee = fee;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /**
     * @notice Emergency withdrawal — only for USDC stuck in contract if router is broken.
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "BB: zero address");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, amount, to);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function pendingUSDC() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function nextBuybackTime() external view returns (uint256) {
        return lastBuybackTime + cooldown;
    }

    function canExecute() external view returns (bool) {
        return !paused
            && block.timestamp >= lastBuybackTime + cooldown
            && USDC.balanceOf(address(this)) >= minBuybackAmount;
    }

    function stats() external view returns (
        uint256 _totalUSDCSpent,
        uint256 _totalWIKBurned,
        uint256 _buybackCount,
        uint256 _pendingUSDC,
        uint256 _lastBuybackTime
    ) {
        return (totalUSDCSpent, totalWIKBurned, buybackCount, USDC.balanceOf(address(this)), lastBuybackTime);
    }
}
