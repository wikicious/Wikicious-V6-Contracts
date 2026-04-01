// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiRevenueDashboard
 * @notice Public protocol revenue dashboard. All data on-chain.
 *         Powers Token Terminal + DeFi Llama integrations.
 *         Builds institutional trust through radical transparency.
 *
 * DEFI LLAMA API COMPATIBILITY:
 *   getTVL()              → total value locked (sum of all vaults)
 *   get24hFees()          → fees generated in last 24 hours
 *   get24hRevenue()       → protocol revenue (fees that go to treasury/stakers)
 *   getAnnualisedRevenue()→ 30-day run rate × 365
 *
 * TOKEN TERMINAL COMPATIBILITY:
 *   getProtocolRevenue(period) → revenue for given time period
 *   getEarnings()              → revenue minus expenses
 *
 * PUBLIC METRICS:
 *   Total volume all-time and 24h
 *   Fee revenue breakdown by source
 *   Prop trading revenue (challenge fees + profit splits)
 *   Bot vault AUM and management fees
 *   NFT marketplace revenue
 *   Ops vault balance and yield earned
 */
interface IWikiBackstop { function totalAssets() external view returns (uint256); }

interface IWikiOpsVault {
        function dashboard() external view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256);
        function totalValue() external view returns (uint256);
    }

interface IWikiOnChainAnalytics {
        function get24hVolume() external view returns (uint256);
        function get24hFees()   external view returns (uint256);
        function getCumulativeFees() external view returns (uint256);
        function getCumulativeVolume() external view returns (uint256);
        function getAnnualisedFeeRunRate() external view returns (uint256);
        function getProtocolSummary() external view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256);
    }

interface IWikiLending  { function totalSupply(uint256 mid) external view returns (uint256); }

contract WikiRevenueDashboard is Ownable2Step {

    struct RevenueBreakdown {
        uint256 tradingFees24h;      // from WikiPerp, WikiSpot, WikiOrderBook
        uint256 propChallengeFees24h;// challenge purchases
        uint256 propProfitSplit24h;  // 20% of funded trader profits
        uint256 botMgmtFees24h;      // 2% annual on bot vault AUM
        uint256 botPerfFees24h;      // 20% of bot profits
        uint256 liqProtectionFees24h;// monthly subscriptions
        uint256 nftFees24h;          // revenue share NFT deposits
        uint256 apiKeyFees24h;       // Pro/Institutional API subscriptions
        uint256 darkPoolFees24h;     // 0.15% dark pool trades
        uint256 structuredProdFees24h;
        uint256 insuranceFees24h;
        uint256 vestingMarketFees24h;
        uint256 total24h;
    }

    struct TVLBreakdown {
        uint256 backstopVault;
        uint256 lendingPools;
        uint256 botVaults;
        uint256 structuredProducts;
        uint256 leveragedYield;
        uint256 opsVault;
        uint256 propPool;
        uint256 total;
    }

    // Contract references
    address public analytics;
    address public opsVault;
    address public backstop;
    address public lending;

    // Manual overrides for metrics that can't be read on-chain easily
    uint256 public manualTVL;
    uint256 public manualPropFees24h;
    uint256 public manualBotFees24h;
    uint256 public lastManualUpdate;

    // Historical daily revenue (for charting)
    mapping(uint256 => uint256) public dailyRevenue;   // day → total fees
    uint256[] public revenueHistory;

    event ManualMetricsUpdated(uint256 tvl, uint256 propFees, uint256 botFees);

    constructor(address _owner, address _analytics, address _opsVault) Ownable(_owner) {
        analytics = _analytics;
        opsVault  = _opsVault;
    }

    // ── DeFi Llama compatible ─────────────────────────────────────────────
    function getTVL() external view returns (uint256) {
        uint256 total = manualTVL;
        if (opsVault != address(0)) {
            try IWikiOpsVault(opsVault).totalValue() returns (uint256 v) { total += v; } catch {}
        }
        if (backstop != address(0)) {
            try IWikiBackstop(backstop).totalAssets() returns (uint256 v) { total += v; } catch {}
        }
        return total;
    }

    function get24hFees() external view returns (uint256) {
        uint256 onchain;
        if (analytics != address(0)) {
            try IWikiOnChainAnalytics(analytics).get24hFees() returns (uint256 v) { onchain = v; } catch {}
        }
        return onchain + manualPropFees24h + manualBotFees24h;
    }

    function get24hRevenue() external view returns (uint256) {
        // Protocol revenue = 30% of fees (ops vault share)
        uint256 fees = this.get24hFees();
        return fees * 30 / 100;
    }

    function getAnnualisedRevenue() external view returns (uint256) {
        return this.get24hRevenue() * 365;
    }

    // ── Token Terminal compatible ─────────────────────────────────────────
    function getProtocolRevenue(uint256 periodDays) external view returns (uint256 revenue) {
        uint256 today = block.timestamp / 1 days;
        for (uint i; i < periodDays && i < revenueHistory.length; i++) {
            uint256 day = today - i;
            revenue += dailyRevenue[day];
        }
        return revenue * 30 / 100; // 30% is protocol's share
    }

    // ── Full dashboard ────────────────────────────────────────────────────
    function getFullDashboard() external view returns (
        uint256 tvl,
        uint256 fees24h,
        uint256 revenue24h,
        uint256 feesAllTime,
        uint256 volumeAllTime,
        uint256 volume24h,
        uint256 annualisedRevenue,
        uint256 opsVaultBalance,
        uint256 opsVaultYieldEarned
    ) {
        tvl          = this.getTVL();
        fees24h      = this.get24hFees();
        revenue24h   = fees24h * 30 / 100;
        annualisedRevenue = revenue24h * 365;

        if (analytics != address(0)) {
            try IWikiOnChainAnalytics(analytics).getCumulativeFees() returns (uint256 v) { feesAllTime = v; } catch {}
            try IWikiOnChainAnalytics(analytics).getCumulativeVolume() returns (uint256 v) { volumeAllTime = v; } catch {}
            try IWikiOnChainAnalytics(analytics).get24hVolume() returns (uint256 v) { volume24h = v; } catch {}
        }

        if (opsVault != address(0)) {
            try IWikiOpsVault(opsVault).dashboard() returns (
                uint256 totalVal, uint256 /*tvl*/, uint256 /*apr*/, uint256 /*rewards*/, uint256 yieldEarned, uint256 /*pending*/, uint256 /*ts*/
            ) {
                opsVaultBalance     = totalVal;
                opsVaultYieldEarned = yieldEarned;
            } catch {}
        }
    }

    // ── Admin: update manual metrics ──────────────────────────────────────
    function updateManualMetrics(uint256 tvl, uint256 propFees24h, uint256 botFees24h) external onlyOwner {
        manualTVL         = tvl;
        manualPropFees24h = propFees24h;
        manualBotFees24h  = botFees24h;
        lastManualUpdate  = block.timestamp;

        uint256 today = block.timestamp / 1 days;
        if (dailyRevenue[today] == 0) revenueHistory.push(today);
        dailyRevenue[today] = this.get24hFees();

        emit ManualMetricsUpdated(tvl, propFees24h, botFees24h);
    }

    function setContracts(address _analytics, address _opsVault, address _backstop, address _lending) external onlyOwner {
        if (_analytics != address(0)) analytics = _analytics;
        if (_opsVault  != address(0)) opsVault  = _opsVault;
        if (_backstop  != address(0)) backstop  = _backstop;
        if (_lending   != address(0)) lending   = _lending;
    }
}
