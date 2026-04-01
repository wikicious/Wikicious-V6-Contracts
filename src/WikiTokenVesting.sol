// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiTokenVesting
 * @notice Manages token vesting for team, advisors, and investors.
 *         Enforces the allocation schedule defined in WIKToken.sol.
 *
 * ─── TEAM VESTING (15% of supply = 150M WIK) ─────────────────────────────────
 *
 *   Timeline: deployed at TGE (token generation event)
 *   Cliff:    1 year — ZERO tokens claimable for first 12 months
 *   Vesting:  After cliff, linear over 3 years (36 monthly unlocks)
 *   Monthly:  150M / 36 = 4.17M WIK/month
 *
 *   Example: Founder holds 60% of team allocation = 90M WIK
 *     Month 1-12:   $0 in WIK (cliff)
 *     Month 13:     First unlock: 60% of 4.17M = 2.5M WIK (~$250K at $0.10)
 *     Month 14-48:  2.5M WIK/month continuously
 *
 * ─── INVESTOR VESTING (10% of supply = 100M WIK) ─────────────────────────────
 *
 *   Cliff:    6 months
 *   Vesting:  After cliff, linear over 2 years (24 monthly unlocks)
 *   Monthly:  100M / 24 = 4.17M WIK/month
 *
 * ─── HOW FOUNDER CLAIMS ──────────────────────────────────────────────────────
 *
 *   1. Multisig calls: addBeneficiary(founderWallet, amount, TEAM, 1yr, 3yr)
 *   2. After 12 months: founder calls claim() → receives WIK in wallet
 *   3. Founder can sell, stake as veWIK, or hold
 *   4. Best practice: stake 70% as veWIK to earn fee income, sell 30% gradually
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] Cliff is enforced — no early claim possible
 * [A2] Linear release — cannot claim future tokens early
 * [A3] Revocation: owner can revoke unvested tokens (sends back to treasury)
 *       but CANNOT claw back already-vested tokens
 * [A4] All schedules public — anyone can verify your vesting on-chain
 */
contract WikiTokenVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable WIK;

    // ── Enums ─────────────────────────────────────────────────────────────────
    enum VestingType { TEAM, INVESTOR, ADVISOR, CUSTOM }

    // ── Structs ───────────────────────────────────────────────────────────────
    struct Schedule {
        address beneficiary;
        string  name;           // e.g. "Founder / CEO", "Seed Investor A"
        uint256 totalAmount;    // total WIK to vest
        uint256 claimedAmount;  // WIK already claimed
        uint256 startTime;      // when vesting starts (TGE timestamp)
        uint256 cliffDuration;  // seconds of cliff (e.g. 365 days for 1 year)
        uint256 vestingDuration;// seconds of linear vesting after cliff
        VestingType vestingType;
        bool    revoked;
        bool    active;
    }

    Schedule[] public schedules;
    mapping(address => uint256[]) public beneficiarySchedules; // wallet → schedule IDs

    // ── Events ────────────────────────────────────────────────────────────────
    event ScheduleAdded(uint256 indexed id, address indexed beneficiary, string name, uint256 amount, VestingType vestType);
    event Claimed(uint256 indexed id, address indexed beneficiary, uint256 amount, uint256 remaining);
    event Revoked(uint256 indexed id, address indexed beneficiary, uint256 unvestedReturned);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address _owner, address _wik) Ownable(_owner) {
        require(_wik != address(0), "Vest: zero WIK");
        WIK = IERC20(_wik);
    }

    // ── Admin: add vesting schedules ──────────────────────────────────────────

    /**
     * @notice Add a vesting schedule for a team member or investor.
     *         Only multisig owner can call this.
     *         WIK tokens must already be in this contract (minted here at TGE).
     *
     * @param beneficiary   Wallet that will receive tokens
     * @param name          Identifying name (stored on-chain for transparency)
     * @param totalAmount   Total WIK to vest
     * @param vestType      TEAM, INVESTOR, ADVISOR, or CUSTOM
     * @param cliffDays     Days before any tokens unlock (0 = no cliff)
     * @param vestingDays   Days of linear vesting after cliff
     *
     * Common presets:
     *   TEAM:     cliffDays=365, vestingDays=1095 (1yr cliff + 3yr vesting)
     *   INVESTOR: cliffDays=180, vestingDays=730  (6mo cliff + 2yr vesting)
     *   ADVISOR:  cliffDays=180, vestingDays=365  (6mo cliff + 1yr vesting)
     */
    function addBeneficiary(
        address      beneficiary,
        string calldata name,
        uint256      totalAmount,
        VestingType  vestType,
        uint256      cliffDays,
        uint256      vestingDays
    ) external onlyOwner returns (uint256 scheduleId) {
        require(beneficiary != address(0),    "Vest: zero address");
        require(totalAmount > 0,              "Vest: zero amount");
        require(vestingDays > 0,              "Vest: zero vesting");
        require(bytes(name).length > 0,       "Vest: empty name");

        // Confirm contract holds enough WIK
        uint256 committed = _totalCommitted();
        uint256 available = WIK.balanceOf(address(this));
        require(available >= committed + totalAmount, "Vest: insufficient WIK balance");

        scheduleId = schedules.length;
        schedules.push(Schedule({
            beneficiary:     beneficiary,
            name:            name,
            totalAmount:     totalAmount,
            claimedAmount:   0,
            startTime:       block.timestamp,
            cliffDuration:   cliffDays * 1 days,
            vestingDuration: vestingDays * 1 days,
            vestingType:     vestType,
            revoked:         false,
            active:          true
        }));

        beneficiarySchedules[beneficiary].push(scheduleId);
        emit ScheduleAdded(scheduleId, beneficiary, name, totalAmount, vestType);
    }

    /**
     * @notice Quick preset: add team member with standard 1yr cliff + 3yr vesting.
     *         Convenience wrapper — same as addBeneficiary with cliff=365, vest=1095.
     */
    function addTeamMember(
        address beneficiary,
        string calldata name,
        uint256 totalWIK
    ) external onlyOwner returns (uint256) {
        return this.addBeneficiary(beneficiary, name, totalWIK, VestingType.TEAM, 365, 1095);
    }

    /**
     * @notice Quick preset: add investor with standard 6mo cliff + 2yr vesting.
     */
    function addInvestor(
        address beneficiary,
        string calldata name,
        uint256 totalWIK
    ) external onlyOwner returns (uint256) {
        return this.addBeneficiary(beneficiary, name, totalWIK, VestingType.INVESTOR, 180, 730);
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    /**
     * @notice Claim all currently vested tokens across all schedules.
     *         Call this after cliff has passed.
     *
     * This is how the FOUNDER withdraws their team allocation:
     *   → Call claim() after month 12
     *   → Receive WIK in wallet
     *   → Sell gradually or stake as veWIK for passive income
     */
    function claim() external nonReentrant returns (uint256 totalClaimed) {
        uint256[] storage ids = beneficiarySchedules[msg.sender];
        require(ids.length > 0, "Vest: no schedules");

        for (uint256 i; i < ids.length; i++) {
            Schedule storage s = schedules[ids[i]];
            if (!s.active || s.revoked) continue;

            uint256 vested = _vestedAmount(s);
            uint256 claimable = vested - s.claimedAmount;
            if (claimable == 0) continue;

            s.claimedAmount += claimable;
            totalClaimed    += claimable;
            emit Claimed(ids[i], msg.sender, claimable, s.totalAmount - s.claimedAmount);
        }

        require(totalClaimed > 0, "Vest: nothing to claim");
        WIK.safeTransfer(msg.sender, totalClaimed);
    }

    /**
     * @notice Claim tokens from a specific schedule ID.
     */
    function claimSchedule(uint256 scheduleId) external nonReentrant returns (uint256 claimable) {
        Schedule storage s = schedules[scheduleId];
        require(s.beneficiary == msg.sender, "Vest: not beneficiary");
        require(s.active && !s.revoked,      "Vest: not active");

        uint256 vested = _vestedAmount(s);
        claimable = vested - s.claimedAmount;
        require(claimable > 0, "Vest: nothing claimable");

        s.claimedAmount += claimable;
        WIK.safeTransfer(msg.sender, claimable);
        emit Claimed(scheduleId, msg.sender, claimable, s.totalAmount - s.claimedAmount);
    }

    // ── Revocation (unvested tokens only) ────────────────────────────────────

    /**
     * @notice Revoke unvested tokens from a schedule.
     *         IMPORTANT: only unvested tokens return to treasury.
     *         Already-vested tokens ALWAYS remain claimable by beneficiary. [A3]
     *
     * Use case: team member leaves before fully vested.
     */
    function revoke(uint256 scheduleId, address returnTo) external onlyOwner {
        Schedule storage s = schedules[scheduleId];
        require(s.active && !s.revoked, "Vest: not revocable");

        uint256 vested   = _vestedAmount(s);
        uint256 unvested = s.totalAmount - vested;
        require(unvested > 0, "Vest: fully vested");

        s.revoked        = true;
        s.totalAmount    = vested; // beneficiary can still claim what they earned

        if (unvested > 0 && returnTo != address(0)) {
            WIK.safeTransfer(returnTo, unvested);
        }
        emit Revoked(scheduleId, s.beneficiary, unvested);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /**
     * @notice Get claimable WIK right now for a wallet.
     *         Frontend uses this to show "You can claim X WIK today."
     */
    function claimableNow(address wallet) external view returns (
        uint256 totalClaimable,
        uint256[] memory ids,
        uint256[] memory amounts
    ) {
        uint256[] memory walletIds = beneficiarySchedules[wallet];
        amounts = new uint256[](walletIds.length);

        for (uint256 i; i < walletIds.length; i++) {
            Schedule memory s = schedules[walletIds[i]];
            if (!s.active || s.revoked) continue;
            uint256 claimable = _vestedAmount(s) - s.claimedAmount;
            amounts[i]      = claimable;
            totalClaimable  += claimable;
        }
        ids = walletIds;
    }

    /**
     * @notice Full vesting status for a wallet.
     *         Shows cliff countdown, monthly unlock rate, and total value.
     */
    function vestingStatus(address wallet) external view returns (
        uint256 totalAllocated,
        uint256 totalVested,
        uint256 totalClaimed_,
        uint256 totalClaimableNow,
        uint256 cliffEndsAt,
        uint256 fullyVestedAt,
        uint256 monthlyUnlockRate,
        bool    cliffPassed
    ) {
        uint256[] memory walletIds = beneficiarySchedules[wallet];
        for (uint256 i; i < walletIds.length; i++) {
            Schedule memory s = schedules[walletIds[i]];
            if (!s.active) continue;

            totalAllocated     += s.totalAmount;
            totalVested        += _vestedAmount(s);
            totalClaimed_      += s.claimedAmount;
            totalClaimableNow  += _vestedAmount(s) - s.claimedAmount;

            uint256 cliffEnd   = s.startTime + s.cliffDuration;
            uint256 vestEnd    = cliffEnd + s.vestingDuration;
            if (cliffEndsAt == 0 || cliffEnd < cliffEndsAt)   cliffEndsAt   = cliffEnd;
            if (fullyVestedAt == 0 || vestEnd > fullyVestedAt) fullyVestedAt = vestEnd;

            // Monthly rate = totalAmount / vestingDuration in months
            uint256 vestMonths = s.vestingDuration / 30 days;
            if (vestMonths > 0) monthlyUnlockRate += s.totalAmount / vestMonths;
        }
        cliffPassed = block.timestamp >= cliffEndsAt;
    }

    /**
     * @notice Public schedule listing — full transparency. [A4]
     */
    function allSchedules() external view returns (Schedule[] memory) {
        return schedules;
    }

    function schedulesFor(address wallet) external view returns (Schedule[] memory) {
        uint256[] memory ids = beneficiarySchedules[wallet];
        Schedule[] memory result = new Schedule[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            result[i] = schedules[ids[i]];
        }
        return result;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _vestedAmount(Schedule memory s) internal view returns (uint256) {
        if (s.revoked) return s.totalAmount; // revoked: beneficiary keeps vested portion

        uint256 cliffEnd = s.startTime + s.cliffDuration;

        // [A1] Before cliff: nothing vested
        if (block.timestamp < cliffEnd) return 0;

        // After full vesting period: everything vested
        uint256 vestEnd = cliffEnd + s.vestingDuration;
        if (block.timestamp >= vestEnd) return s.totalAmount;

        // [A2] Linear vesting between cliff and vestEnd
        uint256 elapsed = block.timestamp - cliffEnd;
        return s.totalAmount * elapsed / s.vestingDuration;
    }

    function _totalCommitted() internal view returns (uint256 total) {
        for (uint256 i; i < schedules.length; i++) {
            if (schedules[i].active && !schedules[i].revoked) {
                total += schedules[i].totalAmount - schedules[i].claimedAmount;
            }
        }
    }
}
