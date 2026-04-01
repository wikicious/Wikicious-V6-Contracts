// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiMarketMakerAgreement
 * @notice Formal on-chain agreements with professional market makers.
 *         MMs commit to posting two-sided liquidity 24/7.
 *         Protocol pays guaranteed fee rebates + performance bonuses.
 *         This is how Binance, dYdX got deep liquidity on day one.
 *
 * WHAT MARKET MAKERS DO:
 *   Professional MMs (Wintermute, Jump, GSR, Amber) post continuous
 *   two-sided quotes within a tight spread. For every trade that crosses
 *   their quotes they earn the spread. The protocol benefits from:
 *     - Tight spreads (better fills for traders)
 *     - Deep order books (large trades without slippage)
 *     - 24/7 liquidity (even during low retail activity)
 *
 * AGREEMENT STRUCTURE:
 *   MM commits to:
 *     - Minimum uptime: quotes present ≥ 95% of time
 *     - Maximum spread: ≤ X bps (e.g. 5 bps for BTC/USD)
 *     - Minimum depth: ≥ $100K on each side within spread
 *
 *   Protocol pays:
 *     - Maker rebate: 0.02% on all MM-made trades (standard)
 *     - Performance bonus: extra WIK if uptime ≥ 99%
 *     - Volume bonus: extra if MM generates > $X volume
 *
 * ONE GOOD MM AGREEMENT > 1,000 RETAIL LPS for depth and fills
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiMarketMakerAgreement is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IERC20 public immutable WIK;

    enum AgreementStatus { Active, Suspended, Terminated, Pending }

    struct Agreement {
        address  mm;                 // market maker wallet
        string   name;               // e.g. "Wintermute"
        uint256  startTime;
        uint256  endTime;
        uint256  minUptimeBps;       // e.g. 9500 = 95%
        uint256  maxSpreadBps;       // e.g. 5 = 0.05%
        uint256  minDepthUsdc;       // e.g. 100_000e6 = $100K each side
        uint256  makerRebateBps;     // e.g. 2 = 0.02%
        uint256  performanceBonusWIK;// WIK per epoch if uptime met
        uint256  totalRebatesPaid;
        uint256  totalBonusPaid;
        uint256  totalVolumeGenerated;
        uint256  epochCount;
        AgreementStatus status;
    }

    struct EpochReport {
        uint256 agreementId;
        uint256 epoch;
        uint256 uptimeBps;           // actual uptime this epoch
        uint256 avgSpreadBps;        // average spread this epoch
        uint256 avgDepthUsdc;        // average depth this epoch
        uint256 volumeGenerated;
        bool    uptimeMet;
        bool    spreadMet;
        bool    depthMet;
        bool    bonusPaid;
    }

    mapping(uint256 => Agreement)    public agreements;
    mapping(address => uint256)      public mmToAgreement;
    mapping(uint256 => EpochReport[])public epochReports;
    mapping(address => bool)         public reporters;    // authorised to submit reports

    uint256 public nextAgreementId;
    uint256 public epochDuration = 7 days;

    event AgreementCreated(uint256 id, address mm, string name);
    event EpochSettled(uint256 agreementId, uint256 epoch, uint256 rebate, uint256 bonus);
    event AgreementTerminated(uint256 id, string reason);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = router;
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        USDC.approve(address(idleYieldRouter), amount);
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address _owner, address _usdc, address _wik) Ownable(_owner) {
        USDC = IERC20(_usdc);
        WIK  = IERC20(_wik);
        reporters[_owner] = true;
    }

    // ── Create agreement ──────────────────────────────────────────────────
    function createAgreement(
        address mm,
        string  calldata name,
        uint256 durationDays,
        uint256 minUptimeBps,
        uint256 maxSpreadBps,
        uint256 minDepthUsdc,
        uint256 makerRebateBps,
        uint256 performanceBonusWIK
    ) external onlyOwner returns (uint256 id) {
        require(mmToAgreement[mm] == 0, "MMA: MM has active agreement");
        require(minUptimeBps <= 10000,  "MMA: invalid uptime");
        require(makerRebateBps <= 20,   "MMA: max rebate 0.20%");

        id = nextAgreementId++;
        agreements[id] = Agreement({
            mm:                  mm,
            name:                name,
            startTime:           block.timestamp,
            endTime:             block.timestamp + durationDays * 1 days,
            minUptimeBps:        minUptimeBps,
            maxSpreadBps:        maxSpreadBps,
            minDepthUsdc:        minDepthUsdc,
            makerRebateBps:      makerRebateBps,
            performanceBonusWIK: performanceBonusWIK,
            totalRebatesPaid:    0,
            totalBonusPaid:      0,
            totalVolumeGenerated:0,
            epochCount:          0,
            status:              AgreementStatus.Active
        });
        mmToAgreement[mm] = id;
        emit AgreementCreated(id, mm, name);
    }

    // ── Settle an epoch (called by keeper with off-chain report) ──────────
    function settleEpoch(
        uint256 agreementId,
        uint256 uptimeBps,
        uint256 avgSpreadBps,
        uint256 avgDepthUsdc,
        uint256 volumeGenerated,
        uint256 rebateEarned     // actual USDC rebate based on volume
    ) external nonReentrant {
        require(reporters[msg.sender], "MMA: not reporter");
        Agreement storage ag = agreements[agreementId];
        require(ag.status == AgreementStatus.Active, "MMA: not active");

        bool uptimeMet = uptimeBps >= ag.minUptimeBps;
        bool spreadMet = avgSpreadBps <= ag.maxSpreadBps;
        bool depthMet  = avgDepthUsdc >= ag.minDepthUsdc;
        bool bonusPaid = false;
        uint256 bonusWIK;

        // Pay performance bonus if all conditions met
        if (uptimeMet && spreadMet && depthMet) {
            bonusWIK = ag.performanceBonusWIK;
            bonusPaid = true;
            ag.totalBonusPaid += bonusWIK;
        }

        ag.totalRebatesPaid      += rebateEarned;
        ag.totalVolumeGenerated  += volumeGenerated;
        ag.epochCount++;

        // Pay out
        if (rebateEarned > 0 && USDC.balanceOf(address(this)) >= rebateEarned) {
            USDC.safeTransfer(ag.mm, rebateEarned);
        }
        if (bonusWIK > 0 && WIK.balanceOf(address(this)) >= bonusWIK) {
            WIK.safeTransfer(ag.mm, bonusWIK);
        }

        epochReports[agreementId].push(EpochReport({
            agreementId:     agreementId,
            epoch:           ag.epochCount,
            uptimeBps:       uptimeBps,
            avgSpreadBps:    avgSpreadBps,
            avgDepthUsdc:    avgDepthUsdc,
            volumeGenerated: volumeGenerated,
            uptimeMet:       uptimeMet,
            spreadMet:       spreadMet,
            depthMet:        depthMet,
            bonusPaid:       bonusPaid
        }));

        emit EpochSettled(agreementId, ag.epochCount, rebateEarned, bonusWIK);
    }

    // ── Suspend / terminate agreement ─────────────────────────────────────
    function suspendAgreement(uint256 id, string calldata reason) external onlyOwner {
        agreements[id].status = AgreementStatus.Suspended;
        emit AgreementTerminated(id, reason);
    }

    function terminateAgreement(uint256 id, string calldata reason) external onlyOwner {
        agreements[id].status = AgreementStatus.Terminated;
        delete mmToAgreement[agreements[id].mm];
        emit AgreementTerminated(id, reason);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getAgreement(uint256 id) external view returns (Agreement memory) { return agreements[id]; }
    function getEpochHistory(uint256 id) external view returns (EpochReport[] memory) { return epochReports[id]; }

    function getMMAStats(uint256 id) external view returns (
        uint256 totalVolume, uint256 totalRebates, uint256 totalBonus,
        uint256 avgUptimeBps, uint256 epochsCompleted
    ) {
        Agreement storage ag = agreements[id];
        totalVolume    = ag.totalVolumeGenerated;
        totalRebates   = ag.totalRebatesPaid;
        totalBonus     = ag.totalBonusPaid;
        epochsCompleted= ag.epochCount;
        if (epochReports[id].length > 0) {
            uint256 sum;
            for (uint i; i < epochReports[id].length; i++) sum += epochReports[id][i].uptimeBps;
            avgUptimeBps = sum / epochReports[id].length;
        }
    }

    function setReporter(address r, bool on) external onlyOwner { reporters[r] = on; }
    function fundRebates(uint256 amount) external onlyOwner { USDC.safeTransferFrom(msg.sender, address(this), amount); }
    function fundBonuses(uint256 amount) external onlyOwner { WIK.safeTransferFrom(msg.sender, address(this), amount); }
}
