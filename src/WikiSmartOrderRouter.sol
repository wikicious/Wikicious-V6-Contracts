// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiSmartOrderRouter — DEX Aggregator with Fee Capture
 *
 * Routes trades through the best available liquidity source to minimise slippage.
 * Sources checked: WikiSpot (internal) → Uniswap V3 → Curve → Balancer
 *
 * REVENUE MODEL
 * Aggregator fee: 0.07% on all routed trades (charged on top of DEX fees)
 * This is the "convenience fee" for finding the optimal path.
 *
 * ROUTING LOGIC
 * 1. Quote WikiSpot internal pool (0 external call needed)
 * 2. Quote Uniswap V3 (via QuoterV5) for same pair
 * 3. Quote Curve (if stable pair)
 * 4. Select route with best amountOut - routerFee
 * 5. Execute via that DEX
 *
 * MULTI-HOP
 * If no direct route exists (e.g. LINK → rETH):
 *   LINK → WETH (Uniswap V3) → rETH (Curve/Balancer)
 *   Router fee applies once on the total input.
 */

interface IWikiSpot {
    function swapExactIn(uint256 poolId, address tokenIn, uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline) external returns (uint256);
    function getAmountOut(uint256 poolId, address tokenIn, uint256 amountIn) external view returns (uint256);
}

interface IUniV3Quoter {
    function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160) external returns (uint256 amountOut);
}

interface IUniV3Router {
    struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface ICurvePool {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract WikiSmartOrderRouter is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IWikiSpot   public wikiSpot;
    IUniV3Quoter public constant UNI_QUOTER  = IUniV3Quoter(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);
    IUniV3Router public constant UNI_ROUTER  = IUniV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address      public constant WETH        = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint256 public constant AGGREGATOR_FEE_BPS = 7;     // 0.07%
    uint256 public constant BPS                = 10000;

    enum Route { WIKI, UNI_V3_LOW, UNI_V3_MED, UNI_V3_HIGH, CURVE }

    struct RouteQuote {
        Route   route;
        uint256 amountOut;
        uint256 fee;
        uint256 gasEst;
    }

    struct PoolMapping {
        uint256 wikiPoolId;
        uint24  uniFeeTier;
        address curvePool;
        int128  curveI;
        int128  curveJ;
    }

    mapping(bytes32 => PoolMapping) public poolMappings; // keccak256(tokenA,tokenB) → mapping

    address public treasury;
    uint256 public totalRouted;
    uint256 public totalFeesCollected;
    mapping(Route => uint256) public routeVolume;

    event Routed(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, Route route, uint256 fee);

    constructor(address _wikiSpot, address _treasury, address _owner) Ownable(_owner) {
        require(_wikiSpot != address(0), "Wiki: zero _wikiSpot");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        wikiSpot = IWikiSpot(_wikiSpot);
        treasury = _treasury;
    }

    // ── Quote Best Route ──────────────────────────────────────────────────────

    function getBestQuote(address tokenIn, address tokenOut, uint256 amountIn)
        public returns (RouteQuote memory best)
    {
        uint256 fee = amountIn * AGGREGATOR_FEE_BPS / BPS;
        uint256 netIn = amountIn - fee;

        bytes32 key = keccak256(abi.encodePacked(tokenIn < tokenOut ? tokenIn : tokenOut, tokenIn < tokenOut ? tokenOut : tokenIn));
        PoolMapping storage pm = poolMappings[key];

        // 1. WikiSpot internal (cheapest gas)
        if (pm.wikiPoolId > 0) {
            try wikiSpot.getAmountOut(pm.wikiPoolId, tokenIn, netIn) returns (uint256 out) {
                if (out > best.amountOut) best = RouteQuote({ route:Route.WIKI, amountOut:out, fee:fee, gasEst:80000 });
            } catch {}
        }

        // 2. Uniswap V3 (0.05% pool)
        try UNI_QUOTER.quoteExactInputSingle(tokenIn, tokenOut, 500, netIn, 0) returns (uint256 out) {
            if (out > best.amountOut) best = RouteQuote({ route:Route.UNI_V3_LOW, amountOut:out, fee:fee, gasEst:150000 });
        } catch {}

        // 3. Uniswap V3 (0.3% pool)
        try UNI_QUOTER.quoteExactInputSingle(tokenIn, tokenOut, 3000, netIn, 0) returns (uint256 out) {
            if (out > best.amountOut) best = RouteQuote({ route:Route.UNI_V3_MED, amountOut:out, fee:fee, gasEst:150000 });
        } catch {}

        // 4. Curve (if stable)
        if (pm.curvePool != address(0)) {
            try ICurvePool(pm.curvePool).get_dy(pm.curveI, pm.curveJ, netIn) returns (uint256 out) {
                if (out > best.amountOut) best = RouteQuote({ route:Route.CURVE, amountOut:out, fee:fee, gasEst:120000 });
            } catch {}
        }
    }

    // ── Execute ───────────────────────────────────────────────────────────────

    function swap(
        address tokenIn, address tokenOut,
        uint256 amountIn, uint256 minOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Deduct aggregator fee
        uint256 fee = amountIn * AGGREGATOR_FEE_BPS / BPS;
        uint256 netIn = amountIn - fee;
        IERC20(tokenIn).safeTransfer(treasury, fee);
        totalFeesCollected += fee;

        // Find and execute best route
        RouteQuote memory best = getBestQuote(tokenIn, tokenOut, amountIn);
        require(best.amountOut >= minOut, "SOR: slippage exceeded");

        bytes32 key = keccak256(abi.encodePacked(tokenIn < tokenOut ? tokenIn : tokenOut, tokenIn < tokenOut ? tokenOut : tokenIn));
        PoolMapping storage pm = poolMappings[key];

        if (best.route == Route.WIKI) {
            IERC20(tokenIn).approve(address(wikiSpot), netIn);
            amountOut = wikiSpot.swapExactIn(pm.wikiPoolId, tokenIn, netIn, minOut, msg.sender, deadline);
        } else if (best.route == Route.UNI_V3_LOW || best.route == Route.UNI_V3_MED) {
            uint24 feeTier = best.route == Route.UNI_V3_LOW ? 500 : 3000;
            IERC20(tokenIn).approve(address(UNI_ROUTER), netIn);
            amountOut = UNI_ROUTER.exactInputSingle(IUniV3Router.ExactInputSingleParams({
                tokenIn:tokenIn, tokenOut:tokenOut, fee:feeTier,
                recipient:msg.sender, deadline:deadline, amountIn:netIn,
                amountOutMinimum:minOut, sqrtPriceLimitX96:0
            }));
        } else if (best.route == Route.CURVE && pm.curvePool != address(0)) {
            IERC20(tokenIn).approve(pm.curvePool, netIn);
            amountOut = ICurvePool(pm.curvePool).exchange(pm.curveI, pm.curveJ, netIn, minOut);
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        } else {
            revert("SOR: no valid route");
        }

        totalRouted += amountIn;
        routeVolume[best.route] += amountIn;
        emit Routed(msg.sender, tokenIn, tokenOut, amountIn, amountOut, best.route, fee);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setPoolMapping(address tokenA, address tokenB, uint256 wikiPoolId, uint24 uniFee, address curvePool, int128 curveI, int128 curveJ) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA));
        poolMappings[key] = PoolMapping({ wikiPoolId:wikiPoolId, uniFeeTier:uniFee, curvePool:curvePool, curveI:curveI, curveJ:curveJ });
    }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function setWikiSpot(address s) external onlyOwner { wikiSpot = IWikiSpot(s); }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
