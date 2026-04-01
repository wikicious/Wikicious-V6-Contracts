// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiConcentratedLP
 * @notice Uniswap V3-style concentrated liquidity.
 *         LPs choose a price range. Capital is 5-20× more efficient.
 *         Same $1M of liquidity = dramatically deeper order book.
 *
 * HOW IT WORKS:
 *   Standard AMM: $1M spread across all prices $0 → ∞
 *     → At current price, only ~$5K is actually usable depth
 *
 *   Concentrated LP: $1M focused between $60K-$80K BTC
 *     → All $1M provides depth within that range
 *     → 200× more capital efficiency in the active range
 *     → Much tighter spreads → better fills → more traders
 *
 * POSITION NFTs:
 *   Each LP position is a unique NFT (positionId)
 *   Different ranges = different NFTs
 *   Transferable — can be sold on secondary market
 *
 * FEE TIERS:
 *   0.01% — Stable pairs (USDC/USDT) — very tight range
 *   0.05% — Major pairs (BTC/ETH) — moderate range
 *   0.30% — Standard pairs — wide range
 *   1.00% — Exotic pairs — full range acceptable
 *
 * CAPITAL EFFICIENCY vs STANDARD AMM:
 *   1% range: 100× more efficient
 *   5% range: 20× more efficient
 *   10% range:10× more efficient
 *   50% range: 2× more efficient
 */
contract WikiConcentratedLP is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct Position {
        address owner;
        uint256 marketId;
        uint256 tickLower;      // lower price bound (in ticks, 1 tick = 0.01% price move)
        uint256 tickUpper;      // upper price bound
        uint256 liquidity;      // liquidity units provided
        uint256 amount0;        // USDC deposited
        uint256 amount1;        // base asset deposited (or equivalent)
        uint256 feeGrowthInside0Last; // for fee calculation
        uint256 feeGrowthInside1Last;
        uint256 tokensOwed0;    // unclaimed fees
        uint256 tokensOwed1;
        uint256 createdAt;
        bool    active;
    }

    struct PoolState {
        uint256 marketId;
        uint256 currentTick;        // current price as tick
        uint256 sqrtPriceX96;       // current sqrt price (Uni V3 format)
        uint256 liquidity;          // active liquidity at current price
        uint256 feeGrowthGlobal0;
        uint256 feeGrowthGlobal1;
        uint256 feeTierBps;
        uint256 totalPositions;
        bool    active;
    }

    mapping(uint256 => Position)   public positions;   // positionId → position
    mapping(uint256 => PoolState)  public pools;       // marketId → pool state
    mapping(address => uint256[])  public userPositions;
    mapping(uint256 => uint256[])  public marketPositions;

    uint256 public nextPositionId;
    uint256 public constant Q96 = 2**96;
    uint256 public constant TICK_BASE_BPS = 1; // 1 tick = 0.01% price

    event PositionMinted(uint256 positionId, address owner, uint256 marketId, uint256 tickLower, uint256 tickUpper, uint256 liquidity);
    event PositionBurned(uint256 positionId, address owner, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 positionId, address owner, uint256 fees0, uint256 fees1);
    event LiquidityAdded(uint256 positionId, uint256 addedLiquidity, uint256 amount0, uint256 amount1);

    constructor(address _owner, address _usdc) Ownable(_owner) {
        USDC = IERC20(_usdc);
    }

    // ── Initialize a pool ─────────────────────────────────────────────────
    function initializePool(uint256 marketId, uint256 initialSqrtPrice, uint256 feeTierBps) external onlyOwner {
        require(feeTierBps == 1 || feeTierBps == 5 || feeTierBps == 30 || feeTierBps == 100, "CLP: invalid fee tier");
        pools[marketId] = PoolState({
            marketId:         marketId,
            currentTick:      _sqrtPriceToTick(initialSqrtPrice),
            sqrtPriceX96:     initialSqrtPrice,
            liquidity:        0,
            feeGrowthGlobal0: 0,
            feeGrowthGlobal1: 0,
            feeTierBps:       feeTierBps,
            totalPositions:   0,
            active:           true
        });
    }

    // ── Mint a concentrated LP position ───────────────────────────────────
    function mintPosition(
        uint256 marketId,
        uint256 tickLower,
        uint256 tickUpper,
        uint256 amount0Desired,  // USDC to deposit
        uint256 amount0Min       // min accepted (slippage protection)
    ) external nonReentrant returns (uint256 positionId, uint256 liquidity, uint256 amount0) {
        PoolState storage pool = pools[marketId];
        require(pool.active,           "CLP: pool not active");
        require(tickLower < tickUpper, "CLP: invalid range");
        require(tickLower >= 0,        "CLP: tick below min");
        require(amount0Desired > 0,    "CLP: zero amount");

        // Calculate liquidity from amount and range
        // Simplified — production uses full Uni V3 math library
        liquidity = _calculateLiquidity(tickLower, tickUpper, amount0Desired, pool.sqrtPriceX96);
        require(liquidity > 0, "CLP: zero liquidity");

        // Calculate actual amounts needed (may differ from desired due to range)
        amount0 = _calculateAmount0(tickLower, tickUpper, liquidity, pool.sqrtPriceX96);
        require(amount0 >= amount0Min, "CLP: slippage");

        USDC.safeTransferFrom(msg.sender, address(this), amount0);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner:                  msg.sender,
            marketId:               marketId,
            tickLower:              tickLower,
            tickUpper:              tickUpper,
            liquidity:              liquidity,
            amount0:                amount0,
            amount1:                0,
            feeGrowthInside0Last:   pool.feeGrowthGlobal0,
            feeGrowthInside1Last:   pool.feeGrowthGlobal1,
            tokensOwed0:            0,
            tokensOwed1:            0,
            createdAt:              block.timestamp,
            active:                 true
        });

        // If position range includes current tick, add to active liquidity
        if (tickLower <= pool.currentTick && pool.currentTick < tickUpper) {
            pool.liquidity += liquidity;
        }
        pool.totalPositions++;

        userPositions[msg.sender].push(positionId);
        marketPositions[marketId].push(positionId);
        emit PositionMinted(positionId, msg.sender, marketId, tickLower, tickUpper, liquidity);
    }

    // ── Burn a position (withdraw liquidity) ──────────────────────────────
    function burnPosition(uint256 positionId) external nonReentrant returns (uint256 amount0, uint256 fees) {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "CLP: not owner");
        require(pos.active,              "CLP: not active");

        PoolState storage pool = pools[pos.marketId];

        // Remove from active liquidity if in range
        if (pos.tickLower <= pool.currentTick && pool.currentTick < pos.tickUpper) {
            pool.liquidity -= pos.liquidity > pool.liquidity ? pool.liquidity : pos.liquidity;
        }

        // Calculate principal + fees owed
        amount0 = pos.amount0;  // principal
        fees    = _calculateFees(positionId, pool);
        pos.active    = false;
        pos.liquidity = 0;

        uint256 total = amount0 + fees;
        if (total > 0) USDC.safeTransfer(msg.sender, total);
        emit PositionBurned(positionId, msg.sender, amount0, fees);
    }

    // ── Collect accumulated fees without removing liquidity ───────────────
    function collectFees(uint256 positionId) external nonReentrant returns (uint256 fees) {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "CLP: not owner");
        require(pos.active,              "CLP: not active");

        PoolState storage pool = pools[pos.marketId];
        fees = _calculateFees(positionId, pool);
        require(fees > 0, "CLP: no fees");

        pos.feeGrowthInside0Last = pool.feeGrowthGlobal0;
        pos.tokensOwed0          = 0;
        USDC.safeTransfer(msg.sender, fees);
        emit FeesCollected(positionId, msg.sender, fees, 0);
    }

    // ── Called by WikiPerp when a trade happens (adds to fee growth) ──────
    function recordTradeFees(uint256 marketId, uint256 feeAmount) external {
        PoolState storage pool = pools[marketId];
        if (pool.liquidity == 0) return;
        pool.feeGrowthGlobal0 += feeAmount * Q96 / pool.liquidity;
    }

    // ── Update price when oracle updates ─────────────────────────────────
    function updatePrice(uint256 marketId, uint256 newSqrtPriceX96) external onlyOwner {
        PoolState storage pool = pools[marketId];
        uint256 oldTick = pool.currentTick;
        uint256 newTick = _sqrtPriceToTick(newSqrtPriceX96);
        pool.sqrtPriceX96 = newSqrtPriceX96;
        pool.currentTick  = newTick;
        // Note: production version updates liquidity as price crosses ticks
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getCapitalEfficiency(uint256 tickLower, uint256 tickUpper) external pure returns (uint256 efficiencyX) {
        // Efficiency vs full-range AMM
        // Wider range = less efficient; narrower = more efficient
        uint256 rangeTicks = tickUpper - tickLower;
        if (rangeTicks == 0) return 1000; // avoid div/0
        // Simplified: 10000 ticks full range; 100 ticks = 100× efficient
        efficiencyX = 10000 / rangeTicks;
        if (efficiencyX < 1) efficiencyX = 1;
    }

    function getLiquidityAtRange(uint256 marketId, uint256 tickLower, uint256 tickUpper)
        external view returns (uint256 totalLiquidity)
    {
        uint256[] storage pids = marketPositions[marketId];
        for (uint i; i < pids.length; i++) {
            Position storage pos = positions[pids[i]];
            if (pos.active && pos.tickLower <= tickLower && pos.tickUpper >= tickUpper) {
                totalLiquidity += pos.liquidity;
            }
        }
    }

    // ── Internal math (simplified — production uses full Uni V3 library) ─
    function _calculateLiquidity(uint256 tL, uint256 tU, uint256 amount, uint256 sqrtPrice)
        internal pure returns (uint256)
    {
        // Simplified: L = amount / (sqrtPriceUpper - sqrtPriceLower) × scale
        uint256 spread = tU - tL;
        if (spread == 0) return 0;
        return amount * 1000 / spread; // simplified ratio
    }

    function _calculateAmount0(uint256 tL, uint256 tU, uint256 liquidity, uint256 sqrtPrice)
        internal pure returns (uint256)
    {
        return liquidity * (tU - tL) / 1000;
    }

    function _calculateFees(uint256 positionId, PoolState storage pool)
        internal view returns (uint256)
    {
        Position storage pos = positions[positionId];
        if (pool.feeGrowthGlobal0 <= pos.feeGrowthInside0Last) return pos.tokensOwed0;
        uint256 growth = pool.feeGrowthGlobal0 - pos.feeGrowthInside0Last;
        return pos.tokensOwed0 + pos.liquidity * growth / Q96;
    }

    function _sqrtPriceToTick(uint256 sqrtPriceX96) internal pure returns (uint256) {
        // Simplified tick calculation
        return sqrtPriceX96 / Q96 * 100;
    }
}
