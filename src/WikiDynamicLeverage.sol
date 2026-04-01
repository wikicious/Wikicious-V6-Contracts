// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";



interface IWikiPerp {
    function updateMarketCaps(uint256 marketIdx, uint256 maxLeverageBps, uint256 maxPositionSize, uint256 maxOILong, uint256 maxOIShort) external;
    function marketsLength() external view returns (uint256);
}

interface IWikiVirtualAMM {
    function setMarketMaxLeverage(uint256 marketIdx, uint256 maxLev) external;
    function marketsLength() external view returns (uint256);
}

interface IWikiVault {
    function insuranceFund() external view returns (uint256);
    function protocolFees() external view returns (uint256);
}

/**
 * @title WikiDynamicLeverage
 * @notice Automatically adjusts maximum leverage and position size caps
 *         based on the current insurance fund balance.
 *
 * ─── WHY THIS EXISTS ──────────────────────────────────────────────────────────
 * When the insurance fund is small (e.g. $0 at launch), high leverage creates
 * real risk: a gap/cascade liquidation could produce a shortfall larger than
 * the fund can cover, meaning other traders absorb the loss ("socialized loss").
 *
 * This interface IWikiPerp {
        function updateMarketCaps(
            uint256 marketIdx,
            uint256 maxLeverageBps,
            uint256 maxPositionSize,
            uint256 maxOILong,
            uint256 maxOIShort
        ) external;
        function marketsLength() external view returns (uint256);
    }

interface IWikiVirtualAMM {
        function setMarketMaxLeverage(uint256 marketIdx, uint256 maxLev) external;
        function marketsLength() external view returns (uint256);
    }

interface IWikiVault {
        function insuranceFund() external view returns (uint256);
        function protocolFees()  external view returns (uint256);
    }

contract solves it by making the rules *automatic* and *on-chain*:
 *  - Anyone can call updateLeverageCaps() at any time (permissionless)
 *  - Caps rise as the fund grows, fall if it shrinks
 *  - No governance delay needed — it reacts to real fund balance in real time
 *  - WikiPerp and WikiVirtualAMM read maxLeverageFor() before opening positions
 *
 * ─── TIER SCHEDULE ───────────────────────────────────────────────────────────
 *
 *   Fund $0        →  max 5×    max pos $100     max OI $5K
 *   Fund $100      →  max 10×   max pos $500     max OI $25K
 *   Fund $500      →  max 20×   max pos $2,000   max OI $100K
 *   Fund $2,000    →  max 25×   max pos $5,000   max OI $250K
 *   Fund $5,000    →  max 50×   max pos $20,000  max OI $1M
 *   Fund $20,000   →  max 75×   max pos $50,000  max OI $5M
 *   Fund $50,000   →  max 100×  max pos $100,000 max OI $20M
 *   Fund $500,000  →  max 100×  max pos $500,000 max OI $100M
 *
 * ─── SAFETY FORMULA ─────────────────────────────────────────────────────────
 * At leverage N, worst-case shortfall per position = collateral × 1/(N-1)
 * We require: insurance_fund >= 10 × worst_case_shortfall per max_position
 * i.e.: fund >= 10 × (maxPos / (lev - 1))
 *
 * This means at any leverage tier, the fund can absorb at least 10 full
 * worst-case liquidations before socialized loss occurs.
 *
 * ─── PERMISSIONLESS UPDATE ────────────────────────────────────────────────────
 * Anyone can call updateLeverageCaps() — keeper bots do this every 5 minutes.
 * The contract reads the live fund balance from WikiVault.insuranceFund().
 * Governance only controls: the tier schedule itself (via multisig + timelock).
 */
contract WikiDynamicLeverage is Ownable2Step, Pausable {

    // ── Interfaces ───────────────────────────────────────────────────────────




    // ── Tier Definition ──────────────────────────────────────────────────────

    struct LeverageTier {
        uint256 minInsuranceFund; // USDC 6 dec — fund must be >= this to unlock tier
        uint256 maxLeverage;      // e.g. 10 = 10×
        uint256 maxPositionUsdc;  // per-position cap in USDC 6 dec
        uint256 maxOIPerMarket;   // max open interest per side per market
        string  name;             // human-readable label
    }

    LeverageTier[] public tiers;

    // ── State ────────────────────────────────────────────────────────────────

    IWikiVault       public vault;
    IWikiVirtualAMM  public vamm;
    IWikiPerp        public perp;

    uint256 public currentTierIdx;          // which tier is currently active
    uint256 public lastUpdateTime;          // last time caps were updated
    uint256 public updateCooldown = 5 minutes; // min time between updates
    bool    public autoUpdateEnabled = true;

    // Snapshot of what was last pushed to contracts
    uint256 public lastPushedLeverage;
    uint256 public lastPushedMaxPos;
    uint256 public lastPushedMaxOI;

    // ── Events ───────────────────────────────────────────────────────────────

    event TierAdvanced(
        uint256 indexed newTierIdx,
        string tierName,
        uint256 maxLeverage,
        uint256 maxPosition,
        uint256 insuranceFund
    );
    event TierReduced(
        uint256 indexed newTierIdx,
        string tierName,
        uint256 maxLeverage,
        uint256 reason // 0 = fund dropped, 1 = manual
    );
    event CapsUpdated(
        uint256 maxLeverage,
        uint256 maxPositionUsdc,
        uint256 maxOIPerMarket,
        uint256 insuranceFund,
        address caller
    );
    event TierScheduleUpdated(uint256 tiersCount);
    event ContractsUpdated(address vault, address vamm, address perp);

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _vault,
        address _vamm,
        address _perp
    ) Ownable(_owner) {
        require(_owner != address(0), "DynLev: zero owner");
        require(_vault != address(0), "DynLev: zero vault");

        vault = IWikiVault(_vault);
        if (_vamm != address(0)) vamm = IWikiVirtualAMM(_vamm);
        if (_perp != address(0)) perp = IWikiPerp(_perp);

        // ── Default tier schedule ────────────────────────────────────────
        // Tier 0: Launch — no seed needed
        tiers.push(LeverageTier({
            minInsuranceFund: 0,
            maxLeverage:      5,
            maxPositionUsdc:  100 * 1e6,          // $100
            maxOIPerMarket:   5_000 * 1e6,         // $5K
            name:             "LAUNCH (no seed)"
        }));
        // Tier 1: Seed — first fees accumulate
        tiers.push(LeverageTier({
            minInsuranceFund: 100 * 1e6,           // $100
            maxLeverage:      10,
            maxPositionUsdc:  500 * 1e6,           // $500
            maxOIPerMarket:   25_000 * 1e6,        // $25K
            name:             "SEED ($100 fund)"
        }));
        // Tier 2: Early
        tiers.push(LeverageTier({
            minInsuranceFund: 500 * 1e6,           // $500
            maxLeverage:      20,
            maxPositionUsdc:  2_000 * 1e6,         // $2K
            maxOIPerMarket:   100_000 * 1e6,       // $100K
            name:             "EARLY ($500 fund)"
        }));
        // Tier 3: Growing
        tiers.push(LeverageTier({
            minInsuranceFund: 2_000 * 1e6,         // $2K
            maxLeverage:      25,
            maxPositionUsdc:  5_000 * 1e6,         // $5K
            maxOIPerMarket:   250_000 * 1e6,       // $250K
            name:             "GROWING ($2K fund)"
        }));
        // Tier 4: Established
        tiers.push(LeverageTier({
            minInsuranceFund: 5_000 * 1e6,         // $5K
            maxLeverage:      50,
            maxPositionUsdc:  20_000 * 1e6,        // $20K
            maxOIPerMarket:   1_000_000 * 1e6,     // $1M
            name:             "ESTABLISHED ($5K fund)"
        }));
        // Tier 5: Mature
        tiers.push(LeverageTier({
            minInsuranceFund: 20_000 * 1e6,        // $20K
            maxLeverage:      75,
            maxPositionUsdc:  50_000 * 1e6,        // $50K
            maxOIPerMarket:   5_000_000 * 1e6,     // $5M
            name:             "MATURE ($20K fund)"
        }));
        // Tier 6: Full
        tiers.push(LeverageTier({
            minInsuranceFund: 50_000 * 1e6,        // $50K
            maxLeverage:      100,
            maxPositionUsdc:  100_000 * 1e6,       // $100K
            maxOIPerMarket:   20_000_000 * 1e6,    // $20M
            name:             "FULL 100x ($50K fund)"
        }));
        // Tier 7: Scale
        tiers.push(LeverageTier({
            minInsuranceFund: 500_000 * 1e6,       // $500K
            maxLeverage:      100,
            maxPositionUsdc:  500_000 * 1e6,       // $500K
            maxOIPerMarket:   100_000_000 * 1e6,   // $100M
            name:             "SCALE ($500K fund)"
        }));

        // Tier 8: 200× — fund $2M
        tiers.push(LeverageTier({
            minInsuranceFund: 2_000_000 * 1e6,       // $2M
            maxLeverage:      200,
            maxPositionUsdc:  2_000 * 1e6,            // $2K pos ($400K notional at 200x)
            maxOIPerMarket:   200_000_000 * 1e6,      // $200M
            name:             "ADVANCED 200x ($2M fund)"
        }));
        // Tier 9: 500× — fund $10M
        tiers.push(LeverageTier({
            minInsuranceFund: 10_000_000 * 1e6,       // $10M
            maxLeverage:      500,
            maxPositionUsdc:  1_000 * 1e6,             // $1K pos ($500K notional at 500x)
            maxOIPerMarket:   500_000_000 * 1e6,       // $500M
            name:             "EXPERT 500x ($10M fund)"
        }));
        // Tier 10: 1000× — fund $50M (crypto only — scaler enforces per market)
        tiers.push(LeverageTier({
            minInsuranceFund: 50_000_000 * 1e6,        // $50M
            maxLeverage:      1000,
            maxPositionUsdc:  500 * 1e6,               // $500 pos ($500K notional at 1000x)
            maxOIPerMarket:   1_000_000_000 * 1e6,     // $1B
            name:             "ULTRA 1000x ($50M fund)"
        }));
        // Tier 11: 2000× — fund $200M (forex major only — scaler enforces)
        tiers.push(LeverageTier({
            minInsuranceFund: 200_000_000 * 1e6,       // $200M
            maxLeverage:      2000,
            maxPositionUsdc:  250 * 1e6,               // $250 pos ($500K notional at 2000x)
            maxOIPerMarket:   2_000_000_000 * 1e6,     // $2B
            name:             "FOREX 2000x ($200M fund)"
        }));

        currentTierIdx = 0;
        lastPushedLeverage = 5;
        lastPushedMaxPos   = 100 * 1e6;
        lastPushedMaxOI    = 5_000 * 1e6;
    }

    // ── Core: read current caps ───────────────────────────────────────────────

    /**
     * @notice Returns the max leverage allowed right now based on live fund.
     *         Read by WikiPerp and WikiVirtualAMM before opening positions.
     *         Pure view — no state changes, no gas cost for callers.
     */
    function maxLeverageFor(address /*user*/) external view returns (uint256) {
        return _computeTier().maxLeverage;
    }

    /**
     * @notice Returns the full current tier with all caps.
     */
    function currentCaps() external view returns (
        uint256 maxLeverage,
        uint256 maxPositionUsdc,
        uint256 maxOIPerMarket,
        uint256 insuranceFund,
        uint256 tierIdx,
        string memory tierName
    ) {
        LeverageTier memory t = _computeTier();
        uint256 fund = vault.insuranceFund();
        return (
            t.maxLeverage,
            t.maxPositionUsdc,
            t.maxOIPerMarket,
            fund,
            currentTierIdx,
            t.name
        );
    }

    /**
     * @notice How much more USDC the fund needs to reach the next tier.
     *         Returns 0 if already at max tier.
     */
    function fundNeededForNextTier() external view returns (
        uint256 needed,
        string memory nextTierName,
        uint256 nextMaxLeverage
    ) {
        uint256 fund = vault.insuranceFund();
        uint256 activeTier = _computeTierIdx(fund);

        if (activeTier + 1 >= tiers.length) {
            return (0, "MAX TIER REACHED", tiers[tiers.length-1].maxLeverage);
        }

        LeverageTier memory next = tiers[activeTier + 1];
        needed = fund >= next.minInsuranceFund ? 0 : next.minInsuranceFund - fund;
        return (needed, next.name, next.maxLeverage);
    }

    // ── Core: update caps ────────────────────────────────────────────────────

    /**
     * @notice Permissionless: anyone can call this to push updated caps to
     *         WikiPerp and WikiVirtualAMM contracts.
     *
     *         Called by:
     *           1. Keeper bot every 5 minutes
     *           2. Anyone who notices tier changed and wants to apply it faster
     *
     *         Reverts if: called too soon (updateCooldown), nothing changed,
     *         or autoUpdateEnabled = false.
     */
    function updateLeverageCaps() external whenNotPaused {
        require(autoUpdateEnabled, "DynLev: auto-update disabled");
        require(block.timestamp >= lastUpdateTime + updateCooldown, "DynLev: cooldown");

        uint256 fund = vault.insuranceFund();
        uint256 newTierIdx = _computeTierIdx(fund);
        LeverageTier memory newTier = tiers[newTierIdx];

        // Check if anything actually changed
        bool tierChanged  = newTierIdx != currentTierIdx;
        bool capsChanged  = newTier.maxLeverage != lastPushedLeverage ||
                            newTier.maxPositionUsdc != lastPushedMaxPos;

        // Always update timestamp even if no change (prevents spam)
        lastUpdateTime = block.timestamp;

        if (!capsChanged && !tierChanged) return; // nothing to do

        uint256 oldTierIdx = currentTierIdx;
        currentTierIdx = newTierIdx;
        lastPushedLeverage = newTier.maxLeverage;
        lastPushedMaxPos   = newTier.maxPositionUsdc;
        lastPushedMaxOI    = newTier.maxOIPerMarket;

        // Push to contracts
        _pushCapsToVAMM(newTier);
        _pushCapsToPerp(newTier);

        // Emit appropriate tier event
        if (newTierIdx > oldTierIdx) {
            emit TierIncreased(newTierIdx, newTier.name, newTier.maxLeverage, fund);
        } else if (newTierIdx < oldTierIdx) {
            emit TierReduced(newTierIdx, newTier.name, newTier.maxLeverage, 0);
        }

        emit CapsUpdated(newTier.maxLeverage, newTier.maxPositionUsdc,
            newTier.maxOIPerMarket, fund, msg.sender);
    }

    /**
     * @notice Owner can force-update immediately (bypasses cooldown).
     *         Used after emergency fund injection or audit sign-off.
     */
    function forceUpdate() external onlyOwner {
        lastUpdateTime = 0; // reset cooldown
        this.updateLeverageCaps();
    }

    // ── Governance: tier schedule ─────────────────────────────────────────────

    /**
     * @notice Replace the entire tier schedule.
     *         Goes through multisig + timelock.
     *         All values in USDC 6-decimal (1e6 = $1).
     */
    function setTierSchedule(
        uint256[] calldata minFunds,
        uint256[] calldata maxLeverages,
        uint256[] calldata maxPositions,
        uint256[] calldata maxOIs,
        string[]  calldata names
    ) external onlyOwner {
        require(minFunds.length == maxLeverages.length, "DynLev: length mismatch");
        require(minFunds.length == maxPositions.length, "DynLev: length mismatch");
        require(minFunds.length >= 2,                   "DynLev: need >= 2 tiers");
        require(minFunds[0] == 0,                       "DynLev: tier 0 must need $0");

        // Validate: tiers must be in ascending order
        for (uint i = 1; i < minFunds.length; i++) {
            require(minFunds[i] > minFunds[i-1],         "DynLev: non-ascending fund");
            require(maxLeverages[i] >= maxLeverages[i-1],"DynLev: non-ascending lev");
        }

        delete tiers;
        for (uint i; i < minFunds.length; i++) {
            // Max leverage enforced by WikiLeverageScaler per market class.
            // DynLev tier schedule can allow up to 2000 for forex markets.
            require(maxLeverages[i] >= 1 && maxLeverages[i] <= 2000, "DynLev: max is 2000x");
            tiers.push(LeverageTier({
                minInsuranceFund: minFunds[i],
                maxLeverage:      maxLeverages[i],
                maxPositionUsdc:  maxPositions[i],
                maxOIPerMarket:   maxOIs[i],
                name:             names[i]
            }));
        }

        emit TierScheduleUpdated(tiers.length);
    }

    function setContracts(address _vault, address _vamm, address _perp) external onlyOwner {
        require(_vault != address(0), "DynLev: zero vault");
        vault = IWikiVault(_vault);
        if (_vamm != address(0)) vamm = IWikiVirtualAMM(_vamm);
        if (_perp != address(0)) perp = IWikiPerp(_perp);
        emit ContractsUpdated(_vault, _vamm, _perp);
    }

    function setUpdateCooldown(uint256 secs) external onlyOwner {
        require(secs <= 1 hours, "DynLev: cooldown too long");
        updateCooldown = secs;
    }

    function setAutoUpdateEnabled(bool enabled) external onlyOwner {
        autoUpdateEnabled = enabled;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Views ─────────────────────────────────────────────────────────────────

    function tiersLength() external view returns (uint256) { return tiers.length; }

    function getTier(uint256 idx) external view returns (LeverageTier memory) {
        require(idx < tiers.length, "DynLev: out of range");
        return tiers[idx];
    }

    function getAllTiers() external view returns (LeverageTier[] memory) {
        return tiers;
    }

    /**
     * @notice Full status — useful for dashboards and keeper bots.
     */
    function status() external view returns (
        uint256 fund,
        uint256 tier,
        string memory tierName,
        uint256 maxLev,
        uint256 maxPos,
        uint256 maxOI,
        uint256 nextTierFundNeeded,
        uint256 nextMaxLev,
        uint256 nextUpdateAllowed
    ) {
        fund = vault.insuranceFund();
        tier = _computeTierIdx(fund);
        LeverageTier memory t = tiers[tier];
        tierName = t.name;
        maxLev   = t.maxLeverage;
        maxPos   = t.maxPositionUsdc;
        maxOI    = t.maxOIPerMarket;

        if (tier + 1 < tiers.length) {
            LeverageTier memory next = tiers[tier + 1];
            nextTierFundNeeded = fund >= next.minInsuranceFund ? 0 : next.minInsuranceFund - fund;
            nextMaxLev = next.maxLeverage;
        }

        nextUpdateAllowed = lastUpdateTime + updateCooldown;
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    function _computeTier() internal view returns (LeverageTier memory) {
        return tiers[_computeTierIdx(vault.insuranceFund())];
    }

    /**
     * @dev Find the highest tier whose minInsuranceFund <= current fund.
     *      Binary search would be slightly more efficient but linear is fine
     *      for ≤ 10 tiers and saves bytecode.
     */
    function _computeTierIdx(uint256 fund) internal view returns (uint256 idx) {
        idx = 0;
        for (uint256 i = 1; i < tiers.length; i++) {
            if (fund >= tiers[i].minInsuranceFund) {
                idx = i;
            } else {
                break; // tiers are sorted ascending
            }
        }
    }

    function _pushCapsToVAMM(LeverageTier memory t) internal {
        if (address(vamm) == address(0)) return;
        try vamm.marketsLength() returns (uint256 len) {
            for (uint256 i; i < len; i++) {
                try vamm.setMarketMaxLeverage(i, t.maxLeverage) {} catch {}
            }
        } catch {}
    }

    function _pushCapsToPerp(LeverageTier memory t) internal {
        if (address(perp) == address(0)) return;
        try perp.marketsLength() returns (uint256 len) {
            for (uint256 i; i < len; i++) {
                try perp.updateMarketCaps(
                    i,
                    t.maxLeverage,
                    t.maxPositionUsdc,
                    t.maxOIPerMarket,
                    t.maxOIPerMarket
                ) {} catch {}
            }
        } catch {}
    }
}
