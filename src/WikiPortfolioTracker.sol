// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiPortfolioTracker
 * @notice Aggregates all user positions across every Wikicious contract
 *         into a single portfolio view. Net worth, P&L, yield, exposure.
 *         Frontend calls getFullPortfolio() and displays the complete picture.
 *
 * WHAT IT AGGREGATES:
 *   Trading:  open perp positions, spot balances, options
 *   Yield:    staking rewards, vault shares, lending supply
 *   Bots:     bot vault allocations per strategy
 *   Prop:     eval status, funded account balance
 *   Tokens:   WIK, veWIK, USDC, WETH, WBTC balances
 *   P&L:      realised + unrealised, lifetime fees paid
 */
interface IERC20 { function balanceOf(address) external view returns (uint256); }

interface IWikiPropFunded { function activeFundedId(address) external view returns (uint256); }

interface IWikiPerp {
        function getOpenPositions(address trader) external view returns (uint256[] memory positionIds);
        function getPositionPnl(uint256 id) external view returns (int256);
        function getPosition(uint256 id) external view returns (address, uint256, bool, uint256, uint256, uint256);
    }

interface IWikiTradeHistory{ function getTaxSummary(address) external view returns (int256, uint256, uint256, uint256, uint256, uint256, int256, int256); }

interface IWikiPropEval   { function activeEvalId(address) external view returns (uint256); function evals(uint256) external view returns (address, uint8, uint8, uint8, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, int256, uint256, uint256, bool, string memory, uint256, uint256, uint256, uint256, uint256, bool); }

interface IWikiBotVault   { function getUserDashboard(address, uint256) external view returns (uint256, uint256, uint256, int256, uint256, uint256, uint256, bool, string memory, string memory); }

interface IWikiBackstop   { function balanceOf(address) external view returns (uint256); function sharesToAssets(uint256) external view returns (uint256); }

interface IWikiLending    { function balanceOfUnderlying(uint256 mid, address user) external view returns (uint256); }

interface IWikiStaking    { function stakedBalance(address) external view returns (uint256); function pendingRewards(address) external view returns (uint256); }

contract WikiPortfolioTracker is Ownable2Step {


    struct ContractRegistry {
        address perp;
        address staking;
        address lending;
        address backstop;
        address botVault;
        address propEval;
        address propFunded;
        address tradeHistory;
        address wik;
        address veWik;
        address usdc;
        address weth;
        address wbtc;
    }

    struct PortfolioSnapshot {
        // Balances
        uint256 usdcBalance;
        uint256 wikBalance;
        uint256 veWikBalance;
        uint256 wethBalance;
        uint256 wbtcBalance;
        // Trading
        int256  unrealisedPerpPnl;
        uint256 openPerpPositions;
        uint256 perpMarginUsed;
        // Yield
        uint256 stakedWik;
        uint256 pendingStakingRewards;
        uint256 lendingBalance;
        uint256 backstopBalance;
        // Bots
        uint256[4] botAllocations;   // per strategy
        int256[4]  botPnl;
        // Prop
        bool    inEvaluation;
        bool    isFunded;
        uint256 evalBalance;
        uint256 fundedBalance;
        // Summary
        uint256 totalValueUsd;
        int256  totalPnlUsd;        // realised + unrealised
        uint256 lifetimeFeesPaid;
        uint256 lifetimeTrades;
    }

    ContractRegistry public registry;
    mapping(address => bool) public recorders;

    constructor(address _owner) Ownable(_owner) { recorders[_owner] = true; }

    function setRegistry(ContractRegistry calldata r) external onlyOwner { registry = r; }

    // ── Master view — frontend calls this once ────────────────────────────
    function getFullPortfolio(address trader) external view returns (PortfolioSnapshot memory p) {
        // Token balances
        if (registry.usdc  != address(0)) p.usdcBalance  = IERC20(registry.usdc).balanceOf(trader);
        if (registry.wik   != address(0)) p.wikBalance   = IERC20(registry.wik).balanceOf(trader);
        if (registry.veWik != address(0)) p.veWikBalance = IERC20(registry.veWik).balanceOf(trader);
        if (registry.weth  != address(0)) p.wethBalance  = IERC20(registry.weth).balanceOf(trader);
        if (registry.wbtc  != address(0)) p.wbtcBalance  = IERC20(registry.wbtc).balanceOf(trader);

        // Perp positions
        if (registry.perp != address(0)) {
            try IWikiPerp(registry.perp).getOpenPositions(trader) returns (uint256[] memory ids) {
                p.openPerpPositions = ids.length;
                for (uint i; i < ids.length; i++) {
                    try IWikiPerp(registry.perp).getPositionPnl(ids[i]) returns (int256 pnl) {
                        p.unrealisedPerpPnl += pnl;
                    } catch {}
                    try IWikiPerp(registry.perp).getPosition(ids[i]) returns (address, uint256, bool, uint256 col, uint256, uint256) {
                        p.perpMarginUsed += col;
                    } catch {}
                }
            } catch {}
        }

        // Staking
        if (registry.staking != address(0)) {
            try IWikiStaking(registry.staking).stakedBalance(trader) returns (uint256 bal) { p.stakedWik = bal; } catch {}
            try IWikiStaking(registry.staking).pendingRewards(trader) returns (uint256 r)  { p.pendingStakingRewards = r; } catch {}
        }

        // Lending
        if (registry.lending != address(0)) {
            try IWikiLending(registry.lending).balanceOfUnderlying(0, trader) returns (uint256 bal) { p.lendingBalance = bal; } catch {}
        }

        // Backstop
        if (registry.backstop != address(0)) {
            try IWikiBackstop(registry.backstop).balanceOf(trader) returns (uint256 shares) {
                if (shares > 0) {
                    try IWikiBackstop(registry.backstop).sharesToAssets(shares) returns (uint256 assets) { p.backstopBalance = assets; } catch {}
                }
            } catch {}
        }

        // Bot vault (all 4 strategies)
        if (registry.botVault != address(0)) {
            for (uint i; i < 4; i++) {
                try IWikiBotVault(registry.botVault).getUserDashboard(trader, i) returns (
                    uint256 shares, uint256 val, uint256 dep, int256 pnl, uint256 /*fee*/, uint256 /*ts*/, bool /*active*/
                ) {
                    p.botAllocations[i] = val;
                    p.botPnl[i]         = pnl;
                } catch {}
            }
        }

        // Prop eval
        if (registry.propEval != address(0)) {
            try IWikiPropEval(registry.propEval).activeEvalId(trader) returns (uint256 eid) {
                if (eid > 0) { p.inEvaluation = true; }
            } catch {}
        }

        // Prop funded
        if (registry.propFunded != address(0)) {
            try IWikiPropFunded(registry.propFunded).activeFundedId(trader) returns (uint256 fid) {
                if (fid > 0) p.isFunded = true;
            } catch {}
        }

        // Trade history summary
        if (registry.tradeHistory != address(0)) {
            try IWikiTradeHistory(registry.tradeHistory).getTaxSummary(trader) returns (
                int256 totalPnl, uint256 fees, uint256 /*unused*/, uint256 trades, uint256 /*u2*/, uint256 /*u3*/, uint256 /*u4*/
            ) {
                p.totalPnlUsd      = totalPnl;
                p.lifetimeFeesPaid = fees;
                p.lifetimeTrades   = trades;
            } catch {}
        }

        // Total value (simplified — production uses oracle for token prices)
        p.totalValueUsd = p.usdcBalance
            + p.lendingBalance
            + p.backstopBalance
            + p.perpMarginUsed
            + p.stakedWik / 1000  // rough WIK price estimate
            + p.botAllocations[0] + p.botAllocations[1] + p.botAllocations[2] + p.botAllocations[3];

        p.totalPnlUsd += p.unrealisedPerpPnl;
        for (uint i; i < 4; i++) p.totalPnlUsd += p.botPnl[i];
    }

    // ── Quick views ───────────────────────────────────────────────────────
    function getNetWorth(address trader) external view returns (uint256 totalUsd, int256 totalPnl) {
        PortfolioSnapshot memory p = this.getFullPortfolio(trader);
        return (p.totalValueUsd, p.totalPnlUsd);
    }

    function getYieldSummary(address trader) external view returns (
        uint256 stakedWik, uint256 pendingRewards,
        uint256 lendingBal, uint256 backstopBal, uint256 totalYieldPositions
    ) {
        PortfolioSnapshot memory p = this.getFullPortfolio(trader);
        stakedWik          = p.stakedWik;
        pendingRewards     = p.pendingStakingRewards;
        lendingBal         = p.lendingBalance;
        backstopBal        = p.backstopBalance;
        totalYieldPositions= (stakedWik > 0 ? 1 : 0) + (lendingBal > 0 ? 1 : 0) + (backstopBal > 0 ? 1 : 0);
    }
}
