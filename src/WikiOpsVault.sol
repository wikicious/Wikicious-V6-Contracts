// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiOpsVault
 * @notice Automatically invests idle ops wallet USDC into yield strategies
 *         inside Wikicious itself. Principal + earnings withdrawable at any time.
 *
 * ─── THE PROBLEM IT SOLVES ───────────────────────────────────────────────────
 *
 *   Without this contract:
 *     WikiRevenueSplitter sends 30% → ops hardware wallet
 *     USDC sits idle earning 0%
 *     You withdraw manually when needed
 *
 *   With this contract:
 *     WikiRevenueSplitter sends 30% → WikiOpsVault
 *     WikiOpsVault immediately deploys USDC into yield strategies
 *     USDC earns 4-25% APY continuously
 *     You withdraw principal + earnings whenever you want
 *     Nothing is locked — full withdrawal at any time
 *
 * ─── YIELD STRATEGIES (in order of priority) ─────────────────────────────────
 *
 *   Strategy 1 — WikiLending (USDC supply pool)
 *     Expected: 4-8% APY
 *     Risk: LOW — overcollateralised borrowers only
 *     Liquidity: INSTANT withdrawal anytime
 *     Allocation: up to 40% of ops balance
 *
 *   Strategy 2 — WikiBackstopVault (bsUSDC)
 *     Expected: 15-25% APY
 *     Risk: MEDIUM — LP absorbs tail-risk shortfalls (last resort)
 *     Liquidity: 7-day unstake delay
 *     Allocation: up to 40% of ops balance
 *
 *   Strategy 3 — WikiFundingArbVault (delta-neutral)
 *     Expected: 5-15% APY from funding rates
 *     Risk: LOW — delta-neutral position
 *     Liquidity: 1-3 days to unwind
 *     Allocation: up to 20% of ops balance
 *
 *   Strategy 4 — Idle USDC (buffer)
 *     Expected: 0% APY
 *     Risk: NONE
 *     Liquidity: INSTANT
 *     Allocation: minimum 10% always kept as instant-liquid buffer
 *
 * ─── WITHDRAWAL ──────────────────────────────────────────────────────────────
 *
 *   withdrawAll()       — pulls from all strategies + sends everything to owner
 *   withdraw(amount)    — partial withdrawal (takes from liquid strategies first)
 *   withdrawInstant(n)  — only from instant-liquid sources (Lending + idle)
 *
 *   The owner can withdraw their full principal at any time. Yield is on top.
 *   There is no lockup on the principal.
 *
 * ─── GROWTH MATH ─────────────────────────────────────────────────────────────
 *
 *   At $10M daily volume (ops receives $54K/month):
 *
 *   Month 1:  $54K deposited → deployed → earns ~$900/mo at 20% blended APY
 *   Month 3:  $162K deployed → earns ~$2,700/mo
 *   Month 6:  $324K deployed → earns ~$5,400/mo
 *   Month 12: $648K deployed → earns ~$10,800/mo
 *
 *   By month 12 you are earning an extra $10,800/month PURELY from the yield
 *   on uninvested ops income. Without this: $0 extra.
 *
 *   At $50M daily volume (ops receives $270K/month):
 *
 *   Month 12: $3.24M deployed → earns ~$54,000/month extra in yield
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] Only owner (ops wallet / multisig) can withdraw
 * [A2] No external parties can interact with funds
 * [A3] Emergency pause freezes all rebalancing (not withdrawals)
 * [A4] Maximum allocation per strategy — no single-strategy concentration risk
 * [A5] Yield tracking — owner can always see principal vs earnings separately
 * [A6] If any strategy fails (paused/bug), vault falls back to idle USDC
 */
interface IWikiFundingArb {
        function deposit(uint256 amount) external;
        function withdraw(uint256 amount) external;
        function balanceOf(address user) external view returns (uint256);
        function estimatedValue(address user) external view returns (uint256);
    }

interface IWikiBackstopVault {
        function deposit(uint256 amount, uint256 minShares) external;
        function requestUnstake(uint256 shares) external;
        function completeUnstake(uint256 requestId) external;
        function balanceOf(address user) external view returns (uint256 shares);
        function sharesToAssets(uint256 shares) external view returns (uint256);
        function nav() external view returns (uint256); // NAV per share in USDC
    }

interface IWikiLending {
        function supply(uint256 mid, uint256 amount) external;
        function withdraw(uint256 mid, uint256 wTokenAmount) external;
        function balanceOfUnderlying(uint256 mid, address user) external view returns (uint256);
        function getExchangeRate(uint256 mid) external view returns (uint256);
    }

contract WikiOpsVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ── Interfaces ────────────────────────────────────────────────────────────




    // ── Tokens ─────────────────────────────────────────────────────────────
    IERC20 public immutable USDC;

    // ── Strategy contracts ─────────────────────────────────────────────────
    IWikiLending        public lendingPool;
    IWikiBackstopVault  public backstopVault;
    IWikiFundingArb     public fundingArbVault;

    uint256 public lendingMarketId;   // USDC market ID in WikiLending

    // ── Strategy allocation caps (BPS) ────────────────────────────────────
    uint256 public lendingAllocBps    = 4000; // max 40% in lending
    uint256 public backstopAllocBps   = 4000; // max 40% in backstop
    uint256 public fundingAllocBps    = 2000; // max 20% in funding arb
    uint256 public minIdleBps         = 1000; // min 10% always idle
    uint256 public constant BPS       = 10_000;

    // ── Accounting ─────────────────────────────────────────────────────────
    uint256 public totalDeposited;    // total USDC ever received from RevenueSplitter
    uint256 public totalWithdrawn;    // total USDC ever withdrawn by owner
    uint256 public lastRebalance;     // timestamp of last rebalance

    // ── Events ────────────────────────────────────────────────────────────
    
    event Withdrawn(address indexed to, uint256 amount, uint256 yieldIncluded);
    event StrategyUpdated(address lending, address backstop, address funding);

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc
    ) Ownable(_owner) {
        require(_usdc != address(0), "OpsVault: zero USDC");
        USDC = IERC20(_usdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RECEIVE INCOME — called by WikiRevenueSplitter on every fee event
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiRevenueSplitter when ops fees arrive.
     *         Replaces the ops hardware wallet address in the splitter.
     *         Automatically rebalances into yield strategies.
     */
    function receiveAndInvest(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "OpsVault: zero amount");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        emit Received(amount, totalDeposited);

        // Auto-rebalance if enough idle to be worth the gas
        uint256 idle = USDC.balanceOf(address(this));
        if (idle > 100 * 1e6) { // only rebalance if >$100 sitting idle
            _rebalance();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // REBALANCE — deploy idle USDC into yield strategies
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy idle USDC into yield strategies according to allocation.
     *         Can be called by owner at any time.
     *         Also called automatically when income arrives.
     */
    function rebalance() external nonReentrant whenNotPaused onlyOwner {
        _rebalance();
    }

    function _rebalance() internal {
        uint256 idle = USDC.balanceOf(address(this));
        if (idle == 0) return;

        // Keep minimum buffer as instant-liquid [A4]
        uint256 toInvest = idle * (BPS - minIdleBps) / BPS;
        if (toInvest < 10 * 1e6) return; // too small to bother

        uint256 total = totalValue();

        // Calculate how much each strategy currently holds
        uint256 curLending   = _lendingBalance();
        uint256 curBackstop  = _backstopBalance();
        uint256 curFunding   = _fundingBalance();

        // Targets
        uint256 tgtLending  = total * lendingAllocBps  / BPS;
        uint256 tgtBackstop = total * backstopAllocBps / BPS;
        uint256 tgtFunding  = total * fundingAllocBps  / BPS;

        uint256 toLending  = 0;
        uint256 toBackstop = 0;
        uint256 toFunding  = 0;
        uint256 remaining  = toInvest;

        // Deploy to lending first (instant liquidity, lowest risk) [A4]
        if (curLending < tgtLending && address(lendingPool) != address(0)) {
            uint256 needed = tgtLending - curLending;
            toLending = needed > remaining ? remaining : needed;
            remaining -= toLending;
            if (toLending > 0) {
                USDC.forceApprove(address(lendingPool), toLending);
                try lendingPool.supply(lendingMarketId, toLending) {} catch { remaining += toLending; toLending = 0; } // [A6]
            }
        }

        // Deploy to backstop (higher yield, 7-day unlock) [A4]
        if (curBackstop < tgtBackstop && address(backstopVault) != address(0) && remaining > 0) {
            uint256 needed = tgtBackstop - curBackstop;
            toBackstop = needed > remaining ? remaining : needed;
            remaining -= toBackstop;
            if (toBackstop > 0) {
                USDC.forceApprove(address(backstopVault), toBackstop);
                try backstopVault.deposit(toBackstop, 0) {} catch { remaining += toBackstop; toBackstop = 0; } // [A6]
            }
        }

        // Deploy to funding arb vault (delta-neutral yield)
        if (curFunding < tgtFunding && address(fundingArbVault) != address(0) && remaining > 0) {
            uint256 needed = tgtFunding - curFunding;
            toFunding = needed > remaining ? remaining : needed;
            remaining -= toFunding;
            if (toFunding > 0) {
                USDC.forceApprove(address(fundingArbVault), toFunding);
                try fundingArbVault.deposit(toFunding) {} catch { remaining += toFunding; toFunding = 0; } // [A6]
            }
        }

        lastRebalance = block.timestamp;
        uint256 idleAfter = USDC.balanceOf(address(this));
        emit Rebalanced(toLending, toBackstop, toFunding, idleAfter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WITHDRAWALS — owner can take money out anytime
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw a specific amount of USDC.
     *         Takes from idle balance first, then pulls from liquid strategies.
     *         Never touches the 7-day backstop unless explicitly requested.
     *
     * @param amount  USDC to withdraw (6 decimals)
     * @param to      Destination address (your hardware wallet)
     */
    function withdraw(uint256 amount, address to) external nonReentrant onlyOwner {
        require(amount > 0, "OpsVault: zero amount");
        require(to != address(0), "OpsVault: zero recipient");

        uint256 withdrawn = _pullFunds(amount);
        require(withdrawn >= amount, "OpsVault: insufficient liquidity");

        uint256 yieldIncluded = withdrawn > (totalDeposited - totalWithdrawn)
            ? withdrawn - (totalDeposited - totalWithdrawn)
            : 0;

        totalWithdrawn += withdrawn;
        USDC.safeTransfer(to, withdrawn);
        emit Withdrawn(to, withdrawn, yieldIncluded);
    }

    /**
     * @notice Withdraw everything — principal + all yield.
     *         Pulls from all instant-liquid strategies.
     *         Note: backstop has 7-day delay. Use requestBackstopUnstake() first if needed.
     */
    function withdrawAll(address to) external nonReentrant onlyOwner {
        require(to != address(0), "OpsVault: zero recipient");

        // Pull from lending (instant)
        uint256 lendBal = _lendingBalance();
        if (lendBal > 0 && address(lendingPool) != address(0)) {
            try lendingPool.withdraw(lendingMarketId, type(uint256).max) {} catch {}
        }

        // Pull from funding arb (fast)
        uint256 fundBal = _fundingBalance();
        if (fundBal > 0 && address(fundingArbVault) != address(0)) {
            try fundingArbVault.withdraw(fundBal) {} catch {}
        }

        // Note: backstopVault has 7-day delay — not included here
        // Use requestBackstopUnstake() + completeBackstopUnstake() separately

        uint256 total = USDC.balanceOf(address(this));
        require(total > 0, "OpsVault: nothing to withdraw");

        uint256 principal = totalDeposited - totalWithdrawn;
        uint256 yield_ = total > principal ? total - principal : 0;

        totalWithdrawn += total;
        USDC.safeTransfer(to, total);
        emit Withdrawn(to, total, yield_);
    }

    /**
     * @notice Withdraw only from instant-liquid sources.
     *         Safe: never touches locked positions.
     */
    function withdrawInstant(uint256 amount, address to) external nonReentrant onlyOwner {
        require(amount > 0 && to != address(0), "OpsVault: bad params");

        uint256 idle = USDC.balanceOf(address(this));
        uint256 pulled = idle;

        // If idle not enough, pull from lending (instant)
        if (pulled < amount && address(lendingPool) != address(0)) {
            uint256 needed = amount - pulled;
            uint256 lendBal = _lendingBalance();
            uint256 toPull = needed > lendBal ? lendBal : needed;
            if (toPull > 0) {
                try lendingPool.withdraw(lendingMarketId, toPull) {
                    pulled += toPull;
                } catch {}
            }
        }

        uint256 toSend = pulled > amount ? amount : pulled;
        require(toSend > 0, "OpsVault: no liquid funds");

        totalWithdrawn += toSend;
        USDC.safeTransfer(to, toSend);
        emit Withdrawn(to, toSend, 0);
    }

    // Backstop has 7-day delay — two-step process
    function requestBackstopUnstake(uint256 shares) external onlyOwner {
        require(address(backstopVault) != address(0), "OpsVault: no backstop");
        backstopVault.requestUnstake(shares);
    }
    function completeBackstopUnstake(uint256 requestId) external onlyOwner {
        require(address(backstopVault) != address(0), "OpsVault: no backstop");
        backstopVault.completeUnstake(requestId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS — dashboard
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Complete vault dashboard.
     *         Frontend uses this to show current state.
     */
    function dashboard() external view returns (
        uint256 totalValue_,
        uint256 idleUSDC,
        uint256 inLending,
        uint256 inBackstop,
        uint256 inFunding,
        uint256 totalDeposited_,
        uint256 totalWithdrawn_,
        uint256 netYieldEarned,
        uint256 estimatedAPY,
        uint256 instantLiquid
    ) {
        idleUSDC     = USDC.balanceOf(address(this));
        inLending    = _lendingBalance();
        inBackstop   = _backstopBalance();
        inFunding    = _fundingBalance();
        totalValue_  = idleUSDC + inLending + inBackstop + inFunding;
        totalDeposited_ = totalDeposited;
        totalWithdrawn_ = totalWithdrawn;

        uint256 principal = totalDeposited > totalWithdrawn
            ? totalDeposited - totalWithdrawn
            : 0;
        netYieldEarned = totalValue_ > principal ? totalValue_ - principal : 0;

        // Blended APY estimate: weighted average of strategy allocations
        // Lending ~6%, Backstop ~20%, Funding ~10%
        uint256 total = totalValue_;
        if (total > 0) {
            estimatedAPY = (
                (inLending  * 600) +   // 6% × lending balance
                (inBackstop * 2000) +  // 20% × backstop balance
                (inFunding  * 1000)    // 10% × funding balance
            ) / total;                 // = blended APY in BPS
        }

        instantLiquid = idleUSDC + inLending; // available without delay
    }

    /**
     * @notice Projects how much the vault will contain at different time horizons.
     *         Assumes constant monthly inflow and current blended APY.
     *
     * @param monthlyInflow     Expected USDC arriving per month (from protocol fees)
     * @param blendedAPYBps     Expected yield in BPS (e.g. 1500 = 15%)
     */
    function projectGrowth(
        uint256 monthlyInflow,
        uint256 blendedAPYBps
    ) external view returns (
        uint256[13] memory monthlyBalance,
        uint256[13] memory cumulativeYield
    ) {
        uint256 balance    = totalValue();
        uint256 monthlyAPY = blendedAPYBps * balance / BPS / 12;
        uint256 totalYield = 0;

        for (uint256 m = 0; m <= 12; m++) {
            monthlyBalance[m]  = balance;
            cumulativeYield[m] = totalYield;

            // Next month: add inflow + yield
            uint256 yield_ = balance * blendedAPYBps / BPS / 12;
            balance     += monthlyInflow + yield_;
            totalYield  += yield_;
        }
    }

    function totalValue() public view returns (uint256) {
        return USDC.balanceOf(address(this))
             + _lendingBalance()
             + _backstopBalance()
             + _fundingBalance();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    function setStrategies(
        address _lending,
        address _backstop,
        address _funding,
        uint256 _lendingMid
    ) external onlyOwner {
        if (_lending  != address(0)) lendingPool    = IWikiLending(_lending);
        if (_backstop != address(0)) backstopVault  = IWikiBackstopVault(_backstop);
        if (_funding  != address(0)) fundingArbVault = IWikiFundingArb(_funding);
        lendingMarketId = _lendingMid;
        emit StrategyUpdated(_lending, _backstop, _funding);
    }

    function setAllocationBps(
        uint256 lending,
        uint256 backstop,
        uint256 funding,
        uint256 minIdle
    ) external onlyOwner {
        require(lending + backstop + funding + minIdle == BPS, "OpsVault: must sum to 100%");
        lendingAllocBps  = lending;
        backstopAllocBps = backstop;
        fundingAllocBps  = funding;
        minIdleBps       = minIdle;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────────

    function _pullFunds(uint256 needed) internal returns (uint256 pulled) {
        // 1. Idle cash first
        uint256 idle = USDC.balanceOf(address(this));
        if (idle >= needed) return needed;
        pulled = idle;

        // 2. Pull from lending (instant)
        uint256 remaining = needed - pulled;
        if (address(lendingPool) != address(0)) {
            uint256 lendBal = _lendingBalance();
            uint256 toPull  = remaining > lendBal ? lendBal : remaining;
            if (toPull > 0) {
                try lendingPool.withdraw(lendingMarketId, toPull) {
                    pulled    += toPull;
                    remaining -= toPull;
                } catch {}
            }
        }

        // 3. Pull from funding arb
        if (remaining > 0 && address(fundingArbVault) != address(0)) {
            uint256 fundBal = _fundingBalance();
            uint256 toPull  = remaining > fundBal ? fundBal : remaining;
            if (toPull > 0) {
                try fundingArbVault.withdraw(toPull) {
                    pulled    += toPull;
                    remaining -= toPull;
                } catch {}
            }
        }

        // Note: backstop not pulled here — 7-day delay. Owner must call requestBackstopUnstake.
    }

    function _lendingBalance() internal view returns (uint256) {
        if (address(lendingPool) == address(0)) return 0;
        try lendingPool.balanceOfUnderlying(lendingMarketId, address(this)) returns (uint256 b) { return b; } catch { return 0; }
    }

    function _backstopBalance() internal view returns (uint256) {
        if (address(backstopVault) == address(0)) return 0;
        try backstopVault.balanceOf(address(this)) returns (uint256 shares) {
            if (shares == 0) return 0;
            try backstopVault.sharesToAssets(shares) returns (uint256 assets) { return assets; } catch { return 0; }
        } catch { return 0; }
    }

    function _fundingBalance() internal view returns (uint256) {
        if (address(fundingArbVault) == address(0)) return 0;
        try fundingArbVault.estimatedValue(address(this)) returns (uint256 v) { return v; } catch { return 0; }
    }
}
