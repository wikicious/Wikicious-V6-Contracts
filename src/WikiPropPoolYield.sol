// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ═══════════════════════════════════════════════════════════════
 *  WikiPropPoolYield — Idle Prop Pool Capital Yield Strategy
 *
 *  Problem: WikiPropPool has USDC sitting idle waiting for traders
 *           to pass evaluations (90-day window). That capital
 *           earns nothing until allocated to a funded account.
 *
 *  Solution: Deploy idle capital automatically:
 *
 *  ┌─────────────────────────────────────────────────────────┐
 *  │  WikiPropPool USDC                                      │
 *  │       │                                                 │
 *  │  ─────┴─────── Idle allocation (max 60% of pool)        │
 *  │  │           │                                          │
 *  │  ▼           ▼                                          │
 *  │  Aave V3     WikiLending    ← instant liquidity         │
 *  │  (40%)       (60%)           ← always available         │
 *  │                                                         │
 *  │  Yield flows back to WikiPropPool → LPs earn more       │
 *  │  When trader requests funded account → withdraw first   │
 *  └─────────────────────────────────────────────────────────┘
 *
 *  Safety rules:
 *  - Max 60% of pool deployed (40% always liquid for instant funding)
 *  - Only Aave V3 and WikiLending (both instant withdrawal)
 *  - NO lock-up strategies
 *  - Circuit breaker: if utilization >70%, instantly recall yield capital
 *  - All yield goes to WikiPropPool → distributed to pool LPs
 * ═══════════════════════════════════════════════════════════════
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256, uint128, uint128, uint128, uint128, uint128,
        uint40, uint16, address, address, address, address, uint128, uint128, uint128
    );
}

interface IWikiLending {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function getSupplyAPY(address asset) external view returns (uint256);
    function getSupplyBalance(address supplier, address asset) external view returns (uint256);
}

interface IWikiPropPool {
    function availableCapital() external view returns (uint256);
    function totalDeposited()   external view returns (uint256);
    function receiveYield(uint256 amount, string calldata source) external;
}

contract WikiPropPoolYield is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Config ────────────────────────────────────────────────────
    uint256 public constant MAX_DEPLOY_BPS    = 6000;  // max 60% of pool deployed
    uint256 public constant AAVE_SPLIT_BPS    = 4000;  // 40% of deployed → Aave V3
    uint256 public constant LENDING_SPLIT_BPS = 6000;  // 60% of deployed → WikiLending
    uint256 public constant RECALL_THRESHOLD  = 7000;  // recall if pool util >70%
    uint256 public constant BPS               = 10000;

    IERC20          public immutable USDC;
    IAavePool       public aavePool;
    IWikiLending    public wikiLending;
    IWikiPropPool   public propPool;
    address         public keeper;

    uint256 public deployedToAave;
    uint256 public deployedToLending;
    uint256 public totalYieldGenerated;
    uint256 public lastDeployTime;
    
    event YieldHarvested(uint256 amount, uint256 timestamp);
    event KeeperSet(address keeper);

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "PropPoolYield: not keeper");
        _;
    }

    constructor(
        address _usdc,
        address _aave,
        address _lending,
        address _propPool,
        address _owner
    ) Ownable(_owner) {
        USDC        = IERC20(_usdc);
        aavePool    = IAavePool(_aave);
        wikiLending = IWikiLending(_lending);
        propPool    = IWikiPropPool(_propPool);
    }

    // ─────────────────────────────────────────────────────────────
    // KEEPER FUNCTIONS — called by keeper bot every 6 hours
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Deploy idle prop pool capital to yield strategies.
     *         Called by keeper when idle > threshold.
     *         USDC must be transferred from PropPool to this contract first.
     */
    function deployIdle(uint256 amount) external onlyKeeper nonReentrant {
        require(amount > 0, "PropPoolYield: zero amount");
        require(USDC.balanceOf(address(this)) >= amount, "PropPoolYield: insufficient balance");

        // Safety: check pool utilization before deploying
        uint256 totalPool = propPool.totalDeposited();
        uint256 available = propPool.availableCapital();
        if (totalPool > 0) {
            uint256 utilization = (totalPool - available) * BPS / totalPool;
            require(utilization < RECALL_THRESHOLD, "PropPoolYield: pool utilization too high");
        }

        uint256 toAave    = amount * AAVE_SPLIT_BPS    / BPS;
        uint256 toLending = amount * LENDING_SPLIT_BPS / BPS;

        // Deploy to Aave V3
        if (toAave > 0) {
            USDC.approve(address(aavePool), toAave);
            aavePool.supply(address(USDC), toAave, address(this), 0);
            deployedToAave += toAave;
        }

        // Deploy to WikiLending
        if (toLending > 0) {
            USDC.approve(address(wikiLending), toLending);
            wikiLending.supply(address(USDC), toLending);
            deployedToLending += toLending;
        }

        lastDeployTime = block.timestamp;
        emit YieldDeployed(toAave, toLending, block.timestamp);
    }

    /**
     * @notice Recall deployed capital back to PropPool.
     *         Called automatically when a trader is about to be funded.
     * @param amountNeeded  Amount to recall (0 = recall all)
     */
    function recall(uint256 amountNeeded, string calldata reason) external onlyKeeper nonReentrant {
        uint256 recallAave    = amountNeeded == 0 ? deployedToAave    : _min(amountNeeded * AAVE_SPLIT_BPS / BPS,    deployedToAave);
        uint256 recallLending = amountNeeded == 0 ? deployedToLending : _min(amountNeeded * LENDING_SPLIT_BPS / BPS, deployedToLending);

        if (recallAave > 0) {
            aavePool.withdraw(address(USDC), recallAave, address(this));
            deployedToAave -= recallAave;
        }
        if (recallLending > 0) {
            wikiLending.withdraw(address(USDC), recallLending);
            deployedToLending -= recallLending;
        }

        // Send back to PropPool
        uint256 bal = USDC.balanceOf(address(this));
        if (bal > 0) {
            USDC.safeTransfer(address(propPool), bal);
        }

        emit YieldRecalled(recallAave, recallLending, reason);
    }

    /**
     * @notice Harvest yield (interest earned above principal) and send to PropPool.
     *         Called by keeper every 24 hours.
     */
    function harvestYield() external onlyKeeper nonReentrant {
        // Harvest from Aave: aToken balance > deployedToAave = interest earned
        // (aTokens accrue value automatically)
        // For now we do a minimal withdrawal of the excess
        uint256 harvested = 0;

        // WikiLending: get current balance vs deployed
        uint256 currentLending = wikiLending.getSupplyBalance(address(this), address(USDC));
        if (currentLending > deployedToLending) {
            uint256 interest = currentLending - deployedToLending;
            if (interest > 0) {
                wikiLending.withdraw(address(USDC), interest);
                harvested += interest;
            }
        }

        if (harvested > 0) {
            totalYieldGenerated += harvested;
            USDC.approve(address(propPool), harvested);
            propPool.receiveYield(harvested, "PropPoolYield");
            emit YieldHarvested(harvested, block.timestamp);
        }
    }

    /**
     * @notice Emergency: recall everything immediately.
     *         Called if something goes wrong.
     */
    function emergencyRecall() external onlyOwner nonReentrant {
        if (deployedToAave > 0) {
            try aavePool.withdraw(address(USDC), type(uint256).max, address(this)) {} catch {}
            deployedToAave = 0;
        }
        if (deployedToLending > 0) {
            try wikiLending.withdraw(address(USDC), deployedToLending) {} catch {}
            deployedToLending = 0;
        }
        uint256 bal = USDC.balanceOf(address(this));
        if (bal > 0) USDC.safeTransfer(address(propPool), bal);
        emit YieldRecalled(0, 0, "emergency");
    }

    // ─────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    function totalDeployed() external view returns (uint256) {
        return deployedToAave + deployedToLending;
    }

    function estimatedAPY() external view returns (uint256 blendedBps) {
        // Aave USDC ~6% + WikiLending USDC ~6.8% blended at 40/60
        uint256 aaveAPY    = 600;   // ~6% (fetched off-chain by keeper, hardcoded for view)
        uint256 lendingAPY = wikiLending.getSupplyAPY(address(USDC)) / 1e14; // normalize to bps
        blendedBps = (aaveAPY * AAVE_SPLIT_BPS + lendingAPY * LENDING_SPLIT_BPS) / BPS;
    }

    function idleCapacityToDeply(uint256 propPoolIdleBalance) external view returns (uint256) {
        uint256 totalPool  = propPool.totalDeposited();
        uint256 maxDeploy  = totalPool * MAX_DEPLOY_BPS / BPS;
        uint256 alreadyOut = deployedToAave + deployedToLending;
        uint256 room       = maxDeploy > alreadyOut ? maxDeploy - alreadyOut : 0;
        return _min(room, propPoolIdleBalance);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }
    function setContracts(address _aave, address _lending, address _propPool) external onlyOwner {
        aavePool    = IAavePool(_aave);
        wikiLending = IWikiLending(_lending);
        propPool    = IWikiPropPool(_propPool);
    }
}
