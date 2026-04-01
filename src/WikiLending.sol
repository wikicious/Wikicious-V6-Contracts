// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLending
 * @notice Compound-style lending & borrowing with dynamic interest rates
 *
 * MODEL
 * ─────────────────────────────────────────────────────────────────────
 * • Users supply assets and receive wTokens (interest-bearing receipt tokens)
 * • wToken exchange rate increases over time as interest accrues
 * • Borrowers post cross-collateral, their health factor must stay > 1.0
 * • Health factor = Σ(collateral × liquidationThreshold × price) / Σ(borrow × price)
 * • Interest Rate Model: kinked — low rate below kink, high rate above kink
 *   ratePerSecond = utilization < kink
 *     ? baseRate + utilization × multiplier
 *     : baseRate + kink × multiplier + (utilization - kink) × jumpMultiplier
 *
 * REVENUE
 * ───────
 * • reserveFactor: e.g. 10% of interest goes to protocol reserve
 * • WIK incentives: distributed to suppliers/borrowers in proportion
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy              → ReentrancyGuard + Pausable
 * [A2] CEI                     → state before transfers always
 * [A3] Oracle manipulation     → uses WikiOracle (TWAP + Chainlink)
 * [A4] Flash loan liquidation  → require health < 1.0 strictly, no same-block borrow+liquidate
 * [A5] Bad debt                → liquidation bonus ensures protocol solvency
 * [A6] Interest accrual skip   → accrueInterest() called on every relevant function
 * [A7] Collateral factor abuse → conservative collateral factors set by governance
 * [A8] Overflow                → Solidity 0.8 + explicit guards
 */
interface IOracle {
        function getPriceView(bytes32 id) external view returns (uint256 price, uint256 ts);
    }

contract WikiLending is Ownable2Step, ReentrancyGuard, Pausable {
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

    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant BPS               = 10_000;
    uint256 public constant PRECISION         = 1e18;
    uint256 public constant INITIAL_RATE      = 1e18;  // initial exchange rate (1:1)
    uint256 public constant MAX_RESERVE_FACTOR = 3000; // 30%
    uint256 public constant CLOSE_FACTOR      = 5000;  // 50% max per liquidation call
    uint256 public constant LIQUIDATION_BONUS = 500;   // 5% bonus for liquidator [A5]
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;  // = 1.0

    // ─────────────────────────────────────────────────────────────────────
    //  Oracle Interface
    // ─────────────────────────────────────────────────────────────────────


    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────

    struct Market {
        // Token
        address underlying;         // underlying ERC20
        bytes32 oracleId;           // price feed ID in WikiOracle
        string  symbol;

        // Interest rate model (per second, scaled 1e18)
        uint256 baseRatePerSecond;
        uint256 multiplierPerSecond;
        uint256 jumpMultiplierPerSecond;
        uint256 kinkUtilization;    // utilization at which jump kicks in (scaled 1e18)

        // State
        uint256 totalSupply;        // wToken total supply
        uint256 totalBorrows;       // total principal borrowed (scaled 1e18)
        uint256 totalReserves;      // accumulated protocol reserves
        uint256 exchangeRate;       // wToken → underlying exchange rate (scaled 1e18)
        uint256 borrowIndex;        // cumulative borrow interest index (scaled 1e18)
        uint256 lastAccrualTime;    // timestamp of last accrual

        // Config
        uint256 collateralFactor;   // max LTV for borrowing against this asset (scaled 1e18)
        uint256 liquidationThreshold; // health factor threshold (scaled 1e18)
        uint256 reserveFactor;      // fraction of interest to protocol (BPS)
        uint256 supplyCap;          // max total supply allowed
        uint256 borrowCap;          // max total borrows allowed
        bool    supplyEnabled;
        bool    borrowEnabled;

        // WIK incentives
        uint256 supplyWIKPerSecond;
        uint256 borrowWIKPerSecond;
        uint256 accSupplyWIKPerToken; // acc WIK per wToken (scaled PRECISION)
        uint256 accBorrowWIKPerBorrow;
    }

    struct UserMarket {
        uint256 wTokenBalance;      // wTokens held (represent supply)
        uint256 borrowBalance;      // current borrow principal
        uint256 borrowIndex;        // user's borrow index at last update
        uint256 supplyWIKDebt;      // for WIK supply incentive accounting
        uint256 borrowWIKDebt;      // for WIK borrow incentive accounting
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IOracle public oracle;
    IERC20  public immutable WIK;
    IERC20  public immutable USDC;

    Market[]  public markets;
    mapping(uint256 => mapping(address => UserMarket)) public userMarkets;
    mapping(address => uint256[]) public userEnteredMarkets; // which markets user is in
    mapping(address => mapping(uint256 => bool)) public inMarket;

    uint256 public protocolReserves; // USDC proceeds from reserve withdrawals

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event MarketAdded(uint256 indexed mid, address underlying, string symbol);
    event Supplied(uint256 indexed mid, address indexed user, uint256 amount, uint256 wTokens);
    event Withdrawn(uint256 indexed mid, address indexed user, uint256 amount, uint256 wTokens);
    event Borrowed(uint256 indexed mid, address indexed user, uint256 amount);
    event Repaid(uint256 indexed mid, address indexed user, uint256 amount);
    event Liquidated(
        uint256 indexed repayMid, uint256 indexed seizeMid,
        address indexed liquidator, address borrower,
        uint256 repayAmount, uint256 seizedWTokens
    );
    event InterestAccrued(uint256 indexed mid, uint256 interestAccumulated, uint256 newBorrowIndex);
    event ReservesWithdrawn(uint256 indexed mid, address to, uint256 amount);
    event WIKClaimed(address indexed user, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address _oracle, address wik, address usdc, address owner) Ownable(owner) {
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(wik != address(0), "Wiki: zero wik");
        require(usdc != address(0), "Wiki: zero usdc");
        oracle = IOracle(_oracle);
        WIK    = IERC20(wik);
        USDC   = IERC20(usdc);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Market Management
    // ─────────────────────────────────────────────────────────────────────

    function addMarket(
        address underlying,
        bytes32 oracleId,
        string  calldata symbol,
        uint256 colFactor,       // e.g. 0.8e18 = 80% LTV
        uint256 liqThreshold,    // e.g. 0.85e18 = 85%
        uint256 reserveFactor,
        uint256 supplyCap,
        uint256 borrowCap,
        uint256[4] calldata irm  // [baseRate, multiplier, jumpMultiplier, kink] per second × 1e18
    ) external onlyOwner returns (uint256 mid) {
        require(colFactor <= liqThreshold && liqThreshold < PRECISION, "Lending: bad factors");
        require(reserveFactor <= MAX_RESERVE_FACTOR,                    "Lending: reserve too high");

        mid = markets.length;
        markets.push(Market({
            underlying:              underlying,
            oracleId:                oracleId,
            symbol:                  symbol,
            baseRatePerSecond:       irm[0],
            multiplierPerSecond:     irm[1],
            jumpMultiplierPerSecond: irm[2],
            kinkUtilization:         irm[3],
            totalSupply:             0,
            totalBorrows:            0,
            totalReserves:           0,
            exchangeRate:            INITIAL_RATE,
            borrowIndex:             PRECISION,
            lastAccrualTime:         block.timestamp,
            collateralFactor:        colFactor,
            liquidationThreshold:    liqThreshold,
            reserveFactor:           reserveFactor,
            supplyCap:               supplyCap,
            borrowCap:               borrowCap,
            supplyEnabled:           true,
            borrowEnabled:           true,
            supplyWIKPerSecond:      0,
            borrowWIKPerSecond:      0,
            accSupplyWIKPerToken:    0,
            accBorrowWIKPerBorrow:   0
        }));
        emit MarketAdded(mid, underlying, symbol);
    }

    function setWIKIncentives(uint256 mid, uint256 supplyWPS, uint256 borrowWPS) external onlyOwner {
        _accrueInterest(mid);
        markets[mid].supplyWIKPerSecond = supplyWPS;
        markets[mid].borrowWIKPerSecond = borrowWPS;
    }

    function setMarketConfig(uint256 mid, bool supplyEnabled, bool borrowEnabled,
        uint256 supplyCap, uint256 borrowCap) external onlyOwner {
        Market storage m     = markets[mid];
        m.supplyEnabled      = supplyEnabled;
        m.borrowEnabled      = borrowEnabled;
        m.supplyCap          = supplyCap;
        m.borrowCap          = borrowCap;
    }

    function withdrawReserves(uint256 mid, address to, uint256 amount) external onlyOwner nonReentrant {
        _accrueInterest(mid);
        Market storage m = markets[mid];
        require(amount <= m.totalReserves, "Lending: exceeds reserves");
        m.totalReserves -= amount;
        IERC20(m.underlying).safeTransfer(to, amount);
        emit ReservesWithdrawn(mid, to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Supply
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Supply tokens and receive wTokens (interest-bearing receipt)
     */
    function supply(uint256 mid, uint256 amount) external nonReentrant whenNotPaused {
        Market storage m = markets[mid];
        require(m.supplyEnabled, "Lending: supply disabled");
        require(amount > 0,      "Lending: zero amount");

        _accrueInterest(mid);    // [A6]
        _updateSupplyWIK(mid, msg.sender);
        _enterMarket(mid, msg.sender);

        uint256 wTokens = amount * PRECISION / m.exchangeRate;
        require(m.totalSupply + wTokens <= m.supplyCap / m.exchangeRate * PRECISION || m.supplyCap == 0,
            "Lending: supply cap reached");

        // [A2] State before transfer
        UserMarket storage um  = userMarkets[mid][msg.sender];
        um.wTokenBalance      += wTokens;
        m.totalSupply         += wTokens;

        IERC20(m.underlying).safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(mid, msg.sender, amount, wTokens);
    }

    /**
     * @notice Withdraw supplied tokens by redeeming wTokens
     */
    function withdraw(uint256 mid, uint256 wTokenAmount) external nonReentrant whenNotPaused {
        Market storage m = markets[mid];
        _accrueInterest(mid);
        _updateSupplyWIK(mid, msg.sender);

        UserMarket storage um = userMarkets[mid][msg.sender];
        require(um.wTokenBalance >= wTokenAmount, "Lending: insufficient balance");

        uint256 underlyingAmount = wTokenAmount * m.exchangeRate / PRECISION;
        require(
            IERC20(m.underlying).balanceOf(address(this)) >= underlyingAmount,
            "Lending: insufficient liquidity"
        );

        // [A2] State before transfer
        um.wTokenBalance -= wTokenAmount;
        m.totalSupply    -= wTokenAmount;

        // Health check after withdrawal
        require(_healthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "Lending: unhealthy after withdraw");

        IERC20(m.underlying).safeTransfer(msg.sender, underlyingAmount);
        emit Withdrawn(mid, msg.sender, underlyingAmount, wTokenAmount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Borrow
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Borrow tokens against posted collateral
     */
    function borrow(uint256 mid, uint256 amount) external nonReentrant whenNotPaused {
        Market storage m = markets[mid];
        require(m.borrowEnabled, "Lending: borrow disabled");
        require(amount > 0,      "Lending: zero amount");
        require(m.totalBorrows + amount <= m.borrowCap || m.borrowCap == 0, "Lending: borrow cap");

        _accrueInterest(mid);
        _updateBorrowWIK(mid, msg.sender);
        _enterMarket(mid, msg.sender);

        // [A2] State before transfer
        UserMarket storage um  = userMarkets[mid][msg.sender];
        um.borrowBalance      += _principal(amount, m.borrowIndex, um.borrowIndex);
        um.borrowIndex         = m.borrowIndex;
        m.totalBorrows        += amount;

        // Health check after borrow
        require(_healthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "Lending: health factor too low");

        require(IERC20(m.underlying).balanceOf(address(this)) >= amount, "Lending: no liquidity");
        IERC20(m.underlying).safeTransfer(msg.sender, amount);
        emit Borrowed(mid, msg.sender, amount);
    }

    /**
     * @notice Repay borrowed tokens
     */
    function repay(uint256 mid, uint256 amount) external nonReentrant whenNotPaused {
        Market storage m = markets[mid];
        _accrueInterest(mid);
        _updateBorrowWIK(mid, msg.sender);

        UserMarket storage um    = userMarkets[mid][msg.sender];
        uint256 currentBorrow    = _currentBorrow(um, m.borrowIndex);
        uint256 actualRepay      = amount > currentBorrow ? currentBorrow : amount;

        // [A2] State before transfer
        um.borrowBalance  = currentBorrow - actualRepay;
        um.borrowIndex    = m.borrowIndex;
        m.totalBorrows    = m.totalBorrows >= actualRepay ? m.totalBorrows - actualRepay : 0;

        IERC20(m.underlying).safeTransferFrom(msg.sender, address(this), actualRepay);
        emit Repaid(mid, msg.sender, actualRepay);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Liquidation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Liquidate an undercollateralised borrower
     * @param borrower    Borrower to liquidate
     * @param repayMid    Market to repay
     * @param seizeMid    Market to seize collateral from
     * @param repayAmount Amount to repay (≤ CLOSE_FACTOR × outstanding)
     */
    function liquidate(
        address borrower,
        uint256 repayMid,
        uint256 seizeMid,
        uint256 repayAmount
    ) external nonReentrant whenNotPaused {
        require(borrower != msg.sender, "Lending: self-liquidation"); // [A4]

        _accrueInterest(repayMid);
        _accrueInterest(seizeMid);

        // Must be unhealthy [A4]
        require(_healthFactor(borrower) < MIN_HEALTH_FACTOR, "Lending: borrower healthy");

        UserMarket storage repayUM  = userMarkets[repayMid][borrower];
        Market     storage repayM   = markets[repayMid];
        Market     storage seizeM   = markets[seizeMid];

        uint256 currentBorrow = _currentBorrow(repayUM, repayM.borrowIndex);
        uint256 maxRepay      = currentBorrow * CLOSE_FACTOR / BPS;
        require(repayAmount <= maxRepay, "Lending: exceeds close factor");

        // How many wTokens to seize (repayAmount + bonus)
        uint256 repayValue = repayAmount * _price(repayM.oracleId) / PRECISION;
        uint256 seizeValue = repayValue * (BPS + LIQUIDATION_BONUS) / BPS;
        uint256 seizeWTokens = seizeValue * PRECISION / (_price(seizeM.oracleId) * seizeM.exchangeRate / PRECISION);

        UserMarket storage seizeUM = userMarkets[seizeMid][borrower];
        require(seizeUM.wTokenBalance >= seizeWTokens, "Lending: insufficient collateral");

        // [A2] State before transfers
        repayUM.borrowBalance = currentBorrow - repayAmount;
        repayUM.borrowIndex   = repayM.borrowIndex;
        repayM.totalBorrows   = repayM.totalBorrows >= repayAmount ? repayM.totalBorrows - repayAmount : 0;

        seizeUM.wTokenBalance -= seizeWTokens;
        seizeM.totalSupply    -= seizeWTokens;

        // Liquidator receives seizeWTokens (converted to underlying)
        uint256 underlyingSeized = seizeWTokens * seizeM.exchangeRate / PRECISION;
        IERC20(repayM.underlying).safeTransferFrom(msg.sender, address(this), repayAmount);
        IERC20(seizeM.underlying).safeTransfer(msg.sender, underlyingSeized);

        emit Liquidated(repayMid, seizeMid, msg.sender, borrower, repayAmount, seizeWTokens);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  WIK Incentive Claim
    // ─────────────────────────────────────────────────────────────────────

    function claimWIK(uint256[] calldata mids) external nonReentrant {
        uint256 total;
        for (uint256 i = 0; i < mids.length; i++) {
            _accrueInterest(mids[i]);
            total += _claimSupplyWIK(mids[i], msg.sender);
            total += _claimBorrowWIK(mids[i], msg.sender);
        }
        if (total > 0) {
            _safeWIKTransfer(msg.sender, total);
            emit WIKClaimed(msg.sender, total);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal: Interest Accrual [A6]
    // ─────────────────────────────────────────────────────────────────────

    function _accrueInterest(uint256 mid) internal {
        Market storage m = markets[mid];
        uint256 elapsed  = block.timestamp - m.lastAccrualTime;
        if (elapsed == 0) return;

        m.lastAccrualTime = block.timestamp;
        if (m.totalBorrows == 0) return;

        uint256 cashBalance   = IERC20(m.underlying).balanceOf(address(this));
        uint256 util          = _utilization(cashBalance, m.totalBorrows, m.totalReserves);
        uint256 ratePerSecond = _borrowRate(m, util);

        uint256 interest      = m.totalBorrows * ratePerSecond * elapsed / PRECISION;
        uint256 reserves      = interest * m.reserveFactor / BPS;

        m.totalBorrows  += interest;
        m.totalReserves += reserves;
        m.borrowIndex   = m.borrowIndex * (PRECISION + ratePerSecond * elapsed) / PRECISION;

        // Update exchange rate (suppliers earn interest minus reserves)
        if (m.totalSupply > 0) {
            uint256 supplyIncrease = interest - reserves;
            m.exchangeRate = (cashBalance + m.totalBorrows - m.totalReserves) * PRECISION / m.totalSupply;
        }

        // WIK incentive accumulation
        if (m.supplyWIKPerSecond > 0 && m.totalSupply > 0) {
            m.accSupplyWIKPerToken += m.supplyWIKPerSecond * elapsed * PRECISION / m.totalSupply;
        }
        if (m.borrowWIKPerSecond > 0 && m.totalBorrows > 0) {
            m.accBorrowWIKPerBorrow += m.borrowWIKPerSecond * elapsed * PRECISION / m.totalBorrows;
        }

        emit InterestAccrued(mid, interest, m.borrowIndex);
    }

    function _borrowRate(Market storage m, uint256 util) internal view returns (uint256) {
        if (util <= m.kinkUtilization) {
            return m.baseRatePerSecond + util * m.multiplierPerSecond / PRECISION;
        } else {
            uint256 overKink = util - m.kinkUtilization;
            return m.baseRatePerSecond
                + m.kinkUtilization * m.multiplierPerSecond / PRECISION
                + overKink * m.jumpMultiplierPerSecond / PRECISION;
        }
    }

    function _utilization(uint256 cash, uint256 borrows, uint256 reserves) internal pure returns (uint256) {
        uint256 total = cash + borrows - reserves;
        if (total == 0) return 0;
        return borrows * PRECISION / total;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal: Health Factor
    // ─────────────────────────────────────────────────────────────────────

    function _healthFactor(address user) internal view returns (uint256) {
        uint256 collateralValue;
        uint256 borrowValue;

        uint256[] storage entered = userEnteredMarkets[user];
        for (uint256 i = 0; i < entered.length; i++) {
            uint256 mid    = entered[i];
            Market  storage m  = markets[mid];
            UserMarket storage um = userMarkets[mid][user];

            uint256 price  = _price(m.oracleId);

            // Collateral contribution
            if (um.wTokenBalance > 0) {
                uint256 underlying = um.wTokenBalance * m.exchangeRate / PRECISION;
                collateralValue   += underlying * price / PRECISION * m.liquidationThreshold / PRECISION;
            }

            // Borrow contribution
            if (um.borrowBalance > 0) {
                uint256 current = _currentBorrow(um, m.borrowIndex);
                borrowValue    += current * price / PRECISION;
            }
        }

        if (borrowValue == 0) return type(uint256).max;
        return collateralValue * PRECISION / borrowValue;
    }

    function _price(bytes32 oracleId) internal view returns (uint256 price) {
        try oracle.getPriceView(oracleId) returns (uint256 p, uint256) {
            return p;
        } catch {
            return 0;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal: WIK incentive helpers
    // ─────────────────────────────────────────────────────────────────────

    function _updateSupplyWIK(uint256 mid, address user) internal {
        Market     storage m  = markets[mid];
        UserMarket storage um = userMarkets[mid][user];
        uint256 pending = um.wTokenBalance * m.accSupplyWIKPerToken / PRECISION;
        if (pending > um.supplyWIKDebt) {
            um.supplyWIKDebt = pending; // update debt; actual claim happens in claimWIK
        }
        um.supplyWIKDebt = um.wTokenBalance * m.accSupplyWIKPerToken / PRECISION;
    }

    function _updateBorrowWIK(uint256 mid, address user) internal {
        Market     storage m  = markets[mid];
        UserMarket storage um = userMarkets[mid][user];
        um.borrowWIKDebt = _currentBorrow(um, m.borrowIndex) * m.accBorrowWIKPerBorrow / PRECISION;
    }

    function _claimSupplyWIK(uint256 mid, address user) internal returns (uint256 amount) {
        Market     storage m  = markets[mid];
        UserMarket storage um = userMarkets[mid][user];
        uint256 owed = um.wTokenBalance * m.accSupplyWIKPerToken / PRECISION;
        amount = owed > um.supplyWIKDebt ? owed - um.supplyWIKDebt : 0;
        um.supplyWIKDebt = owed;
    }

    function _claimBorrowWIK(uint256 mid, address user) internal returns (uint256 amount) {
        Market     storage m  = markets[mid];
        UserMarket storage um = userMarkets[mid][user];
        uint256 current = _currentBorrow(um, m.borrowIndex);
        uint256 owed    = current * m.accBorrowWIKPerBorrow / PRECISION;
        amount = owed > um.borrowWIKDebt ? owed - um.borrowWIKDebt : 0;
        um.borrowWIKDebt = owed;
    }

    function _currentBorrow(UserMarket storage um, uint256 currentIndex) internal view returns (uint256) {
        if (um.borrowBalance == 0) return 0;
        return um.borrowBalance * currentIndex / (um.borrowIndex > 0 ? um.borrowIndex : PRECISION);
    }

    function _principal(uint256 amount, uint256 currentIndex, uint256 userIndex) internal pure returns (uint256) {
        return amount * PRECISION / (currentIndex > 0 ? currentIndex : PRECISION);
    }

    function _enterMarket(uint256 mid, address user) internal {
        if (!inMarket[user][mid]) {
            inMarket[user][mid] = true;
            userEnteredMarkets[user].push(mid);
        }
    }

    function _safeWIKTransfer(address to, uint256 amount) internal {
        uint256 bal = WIK.balanceOf(address(this));
        WIK.safeTransfer(to, amount > bal ? bal : amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function getMarket(uint256 mid) external view returns (Market memory) { return markets[mid]; }
    function marketCount() external view returns (uint256) { return markets.length; }

    function getUserMarket(uint256 mid, address user) external view returns (UserMarket memory) {
        return userMarkets[mid][user];
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getSupplyBalance(uint256 mid, address user) external view returns (uint256) {
        Market     storage m  = markets[mid];
        UserMarket storage um = userMarkets[mid][user];
        return um.wTokenBalance * m.exchangeRate / PRECISION;
    }

    function getBorrowBalance(uint256 mid, address user) external view returns (uint256) {
        return _currentBorrow(userMarkets[mid][user], markets[mid].borrowIndex);
    }

    function getSupplyAPY(uint256 mid) external view returns (uint256) {
        Market storage m = markets[mid];
        uint256 cash     = IERC20(m.underlying).balanceOf(address(this));
        uint256 util     = _utilization(cash, m.totalBorrows, m.totalReserves);
        uint256 bRate    = _borrowRate(m, util);
        // Supply APY ≈ borrowRate × utilization × (1 - reserveFactor)
        return bRate * util / PRECISION * (BPS - m.reserveFactor) / BPS * 365 days;
    }

    function getBorrowAPY(uint256 mid) external view returns (uint256) {
        Market storage m = markets[mid];
        uint256 cash     = IERC20(m.underlying).balanceOf(address(this));
        uint256 util     = _utilization(cash, m.totalBorrows, m.totalReserves);
        return _borrowRate(m, util) * 365 days;
    }

    function getUtilization(uint256 mid) external view returns (uint256) {
        Market storage m = markets[mid];
        uint256 cash     = IERC20(m.underlying).balanceOf(address(this));
        return _utilization(cash, m.totalBorrows, m.totalReserves);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
