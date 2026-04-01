// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title RadiantAdapter — IExternalLender adapter for Radiant Capital on Arbitrum
 *
 * Radiant V5 uses the same interface as Aave V5/V3 (fork).
 * Lending Pool on Arbitrum: 0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1
 * rUSDC (interest-bearing):  0x0D914606f3424804FA1BbBE56CCC3416733acEC6
 */

interface IRadiantPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration, uint128 liquidityIndex, uint128 currentLiquidityRate,
        uint128 variableBorrowIndex, uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id,
        address aTokenAddress, address stableDebtTokenAddress,
        address variableDebtTokenAddress, address interestRateStrategyAddress,
        uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt
    );
}

interface IExternalLender {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getAPY() external view returns (uint256 apyBps);
    function getBalance(address asset) external view returns (uint256);
}

contract RadiantAdapter
    // Events
    // AUDIT: emit events on all state changes
 is IExternalLender, Ownable2Step {
    using SafeERC20 for IERC20;

    IRadiantPool public constant RADIANT_POOL = IRadiantPool(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);
    address      public constant R_USDC       = 0x0D914606f3424804FA1BbBE56CCC3416733acEC6;
    address      public constant USDC         = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256      public constant RAY          = 1e27;
    address public aggregator;

    constructor(address _aggregator, address _owner) Ownable(_owner) { aggregator = _aggregator; }

    modifier onlyAggregator() { require(msg.sender == aggregator || msg.sender == owner(), "not aggregator"); _; }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external nonReentrant override onlyAggregator {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).approve(address(RADIANT_POOL), amount);
        RADIANT_POOL.deposit(asset, amount, onBehalfOf, referralCode);
    }

    function withdraw(address asset, uint256 amount, address to) external nonReentrant override onlyAggregator returns (uint256) {
        return RADIANT_POOL.withdraw(asset, amount, to);
    }

    function getAPY() external view override returns (uint256 apyBps) {
        try RADIANT_POOL.getReserveData(USDC) returns (
            uint256, uint128, uint128 rate, uint128, uint128, uint128, uint40, uint16,
            address, address, address, address, uint128, uint128, uint128
        ) {
            apyBps = uint256(rate) * 365 days * 10000 / RAY;
        } catch { apyBps = 350; }
    }

    function getBalance(address) external view override returns (uint256) {
        return IERC20(R_USDC).balanceOf(address(this));
    }

    function setAggregator(address a) external onlyOwner { aggregator = a; }
    function emergencyWithdraw() external onlyOwner { RADIANT_POOL.withdraw(USDC, type(uint256).max, owner()); }
    event RadiantWithdraw(address indexed user, address token, uint256 amount);
}
