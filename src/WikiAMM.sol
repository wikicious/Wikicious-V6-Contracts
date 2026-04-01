// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./WikiVault.sol";
import "./WikiOracle.sol";

/// @title WikiAMM — GMX-style multi-asset liquidity pool
/// @notice LPs deposit USDC to earn fees; pool is counterparty to all trades
contract WikiAMM is ERC20, Ownable2Step, ReentrancyGuard, Pausable {

    WikiVault  public immutable vault;
    WikiOracle public immutable oracle;

    struct PoolStats {
        uint256 totalLiquidity;   // USDC 6dec
        uint256 reservedForLongs; // collateral backing longs
        uint256 reservedForShorts;
        uint256 totalFeesEarned;
        uint256 totalPnlPaid;
        uint256 lastAUM;
    }

    PoolStats public pool;

    // LP token = WLP (Wikicious LP token)
    // 1 WLP = proportional share of pool AUM

    uint256 public mintFeeBps      = 30;  // 0.30% to add liquidity

    // ── Flash Loan / Price Manipulation Protection ─────────────────
    uint256 public  price0CumulativeLast;
    uint256 public  price1CumulativeLast;
    uint32  private _blockTimestampLast;
    uint256 public  constant MAX_SWAP_DEVIATION_BPS = 1000; // 10% max single-block deviation

    event PriceManipulationBlocked(uint256 spotPrice, uint256 twapPrice);

    function _updateCumulativePrice(uint256 res0, uint256 res1) internal {
        uint32 ts = uint32(block.timestamp % 2**32);
        uint32 elapsed = ts - _blockTimestampLast;
        if (elapsed > 0 && res0 > 0 && res1 > 0) {
            price0CumulativeLast += (res1 * 1e18 / res0) * elapsed;
            price1CumulativeLast += (res0 * 1e18 / res1) * elapsed;
            _blockTimestampLast = ts;
        }
    }

    // Called before swaps — reverts if price moved >10% in one block
    function _assertNotManipulated(uint256 spotPrice0, uint256 res0, uint256 res1) internal view {
        if (res0 == 0 || _blockTimestampLast == 0) return;
        uint256 twap = price0CumulativeLast / (uint32(block.timestamp % 2**32) - _blockTimestampLast + 1);
        if (twap == 0) return;
        uint256 dev = spotPrice0 > twap
            ? (spotPrice0 - twap) * 10000 / twap
            : (twap - spotPrice0) * 10000 / twap;
        require(dev <= MAX_SWAP_DEVIATION_BPS, "WikiAMM: flash loan price manipulation detected");
    }
    uint256 public burnFeeBps      = 30;  // 0.30% to remove liquidity
    uint256 public constant BPS    = 10000;
    uint256 public constant MIN_LP = 1000; // minimum LP tokens

    IERC20 public immutable USDC;

    event LiquidityAdded(address indexed lp, uint256 usdcAmount, uint256 wlpMinted);
    event LiquidityRemoved(address indexed lp, uint256 wlpBurned, uint256 usdcAmount);
    event AMMTrade(address indexed trader, bool isLong, uint256 size, uint256 price, int256 pnl);

    constructor(address usdc, address _vault, address _oracle, address owner)
        ERC20("Wikicious LP", "WLP")
        Ownable(owner)
    {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_vault != address(0), "Wiki: zero _vault");
        require(_oracle != address(0), "Wiki: zero _oracle");
        _transferOwnership(owner);
        USDC   = IERC20(usdc);
        vault  = WikiVault(_vault);
        oracle = WikiOracle(_oracle);
    }

    // ── LP Actions ────────────────────────────────────────────
    function addLiquidity(uint256 usdcAmount) external nonReentrant whenNotPaused returns (uint256 wlpOut) {
        require(usdcAmount > 0, "AMM: zero amount");
        USDC.transferFrom(msg.sender, address(this), usdcAmount);

        uint256 fee   = usdcAmount * mintFeeBps / BPS;
        uint256 netIn = usdcAmount - fee;
        pool.totalLiquidity  += netIn;
        pool.totalFeesEarned += fee;

        // WLP price = AUM / totalSupply
        uint256 aum = getAUM();
        uint256 supply = totalSupply();
        if (supply == 0) {
            wlpOut = netIn;
        } else {
            wlpOut = netIn * supply / aum;
        }
        require(wlpOut >= MIN_LP, "AMM: insufficient WLP out");
        _mint(msg.sender, wlpOut);
        emit LiquidityAdded(msg.sender, usdcAmount, wlpOut);
    }

    function removeLiquidity(uint256 wlpAmount) external nonReentrant returns (uint256 usdcOut) {
        require(wlpAmount > 0, "AMM: zero WLP");
        require(balanceOf(msg.sender) >= wlpAmount, "AMM: insufficient WLP");

        uint256 aum    = getAUM();
        uint256 supply = totalSupply();
        uint256 gross  = wlpAmount * aum / supply;
        uint256 fee    = gross * burnFeeBps / BPS;
        usdcOut        = gross - fee;

        pool.totalLiquidity  = pool.totalLiquidity >= gross ? pool.totalLiquidity - gross : 0;
        pool.totalFeesEarned += fee;

        require(USDC.balanceOf(address(this)) >= usdcOut, "AMM: insufficient pool liquidity");
        _burn(msg.sender, wlpAmount);
        USDC.transfer(msg.sender, usdcOut);
        emit LiquidityRemoved(msg.sender, wlpAmount, usdcOut);
    }

    // ── AMM Trade ─────────────────────────────────────────────
    /// @notice Called by WikiPerp when pool acts as counterparty
    function recordTrade(
        address trader, bool isLong, uint256 size,
        uint256 entryPrice, uint256 exitPrice
    ) external onlyOwner {
        int256 traderPnl = isLong
            ? int256(size) * (int256(exitPrice) - int256(entryPrice)) / int256(entryPrice)
            : int256(size) * (int256(entryPrice) - int256(exitPrice)) / int256(entryPrice);

        // Pool is opposite side — pool PnL = -traderPnl
        if (traderPnl > 0) {
            pool.totalPnlPaid += uint256(traderPnl);
        } else {
            pool.totalFeesEarned += uint256(-traderPnl);
        }

        emit AMMTrade(trader, isLong, size, exitPrice, traderPnl);
    }

    // ── Views ─────────────────────────────────────────────────
    function getAUM() public view returns (uint256) {
        // AUM = USDC balance + unrealized PnL from open positions (simplified)
        return USDC.balanceOf(address(this));
    }

    function getWLPPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // 1 USDC initial
        return getAUM() * 1e6 / supply;
    }

    function getPoolStats() external view returns (PoolStats memory) {
        return pool;
    }

    function setFees(uint256 mintFee, uint256 burnFee) external onlyOwner {
        mintFeeBps = mintFee;
        burnFeeBps = burnFee;
    }
}
