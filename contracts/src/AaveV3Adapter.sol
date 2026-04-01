// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title AaveV3Adapter — IExternalLender adapter for Aave V3 on Arbitrum
 *
 * Implements the IExternalLender interface that WikiYieldAggregator expects.
 * Deposits USDC into Aave V3 and earns aUSDC yield.
 *
 * Aave V3 Pool on Arbitrum: 0x794a61358D6845594F94dc1DB02A252b5b4814aD
 * aUSDC on Arbitrum:        0x724dc807b04555b71ed48a6896b6F41593b8C637
 */

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external nonReentrant;
    function withdraw(address asset, uint256 amount, address to) external nonReentrant returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40  lastUpdateTimestamp,
        uint16  id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    );
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

interface IExternalLender {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external nonReentrant;
    function withdraw(address asset, uint256 amount, address to) external nonReentrant returns (uint256);
    function getAPY() external view returns (uint256 apyBps);
    function getBalance(address asset) external view returns (uint256);
}

contract AaveV3Adapter is IExternalLender, Ownable2Step, ReentrancyGuard{
    using SafeERC20 for IERC20;

    // Aave V3 Pool on Arbitrum mainnet
    IAaveV3Pool public constant AAVE_POOL = IAaveV3Pool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    // aUSDC on Arbitrum (interest-bearing USDC from Aave)
    IAToken public constant A_USDC = IAToken(0x724dc807b04555b71ed48a6896b6F41593b8C637);

    // USDC on Arbitrum
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Only WikiYieldAggregator can call supply/withdraw
    address public aggregator;

    uint256 public constant RAY = 1e27;
    

    constructor(address _aggregator, address _owner) Ownable(_owner) {
        aggregator = _aggregator;
    }

    modifier onlyAggregator() {
        require(msg.sender == aggregator || msg.sender == owner(), "Adapter: not aggregator");
        _;
    }

    // ── IExternalLender implementation ─────────────────────────────────────

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  referralCode
    ) external nonReentrant override onlyAggregator {
        require(asset == USDC, "Adapter: only USDC");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(AAVE_POOL), amount);
        AAVE_POOL.supply(asset, amount, onBehalfOf, referralCode);
        emit Supplied(amount, A_USDC.balanceOf(onBehalfOf));
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external nonReentrant override onlyAggregator returns (uint256 withdrawn) {
        require(asset == USDC, "Adapter: only USDC");
        // amount = type(uint256).max means withdraw all
        withdrawn = AAVE_POOL.withdraw(asset, amount, to);
        emit Withdrawn(withdrawn);
    }

    /**
     * @notice Returns current Aave USDC supply APY in basis points.
     * Aave stores rate in RAY (1e27) per second. Convert to annual BPS:
     *   APY_BPS = (liquidityRate / RAY) * seconds_per_year * 10000
     */
    function getAPY() external view override returns (uint256 apyBps) {
        try AAVE_POOL.getReserveData(USDC) returns (
            uint256, uint128, uint128 currentLiquidityRate,
            uint128, uint128, uint128, uint40, uint16,
            address, address, address, address, uint128, uint128, uint128
        ) {
            // currentLiquidityRate is in RAY (1e27) per second
            // Annual rate = rate * 365 days
            uint256 ratePerSecond  = uint256(currentLiquidityRate);
            uint256 ratePerYear    = ratePerSecond * 365 days;
            apyBps = ratePerYear * 10000 / RAY;
        } catch {
            apyBps = 400; // 4% fallback if call fails
        }
    }

    /**
     * @notice Returns current aUSDC balance (principal + accrued interest).
     */
    function getBalance(address /*asset*/) external view override returns (uint256) {
        return A_USDC.balanceOf(address(this));
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function setAggregator(address _aggregator) external onlyOwner {
        aggregator = _aggregator;
    }

    /**
     * @notice Emergency: withdraw all aUSDC to owner.
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 bal = A_USDC.balanceOf(address(this));
        if (bal > 0) AAVE_POOL.withdraw(USDC, type(uint256).max, owner());
    }
}
