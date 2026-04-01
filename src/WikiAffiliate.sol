// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiAffiliate
 * @notice On-chain referral and affiliate program.
 *
 * ─── HOW IT WORKS ────────────────────────────────────────────────────────────
 *
 * 1. Any user registers a unique referral code (free, one per address)
 * 2. New users sign up using a referral code → bound to that referrer forever
 * 3. Every time WikiPerp / WikiSpot calls recordFee(trader, feeUsdc):
 *    - Referrer earns referrerBps of that fee (default 20% = 2000 bps)
 *    - Trader earns traderDiscountBps fee rebate (default 10% = 1000 bps)
 *    - Protocol keeps the rest
 * 4. Earnings accumulate on-chain; anyone can call claim() at any time
 *
 * ─── TIERS ───────────────────────────────────────────────────────────────────
 *
 *  Tier 0 BRONZE  — default, 20% referrer share, 10% trader rebate
 *  Tier 1 SILVER  — $100K total referred volume, 25% share, 12% rebate
 *  Tier 2 GOLD    — $1M total referred volume,  30% share, 15% rebate
 *  Tier 3 DIAMOND — $10M total referred volume, 40% share, 20% rebate
 *
 * ─── REVENUE IMPACT ──────────────────────────────────────────────────────────
 *
 * Protocol net: normal fee × (1 - referrerShare - traderRebate)
 * Net protocol share at Bronze: 1.0 × (1 - 0.20 - 0.10) = 70% of fees
 * BUT: affiliates drive 30-40% more volume → net revenue UP despite the split
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Code uniqueness enforced via mapping — no duplicates
 * [A2] CEI pattern — balances updated before transfers
 * [A3] Only registered fee sources can call recordFee
 * [A4] Referrer cannot be trader (self-referral blocked)
 * [A5] ReentrancyGuard on claim
 */
contract WikiAffiliate is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    uint256 public constant BPS = 10_000;

    // ─── Tier config ──────────────────────────────────────────────────────
    struct Tier {
        uint256 minVolume;       // total referred volume to unlock
        uint256 referrerBps;    // referrer share of fees
        uint256 traderBps;      // trader fee rebate
        string  name;
    }

    Tier[4] public tiers;

    // ─── Referrer data ────────────────────────────────────────────────────
    struct Referrer {
        address addr;
        bytes32 code;
        uint256 totalReferredVolume;  // total notional traded by referees
        uint256 totalFeesEarned;      // lifetime USDC earned
        uint256 pendingClaim;         // USDC claimable now
        uint256 refereeCount;
        uint8   tier;
        uint256 registeredAt;
    }

    mapping(address  => Referrer) public referrers;
    mapping(bytes32  => address)  public codeToReferrer;  // code → referrer addr [A1]
    mapping(address  => address)  public traderReferrer;  // trader → their referrer
    mapping(address  => bool)     public feeSources;      // authorised callers [A3]

    // ─── Trader data ──────────────────────────────────────────────────────
    struct TraderRebate {
        uint256 totalRebateEarned;
        uint256 pendingRebate;
    }
    mapping(address => TraderRebate) public traderRebates;

    // ─── Stats ────────────────────────────────────────────────────────────
    uint256 public totalReferrersPaid;
    uint256 public totalTraderRebates;
    uint256 public totalProtocolKept;
    uint256 public totalReferrers;
    IERC20  public immutable USDC;

    // ─── Events ───────────────────────────────────────────────────────────
    event CodeRegistered(address indexed referrer, bytes32 indexed code);
    event TraderReferred(address indexed trader, address indexed referrer, bytes32 code);
    event FeeRecorded(address indexed trader, address indexed referrer, uint256 fee, uint256 toReferrer, uint256 toTrader);
    event Claimed(address indexed who, uint256 amount, bool isReferrer);
    event TierUpgraded(address indexed referrer, uint8 newTier, string tierName);

    constructor(address _owner, address _usdc) Ownable(_owner) {
        require(_usdc != address(0), "Affiliate: zero usdc");
        USDC = IERC20(_usdc);

        // Set tier schedule
        tiers[0] = Tier(0,                2_000, 1_000, "BRONZE");
        tiers[1] = Tier(100_000  * 1e6,   2_500, 1_200, "SILVER");
        tiers[2] = Tier(1_000_000 * 1e6,  3_000, 1_500, "GOLD");
        tiers[3] = Tier(10_000_000 * 1e6, 4_000, 2_000, "DIAMOND");
    }

    // ─── Register referral code ───────────────────────────────────────────

    /**
     * @notice Register a unique referral code. Free. One per address.
     * @param code A short bytes32 code (e.g. keccak256("ALICE123"))
     */
    function registerCode(bytes32 code) external whenNotPaused {
        require(referrers[msg.sender].addr == address(0), "Affiliate: already registered");
        require(codeToReferrer[code] == address(0),       "Affiliate: code taken"); // [A1]
        require(code != bytes32(0),                       "Affiliate: empty code");

        referrers[msg.sender] = Referrer({
            addr:                  msg.sender,
            code:                  code,
            totalReferredVolume:   0,
            totalFeesEarned:       0,
            pendingClaim:          0,
            refereeCount:          0,
            tier:                  0,
            registeredAt:          block.timestamp
        });
        codeToReferrer[code] = msg.sender;
        totalReferrers++;
        emit CodeRegistered(msg.sender, code);
    }

    // ─── Trader sign-up ───────────────────────────────────────────────────

    /**
     * @notice Trader uses a referral code to bind to a referrer.
     *         Can only be called once per trader address.
     */
    function useCode(bytes32 code) external whenNotPaused {
        require(traderReferrer[msg.sender] == address(0), "Affiliate: already referred");
        address ref = codeToReferrer[code];
        require(ref != address(0),   "Affiliate: unknown code");
        require(ref != msg.sender,   "Affiliate: self-referral"); // [A4]

        traderReferrer[msg.sender] = ref;
        referrers[ref].refereeCount++;
        emit TraderReferred(msg.sender, ref, code);
    }

    // ─── Fee recording (called by WikiPerp / WikiSpot) ────────────────────

    /**
     * @notice Record a trading fee and allocate referrer + trader shares.
     *         Called by WikiPerp.collectFee() and WikiSpot after each trade.
     *
     * @param trader    The trader who paid the fee
     * @param feeUsdc   Fee amount in USDC (6 dec)
     * @param notional  Trade notional (for volume tracking + tier advancement)
     */
    function recordFee(
        address trader,
        uint256 feeUsdc,
        uint256 notional
    ) external whenNotPaused {
        require(feeSources[msg.sender], "Affiliate: not fee source"); // [A3]
        if (feeUsdc == 0) return;

        address ref = traderReferrer[trader];
        if (ref == address(0)) {
            totalProtocolKept += feeUsdc;
            return; // no referrer — protocol keeps all
        }

        Referrer storage r = referrers[ref];
        Tier    memory  t  = tiers[r.tier];

        uint256 toReferrer = feeUsdc * t.referrerBps / BPS;
        uint256 toTrader   = feeUsdc * t.traderBps   / BPS;
        uint256 toProtocol = feeUsdc - toReferrer - toTrader;

        // [A2] Update state before any transfer
        r.pendingClaim           += toReferrer;
        r.totalFeesEarned        += toReferrer;
        r.totalReferredVolume    += notional;
        traderRebates[trader].pendingRebate      += toTrader;
        traderRebates[trader].totalRebateEarned  += toTrader;
        totalReferrersPaid  += toReferrer;
        totalTraderRebates  += toTrader;
        totalProtocolKept   += toProtocol;

        // Advance tier if volume threshold met
        _checkTierUpgrade(r);

        emit FeeRecorded(trader, ref, feeUsdc, toReferrer, toTrader);
    }

    // ─── Claim ────────────────────────────────────────────────────────────

    /// @notice Referrer claims accumulated earnings
    function claimReferrer() external nonReentrant whenNotPaused {
        Referrer storage r = referrers[msg.sender];
        uint256 amt = r.pendingClaim;
        require(amt > 0, "Affiliate: nothing to claim");
        r.pendingClaim = 0; // [A2]
        USDC.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt, true);
    }

    /// @notice Trader claims accumulated fee rebates
    function claimRebate() external nonReentrant whenNotPaused {
        uint256 amt = traderRebates[msg.sender].pendingRebate;
        require(amt > 0, "Affiliate: nothing to claim");
        traderRebates[msg.sender].pendingRebate = 0; // [A2]
        USDC.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt, false);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function getReferrer(address addr) external view returns (Referrer memory) {
        return referrers[addr];
    }

    function getTraderRebate(address trader) external view returns (uint256 pending, uint256 total) {
        return (traderRebates[trader].pendingRebate, traderRebates[trader].totalRebateEarned);
    }

    function lookupCode(bytes32 code) external view returns (address referrer, uint8 tier, string memory tierName) {
        referrer = codeToReferrer[code];
        if (referrer == address(0)) return (address(0), 0, "");
        uint8 t = referrers[referrer].tier;
        return (referrer, t, tiers[t].name);
    }

    function stats() external view returns (
        uint256 totalRefs, uint256 paidToRefs, uint256 paidToTraders, uint256 keptByProtocol
    ) {
        return (totalReferrers, totalReferrersPaid, totalTraderRebates, totalProtocolKept);
    }

    // ─── Internals ────────────────────────────────────────────────────────

    function _checkTierUpgrade(Referrer storage r) internal {
        uint8 newTier = r.tier;
        for (uint8 i = 3; i > r.tier; i--) {
            if (r.totalReferredVolume >= tiers[i].minVolume) {
                newTier = i;
                break;
            }
        }
        if (newTier != r.tier) {
            r.tier = newTier;
            emit TierUpgraded(r.addr, newTier, tiers[newTier].name);
        }
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function setFeeSource(address source, bool enabled) external onlyOwner { feeSources[source] = enabled; }
    function setTier(uint8 idx, uint256 minVol, uint256 refBps, uint256 trdBps, string calldata name) external onlyOwner {
        require(idx < 4, "Affiliate: bad tier");
        tiers[idx] = Tier(minVol, refBps, trdBps, name);
    }
    function fundContract(uint256 amount) external {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
