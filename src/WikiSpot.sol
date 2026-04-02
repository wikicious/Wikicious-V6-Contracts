// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title WikiSpot — Constant-product AMM for spot token swaps
/// @notice x*y=k AMM, like Uniswap V5, with protocol fee
contract WikiSpot is Ownable2Step, ReentrancyGuard {
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

    struct Pool {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalLP;
        uint256 feeBps;        // swap fee, e.g. 30 = 0.3%
        uint256 volumeA;
        uint256 volumeB;
        bool    active;
    }

    Pool[]  public pools;
    mapping(bytes32 => uint256)            public pairToPool;
    mapping(uint256 => mapping(address => uint256)) public lpBalances;

    uint256 public constant PROTOCOL_FEE_BPS = 5; // 0.05% to protocol
    uint256 public constant BPS = 10000;
    address public protocolFeeRecipient;

    event PoolCreated(uint256 indexed poolId, address tokenA, address tokenB);
    event LiquidityAdded(uint256 indexed poolId, address indexed lp, uint256 amtA, uint256 amtB, uint256 lpMinted);
    event LiquidityRemoved(uint256 indexed poolId, address indexed lp, uint256 amtA, uint256 amtB, uint256 lpBurned);
    event Swap(uint256 indexed poolId, address indexed trader, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut);

    constructor(address owner, address feeRecipient) Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        require(feeRecipient != address(0), "Wiki: zero feeRecipient");
        _transferOwnership(owner);
        protocolFeeRecipient = feeRecipient;
    }

    // ── Pool Management ───────────────────────────────────────
    function createPool(address tokenA, address tokenB, uint256 feeBps)
        external onlyOwner returns (uint256 poolId)
    {
        require(tokenA != tokenB, "Spot: same tokens");
        require(feeBps <= 100, "Spot: fee too high");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 key = keccak256(abi.encodePacked(t0, t1));
        require(pairToPool[key] == 0 && pools.length == 0 || pairToPool[key] == 0, "Spot: pool exists");

        poolId = pools.length;
        pools.push(Pool({ tokenA:t0, tokenB:t1, reserveA:0, reserveB:0, totalLP:0, feeBps:feeBps, volumeA:0, volumeB:0, active:true }));
        pairToPool[key] = poolId + 1; // +1 so 0 means not found
        emit PoolCreated(poolId, t0, t1);
    }

    // ── Liquidity ─────────────────────────────────────────────
    function addLiquidity(uint256 poolId, uint256 amtA, uint256 amtB, uint256 minLP)
        external nonReentrant returns (uint256 lpMinted)
    {
        Pool storage p = pools[poolId];
        require(p.active, "Spot: pool inactive");

        IERC20(p.tokenA).safeTransferFrom(msg.sender, address(this), amtA);
        IERC20(p.tokenB).safeTransferFrom(msg.sender, address(this), amtB);

        if (p.totalLP == 0) {
            lpMinted = _sqrt(amtA * amtB);
        } else {
            uint256 lpA = amtA * p.totalLP / p.reserveA;
            uint256 lpB = amtB * p.totalLP / p.reserveB;
            lpMinted = lpA < lpB ? lpA : lpB;
        }
        require(lpMinted >= minLP, "Spot: insufficient LP");

        p.reserveA += amtA;
        p.reserveB += amtB;
        p.totalLP  += lpMinted;
        lpBalances[poolId][msg.sender] += lpMinted;

        emit LiquidityAdded(poolId, msg.sender, amtA, amtB, lpMinted);
    }

    function removeLiquidity(uint256 poolId, uint256 lpAmount, uint256 minA, uint256 minB)
        external nonReentrant returns (uint256 amtA, uint256 amtB)
    {
        Pool storage p = pools[poolId];
        require(lpBalances[poolId][msg.sender] >= lpAmount, "Spot: insufficient LP");

        amtA = lpAmount * p.reserveA / p.totalLP;
        amtB = lpAmount * p.reserveB / p.totalLP;
        require(amtA >= minA && amtB >= minB, "Spot: slippage");

        lpBalances[poolId][msg.sender] -= lpAmount;
        p.totalLP  -= lpAmount;
        p.reserveA -= amtA;
        p.reserveB -= amtB;

        IERC20(p.tokenA).safeTransfer(msg.sender, amtA);
        IERC20(p.tokenB).safeTransfer(msg.sender, amtB);
        emit LiquidityRemoved(poolId, msg.sender, amtA, amtB, lpAmount);
    }

    // ── Swap ──────────────────────────────────────────────────
    function swapExactIn(
        uint256 poolId, address tokenIn, uint256 amtIn, uint256 minOut, address recipient
    ) external nonReentrant returns (uint256 amtOut) {
        Pool storage p = pools[poolId];
        require(p.active, "Spot: inactive");
        require(tokenIn == p.tokenA || tokenIn == p.tokenB, "Spot: wrong token");

        bool aToB = tokenIn == p.tokenA;
        (uint256 rIn, uint256 rOut) = aToB ? (p.reserveA, p.reserveB) : (p.reserveB, p.reserveA);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amtIn);

        // Protocol fee
        uint256 protFee = amtIn * PROTOCOL_FEE_BPS / BPS;
        uint256 swapFee = amtIn * p.feeBps / BPS;
        uint256 netIn   = amtIn - protFee - swapFee;

        // x*y=k
        amtOut = (netIn * rOut) / (rIn + netIn);
        require(amtOut >= minOut, "Spot: slippage exceeded");

        address tokenOut = aToB ? p.tokenB : p.tokenA;
        if (aToB) { p.reserveA += amtIn - protFee; p.reserveB -= amtOut; p.volumeA += amtIn; }
        else      { p.reserveB += amtIn - protFee; p.reserveA -= amtOut; p.volumeB += amtIn; }

        IERC20(tokenOut).safeTransfer(recipient, amtOut);
        if (protFee > 0) IERC20(tokenIn).safeTransfer(protocolFeeRecipient, protFee);

        emit Swap(poolId, msg.sender, tokenIn, amtIn, tokenOut, amtOut);
    }

    function getAmountOut(uint256 poolId, address tokenIn, uint256 amtIn)
        external view returns (uint256 amtOut, uint256 priceImpactBps)
    {
        Pool storage p = pools[poolId];
        bool aToB = tokenIn == p.tokenA;
        (uint256 rIn, uint256 rOut) = aToB ? (p.reserveA, p.reserveB) : (p.reserveB, p.reserveA);

        uint256 fees   = amtIn * (PROTOCOL_FEE_BPS + p.feeBps) / BPS;
        uint256 netIn  = amtIn - fees;
        amtOut         = (netIn * rOut) / (rIn + netIn);

        uint256 spotPrice = rOut * 1e18 / rIn;
        uint256 execPrice = amtOut * 1e18 / amtIn;
        priceImpactBps    = spotPrice > execPrice ? (spotPrice - execPrice) * BPS / spotPrice : 0;
    }

    function getPool(uint256 poolId) external view returns (Pool memory) { return pools[poolId]; }
    function poolCount() external view returns (uint256) { return pools.length; }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
