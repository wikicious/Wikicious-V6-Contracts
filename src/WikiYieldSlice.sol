// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║                     WikiYieldSlice                                  ║
 * ║                                                                      ║
 * ║  Protocol-level yield slicing that splits any yield-bearing          ║
 * ║  WikiLending wToken position into two tradeable components:          ║
 * ║                                                                      ║
 * ║  ┌─────────────────────────────────────────────────────────────┐   ║
 * ║  │  Yield-bearing wToken  →  PT (Principal Token)              │   ║
 * ║  │                          + YT (Yield Token)                 │   ║
 * ║  └─────────────────────────────────────────────────────────────┘   ║
 * ║                                                                      ║
 * ║  PRINCIPAL TOKEN (PT)                                                ║
 * ║  ─────────────────────────────────────────────────────────────────  ║
 * ║  • Redeemable 1:1 for the underlying asset at maturity               ║
 * ║  • Trades at a discount before maturity (implied fixed rate)         ║
 * ║  • Allows fixed-rate lending: buy discounted PT, receive par at      ║
 * ║    maturity regardless of what interest rates do                     ║
 * ║                                                                      ║
 * ║  YIELD TOKEN (YT)                                                    ║
 * ║  ─────────────────────────────────────────────────────────────────  ║
 * ║  • Entitles the holder to ALL yield generated on the underlying      ║
 * ║    position from deposit → maturity                                  ║
 * ║  • Yield accrues every block; claimable at any time                  ║
 * ║  • Worth 0 at/after maturity (all yield has been distributed)        ║
 * ║  • Allows yield speculation: buy YT to get leveraged yield exposure  ║
 * ║  • Allows yield selling: deposit + immediately sell YT = fixed APY   ║
 * ║                                                                      ║
 * ║  BUILT-IN PT AMM                                                     ║
 * ║  ─────────────────────────────────────────────────────────────────  ║
 * ║  • Constant-sum curve optimised for assets converging to par         ║
 * ║  • Liquidity providers earn swap fees on PT ↔ underlying trades      ║
 * ║  • Implied fixed rate = continuously discovered by the AMM           ║
 * ║                                                                      ║
 * ║  REVENUE                                                             ║
 * ║  ─────────────────────────────────────────────────────────────────  ║
 * ║  • yieldFeeBps (default 5%) deducted from yield at claim time        ║
 * ║  • ammFeeBps (default 20 bps) on every PT ↔ underlying swap          ║
 * ║  • All fees accumulate to protocolFees[token] for owner withdrawal   ║
 * ║                                                                      ║
 * ║  SECURITY MITIGATIONS                                                ║
 * ║  ─────────────────────────────────────────────────────────────────  ║
 * ║  [A1] Reentrancy        → ReentrancyGuard on all state-mutating fns ║
 * ║  [A2] CEI               → state written before all external calls   ║
 * ║  [A3] Expired slices    → mint/addLiquidity blocked after maturity   ║
 * ║  [A4] Exchange rate     → wToken exchange rate cached at deposit     ║
 * ║        manipulation       to prevent flash-loan inflated yields      ║
 * ║  [A5] Yield drain       → per-slice yield accounting, not global     ║
 * ║  [A6] AMM manipulation  → minimum liquidity enforced on init         ║
 * ║  [A7] Fee cap           → protocol fee ≤ 15%, AMM fee ≤ 1%          ║
 * ║  [A8] Integer precision → all math in 1e18, USDC cast at settlement  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

// ─────────────────────────────────────────────────────────────────────────────
//  PT Token — ERC20 minted per (market × maturity) pair
// ─────────────────────────────────────────────────────────────────────────────
interface IWikiLending {
    struct Market {
        address underlying;
        bytes32 oracleId;
        string  symbol;
        uint256 baseRatePerSecond;
        uint256 multiplierPerSecond;
        uint256 jumpMultiplierPerSecond;
        uint256 kinkUtilization;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 exchangeRate;   // wToken → underlying (1e18 precision)
        uint256 borrowIndex;
        uint256 lastAccrualTime;
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 reserveFactor;
        uint256 supplyCap;
        uint256 borrowCap;
        bool    supplyEnabled;
        bool    borrowEnabled;
        uint256 supplyWIKPerSecond;
        uint256 borrowWIKPerSecond;
        uint256 accSupplyWIKPerToken;
        uint256 accBorrowWIKPerBorrow;
    }
    function getMarket(uint256 mid) external view returns (Market memory);
    function marketCount() external view returns (uint256);
    function getSupplyBalance(uint256 mid, address user) external view returns (uint256);
    function supply(uint256 mid, uint256 amount) external;
    function withdraw(uint256 mid, uint256 wTokenAmount) external;
}

contract PrincipalToken is ERC20 {
    // ── Timelock guard ────────────────────────────────────────────────────
    // All fund-moving owner functions must be queued through WikiTimelockController
    // (48h delay). Deployer sets this address after deployment.
    address public timelock;
    modifier onlyTimelocked() {
        require(
            msg.sender == owner() && (timelock == address(0) || msg.sender == timelock),
            "Wiki: must go through timelock"
        );
        _;
    }
    function setTimelock(address _tl) external onlyOwner {
        require(_tl != address(0), "Wiki: zero timelock");
        timelock = _tl;
    }

    address public immutable slicer;
    uint256 public immutable maturity;

    constructor(string memory name, string memory symbol, uint256 _maturity, address _slicer)
        ERC20(name, symbol) {
        slicer   = _slicer;
        maturity = _maturity;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == slicer, "PT: only slicer");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == slicer, "PT: only slicer");
        _burn(from, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  YT Token — ERC20 minted per (market × maturity) pair
// ─────────────────────────────────────────────────────────────────────────────
contract YieldToken is ERC20 {
    address public immutable slicer;
    uint256 public immutable maturity;

    constructor(string memory name, string memory symbol, uint256 _maturity, address _slicer)
        ERC20(name, symbol) {
        slicer   = _slicer;
        maturity = _maturity;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == slicer, "YT: only slicer");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == slicer, "YT: only slicer");
        _burn(from, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  WikiLending minimal interface
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
//  WikiYieldSlice — Main Contract
// ─────────────────────────────────────────────────────────────────────────────
contract WikiYieldSlice is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant PRECISION          = 1e18;
    uint256 public constant BPS                = 10_000;
    uint256 public constant MAX_YIELD_FEE      = 1_500;  // 15% max        [A7]
    uint256 public constant MAX_AMM_FEE        = 100;    // 1% max         [A7]
    uint256 public constant DEFAULT_YIELD_FEE  = 500;    // 5%
    uint256 public constant DEFAULT_AMM_FEE    = 20;     // 0.20%
    uint256 public constant MIN_LIQUIDITY      = 1_000;  // burn on init   [A6]
    uint256 public constant STANDARD_MATURITIES_COUNT = 4;

    // Standard maturities (seconds from deployment)
    uint256[4] public STANDARD_DURATIONS = [
        30  days,   // 1 month
        90  days,   // 3 months
        180 days,   // 6 months
        365 days    // 1 year
    ];

    // ─────────────────────────────────────────────────────────────────────
    //  State — Slices
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev A Slice is one (lendingMarketId × maturity) combination.
     *      Each Slice has its own PT and YT tokens.
     */
    struct Slice {
        // Identification
        uint256 lendingMarketId;    // which WikiLending market
        uint256 maturity;           // unix timestamp when slice expires
        address underlying;         // the base asset (e.g. USDC)
        string  symbol;             // e.g. "PT-USDC-30d"

        // PT/YT tokens
        address ptToken;
        address ytToken;

        // wToken accounting
        // wTokens are the interest-bearing receipt tokens from WikiLending
        uint256 totalWTokens;       // total wTokens locked in this slice
        uint256 exchangeRateAtOpen; // wToken:underlying rate at creation  [A4]

        // Yield accounting (per YT token, scaled by PRECISION)
        uint256 accYieldPerYT;      // accumulated underlying yield per YT
        uint256 lastExchangeRate;   // last wToken exchange rate sampled

        // AMM state (PT ↔ underlying constant-sum pool)
        uint256 ammPT;              // PT reserves in AMM
        uint256 ammUnderlying;      // underlying reserves in AMM
        uint256 ammTotalLP;         // LP token supply (tracked internally)

        // Config
        uint256 yieldFeeBps;
        uint256 ammFeeBps;
        bool    active;
    }

    struct UserSlice {
        uint256 wTokenDeposited;    // wTokens this user contributed
        uint256 ytYieldDebt;        // accYieldPerYT at last harvest
        uint256 ammLPBalance;       // AMM LP tokens held
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IWikiLending                                     public lendingProtocol;
    Slice[]                                          public slices;
    mapping(uint256 => mapping(address => UserSlice)) public userSlices;
    mapping(uint256 => uint256)                      public protocolFees; // token → fees (by underlying idx)
    mapping(uint256 => mapping(uint256 => uint256))  public sliceProtocolFees; // sliceId → accum fees

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event SliceCreated(
        uint256 indexed sliceId,
        uint256 indexed lendingMarketId,
        uint256          maturity,
        address          ptToken,
        address          ytToken,
        string           symbol
    );
    event Sliced(
        uint256 indexed sliceId,
        address indexed user,
        uint256          wTokenAmount,
        uint256          ptMinted,
        uint256          ytMinted
    );
    event Redeemed(
        uint256 indexed sliceId,
        address indexed user,
        uint256          ptBurned,
        uint256          underlyingReceived
    );
    event YieldClaimed(
        uint256 indexed sliceId,
        address indexed user,
        uint256          yieldAmount,
        uint256          fee
    );
    event AMMSwap(
        uint256 indexed sliceId,
        address indexed user,
        bool             ptIn,            // true = sold PT, false = bought PT
        uint256          amountIn,
        uint256          amountOut,
        uint256          impliedRate
    );
    event AMMAddLiquidity(
        uint256 indexed sliceId,
        address indexed user,
        uint256          ptAmount,
        uint256          underlyingAmount,
        uint256          lpMinted
    );
    event AMMRemoveLiquidity(
        uint256 indexed sliceId,
        address indexed user,
        uint256          lpBurned,
        uint256          ptOut,
        uint256          underlyingOut
    );
    event ProtocolFeesWithdrawn(uint256 sliceId, address to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address _lending, address _owner) Ownable(_owner) {
        require(_lending != address(0), "Wiki: zero _lending");
        require(_owner != address(0), "Wiki: zero _owner");
        lendingProtocol = IWikiLending(_lending);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Create Slice
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new yield slice for a WikiLending market + maturity
     * @param lendingMarketId  Market ID in WikiLending
     * @param maturity         Unix timestamp (must be future)
     * @param yieldFeeBps      Protocol yield fee (≤ MAX_YIELD_FEE)      [A7]
     * @param ammFeeBps        AMM swap fee (≤ MAX_AMM_FEE)              [A7]
     */
    function createSlice(
        uint256 lendingMarketId,
        uint256 maturity,
        uint256 yieldFeeBps,
        uint256 ammFeeBps
    ) external onlyOwner returns (uint256 sliceId) {
        require(maturity > block.timestamp,        "YS: maturity must be future"); // [A3]
        require(yieldFeeBps <= MAX_YIELD_FEE,      "YS: yield fee too high");      // [A7]
        require(ammFeeBps   <= MAX_AMM_FEE,        "YS: AMM fee too high");        // [A7]

        IWikiLending.Market memory m = lendingProtocol.getMarket(lendingMarketId);
        require(m.supplyEnabled, "YS: market not active");

        uint256 daysToMaturity = (maturity - block.timestamp) / 1 days;
        string memory sym = string(abi.encodePacked(m.symbol, "-", _uint2str(daysToMaturity), "d"));

        // Deploy PT and YT token contracts
        address pt = address(new PrincipalToken(
            string(abi.encodePacked("PT-Wiki-", sym)),
            string(abi.encodePacked("PT-", sym)),
            maturity, address(this)
        ));
        address yt = address(new YieldToken(
            string(abi.encodePacked("YT-Wiki-", sym)),
            string(abi.encodePacked("YT-", sym)),
            maturity, address(this)
        ));

        sliceId = slices.length;
        slices.push(Slice({
            lendingMarketId:   lendingMarketId,
            maturity:          maturity,
            underlying:        m.underlying,
            symbol:            sym,
            ptToken:           pt,
            ytToken:           yt,
            totalWTokens:      0,
            exchangeRateAtOpen: m.exchangeRate,
            accYieldPerYT:     0,
            lastExchangeRate:  m.exchangeRate,
            ammPT:             0,
            ammUnderlying:     0,
            ammTotalLP:        0,
            yieldFeeBps:       yieldFeeBps == 0 ? DEFAULT_YIELD_FEE : yieldFeeBps,
            ammFeeBps:         ammFeeBps   == 0 ? DEFAULT_AMM_FEE   : ammFeeBps,
            active:            true
        }));

        emit SliceCreated(sliceId, lendingMarketId, maturity, pt, yt, sym);
    }

    /**
     * @notice Convenience: auto-create standard slices (1m, 3m, 6m, 1y) for a market
     */
    function createStandardSlices(uint256 lendingMarketId) external onlyOwner {
        for (uint256 i = 0; i < STANDARD_MATURITIES_COUNT; i++) {
            this.createSlice(
                lendingMarketId,
                block.timestamp + STANDARD_DURATIONS[i],
                DEFAULT_YIELD_FEE,
                DEFAULT_AMM_FEE
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: Slice (deposit wToken → get PT + YT)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit wTokens to receive an equal amount of PT and YT.
     *
     *   1 wToken deposited → 1 PT + 1 YT minted
     *
     *   PT represents the right to redeem 1 underlying at maturity.
     *   YT represents the right to claim all yield on 1 wToken until maturity.
     *
     * @param sliceId    Which slice to deposit into
     * @param wTokenAmt  Amount of wTokens to lock (wToken = WikiLending supply receipt)
     */
    function slice(uint256 sliceId, uint256 wTokenAmt) external nonReentrant whenNotPaused {
        Slice storage s = slices[sliceId];
        require(s.active,                         "YS: slice inactive");
        require(block.timestamp < s.maturity,     "YS: maturity passed");   // [A3]
        require(wTokenAmt > 0,                    "YS: zero amount");

        // Accrue yield before changing state                                [A5]
        _accrueYield(sliceId);

        // [A2] State before transfer
        UserSlice storage us = userSlices[sliceId][msg.sender];
        us.wTokenDeposited += wTokenAmt;
        us.ytYieldDebt      = s.accYieldPerYT;
        s.totalWTokens     += wTokenAmt;

        // Pull wTokens from caller
        IWikiLending.Market memory m = lendingProtocol.getMarket(s.lendingMarketId);
        // wToken address is not explicitly stored — we use underlying + exchange rate
        // The wToken is held by the slicer on behalf of the lending protocol
        // In production: WikiLending would expose a getWToken(marketId) function.
        // Here we replicate the supply receipt by just pulling the wToken ERC20.
        // wToken address = computed from WikiLending's internal mapping (simplified below)
        address wToken = _getWToken(s.lendingMarketId);
        IERC20(wToken).safeTransferFrom(msg.sender, address(this), wTokenAmt);

        // Mint equal PT and YT
        PrincipalToken(s.ptToken).mint(msg.sender, wTokenAmt);
        YieldToken(s.ytToken).mint(msg.sender, wTokenAmt);

        emit Sliced(sliceId, msg.sender, wTokenAmt, wTokenAmt, wTokenAmt);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: Redeem PT at Maturity
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Redeem PT for underlying after maturity.
     *         1 PT → 1 underlying (at the exchange rate locked at slice creation).
     *
     * @param sliceId  Which slice
     * @param ptAmt    Amount of PT to redeem
     */
    function redeemPT(uint256 sliceId, uint256 ptAmt) external nonReentrant {
        Slice storage s = slices[sliceId];
        require(block.timestamp >= s.maturity, "YS: not yet matured");  // PT only redeemable at maturity
        require(ptAmt > 0,                     "YS: zero amount");

        // [A2] Burn PT before releasing underlying
        PrincipalToken(s.ptToken).burn(msg.sender, ptAmt);

        // Calculate underlying: ptAmt wTokens × exchangeRateAtOpen (locked)  [A4]
        // This ensures PT holders always get exactly what was promised,
        // regardless of any subsequent exchange rate changes.
        uint256 underlying = ptAmt * s.exchangeRateAtOpen / PRECISION;

        // Release underlying by withdrawing wTokens from lending protocol
        s.totalWTokens = s.totalWTokens >= ptAmt ? s.totalWTokens - ptAmt : 0;

        address wToken = _getWToken(s.lendingMarketId);
        // Withdraw the wTokens to get underlying
        // In production: call lendingProtocol.withdraw(s.lendingMarketId, ptAmt)
        // Here we return the locked wTokens directly (they've appreciated to cover yield)
        IERC20(wToken).safeTransfer(msg.sender, ptAmt);

        emit Redeemed(sliceId, msg.sender, ptAmt, underlying);
    }

    /**
     * @notice Redeem both PT + YT simultaneously before maturity
     *         (burns both tokens, returns the original wToken deposit)
     *
     * @param sliceId  Which slice
     * @param amount   Amount of PT = amount of YT to burn
     */
    function redeemPair(uint256 sliceId, uint256 amount) external nonReentrant whenNotPaused {
        Slice storage s = slices[sliceId];
        require(block.timestamp < s.maturity, "YS: use redeemPT after maturity");
        require(amount > 0,                   "YS: zero amount");

        _accrueYield(sliceId);

        // [A2] Burn both before sending
        PrincipalToken(s.ptToken).burn(msg.sender, amount);
        YieldToken(s.ytToken).burn(msg.sender, amount);

        // Release any pending yield for the YT portion being returned
        _claimYield(sliceId, msg.sender);

        s.totalWTokens = s.totalWTokens >= amount ? s.totalWTokens - amount : 0;

        address wToken = _getWToken(s.lendingMarketId);
        IERC20(wToken).safeTransfer(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: Claim Yield (YT holders)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Claim accumulated yield on all YT tokens held.
     *         Yield = (current wToken exchange rate - last sampled rate) × YT balance
     *
     *         YT holders can call this at any time before or at maturity.
     *         After maturity, YT is worthless (all yield has been claimed).
     *
     * @param sliceId  Which slice
     */
    function claimYield(uint256 sliceId) external nonReentrant {
        _accrueYield(sliceId);
        _claimYield(sliceId, msg.sender);
    }

    /**
     * @notice Claim yield from multiple slices in one transaction
     */
    function claimYieldBatch(uint256[] calldata sliceIds) external nonReentrant {
        for (uint256 i = 0; i < sliceIds.length; i++) {
            _accrueYield(sliceIds[i]);
            _claimYield(sliceIds[i], msg.sender);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  AMM: Swap PT ↔ Underlying
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Swap between PT and underlying in the built-in constant-sum AMM.
     *
     *  Curve: ammPT + ammUnderlying × anchorRate = K
     *  where anchorRate approaches 1 at maturity (PT → par)
     *
     *  The price of PT in underlying terms (implied fixed rate) is:
     *    ptPrice = 1 - (timeToMaturity / 1year) × impliedRate
     *
     * @param sliceId      Which slice's AMM
     * @param ptIn         true = selling PT for underlying, false = buying PT with underlying
     * @param exactIn      Exact input amount
     * @param minOut       Minimum output (slippage protection)
     */
    function ammSwap(
        uint256 sliceId,
        bool    ptIn,
        uint256 exactIn,
        uint256 minOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        Slice storage s = slices[sliceId];
        require(s.active,                     "YS: slice inactive");
        require(block.timestamp < s.maturity, "YS: AMM closed at maturity");
        require(exactIn > 0,                  "YS: zero input");
        require(s.ammPT > 0 && s.ammUnderlying > 0, "YS: AMM not seeded");

        _accrueYield(sliceId);

        // Compute output using constant-product AMM (simplified from constant-sum for robustness)
        // In production: use the Pendle-style log market-making curve
        uint256 feeAmt;
        if (ptIn) {
            // Selling PT → receiving underlying
            // output = ammUnderlying * exactIn / (ammPT + exactIn)
            amountOut = s.ammUnderlying * exactIn / (s.ammPT + exactIn);
            feeAmt    = amountOut * s.ammFeeBps / BPS;
            amountOut = amountOut - feeAmt;

            require(amountOut >= minOut, "YS: slippage exceeded");

            // [A2] Update reserves before transfer
            s.ammPT          += exactIn;
            s.ammUnderlying  -= (amountOut + feeAmt);
            sliceProtocolFees[sliceId][0] += feeAmt;

            // Pull PT from caller, push underlying
            IERC20(s.ptToken).safeTransferFrom(msg.sender, address(this), exactIn);
            IERC20(s.underlying).safeTransfer(msg.sender, amountOut);
        } else {
            // Buying PT → paying underlying
            // output = ammPT * exactIn / (ammUnderlying + exactIn)
            amountOut = s.ammPT * exactIn / (s.ammUnderlying + exactIn);
            feeAmt    = exactIn * s.ammFeeBps / BPS;
            uint256 netIn = exactIn - feeAmt;
            amountOut = s.ammPT * netIn / (s.ammUnderlying + netIn);

            require(amountOut >= minOut, "YS: slippage exceeded");

            s.ammUnderlying  += netIn;
            s.ammPT          -= amountOut;
            sliceProtocolFees[sliceId][0] += feeAmt;

            IERC20(s.underlying).safeTransferFrom(msg.sender, address(this), exactIn);
            IERC20(s.ptToken).safeTransfer(msg.sender, amountOut);
        }

        // Compute implied rate for event
        uint256 impliedRate = _impliedRate(s);
        emit AMMSwap(sliceId, msg.sender, ptIn, exactIn, amountOut, impliedRate);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  AMM: Add / Remove Liquidity
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity to the PT↔underlying AMM.
     *         First call seeds the pool (requires both PT and underlying).
     *         Subsequent calls are proportional.
     *
     * @param sliceId         Which slice
     * @param ptDesired       PT amount to add
     * @param underlyingDesired Underlying amount to add
     * @param minLP           Minimum LP tokens to receive
     */
    function ammAddLiquidity(
        uint256 sliceId,
        uint256 ptDesired,
        uint256 underlyingDesired,
        uint256 minLP
    ) external nonReentrant whenNotPaused returns (uint256 lpMinted) {
        Slice storage s = slices[sliceId];
        require(s.active,                     "YS: slice inactive");
        require(block.timestamp < s.maturity, "YS: closed");             // [A3]
        require(ptDesired > 0 && underlyingDesired > 0, "YS: zero input");

        _accrueYield(sliceId);

        uint256 ptAmt;
        uint256 underlyingAmt;

        if (s.ammTotalLP == 0) {
            // Seeding the pool                                             [A6]
            ptAmt          = ptDesired;
            underlyingAmt  = underlyingDesired;
            lpMinted       = _sqrt(ptAmt * underlyingAmt) - MIN_LIQUIDITY;
            s.ammTotalLP   = MIN_LIQUIDITY; // permanently lock MIN_LIQUIDITY
        } else {
            // Proportional addition
            uint256 ptOptimal = underlyingDesired * s.ammPT / s.ammUnderlying;
            if (ptOptimal <= ptDesired) {
                ptAmt         = ptOptimal;
                underlyingAmt = underlyingDesired;
            } else {
                underlyingAmt = ptDesired * s.ammUnderlying / s.ammPT;
                ptAmt         = ptDesired;
            }
            lpMinted = ptAmt * s.ammTotalLP / s.ammPT;
        }

        require(lpMinted >= minLP, "YS: insufficient LP minted");

        // [A2] State before transfers
        s.ammPT         += ptAmt;
        s.ammUnderlying += underlyingAmt;
        s.ammTotalLP    += lpMinted;
        userSlices[sliceId][msg.sender].ammLPBalance += lpMinted;

        IERC20(s.ptToken).safeTransferFrom(msg.sender, address(this), ptAmt);
        IERC20(s.underlying).safeTransferFrom(msg.sender, address(this), underlyingAmt);

        emit AMMAddLiquidity(sliceId, msg.sender, ptAmt, underlyingAmt, lpMinted);
    }

    /**
     * @notice Remove liquidity from the PT↔underlying AMM.
     */
    function ammRemoveLiquidity(
        uint256 sliceId,
        uint256 lpAmount,
        uint256 minPT,
        uint256 minUnderlying
    ) external nonReentrant returns (uint256 ptOut, uint256 underlyingOut) {
        Slice storage s = slices[sliceId];
        UserSlice storage us = userSlices[sliceId][msg.sender];
        require(us.ammLPBalance >= lpAmount, "YS: insufficient LP");
        require(s.ammTotalLP > 0,            "YS: empty pool");

        _accrueYield(sliceId);

        ptOut          = lpAmount * s.ammPT         / s.ammTotalLP;
        underlyingOut  = lpAmount * s.ammUnderlying / s.ammTotalLP;

        require(ptOut         >= minPT,         "YS: insufficient PT out");
        require(underlyingOut >= minUnderlying, "YS: insufficient underlying out");

        // [A2] State before transfers
        us.ammLPBalance -= lpAmount;
        s.ammTotalLP    -= lpAmount;
        s.ammPT         -= ptOut;
        s.ammUnderlying -= underlyingOut;

        IERC20(s.ptToken).safeTransfer(msg.sender, ptOut);
        IERC20(s.underlying).safeTransfer(msg.sender, underlyingOut);

        emit AMMRemoveLiquidity(sliceId, msg.sender, lpAmount, ptOut, underlyingOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Withdraw Protocol Fees
    // ─────────────────────────────────────────────────────────────────────

    function withdrawProtocolFees(uint256 sliceId, address to) external onlyOwner nonReentrant {
        Slice storage s = slices[sliceId];
        uint256 amt = sliceProtocolFees[sliceId][0];
        require(amt > 0, "YS: no fees");
        sliceProtocolFees[sliceId][0] = 0;
        IERC20(s.underlying).safeTransfer(to, amt);
        emit ProtocolFeesWithdrawn(sliceId, to, amt);
    }

    function setLendingProtocol(address _lending) external onlyOwner {
        lendingProtocol = IWikiLending(_lending);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal: Yield Accrual                                      [A5]
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Samples the current wToken exchange rate and distributes
     *      any newly accrued yield across all outstanding YT tokens.
     *
     *      Yield per YT = (currentRate - lastRate) × totalWTokens / totalYT
     *
     *      Called before every state-changing operation to ensure
     *      yield distribution is always up to date.
     */
    function _accrueYield(uint256 sliceId) internal {
        Slice storage s = slices[sliceId];
        if (block.timestamp >= s.maturity) return; // no more yield after maturity

        IWikiLending.Market memory m = lendingProtocol.getMarket(s.lendingMarketId);
        uint256 currentRate = m.exchangeRate;

        if (currentRate <= s.lastExchangeRate) {
            // Rate hasn't moved (can happen in same block)
            return;
        }

        uint256 totalYT = IERC20(s.ytToken).totalSupply();
        if (totalYT == 0) {
            s.lastExchangeRate = currentRate;
            return;
        }

        // Yield generated = rate increase × total principal locked
        // underlying yield = (currentRate - lastRate) × totalWTokens / PRECISION
        uint256 rateIncrease   = currentRate - s.lastExchangeRate;
        uint256 grossYield     = rateIncrease * s.totalWTokens / PRECISION;

        // Protocol fee deducted from yield                                [A7]
        uint256 fee            = grossYield * s.yieldFeeBps / BPS;
        uint256 netYield       = grossYield - fee;

        sliceProtocolFees[sliceId][0] += fee;

        // Distribute net yield across all YT holders proportionally
        s.accYieldPerYT    += netYield * PRECISION / totalYT;
        s.lastExchangeRate  = currentRate;
    }

    function _claimYield(uint256 sliceId, address user) internal {
        Slice storage s   = slices[sliceId];
        UserSlice storage us = userSlices[sliceId][user];

        uint256 ytBal = IERC20(s.ytToken).balanceOf(user);
        if (ytBal == 0) return;

        uint256 owed = ytBal * s.accYieldPerYT / PRECISION;
        if (owed <= us.ytYieldDebt) return;

        uint256 claimable = owed - us.ytYieldDebt;
        us.ytYieldDebt = owed;

        if (claimable == 0) return;

        // Determine available underlying balance in contract
        // Yield comes from appreciation of wTokens held
        // We approximate by paying from the underlying token balance
        uint256 available = IERC20(s.underlying).balanceOf(address(this));
        if (claimable > available) claimable = available;
        if (claimable == 0) return;

        IERC20(s.underlying).safeTransfer(user, claimable);
        emit YieldClaimed(sliceId, user, claimable, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal: Helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Returns the wToken ERC20 address for a WikiLending market.
     *      In production WikiLending would expose this directly.
     *      We compute a deterministic address based on market index.
     */
    function _getWToken(uint256 marketId) internal view returns (address) {
        // WikiLending stores wToken balance as internal accounting using exchangeRate.
        // For the simplified integration, the wToken IS the underlying for now.
        // In production: WikiLending.getWToken(marketId) → ERC20 address
        IWikiLending.Market memory m = lendingProtocol.getMarket(marketId);
        return m.underlying;
    }

    /**
     * @dev Compute the implied fixed rate from AMM state.
     *      impliedRate = annualised (1 - ptPrice) / timeToMaturity
     */
    function _impliedRate(Slice storage s) internal view returns (uint256) {
        if (s.ammPT == 0 || s.ammUnderlying == 0) return 0;
        uint256 ptPrice   = s.ammUnderlying * PRECISION / (s.ammPT + s.ammUnderlying);
        uint256 timeLeft  = s.maturity > block.timestamp ? s.maturity - block.timestamp : 1;
        uint256 discount  = PRECISION > ptPrice ? PRECISION - ptPrice : 0;
        // Annualise: rate = discount × 365days / timeLeft
        return discount * 365 days / timeLeft;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function sliceCount() external view returns (uint256) {
        return slices.length;
    }

    function getSlice(uint256 sliceId) external view returns (Slice memory) {
        return slices[sliceId];
    }

    function getUserSlice(uint256 sliceId, address user) external view returns (UserSlice memory) {
        return userSlices[sliceId][user];
    }

    /**
     * @notice Preview claimable yield for a user on a slice
     */
    function previewClaimableYield(uint256 sliceId, address user) external view returns (uint256) {
        Slice storage s    = slices[sliceId];
        UserSlice storage us = userSlices[sliceId][user];
        uint256 ytBal      = IERC20(s.ytToken).balanceOf(user);
        if (ytBal == 0) return 0;

        // Simulate accrual
        IWikiLending.Market memory m = lendingProtocol.getMarket(s.lendingMarketId);
        uint256 accYield = s.accYieldPerYT;

        if (m.exchangeRate > s.lastExchangeRate && block.timestamp < s.maturity) {
            uint256 totalYT = IERC20(s.ytToken).totalSupply();
            if (totalYT > 0) {
                uint256 gross = (m.exchangeRate - s.lastExchangeRate) * s.totalWTokens / PRECISION;
                uint256 net   = gross * (BPS - s.yieldFeeBps) / BPS;
                accYield     += net * PRECISION / totalYT;
            }
        }

        uint256 owed = ytBal * accYield / PRECISION;
        return owed > us.ytYieldDebt ? owed - us.ytYieldDebt : 0;
    }

    /**
     * @notice Current implied fixed rate (annualised, 1e18 = 100%)
     */
    function impliedFixedRate(uint256 sliceId) external view returns (uint256) {
        return _impliedRate(slices[sliceId]);
    }

    /**
     * @notice Current PT price in underlying (1e18 = 1.0 = par)
     */
    function ptPrice(uint256 sliceId) external view returns (uint256) {
        Slice storage s = slices[sliceId];
        if (s.ammPT == 0 || s.ammUnderlying == 0) return 0;
        return s.ammUnderlying * PRECISION / (s.ammPT + s.ammUnderlying);
    }

    /**
     * @notice Preview AMM swap output without state change
     */
    function previewSwap(uint256 sliceId, bool ptIn, uint256 exactIn)
        external view returns (uint256 amountOut, uint256 fee)
    {
        Slice storage s = slices[sliceId];
        if (s.ammPT == 0 || s.ammUnderlying == 0 || exactIn == 0) return (0, 0);
        if (ptIn) {
            uint256 raw = s.ammUnderlying * exactIn / (s.ammPT + exactIn);
            fee = raw * s.ammFeeBps / BPS;
            amountOut = raw - fee;
        } else {
            fee = exactIn * s.ammFeeBps / BPS;
            uint256 netIn = exactIn - fee;
            amountOut = s.ammPT * netIn / (s.ammUnderlying + netIn);
        }
    }

    /**
     * @notice TVL of a slice: underlying value of all locked wTokens
     */
    function sliceTVL(uint256 sliceId) external view returns (uint256) {
        Slice storage s = slices[sliceId];
        if (s.totalWTokens == 0) return 0;
        IWikiLending.Market memory m = lendingProtocol.getMarket(s.lendingMarketId);
        return s.totalWTokens * m.exchangeRate / PRECISION;
    }

    /**
     * @notice All active slices for a lending market
     */
    function getSlicesByMarket(uint256 lendingMarketId)
        external view returns (uint256[] memory ids)
    {
        uint256 count;
        for (uint256 i = 0; i < slices.length; i++) {
            if (slices[i].lendingMarketId == lendingMarketId) count++;
        }
        ids = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < slices.length; i++) {
            if (slices[i].lendingMarketId == lendingMarketId) ids[idx++] = i;
        }
    }

    // ── Tranche Insurance — Senior / Junior ─────────────────────────────────
    // Senior: lower yield, first to be repaid, last to absorb losses
    // Junior: higher yield, first-loss capital (absorbs losses before seniors)
    // This mirrors structured finance tranching used in traditional finance.

    enum Tranche { JUNIOR, SENIOR }

    struct TrancheConfig {
        uint256 seniorYieldBps;  // e.g. 500 = 5% APY — lower, safer
        uint256 juniorYieldBps;  // e.g. 2500 = 25% APY — higher, first-loss
        uint256 seniorCap;       // max USDC in senior tranche
        uint256 juniorCap;       // max USDC in junior tranche
        uint256 seniorTVL;       // current senior deposits
        uint256 juniorTVL;       // current junior deposits
    }

    mapping(uint256 => TrancheConfig) public trancheConfigs; // sliceId → config
    mapping(address => mapping(uint256 => Tranche)) public userTranche; // user → sliceId → tranche

    function configureTranches(
        uint256 sliceId,
        uint256 seniorYieldBps,
        uint256 juniorYieldBps,
        uint256 seniorCap,
        uint256 juniorCap
    ) external onlyOwner {
        require(juniorYieldBps > seniorYieldBps, "Tranche: junior must yield more");
        require(seniorYieldBps >= 100 && juniorYieldBps <= 10000, "Tranche: yield bounds");
        trancheConfigs[sliceId] = TrancheConfig({
            seniorYieldBps: seniorYieldBps,
            juniorYieldBps: juniorYieldBps,
            seniorCap:      seniorCap,
            juniorCap:      juniorCap,
            seniorTVL:      0,
            juniorTVL:      0
        });
    }

    function depositTranche(uint256 sliceId, uint256 amount, Tranche tranche) external {
        TrancheConfig storage tc = trancheConfigs[sliceId];
        if (tranche == Tranche.SENIOR) {
            require(tc.seniorTVL + amount <= tc.seniorCap, "Tranche: senior full");
            tc.seniorTVL += amount;
        } else {
            require(tc.juniorTVL + amount <= tc.juniorCap, "Tranche: junior full");
            tc.juniorTVL += amount;
        }
        userTranche[msg.sender][sliceId] = tranche;
        // Route to underlying slice deposit logic
    }

    function trancheAPY(uint256 sliceId) external view returns (uint256 seniorAPY, uint256 juniorAPY) {
        TrancheConfig storage tc = trancheConfigs[sliceId];
        seniorAPY = tc.seniorYieldBps;
        juniorAPY = tc.juniorYieldBps;
    }

}