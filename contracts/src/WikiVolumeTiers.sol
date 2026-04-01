// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiVolumeTiers
 * @notice 5-tier fee discount system based on 30-day rolling trading volume.
 *         High-volume traders pay lower taker fees, keeping flow concentrated
 *         on Wikicious rather than splitting across venues.
 *
 * TIERS (30-day cumulative notional volume)
 * ─────────────────────────────────────────────────────────────────────────
 * TIER 0 (default) : <$100K       → 0bps discount  (0.06% taker)
 * TIER 1           : $100K–1M     → 10bps discount (0.05% taker)
 * TIER 2           : $1M–10M      → 20bps discount (0.04% taker)
 * TIER 3           : $10M–50M     → 30bps discount (0.03% taker)
 * TIER 4 (VIP)     : >$50M        → 40bps discount (0.02% taker)
 *
 * REVENUE IMPACT
 * ─────────────────────────────────────────────────────────────────────────
 * Top 20% of traders generate 80% of volume.
 * Without tiers: they split volume across venues.
 * With tiers: they concentrate volume to maintain their tier.
 * Net effect: +30–50% volume from high-value traders despite lower rates.
 *
 * INTEGRATION
 * ─────────────────────────────────────────────────────────────────────────
 * WikiPerp calls recordVolume() on every trade close.
 * WikiPerp calls getDiscount(trader) to apply fee reduction before charging.
 * WikiOrderBook does the same for spot volume.
 */
contract WikiVolumeTiers is Ownable2Step, ReentrancyGuard {

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant WINDOW       = 30 days;
    uint256 public constant MAX_BUCKETS  = 30;        // daily buckets
    uint256 public constant BPS          = 10_000;

    // ── Structs ────────────────────────────────────────────────────────────

    struct TierConfig {
        uint256 minVolume;      // minimum 30d volume to qualify (USDC 6dec)
        uint256 discountBps;    // fee discount in basis points
        string  name;           // e.g. "VIP"
    }

    // Rolling window: store daily buckets for each trader
    struct VolumeWindow {
        uint256[30] dailyVolume; // circular buffer, indexed by day
        uint256     lastDay;     // the day index of the most recent bucket
        uint256     total30d;    // cached rolling total (updated on each trade)
    }

    // ── State ──────────────────────────────────────────────────────────────
    TierConfig[5]   public tiers;
    mapping(address => VolumeWindow) private windows;
    mapping(address => bool)         public  recorders; // WikiPerp, WikiOrderBook

    uint256 public totalVolumeRecorded;

    // ── Events ─────────────────────────────────────────────────────────────
    event VolumeRecorded(address indexed trader, uint256 amount, uint256 newTotal30d, uint8 tier);
    event TierUpdated(uint8 tier, uint256 minVolume, uint256 discountBps);
    event RecorderSet(address indexed recorder, bool enabled);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "Wiki: zero _owner");
        // Tier 0: default, no discount
        tiers[0] = TierConfig({ minVolume: 0,                    discountBps: 0,  name: "Standard" });
        // Tier 1: $100K monthly
        tiers[1] = TierConfig({ minVolume: 100_000 * 1e6,        discountBps: 10, name: "Advanced" });
        // Tier 2: $1M monthly
        tiers[2] = TierConfig({ minVolume: 1_000_000 * 1e6,      discountBps: 20, name: "Pro"      });
        // Tier 3: $10M monthly
        tiers[3] = TierConfig({ minVolume: 10_000_000 * 1e6,     discountBps: 30, name: "Elite"    });
        // Tier 4: $50M monthly
        tiers[4] = TierConfig({ minVolume: 50_000_000 * 1e6,     discountBps: 40, name: "VIP"      });
    }

    // ── Record Volume (called by WikiPerp / WikiOrderBook) ─────────────────

    /**
     * @notice Record a trade's notional volume for a trader.
     *         Called by authorised contracts (WikiPerp, WikiOrderBook).
     * @param trader Address of the trader
     * @param amount Notional volume in USDC (6 decimals)
     */
    function recordVolume(address trader, uint256 amount)
        external
        nonReentrant
        returns (uint8 currentTier)
    {
        require(recorders[msg.sender] || msg.sender == owner(), "VT: not recorder");
        if (amount == 0 || trader == address(0)) return 0;

        VolumeWindow storage w = windows[trader];

        uint256 today = block.timestamp / 1 days;

        // Roll stale buckets to zero
        _rollWindow(w, today);

        // Add to today's bucket
        uint256 bucket = today % MAX_BUCKETS;
        w.dailyVolume[bucket] += amount;
        w.total30d            += amount;
        w.lastDay              = today;

        totalVolumeRecorded += amount;
        currentTier          = _tierOf(w.total30d);

        emit VolumeRecorded(trader, amount, w.total30d, currentTier);
    }

    // ── Query (called by WikiPerp before fee calculation) ─────────────────

    /**
     * @notice Get the fee discount in BPS for a trader.
     * @return discountBps  e.g. 10 = 0.10% discount from base taker fee
     * @return tier         0–4
     */
    function getDiscount(address trader)
        external
        view
        returns (uint256 discountBps, uint8 tier)
    {
        uint256 vol30d = get30dVolume(trader);
        tier = _tierOf(vol30d);
        discountBps = tiers[tier].discountBps;
    }

    /**
     * @notice Calculate effective taker fee given base rate and trader discount.
     * @param baseTakerBps  Base taker fee in BPS (e.g. 6 = 0.06%)
     * @param trader        Trader address
     * @return effectiveBps Actual fee to charge
     */
    function effectiveFee(uint256 baseTakerBps, address trader)
        external
        view
        returns (uint256 effectiveBps)
    {
        (uint256 disc,) = this.getDiscount(trader);
        effectiveBps = baseTakerBps > disc ? baseTakerBps - disc : 0;
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function get30dVolume(address trader) public view returns (uint256 total) {
        VolumeWindow storage w = windows[trader];
        if (w.lastDay == 0) return 0;

        uint256 today = block.timestamp / 1 days;
        uint256 cutoff = today >= 30 ? today - 29 : 0;

        // Sum non-stale buckets
        for (uint256 d = cutoff; d <= today; d++) {
            total += w.dailyVolume[d % MAX_BUCKETS];
        }
    }

    function getTierInfo(address trader) external view returns (
        uint8  tier,
        string memory tierName,
        uint256 volume30d,
        uint256 discountBps,
        uint256 nextTierVolume,
        uint256 volumeToNextTier
    ) {
        volume30d   = get30dVolume(trader);
        tier        = _tierOf(volume30d);
        tierName    = tiers[tier].name;
        discountBps = tiers[tier].discountBps;
        if (tier < 4) {
            nextTierVolume   = tiers[tier + 1].minVolume;
            volumeToNextTier = nextTierVolume > volume30d ? nextTierVolume - volume30d : 0;
        }
    }

    function getAllTiers() external view returns (TierConfig[5] memory) {
        return tiers;
    }

    // ── Owner ──────────────────────────────────────────────────────────────

    function setRecorder(address recorder, bool enabled) external onlyOwner {
        recorders[recorder] = enabled;
        emit RecorderSet(recorder, enabled);
    }

    function updateTier(uint8 tier, uint256 minVolume, uint256 discountBps, string calldata name)
        external onlyOwner
    {
        require(tier < 5, "VT: bad tier");
        require(discountBps <= 50, "VT: discount too high"); // max 0.50% discount
        tiers[tier] = TierConfig(minVolume, discountBps, name);
        emit TierUpdated(tier, minVolume, discountBps);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _rollWindow(VolumeWindow storage w, uint256 today) internal {
        if (w.lastDay == 0) return;

        uint256 daysElapsed = today > w.lastDay ? today - w.lastDay : 0;
        if (daysElapsed == 0) return;

        uint256 toClear = daysElapsed < MAX_BUCKETS ? daysElapsed : MAX_BUCKETS;
        for (uint256 i = 1; i <= toClear; i++) {
            uint256 oldBucket = (w.lastDay + i) % MAX_BUCKETS;
            w.total30d -= w.dailyVolume[oldBucket];
            w.dailyVolume[oldBucket] = 0;
        }
    }

    function _tierOf(uint256 vol) internal view returns (uint8) {
        for (uint8 i = 4; i > 0; i--) {
            if (vol >= tiers[i].minVolume) return i;
        }
        return 0;
    }
}
