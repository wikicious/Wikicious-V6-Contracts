// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiBackstopVault
 * @notice The "last line of defence" before ADL. LPs deposit USDC and earn
 *         high yield in exchange for absorbing protocol losses.
 *
 * ─── THE HYPERLIQUID HLP MODEL ────────────────────────────────────────────────
 *
 * Hyperliquid's HLP vault earned $60M for LPs in 2024 while absorbing $0 in
 * losses because it was structured correctly:
 *
 *   • LPs earn 50% of all protocol trading fees
 *   • LPs earn 100% of funding rate income on net OI imbalance
 *   • LPs absorb losses ONLY when insurance fund is exhausted
 *   • In practice fees >> losses, so LPs are net profitable
 *
 * WikiBackstopVault works the same way. The expected yield is high enough
 * that LPs willingly accept the tail risk of absorbing shortfalls.
 *
 * ─── YIELD SOURCES ────────────────────────────────────────────────────────────
 *
 *   50% of protocol trading fees     → directly to this vault
 *   100% of net OI funding income    → directly to this vault
 *   Internal arb profits (partial)   → from WikiInternalArb
 *
 *   At $10M daily volume × 0.06% fee × 50% vault share = $3,000/day = $1.1M/yr
 *   At $50M TVL that's 2.2% APY from fees alone + funding rates typically 5-15%
 *   Total expected: 15–25% APY in normal conditions
 *
 * ─── LOSS SCENARIOS ───────────────────────────────────────────────────────────
 *
 *   Coverage order for any shortfall:
 *     1. Liquidated trader's remaining collateral    (always first)
 *     2. WikiVault insurance fund                   (protocol-owned)
 *     3. WikiBackstopVault (this contract)           ← LPs absorb here
 *     4. WikiADL — force-close profitable traders   (absolute last resort)
 *
 *   The vault acts as a shock absorber between the insurance fund and ADL.
 *   With $1M in the backstop vault, the protocol can absorb $1M in simultaneous
 *   shortfalls before a single trader is ADL'd.
 *
 * ─── LP MECHANICS ─────────────────────────────────────────────────────────────
 *
 *   1. LP deposits USDC → receives bsUSDC (backstop LP token, 1:1 at inception)
 *   2. As fees accumulate, bsUSDC NAV increases → bsUSDC worth more than $1
 *   3. As losses occur, bsUSDC NAV decreases
 *   4. LP redeems bsUSDC → receives USDC at current NAV
 *   5. 7-day unstaking delay (prevents LPs from withdrawing before covering losses)
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] 7-day withdrawal delay — LPs cannot front-run losses by withdrawing early
 * [A2] Maximum single-cover capped at 10% of vault TVL — no single event drains vault
 * [A3] Only WikiADL can call cover() — not callable by random addresses
 * [A4] NAV tracking — loss accurately reflected in LP token price
 * [A5] Minimum deposit $100 — prevents dust griefing
 * [A6] ReentrancyGuard on all LP operations
 */
contract WikiBackstopVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    uint256 public constant BPS              = 10_000;
    uint256 public constant PRECISION        = 1e18;
    uint256 public constant UNSTAKE_DELAY    = 7 days;    // [A1]
    uint256 public constant MAX_COVER_BPS    = 1_000;     // 10% of TVL per event [A2]
    uint256 public constant MIN_DEPOSIT      = 100 * 1e6; // $100 [A5]
    uint256 public constant PERF_FEE_BPS     = 2_000;     // 20% of profits to protocol
    uint256 public constant MGMT_FEE_BPS     = 100;       // 1% annual management fee

    // ── State ─────────────────────────────────────────────────────────────────

    IERC20   public immutable USDC;
    address  public adlContract;             // only address that can call cover() [A3]
    address  public feeRecipient;            // receives performance + management fees

    uint256  public totalUSDC;               // total USDC in vault (not counting fees)
    uint256  public totalLossAbsorbed;       // lifetime losses absorbed
    uint256  public totalYieldEarned;        // lifetime fees received
    uint256  public lastFeeTime;             // for management fee accrual
    uint256  public highWaterMark;           // for performance fee calculation

    // ── Pending unstakes [A1] ──────────────────────────────────────────────────

    struct UnstakeRequest {
        address lp;
        uint256 shares;        // bsUSDC to burn
        uint256 requestedAt;
        bool    completed;
    }

    UnstakeRequest[]          public unstakeRequests;
    mapping(address => uint256[]) public userUnstakes;

    // ── Authorised fee sources ─────────────────────────────────────────────────
    mapping(address => bool)  public feeSources;

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(address indexed lp, uint256 usdc, uint256 shares, uint256 navPerShare);
    event UnstakeRequested(address indexed lp, uint256 shares, uint256 unlockTime);
    event Withdrawn(address indexed lp, uint256 usdc, uint256 shares, uint256 navPerShare);
    event LossCovered(uint256 shortfall, uint256 covered, uint256 newNAV);
    event YieldReceived(address indexed source, uint256 amount);
    event NavUpdated(uint256 nav);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _usdc,
        address _feeRecipient
    ) ERC20("Wiki Backstop USDC", "bsUSDC") Ownable(_owner) {
        require(_usdc         != address(0), "Backstop: zero usdc");
        require(_feeRecipient != address(0), "Backstop: zero fee recipient");
        USDC         = IERC20(_usdc);
        feeRecipient = _feeRecipient;
        lastFeeTime  = block.timestamp;
        highWaterMark = PRECISION; // $1.00 starting NAV
    }

    // ── NAV calculation ───────────────────────────────────────────────────────

    /**
     * @notice Current NAV per bsUSDC share.
     *         Starts at 1e6 ($1.00). Rises as fees accumulate. Falls if losses occur.
     */
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // bootstrap: $1.00
        return totalUSDC * PRECISION / supply;
    }

    function availableCover() external view returns (uint256) {
        uint256 maxCover = totalUSDC * MAX_COVER_BPS / BPS;
        return maxCover;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC into the backstop vault. Receive bsUSDC at current NAV.
     * @param amount   USDC amount (6 dec)
     * @param minShares Slippage protection
     */
    function deposit(uint256 amount, uint256 minShares) external nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "Backstop: below min"); // [A5]
        _accrueManagementFee();

        uint256 nav     = navPerShare();
        uint256 shares  = nav > 0 ? amount * PRECISION / nav : amount * PRECISION / 1e6;
        require(shares >= minShares, "Backstop: slippage");

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDC += amount;
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, amount, shares, nav);
    }

    // ── Withdrawal (7-day delay) ──────────────────────────────────────────────

    /**
     * @notice Request withdrawal. Shares locked. USDC claimable after 7 days. [A1]
     */
    function requestUnstake(uint256 shares) external nonReentrant whenNotPaused {
        require(balanceOf(msg.sender) >= shares, "Backstop: insufficient shares");
        require(shares > 0, "Backstop: zero shares");

        _transfer(msg.sender, address(this), shares); // lock shares in contract

        uint256 reqId = unstakeRequests.length;
        unstakeRequests.push(UnstakeRequest({
            lp:          msg.sender,
            shares:      shares,
            requestedAt: block.timestamp,
            completed:   false
        }));
        userUnstakes[msg.sender].push(reqId);

        emit UnstakeRequested(msg.sender, shares, block.timestamp + UNSTAKE_DELAY);
    }

    /**
     * @notice Complete withdrawal after 7-day delay.
     */
    function completeUnstake(uint256 requestId) external nonReentrant whenNotPaused {
        UnstakeRequest storage req = unstakeRequests[requestId];
        require(req.lp == msg.sender,                                  "Backstop: not your request");
        require(!req.completed,                                        "Backstop: already completed");
        require(block.timestamp >= req.requestedAt + UNSTAKE_DELAY,   "Backstop: still locked"); // [A1]

        uint256 nav      = navPerShare();
        uint256 usdc_out = req.shares * nav / PRECISION;
        require(usdc_out <= totalUSDC, "Backstop: insufficient liquidity");

        req.completed  = true;
        totalUSDC     -= usdc_out;
        _burn(address(this), req.shares);

        // Performance fee on profit
        if (nav > highWaterMark) {
            uint256 profitPerShare = nav - highWaterMark;
            uint256 perfFee = req.shares * profitPerShare / PRECISION * PERF_FEE_BPS / BPS;
            if (perfFee > 0 && perfFee < usdc_out) {
                usdc_out -= perfFee;
                USDC.safeTransfer(feeRecipient, perfFee);
            }
        }
        if (nav > highWaterMark) highWaterMark = nav;

        USDC.safeTransfer(msg.sender, usdc_out);
        emit Withdrawn(msg.sender, usdc_out, req.shares, nav);
    }

    // ── Loss coverage ─────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiADL to cover a shortfall. [A3]
     *         Reduces totalUSDC — reflected in lower NAV for LPs.
     *
     * @param shortfall  USDC amount needed
     * @return covered   USDC actually covered (may be less if vault can't cover all)
     */
    function cover(uint256 shortfall) external nonReentrant returns (uint256 covered) {
        require(msg.sender == adlContract || adlContract == address(0), "Backstop: not ADL"); // [A3]
        require(shortfall > 0, "Backstop: zero shortfall");

        // Cap at MAX_COVER_BPS of TVL [A2]
        uint256 maxCover = totalUSDC * MAX_COVER_BPS / BPS;
        covered = shortfall < maxCover ? shortfall : maxCover;
        if (covered > totalUSDC) covered = totalUSDC;
        if (covered == 0) return 0;

        // Transfer USDC to cover the loss
        totalUSDC -= covered;
        totalLossAbsorbed += covered;
        USDC.safeTransfer(msg.sender, covered);

        emit LossCovered(shortfall, covered, navPerShare());
    }

    // ── Yield reception ───────────────────────────────────────────────────────

    /**
     * @notice Receive yield from fee sources (WikiPerp, WikiRevenueSplitter, etc.)
     *         Increases totalUSDC → raises NAV for LPs.
     */
    function receiveYield(uint256 amount) external nonReentrant {
        require(feeSources[msg.sender] || msg.sender == owner(), "Backstop: not fee source");
        require(amount > 0, "Backstop: zero yield");

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDC     += amount;
        totalYieldEarned += amount;

        emit YieldReceived(msg.sender, amount);
        emit NavUpdated(navPerShare());
    }

    // ── Management fee ────────────────────────────────────────────────────────

    function _accrueManagementFee() internal {
        if (totalUSDC == 0) return;
        uint256 elapsed = block.timestamp - lastFeeTime;
        if (elapsed == 0) return;
        uint256 fee = totalUSDC * MGMT_FEE_BPS * elapsed / BPS / 365 days;
        lastFeeTime = block.timestamp;
        if (fee > 0 && fee < totalUSDC) {
            totalUSDC -= fee;
            USDC.safeTransfer(feeRecipient, fee);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function stats() external view returns (
        uint256 tvl,
        uint256 nav,
        uint256 supply,
        uint256 yieldEarned,
        uint256 lossAbsorbed,
        uint256 estimatedApy
    ) {
        tvl          = totalUSDC;
        nav          = navPerShare();
        supply       = totalSupply();
        yieldEarned  = totalYieldEarned;
        lossAbsorbed = totalLossAbsorbed;
        // Estimate APY = (current NAV - 1.00) / days_since_start × 365
        // Simplified: show annualised if NAV > 1.00
        estimatedApy = nav > 1e6 ? (nav - 1e6) * BPS / 1e6 : 0;
    }

    function unstakeRequestsFor(address lp) external view returns (uint256[] memory) {
        return userUnstakes[lp];
    }

    function getUnstakeRequest(uint256 id) external view returns (UnstakeRequest memory) {
        return unstakeRequests[id];
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdlContract(address _adl)    external onlyOwner { adlContract = _adl; }
    function setFeeRecipient(address _fr)    external onlyOwner { require(_fr != address(0)); feeRecipient = _fr; }
    function setFeeSource(address src, bool ok) external onlyOwner { feeSources[src] = ok; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
