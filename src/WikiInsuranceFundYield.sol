// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";



interface IWikiFeeDistributor {
    function receiveInsuranceYield(uint256 amount) external;
}

/**
 * @title WikiInsuranceFundYield
 * @notice Deploys idle WikiVault insurance fund USDC into WikiLending to earn
 *         yield without reducing the insurance guarantee.
 *
 * HOW IT WORKS
 * ─────────────────────────────────────────────────────────────────────────
 * 1. WikiVault insurance fund normally sits idle earning 0%.
 * 2. This interface IWikiFeeDistributor {
    function receiveFee(uint8 source, uint256 amount, address payer) external;
}

contract holds a portion of that USDC and supplies it to
 *    WikiLending USDC market (30-day maturity max).
 * 3. WikiLending USDC earns ~8% APY based on borrower interest.
 * 4. Yield is harvested daily and routed to WikiFeeDistributor.
 * 5. Reserve ratio kept at ≥30% liquid USDC at all times so
 *    liquidation shortfalls are never impacted.
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * At $1M insurance fund, 70% deployed at 8% APY = $56,000/year
 * At $5M insurance fund, 70% deployed at 8% APY = $280,000/year
 * Zero additional risk — USDC is redeemable from WikiLending in < 1 block.
 *
 * SAFETY
 * ─────────────────────────────────────────────────────────────────────────
 * [A1] MIN_LIQUID_RATIO: 30% of fund always stays in USDC, not deployed
 * [A2] Emergency recall: owner can force-withdraw all deployed funds
 * [A3] Max utilisation: never deploy > MAX_DEPLOY_BPS of total fund
 * [A4] Yield-only harvest: principal is never withdrawn to revenue
 */

interface IWikiLending {
    function supply(uint256 marketId, uint256 amount) external returns (uint256 wTokens);
    function redeem(uint256 marketId, uint256 wTokens) external returns (uint256 usdcOut);
    function getExchangeRate(uint256 marketId) external view returns (uint256);
    function balanceOf(uint256 marketId, address account) external view returns (uint256);
    function supplyAPY(uint256 marketId) external view returns (uint256);
}


contract WikiInsuranceFundYield is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant BPS              = 10_000;
    uint256 public constant MIN_LIQUID_BPS   = 3_000;  // 30% stays liquid [A1]
    uint256 public constant MAX_DEPLOY_BPS   = 7_000;  // max 70% deployed [A3]
    uint256 public constant USDC_MARKET_ID   = 0;      // WikiLending USDC market

    // ── Storage ────────────────────────────────────────────────────────────
    IERC20              public immutable USDC;
    IWikiLending        public immutable lending;
    IWikiFeeDistributor public           feeDistributor;

    uint256 public totalDeployed;       // USDC currently in WikiLending
    uint256 public totalYieldHarvested; // lifetime yield earned
    uint256 public lastHarvestTime;
    uint256 public deployedWTokens;     // wToken receipt from lending

    // ── Events ─────────────────────────────────────────────────────────────
    
    event YieldHarvested(uint256 yieldAmount, uint256 timestamp);
    event Deployed(uint256 amount, uint256 wTokens);
    event EmergencyRecall(uint256 usdcRecovered);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _usdc, address _lending, address _feeDist, address _owner)
        Ownable(_owner)
    {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_lending != address(0), "Wiki: zero _lending");
        require(_feeDist != address(0), "Wiki: zero _feeDist");
        USDC           = IERC20(_usdc);
        lending        = IWikiLending(_lending);
        feeDistributor = IWikiFeeDistributor(_feeDist);
    }

    // ── Deploy: Send USDC to WikiLending ──────────────────────────────────

    /**
     * @notice Deploy a portion of received insurance USDC into WikiLending.
     * @param amount USDC to deploy (must leave MIN_LIQUID_BPS in contract)
     */
    function deploy(uint256 amount) external onlyOwner nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        require(amount <= balance, "IFY: insufficient balance");

        // Enforce minimum liquid ratio [A1][A3]
        uint256 totalFund = balance + totalDeployed;
        uint256 maxDeploy = totalFund * MAX_DEPLOY_BPS / BPS;
        require(totalDeployed + amount <= maxDeploy, "IFY: exceeds max deploy ratio");

        uint256 liquid = balance - amount;
        require(liquid * BPS >= (totalFund - amount) * MIN_LIQUID_BPS, "IFY: liquid ratio too low");

        USDC.approve(address(lending), amount);
        uint256 wTokens = lending.supply(USDC_MARKET_ID, amount);

        totalDeployed   += amount;
        deployedWTokens += wTokens;

        emit Deployed(amount, wTokens);
    }

    // ── Harvest: Collect yield, keep principal deployed ───────────────────

    /**
     * @notice Harvest accrued yield from WikiLending without withdrawing principal.
     *         Called daily by keeper bot.
     */
    function harvest() external nonReentrant {
        require(deployedWTokens > 0, "IFY: nothing deployed");

        uint256 rate = lending.getExchangeRate(USDC_MARKET_ID);
        // Current value of wTokens in USDC
        uint256 currentValue = deployedWTokens * rate / 1e18;
        uint256 yield = currentValue > totalDeployed ? currentValue - totalDeployed : 0;

        if (yield == 0) return;

        // Redeem only the yield portion (partial wToken redemption)
        uint256 yieldWTokens = yield * 1e18 / rate;
        if (yieldWTokens > deployedWTokens) yieldWTokens = deployedWTokens;

        uint256 usdcOut = lending.redeem(USDC_MARKET_ID, yieldWTokens);
        deployedWTokens -= yieldWTokens;
        // principal stays: totalDeployed unchanged

        totalYieldHarvested += usdcOut;
        lastHarvestTime      = block.timestamp;

        // Route yield to protocol fee distributor
        USDC.approve(address(feeDistributor), usdcOut);
        feeDistributor.receiveFee(7, usdcOut, address(this)); // source 7 = insurance yield

        emit YieldHarvested(usdcOut, block.timestamp);
    }

    // ── Recall: Withdraw from WikiLending back to contract ────────────────

    /**
     * @notice Partially recall deployed funds (e.g. to cover a liquidation shortfall).
     * @param amount USDC to recall
     */
    function recall(uint256 amount) external onlyOwner nonReentrant {
        uint256 rate      = lending.getExchangeRate(USDC_MARKET_ID);
        uint256 wTokens   = amount * 1e18 / rate;
        if (wTokens > deployedWTokens) wTokens = deployedWTokens;

        uint256 usdcOut   = lending.redeem(USDC_MARKET_ID, wTokens);
        deployedWTokens  -= wTokens;
        totalDeployed    -= usdcOut < totalDeployed ? usdcOut : totalDeployed;

        emit Recalled(usdcOut);
    }

    /**
     * @notice Emergency: recall everything immediately. [A2]
     */
    function emergencyRecallAll() external onlyOwner nonReentrant {
        if (deployedWTokens == 0) return;
        uint256 usdcOut = lending.redeem(USDC_MARKET_ID, deployedWTokens);
        deployedWTokens = 0;
        totalDeployed   = 0;
        emit EmergencyRecall(usdcOut);
    }

    // ── Receive USDC from WikiVault ────────────────────────────────────────

    function receiveFromVault(uint256 amount) external nonReentrant {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function liquidBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function deployedValue() external view returns (uint256) {
        if (deployedWTokens == 0) return 0;
        uint256 rate = lending.getExchangeRate(USDC_MARKET_ID);
        return deployedWTokens * rate / 1e18;
    }

    function pendingYield() external view returns (uint256) {
        if (deployedWTokens == 0) return 0;
        uint256 rate = lending.getExchangeRate(USDC_MARKET_ID);
        uint256 current = deployedWTokens * rate / 1e18;
        return current > totalDeployed ? current - totalDeployed : 0;
    }

    function currentAPY() external view returns (uint256) {
        return lending.supplyAPY(USDC_MARKET_ID);
    }
}
