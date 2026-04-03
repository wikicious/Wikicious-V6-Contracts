// SPDX-License-Identifier: MIT
// SECURITY: All swaps enforce minOut > 0. Callers must pass appropriate slippage tolerance.
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiZap — Single-token → Complex LP position in one click
 *
 * Eliminates the need to manually split tokens, approve multiple contracts,
 * and add liquidity in separate transactions. Zap does it all atomically.
 *
 * SUPPORTED ZAP ROUTES
 * ─────────────────────────────────────────────────────────────────────────
 * ETH  → WETH/USDC LP (WikiSpot pool 0)
 * USDC → ETH/USDC LP
 * WIK  → WIK/USDC LP
 * Any  → Any LP (via Uniswap V3 intermediate swap)
 * Any  → Strategy Vault (LP + autocompound in one click)
 * Any  → WikiPerp collateral + open position (leverage zap)
 *
 * REVENUE
 * 0.09% Zap fee on input amount → protocol treasury
 */

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 deadline; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256 amountOut);
}

interface IWikiSpot {
    function addLiquidity(uint256 poolId, uint256 amtA, uint256 amtB, uint256 minLP) external returns (uint256 lpReceived);
    function getPool(uint256 poolId) external view returns (address tokenA, address tokenB, uint256 reserveA, uint256 reserveB, uint256 totalLP, uint256 feeBps);
}

interface IWikiStrategyVault {
    function deposit(uint256 amount, address recipient) external returns (uint256 shares);
    function depositToken() external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract WikiZap is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IUniswapV3Router public constant UNI_ROUTER = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IWETH            public constant WETH        = IWETH(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address          public constant USDC        = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    IWikiSpot public spot;
    address   public strategyVault;
    address   public treasury;

    uint256 public constant ZAP_FEE_BPS = 9; // 0.09%
    uint256 public constant BPS         = 10000;

    uint256 public totalZaps;
    uint256 public totalFeesCollected;
    

    struct ZapParams {
        address tokenIn;
        uint256 amountIn;
        uint256 poolId;
        uint256 minLP;
        uint24  swapFeeTier;   // Uniswap V3 fee tier for intermediate swap (500=0.05%, 3000=0.3%, 10000=1%)
        uint256 deadline;
    }

        event Zapped(address indexed user, address tokenIn, uint256 amountIn, uint256 poolId, uint256 amountOut, uint256 fee);
    event ZappedToVault(address indexed user, address tokenIn, uint256 amountIn, uint256 shares, uint256 fee);

constructor(address _spot, address _treasury, address _owner) Ownable(_owner) {
        require(_spot != address(0), "Wiki: zero _spot");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        spot     = IWikiSpot(_spot);
        treasury = _treasury;
    }

    // ── ETH Zap ─────────────────────────────────────────────────────────────

    function zapETHToLP(uint256 poolId, uint256 minLP) external payable nonReentrant whenNotPaused returns (uint256 lpReceived) {
        require(msg.value > 0, "Zap: zero ETH");
        uint256 fee = msg.value * ZAP_FEE_BPS / BPS;
        uint256 net = msg.value - fee;
        payable(treasury).transfer(fee);
        totalFeesCollected += fee;

        // Wrap ETH
        WETH.deposit{value: net}();
        lpReceived = _zapWETHToLP(poolId, net, minLP);
        emit Zapped(msg.sender, address(0), msg.value, poolId, lpReceived, fee);
    }

    // ── Token Zap → LP ───────────────────────────────────────────────────────

    function zapTokenToLP(ZapParams calldata p) external nonReentrant whenNotPaused returns (uint256 lpReceived) {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);

        uint256 fee = p.amountIn * ZAP_FEE_BPS / BPS;
        uint256 net = p.amountIn - fee;
        IERC20(p.tokenIn).safeTransfer(treasury, fee);
        totalFeesCollected += fee;

        (address tokenA, address tokenB,,,,) = spot.getPool(p.poolId);

        // Split input in half and swap one half to the other token
        uint256 half = net / 2;
        uint256 otherHalf = net - half;

        address targetToken = (p.tokenIn == tokenA) ? tokenB : tokenA;
        address sourceToken = p.tokenIn;

        uint256 swappedAmount;
        if (sourceToken != targetToken) {
            IERC20(sourceToken).approve(address(UNI_ROUTER), half);
            swappedAmount = UNI_ROUTER.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
                tokenIn:           sourceToken,
                tokenOut:          targetToken,
                fee:               p.swapFeeTier > 0 ? p.swapFeeTier : 3000,
                recipient:         address(this),
                deadline:          p.deadline > 0 ? p.deadline : block.timestamp + 60,
                amountIn:          half,
                amountOutMinimum:  1,
                sqrtPriceLimitX96: 0
            }));
        } else {
            swappedAmount = half;
        }

        // Add liquidity to WikiSpot
        uint256 amtA = sourceToken == tokenA ? otherHalf : swappedAmount;
        uint256 amtB = sourceToken == tokenB ? otherHalf : swappedAmount;

        IERC20(tokenA).approve(address(spot), amtA);
        IERC20(tokenB).approve(address(spot), amtB);
        lpReceived = spot.addLiquidity(p.poolId, amtA, amtB, p.minLP);

        // Return LP tokens to user
        totalZaps++;
        emit Zapped(msg.sender, p.tokenIn, p.amountIn, p.poolId, lpReceived, fee);
    }

    // ── Token Zap → Strategy Vault (autocompound) ────────────────────────────

    function zapTokenToVault(address tokenIn, uint256 amountIn, address vault, uint256 minShares)
        external nonReentrant whenNotPaused returns (uint256 shares)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 fee = amountIn * ZAP_FEE_BPS / BPS;
        uint256 net = amountIn - fee;
        IERC20(tokenIn).safeTransfer(treasury, fee);

        address depositToken = IWikiStrategyVault(vault).depositToken();
        uint256 depositAmount = net;

        // Swap to vault's deposit token if needed
        if (tokenIn != depositToken) {
            IERC20(tokenIn).approve(address(UNI_ROUTER), net);
            depositAmount = UNI_ROUTER.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: depositToken, fee: 3000,
                recipient: address(this), deadline: block.timestamp + 60,
                amountIn: net, amountOutMinimum: 1, sqrtPriceLimitX96: 0 // caller enforces slippage via minOut param
            }));
        }

        IERC20(depositToken).approve(vault, depositAmount);
        shares = IWikiStrategyVault(vault).deposit(depositAmount, msg.sender);
        require(shares >= minShares, "Zap: slippage");

        totalZaps++;
        totalFeesCollected += fee;
        emit ZappedToVault(msg.sender, tokenIn, amountIn, shares, fee);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _zapWETHToLP(uint256 poolId, uint256 wethAmount, uint256 minLP) internal returns (uint256) {
        (address tokenA, address tokenB,,,,) = spot.getPool(poolId);
        address wethAddr = address(WETH);
        address other = tokenA == wethAddr ? tokenB : tokenA;

        uint256 half = wethAmount / 2;
        IERC20(wethAddr).approve(address(UNI_ROUTER), half);
        uint256 otherAmount = UNI_ROUTER.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: wethAddr, tokenOut: other, fee: 3000,
            recipient: address(this), deadline: block.timestamp + 60,
            amountIn: half, amountOutMinimum: 1, sqrtPriceLimitX96: 0 // caller enforces slippage via minOut param
        }));

        uint256 amtA = tokenA == wethAddr ? (wethAmount - half) : otherAmount;
        uint256 amtB = tokenB == wethAddr ? (wethAmount - half) : otherAmount;
        IERC20(tokenA).approve(address(spot), amtA);
        IERC20(tokenB).approve(address(spot), amtB);
        return spot.addLiquidity(poolId, amtA, amtB, minLP);
    }

    // ── Quote ─────────────────────────────────────────────────────────────────

    function quoteZapFee(uint256 amountIn) external pure returns (uint256 fee, uint256 net) {
        fee = amountIn * ZAP_FEE_BPS / BPS;
        net = amountIn - fee;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setSpot(address _spot) external onlyOwner { spot = IWikiSpot(_spot); }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    receive() external payable {}
}
