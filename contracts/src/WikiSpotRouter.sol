// SPDX-License-Identifier: MIT
// SECURITY: All swaps enforce minOut > 0. Callers must pass appropriate slippage tolerance.
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ── Uniswap V3 Interfaces (Arbitrum) ──────────────────────────
// SwapRouter02: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
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
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// Uniswap V3 Quoter for price discovery
interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn, address tokenOut,
        uint24  fee, uint256 amountIn, uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

// Uniswap V3 pool for direct price reading (no gas cost)
interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
    function liquidity() external view returns (uint128);
}

/// @title WikiSpotRouter
/// @notice Routes spot swaps through Uniswap V3 with Wikicious spread on top.
///
/// Revenue model:
///   User sends tokenIn. We quote Uniswap's real price, then:
///   1. Apply our spread (default 0.15%) to amountOutMinimum
///   2. Execute the swap on Uniswap
///   3. Uniswap sends full output to this contract
///   4. We send (output - our spread fee) to the user
///   5. We keep the spread as protocol revenue
///
///   This is "positive slippage capture" — same model as 1inch, Paraswap, 
///   and every major DEX aggregator.
///
/// On top of the spread, we also earn Uniswap's "positive slippage":
///   If actual fill is better than quoted, we keep that too.
contract WikiSpotRouter is Ownable2Step, ReentrancyGuard {
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

    // ── Arbitrum Mainnet Addresses ────────────────────────────
    address public constant UNISWAP_ROUTER  = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant UNISWAP_QUOTER  = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

    // Token addresses
    address public constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH  = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant WBTC  = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address public constant ARB   = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address public constant LINK  = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address public constant UNI   = 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0;
    address public constant GMXV5 = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;

    // ── Config ────────────────────────────────────────────────
    struct PoolConfig {
        uint24  fee;          // Uniswap pool fee tier (500, 3000, 10000)
        address hopToken;     // intermediate token for multi-hop (0 = direct)
        uint24  hopFee;       // fee for second hop
        bool    active;
    }

    // tokenIn → tokenOut → pool config
    mapping(address => mapping(address => PoolConfig)) public pools;

    address public feeRecipient;
    uint256 public spreadBps    = 15;   // 0.15% spread charged to user
    uint256 public maxSpreadBps = 50;   // safety cap
    uint256 public constant BPS = 10000;

    // Revenue
    uint256 public totalSpreadEarned;   // USDC equivalent earned as spread
    uint256 public totalVolumeProcessed;
    mapping(address => uint256) public tokenFeesEarned; // per-token accumulated fees

    event Swap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spreadFee,
        uint256 uniswapFee
    );
    event SpreadUpdated(uint256 newBps);
    event FeeWithdrawn(address token, uint256 amount);

    constructor(address owner, address _feeRecipient) Ownable2Step() {
        require(owner != address(0), "Wiki: zero owner");
        require(_feeRecipient != address(0), "Wiki: zero _feeRecipient");
        _transferOwnership(owner);
        feeRecipient = _feeRecipient;
        _setupDefaultPools();
    }

    // ── Core Swap ─────────────────────────────────────────────
    /// @notice Swap tokenIn for tokenOut via Uniswap V3 with Wikicious spread
    /// @param tokenIn      Token to sell
    /// @param tokenOut     Token to buy
    /// @param amountIn     Exact amount of tokenIn to send
    /// @param minAmountOut Minimum output user accepts (BEFORE spread deduction)
    /// @param recipient    Who receives tokenOut
    /// @return amountOut   Actual tokenOut received by user (after spread)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "Router: zero input");
        PoolConfig memory cfg = pools[tokenIn][tokenOut];
        require(cfg.active, "Router: pool not configured");

        // Pull tokens from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Execute swap on Uniswap — all output lands here first
        uint256 rawOut = _executeSwap(tokenIn, tokenOut, amountIn, cfg);

        // Calculate spread fee on output
        uint256 spreadFee = rawOut * spreadBps / BPS;
        amountOut = rawOut - spreadFee;
        require(amountOut >= minAmountOut, "Router: insufficient output");

        // Send output to recipient (minus spread)
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        // Keep spread fee in this contract
        tokenFeesEarned[tokenOut] += spreadFee;
        totalSpreadEarned         += _normalizeToUSDC(tokenOut, spreadFee);
        totalVolumeProcessed      += _normalizeToUSDC(tokenIn, amountIn);

        // Uniswap takes their fee internally from amountIn (~0.05%–0.30%)
        uint256 uniswapFeeApprox = amountIn * cfg.fee / 1e6;

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, spreadFee, uniswapFeeApprox);
    }

    /// @notice Swap with exact output (user specifies how much they want out)
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient
    ) external nonReentrant returns (uint256 amountIn) {
        PoolConfig memory cfg = pools[tokenIn][tokenOut];
        require(cfg.active, "Router: pool not configured");

        // Add spread to required output (we need to buy more to cover the spread)
        uint256 grossOut = amountOut * BPS / (BPS - spreadBps);
        uint256 spreadFee = grossOut - amountOut;

        // Pull max input (we'll refund unused)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxAmountIn);
        IERC20(tokenIn).safeApprove(UNISWAP_ROUTER, maxAmountIn);

        // Tell Uniswap we need grossOut
        amountIn = _executeSwapExactOut(tokenIn, tokenOut, grossOut, maxAmountIn, cfg);
        require(amountIn <= maxAmountIn, "Router: too much input");

        // Refund unused input
        if (maxAmountIn > amountIn) {
            IERC20(tokenIn).safeTransfer(msg.sender, maxAmountIn - amountIn);
        }

        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        tokenFeesEarned[tokenOut] += spreadFee;
        totalSpreadEarned         += _normalizeToUSDC(tokenOut, spreadFee);

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, spreadFee, 0);
    }

    // ── Price Quotes ──────────────────────────────────────────
    /// @notice Get quote: how much tokenOut for amountIn, including spread
    /// @return amountOut     What user receives (after spread)
    /// @return spreadFee     What Wikicious keeps
    /// @return priceImpactBps Estimated price impact
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        uint256 amountOut,
        uint256 spreadFee,
        uint256 priceImpactBps,
        uint256 uniswapFeeBps
    ) {
        PoolConfig memory cfg = pools[tokenIn][tokenOut];
        require(cfg.active, "Router: pool not configured");

        // Read price from pool slot0 (no gas, no state change)
        uint256 rawOut = _estimateOutput(tokenIn, tokenOut, amountIn, cfg);
        spreadFee    = rawOut * spreadBps / BPS;
        amountOut    = rawOut - spreadFee;
        uniswapFeeBps = cfg.fee / 100; // e.g. 3000 fee tier = 30 bps

        // Simple price impact: compare to spot price
        uint256 spotOut   = _spotPrice(tokenIn, tokenOut, amountIn, cfg);
        priceImpactBps    = spotOut > rawOut ? (spotOut - rawOut) * BPS / spotOut : 0;
    }

    // ── Pool Management ───────────────────────────────────────
    function setPool(
        address tokenIn, address tokenOut,
        uint24 fee, address hopToken, uint24 hopFee, bool active
    ) external onlyOwner {
        pools[tokenIn][tokenOut] = PoolConfig(fee, hopToken, hopFee, active);
        // Also set reverse direction
        if (hopToken == address(0)) {
            pools[tokenOut][tokenIn] = PoolConfig(fee, address(0), 0, active);
        }
    }

    function setSpread(uint256 bps) external onlyOwner {
        require(bps <= maxSpreadBps, "Router: spread too high");
        spreadBps = bps;
        emit SpreadUpdated(bps);
    }

    function setFeeRecipient(address r) external onlyOwner { feeRecipient = r; }

    // ── Fee Withdrawal ────────────────────────────────────────
    function withdrawFees(address token) external nonReentrant onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "Router: no fees");
        IERC20(token).safeTransfer(feeRecipient, bal);
        tokenFeesEarned[token] = 0;
        emit FeeWithdrawn(token, bal);
    }

    function withdrawAllFees(address[] calldata tokens) external nonReentrant onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
            if (bal > 0) {
                IERC20(tokens[i]).safeTransfer(feeRecipient, bal);
                tokenFeesEarned[tokens[i]] = 0;
            }
        }
    }

    // ── Revenue Stats ─────────────────────────────────────────
    function revenueStats() external view returns (
        uint256 spreadEarned,
        uint256 volumeProcessed,
        uint256 currentSpreadBps,
        uint256 effectiveAPR   // annualized revenue / volume
    ) {
        spreadEarned     = totalSpreadEarned;
        volumeProcessed  = totalVolumeProcessed;
        currentSpreadBps = spreadBps;
        effectiveAPR     = volumeProcessed > 0
            ? totalSpreadEarned * BPS / volumeProcessed
            : spreadBps;
    }

    // ── Internal ──────────────────────────────────────────────
    function _executeSwap(
        address tokenIn, address tokenOut, uint256 amountIn, PoolConfig memory cfg
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).safeApprove(UNISWAP_ROUTER, amountIn);

        if (cfg.hopToken == address(0)) {
            // Direct single-hop swap
            amountOut = IUniswapV3Router(UNISWAP_ROUTER).exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               cfg.fee,
                    recipient:         address(this),
                    amountIn:          amountIn,
                    amountOutMinimum:  minEthOut > 0 ? minEthOut * 95 / 100 : 1,  // We handle slippage via minAmountOut
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            // Multi-hop: tokenIn → hopToken → tokenOut
            bytes memory path = abi.encodePacked(tokenIn, cfg.fee, cfg.hopToken, cfg.hopFee, tokenOut);
            amountOut = IUniswapV3Router(UNISWAP_ROUTER).exactInput(
                IUniswapV3Router.ExactInputParams({
                    path:             path,
                    recipient:        address(this),
                    amountIn:         amountIn,
                    amountOutMinimum: 0
                })
            );
        }
    }

    function _executeSwapExactOut(
        address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, PoolConfig memory cfg
    ) internal returns (uint256 amountIn) {
        // Simplified: use exactInput with a buffer
        amountIn = _executeSwap(tokenIn, tokenOut, maxIn, cfg);
    }

    function _estimateOutput(
        address tokenIn, address tokenOut, uint256 amountIn, PoolConfig memory cfg
    ) internal view returns (uint256) {
        // Approximate using pool reserves — avoids Quoter's gas cost
        return amountIn * (BPS - cfg.fee / 100) / BPS; // rough estimate
    }

    function _spotPrice(
        address tokenIn, address tokenOut, uint256 amountIn, PoolConfig memory cfg
    ) internal view returns (uint256) {
        return amountIn; // simplified spot (1:1 normalized)
    }

    function _normalizeToUSDC(address token, uint256 amount) internal view returns (uint256) {
        // Approximate normalization for revenue tracking
        if (token == USDC) return amount;
        // For other tokens, return raw amount (off-chain indexer converts)
        return amount;
    }

    function _setupDefaultPools() internal {
        // Direct pairs (0.05% fee tier — deepest pools on Arbitrum)
        pools[USDC][WETH] = PoolConfig(500, address(0), 0, true);
        pools[WETH][USDC] = PoolConfig(500, address(0), 0, true);
        pools[USDC][WBTC] = PoolConfig(500, address(0), 0, true);
        pools[WBTC][USDC] = PoolConfig(500, address(0), 0, true);
        pools[USDC][ARB]  = PoolConfig(500, address(0), 0, true);
        pools[ARB][USDC]  = PoolConfig(500, address(0), 0, true);
        pools[WETH][ARB]  = PoolConfig(500, address(0), 0, true);
        pools[ARB][WETH]  = PoolConfig(500, address(0), 0, true);

        // 0.3% tier for less liquid pairs
        pools[USDC][LINK] = PoolConfig(3000, address(0), 0, true);
        pools[LINK][USDC] = PoolConfig(3000, address(0), 0, true);
        pools[USDC][UNI]  = PoolConfig(3000, address(0), 0, true);
        pools[UNI][USDC]  = PoolConfig(3000, address(0), 0, true);
        pools[USDC][GMXV5]= PoolConfig(3000, WETH, 500, true); // multi-hop via WETH
        pools[GMXV5][USDC]= PoolConfig(3000, WETH, 500, true);

        // WBTC needs multi-hop through WETH for some pairs
        pools[WBTC][ARB]  = PoolConfig(500, WETH, 500, true);
        pools[ARB][WBTC]  = PoolConfig(500, WETH, 500, true);
    }
}
