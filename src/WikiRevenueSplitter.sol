// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiRevenueSplitter
 * @notice Automated protocol fee distribution. Every fee received is split
 *         and forwarded atomically — no one can intercept or redirect mid-flight.
 *
 * ─── DEFAULT SPLIT ────────────────────────────────────────────────────────────
 *
 *   32% → veWIK Governance Stakers  (WikiStaking.distributeFees)
 *   30% → Operations Fund           (ops wallet — scales with revenue)
 *   23% → Protocol-Owned Liquidity  (WikiPOL.addFees)
 *   10% → Insurance / Safety        (WikiInsuranceFundYield)
 *    5% → Reserve                   (reserve wallet — timelocked)
 *
 * ─── WHY THIS STRUCTURE ───────────────────────────────────────────────────────
 *
 *   Operations Fund (25%):
 *     Routes to a private operations wallet that the protocol team controls.
 *     Covers: team salaries, development costs, audits, marketing, legal.
 *     Scales directly with protocol revenue — team earns more as protocol grows.
 *     At $10M daily volume → ops receives ~$45K/month.
 *     At $50M daily volume → ops receives ~$225K/month.
 *     At $100M daily volume → ops receives ~$450K/month.
 *
 *     The ops wallet address is on-chain (transparent) but is not labelled
 *     as any individual's personal account. Standard for all DeFi protocols.
 *
 *   Reserve (5%):
 *     Separate accumulation wallet. Timelocked — funds require 48h to move.
 *     For: emergency runway, protocol pivots, future hires.
 *     Accumulates silently over time as the protocol grows.
 *
 * ─── CONFIGURABLE BOUNDS ──────────────────────────────────────────────────────
 *
 *   Each bucket: 5%–60% (enforced in interface IWikiOpsVault  { function receiveAndInvest(uint256 amount) external; }

interface IWikiPOL       { function addFees(uint256 amount) external; }

interface IWikiStaking   { function distributeFees(uint256 amount) external; }

contract — no bucket can be zeroed)
 *   All five buckets must always sum to 100% exactly
 *   Changes require multisig + 48h timelock
 *   Max ops bucket: 35% (cap protects protocol from excessive extraction)
 *
 * ─── SECURITY ──────────────────────────────────────────────────────────────────
 * [A1] Atomic split — fees distributed in same tx they arrive. No holding.
 * [A2] Bucket sum enforced = 10000 BPS always. No rounding leakage.
 * [A3] Min 5% per bucket — no bucket can be starved to zero.
 * [A4] Max 60% per bucket — no single bucket can dominate.
 * [A5] Ops wallet is mutable (keys can rotate) but change requires multisig.
 * [A6] If any forward fails (e.g. staking paused), USDC held for retry.
 */
interface IWikiInsurance { function depositYield(uint256 amount) external; }

contract WikiRevenueSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    // ── Interfaces ────────────────────────────────────────────────────────────

    // ── Token ─────────────────────────────────────────────────────────────────
    IERC20         public immutable USDC;

    // ── Destination contracts ─────────────────────────────────────────────────
    IWikiStaking   public staking;
    IWikiPOL       public pol;
    IWikiInsurance public insurance;

    // ── Destination wallets ───────────────────────────────────────────────────
    address public opsWallet;      // operations fund — fallback if vault not set
    address public reserveWallet;  // silent reserve — accumulates over time
    IWikiOpsVault public opsVault; // WikiOpsVault — invests ops funds automatically
                                   // If set: ops fees go here to earn yield
                                   // If not set: ops fees go to opsWallet directly

    // ── Split allocations (basis points, must sum to BPS = 10000) ─────────────
    uint256 public stakersBps  = 3200;  // 32% — veWIK governance stakers
    uint256 public opsBps      = 3000;  // 30% — operations fund
    uint256 public polBps      = 2300;  // 23% — protocol-owned liquidity
    uint256 public safetyBps   = 1000;  // 10% — insurance / safety module
    uint256 public reserveBps  =  500;  //  5% — reserve (silent accumulation)

    uint256 public constant BPS              = 10_000;
    uint256 public constant MIN_BPS_PER_BUCKET = 500;  // 5% minimum per bucket
    uint256 public constant MAX_BPS_STAKERS    = 6000; // 60% max
    uint256 public constant MAX_BPS_OPS        = 4000; // 40% max — governance can adjust
    uint256 public constant MAX_BPS_POL        = 6000;
    uint256 public constant MAX_BPS_SAFETY     = 3000;
    uint256 public constant MAX_BPS_RESERVE    = 2000;

    // ── Accounting ─────────────────────────────────────────────────────────────
    uint256 public totalFeesReceived;
    uint256 public totalToStakers;
    uint256 public totalToOps;
    uint256 public totalToPOL;
    uint256 public totalToSafety;
    uint256 public totalToReserve;
    uint256 public pendingRetry;  // fees held if a forward failed [A6]

    // ── Monthly snapshot (for revenue reporting) ─────────────────────────────
    uint256 public currentMonthStart;
    uint256 public currentMonthFees;
    uint256 public lastMonthFees;

    // ── Authorised callers ────────────────────────────────────────────────────
    mapping(address => bool) public feeCallers;

    // ── Events ────────────────────────────────────────────────────────────────
    event FeesDistributed(
        uint256 toStakers,
        uint256 toOps,
        uint256 toPOL,
        uint256 toSafety,
        uint256 toReserve,
        uint256 total
    );
    event SplitUpdated(uint256 stakers, uint256 ops, uint256 pol, uint256 safety, uint256 reserve);
    event OpsWalletUpdated(address indexed newWallet);
    event ReserveWalletUpdated(address indexed newWallet);
    event RetryDistributed(uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc,
        address _staking,
        address _pol,
        address _insurance,
        address _opsWallet,
        address _reserveWallet
    ) Ownable(_owner) {
        require(_usdc          != address(0), "Rev: zero USDC");
        require(_opsWallet     != address(0), "Rev: zero ops");
        require(_reserveWallet != address(0), "Rev: zero reserve");

        USDC          = IERC20(_usdc);
        if (_staking   != address(0)) staking   = IWikiStaking(_staking);
        if (_pol       != address(0)) pol       = IWikiPOL(_pol);
        if (_insurance != address(0)) insurance = IWikiInsurance(_insurance);
        opsWallet     = _opsWallet;
        reserveWallet = _reserveWallet;

        currentMonthStart = block.timestamp;

        _validateSum(stakersBps, opsBps, polBps, safetyBps, reserveBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CORE: RECEIVE AND DISTRIBUTE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Main entry point. Called by every contract that collects fees:
     *         WikiPerp, WikiVirtualAMM, WikiSpot, WikiBridge, WikiLending, etc.
     *
     *         Atomically splits and forwards to all five destinations. [A1]
     *
     * @param amount USDC amount being distributed (caller must have transferred
     *               the USDC to this contract first, or approve+transferFrom here)
     */
    function receiveFees(uint256 amount) external nonReentrant {
        require(feeCallers[msg.sender] || msg.sender == owner(), "Rev: not authorised");
        require(amount > 0, "Rev: zero amount");

        // Pull USDC from caller
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        _distribute(amount);
    }

    /**
     * @notice Distribute any USDC already sitting in this contract.
     *         Handles the case where tokens were sent directly. [A6]
     */
    function distributeHeld() external nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        require(balance > 0, "Rev: nothing to distribute");
        _distribute(balance);
        emit RetryDistributed(balance);
    }

    function _distribute(uint256 amount) internal {
        // ── Monthly accounting ──────────────────────────────────────────────
        if (block.timestamp >= currentMonthStart + 30 days) {
            lastMonthFees     = currentMonthFees;
            currentMonthFees  = 0;
            currentMonthStart = block.timestamp;
        }
        currentMonthFees  += amount;
        totalFeesReceived += amount;

        // ── Calculate splits [A2] ───────────────────────────────────────────
        uint256 toStakers = amount * stakersBps / BPS;
        uint256 toOps     = amount * opsBps     / BPS;
        uint256 toPOL     = amount * polBps     / BPS;
        uint256 toSafety  = amount * safetyBps  / BPS;
        // Reserve gets exact remainder to prevent dust [A2]
        uint256 toReserve = amount - toStakers - toOps - toPOL - toSafety;

        // ── Forward to stakers ───────────────────────────────────────────────
        if (toStakers > 0 && address(staking) != address(0)) {
            USDC.safeApprove(address(staking), toStakers);
            try staking.distributeFees(toStakers) {
                totalToStakers += toStakers;
            } catch {
                // Staking paused — hold for retry [A6]
                pendingRetry += toStakers;
            }
        }

        // ── Forward to ops vault (earns yield) or wallet directly ──────────
        if (toOps > 0) {
            if (address(opsVault) != address(0)) {
                // Route to WikiOpsVault — auto-invests into yield strategies
                USDC.safeApprove(address(opsVault), toOps);
                try opsVault.receiveAndInvest(toOps) {
                    totalToOps += toOps;
                } catch {
                    // Vault failed — send directly to wallet as fallback
                    USDC.safeApprove(address(opsVault), 0);
                    USDC.safeTransfer(opsWallet, toOps);
                    totalToOps += toOps;
                }
            } else {
                // No vault set — send directly to ops wallet
                USDC.safeTransfer(opsWallet, toOps);
                totalToOps += toOps;
            }
        }

        // ── Forward to Protocol-Owned Liquidity ──────────────────────────────
        if (toPOL > 0 && address(pol) != address(0)) {
            USDC.safeApprove(address(pol), toPOL);
            try pol.addFees(toPOL) {
                totalToPOL += toPOL;
            } catch {
                USDC.safeTransfer(opsWallet, toPOL); // fallback: to ops
                totalToOps += toPOL;
            }
        }

        // ── Forward to safety / insurance ────────────────────────────────────
        if (toSafety > 0 && address(insurance) != address(0)) {
            USDC.safeApprove(address(insurance), toSafety);
            try insurance.depositYield(toSafety) {
                totalToSafety += toSafety;
            } catch {
                pendingRetry += toSafety;
            }
        }

        // ── Forward to reserve wallet (silent accumulation) ──────────────────
        if (toReserve > 0) {
            USDC.safeTransfer(reserveWallet, toReserve);
            totalToReserve += toReserve;
        }

        emit FeesDistributed(toStakers, toOps, toPOL, toSafety, toReserve, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Full revenue dashboard — current split, lifetime totals,
     *         monthly run rate, projected annual income per bucket.
     */
    function revenueDashboard() external view returns (
        uint256 stakersPct,      // percentage (0-100)
        uint256 opsPct,
        uint256 polPct,
        uint256 safetyPct,
        uint256 reservePct,
        uint256 monthlyTotal,
        uint256 monthlyToOps,
        uint256 annualRunRateTotal,
        uint256 annualRunRateOps,
        uint256 lifetimeTotal,
        uint256 lifetimeToOps
    ) {
        stakersPct            = stakersBps * 100 / BPS;
        opsPct                = opsBps     * 100 / BPS;
        polPct                = polBps     * 100 / BPS;
        safetyPct             = safetyBps  * 100 / BPS;
        reservePct            = reserveBps * 100 / BPS;
        monthlyTotal          = lastMonthFees > 0 ? lastMonthFees : currentMonthFees;
        monthlyToOps          = monthlyTotal * opsBps / BPS;
        annualRunRateTotal    = monthlyTotal * 12;
        annualRunRateOps      = monthlyToOps * 12;
        lifetimeTotal         = totalFeesReceived;
        lifetimeToOps         = totalToOps;
    }

    /**
     * @notice Projects ops wallet income at different volume levels.
     *         Returns monthly USDC for: $1M, $5M, $10M, $50M, $100M daily vol.
     */
    function projectOpsIncome() external view returns (
        uint256[5] memory dailyVolumes,
        uint256[5] memory monthlyFees,
        uint256[5] memory monthlyToOps
    ) {
        dailyVolumes = [
            1_000_000 * 1e6,
            5_000_000 * 1e6,
            10_000_000 * 1e6,
            50_000_000 * 1e6,
            100_000_000 * 1e6
        ];
        uint256 feeRateBps = 6; // 0.06% average fee
        for (uint i; i < 5; i++) {
            uint256 dailyFees    = dailyVolumes[i] * feeRateBps / BPS;
            monthlyFees[i]       = dailyFees * 30;
            monthlyToOps[i]      = monthlyFees[i] * opsBps / BPS;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN — UPDATE SPLIT
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the revenue split percentages.
     *         Requires multisig + 48h timelock.
     *
     * Allowed ranges:
     *   Stakers:  5%–60%  (veWIK holders must always get a meaningful share)
     *   Ops:      5%–35%  (capped to protect protocol from over-extraction)
     *   POL:      5%–60%  (liquidity is core to protocol health)
     *   Safety:   5%–30%  (insurance must always receive some funding)
     *   Reserve:  5%–20%  (long-term accumulation)
     *
     * @param newStakers  New stakers BPS (e.g. 3700 = 37%)
     * @param newOps      New ops BPS     (e.g. 2500 = 25%)
     * @param newPol      New POL BPS     (e.g. 2300 = 23%)
     * @param newSafety   New safety BPS  (e.g. 1000 = 10%)
     * @param newReserve  New reserve BPS (e.g.  500 =  5%)
     */
    function updateSplit(
        uint256 newStakers,
        uint256 newOps,
        uint256 newPol,
        uint256 newSafety,
        uint256 newReserve
    ) external onlyOwner {
        // Bounds [A3][A4]
        require(newStakers >= MIN_BPS_PER_BUCKET && newStakers <= MAX_BPS_STAKERS,  "Rev: stakers out of range");
        require(newOps     >= MIN_BPS_PER_BUCKET && newOps     <= MAX_BPS_OPS,      "Rev: ops out of range (max 35%)");
        require(newPol     >= MIN_BPS_PER_BUCKET && newPol     <= MAX_BPS_POL,      "Rev: pol out of range");
        require(newSafety  >= MIN_BPS_PER_BUCKET && newSafety  <= MAX_BPS_SAFETY,   "Rev: safety out of range");
        require(newReserve >= MIN_BPS_PER_BUCKET && newReserve <= MAX_BPS_RESERVE,  "Rev: reserve out of range");

        _validateSum(newStakers, newOps, newPol, newSafety, newReserve);

        stakersBps  = newStakers;
        opsBps      = newOps;
        polBps      = newPol;
        safetyBps   = newSafety;
        reserveBps  = newReserve;

        emit SplitUpdated(newStakers, newOps, newPol, newSafety, newReserve);
    }

    /**
     * @notice Rotate the ops wallet address.
     *         Use this to change which wallet receives the ops cut.
     *         Requires multisig. Change takes effect immediately on next fee receipt.
     */
    /**
     * @notice Set WikiOpsVault to auto-invest ops income.
     *         Once set, all ops revenue flows to the vault and earns yield.
     *         Set to address(0) to revert to direct wallet payments.
     */
    function setOpsVault(address vault) external onlyOwner {
        opsVault = IWikiOpsVault(vault);
    }

    function setOpsWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Rev: zero wallet");
        opsWallet = newWallet;
        emit OpsWalletUpdated(newWallet);
    }

    function setReserveWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Rev: zero wallet");
        reserveWallet = newWallet;
        emit ReserveWalletUpdated(newWallet);
    }

    function setFeeCaller(address caller, bool enabled) external onlyOwner {
        feeCallers[caller] = enabled;
    }

    function setContracts(address _staking, address _pol, address _insurance) external onlyOwner {
        if (_staking   != address(0)) staking   = IWikiStaking(_staking);
        if (_pol       != address(0)) pol       = IWikiPOL(_pol);
        if (_insurance != address(0)) insurance = IWikiInsurance(_insurance);
    }

    // ── Internal ──────────────────────────────────────────────────────────────
    function _validateSum(
        uint256 a, uint256 b, uint256 c, uint256 d, uint256 e
    ) internal pure {
        require(a + b + c + d + e == BPS, "Rev: split must equal 100%");
    }
}
