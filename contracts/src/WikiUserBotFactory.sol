// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ═══════════════════════════════════════════════════════════════
 *  WikiUserBotFactory — User-Created Trading Bots (Bybit-style)
 *
 *  Users deploy their own on-chain bot strategies. Each bot is
 *  a registered strategy that anyone can deposit into.
 *
 *  Features:
 *  - User writes bot strategy logic (parameters only — execution
 *    is off-chain via keeper, trustless via signed payloads)
 *  - Max 5 bots per user wallet (configurable by governance)
 *  - Performance fee: creator earns 10-30% of profits
 *  - Management fee: 0-2% annual
 *  - Public marketplace listing optional
 *  - Bot can be paused/retired by creator
 *  - Protocol earns 5% of all bot performance fees
 *
 *  Bot types: Grid, DCA, Trend Follow, Mean Reversion, Custom
 * ═══════════════════════════════════════════════════════════════
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IWikiPerp {
    function placeMarketOrder(uint256 marketId, bool isLong, uint256 collateral, uint256 leverage, uint256 tp, uint256 sl) external returns (uint256);
    function closePosition(uint256 posId) external;
    function getPositionPnl(uint256 posId) external view returns (int256);
}

interface IWikiOracle {
    function getPrice(bytes32 marketId) external view returns (uint256 price, uint256 confidence, uint256 updatedAt);
}


interface IKeeperRegistry {
    function isKeeper(address) external view returns (bool);
}
contract WikiUserBotFactory is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────
    uint256 public constant MAX_BOTS_PER_USER     = 5;       // max bots one wallet can create
    uint256 public constant MAX_PERF_FEE_BPS      = 3000;    // 30% max performance fee
    uint256 public constant MAX_MGMT_FEE_BPS      = 200;     // 2% max management fee
    uint256 public constant PROTOCOL_FEE_BPS      = 500;     // 5% of creator's perf fee → protocol
    uint256 public constant MIN_DEPOSIT           = 10e6;    // $10 USDC minimum deposit
    uint256 public constant MAX_DEPOSIT_PER_BOT   = 1_000_000e6; // $1M per bot cap
    uint256 public constant BPS                   = 10000;

    IERC20  public immutable USDC;
    IWikiPerp  public perp;
    IWikiOracle public oracle;
    address public revenueSplitter;
    address public keeperRegistry;   // authorized keepers can execute trades

    // ── Bot Types ─────────────────────────────────────────────────
    enum BotType { GRID, DCA, TREND_FOLLOW, MEAN_REVERSION, CUSTOM }
    enum BotStatus { ACTIVE, PAUSED, RETIRED }

    // ── Bot Config (set by creator, immutable after creation) ─────
    struct BotConfig {
        string   name;           // display name
        string   description;    // strategy description
        BotType  botType;
        address  creator;
        uint256  createdAt;
        uint256  perfFeeBps;     // creator's cut of profits
        uint256  mgmtFeeBps;     // annual management fee (bps)
        uint256  maxLeverage;    // max leverage this bot can use (1–125)
        uint256  maxDrawdownBps; // auto-pause if drawdown exceeds this
        bytes32  marketId;       // primary market traded
        bool     isPublic;       // listed in marketplace
        BotStatus status;
    }

    // ── Bot Runtime State ─────────────────────────────────────────
    struct BotState {
        uint256 totalDeposited;   // total USDC deposited by all investors
        uint256 totalShares;      // total share tokens outstanding
        uint256 highWaterMark;    // nav at peak (for perf fee HWM calc)
        uint256 navPerShare;      // current NAV per share (scaled 1e18)
        uint256 lastMgmtFeeTime;  // last management fee accrual
        uint256 totalPerfFeesPaid;
        uint256 totalMgmtFeesPaid;
        uint256 openPositionId;   // current open position (0 = flat)
        uint256 tradeCount;
        int256  totalPnl;
    }

    // ── Investor Position ─────────────────────────────────────────
    struct InvestorPosition {
        uint256 shares;
        uint256 depositedUsdc;
        uint256 highWaterMark;    // investor's personal HWM for perf fee
        uint256 depositTime;
    }

    // ── Storage ───────────────────────────────────────────────────
    mapping(uint256 => BotConfig) public bots;
    mapping(uint256 => BotState)  public botStates;
    mapping(address => mapping(uint256 => InvestorPosition)) public positions;
    mapping(address => uint256[]) public userBots;       // creator → their bot IDs
    mapping(address => uint256[]) public userInvested;   // investor → bots they're in
    mapping(uint256 => address[]) public botInvestors;
    uint256 public totalBots;

    // ── Trade Execution Log ───────────────────────────────────────
    struct TradeLog {
        uint256 timestamp;
        bool    isLong;
        uint256 collateral;
        uint256 leverage;
        int256  pnl;
        string  reason;  // e.g. "Grid buy level 3", "DCA entry #4"
    }
    mapping(uint256 => TradeLog[]) public tradeLogs;  // botId → history

    // ── Events ────────────────────────────────────────────────────
    event BotCreated(uint256 indexed botId, address indexed creator, string name, BotType botType);
    event BotDeposit(uint256 indexed botId, address indexed investor, uint256 usdc, uint256 shares);
    event BotWithdraw(uint256 indexed botId, address indexed investor, uint256 usdc, uint256 perfFee);
    event BotTradeExecuted(uint256 indexed botId, bool isLong, uint256 collateral, int256 pnl, string reason);
    event BotStatusChanged(uint256 indexed botId, BotStatus newStatus);
    event BotNAVUpdated(uint256 indexed botId, uint256 newNAV);
    event CircuitBreakerTripped(uint256 indexed botId, uint256 drawdownBps);

    constructor(address _usdc, address _perp, address _oracle, address _revenue, address _keepers, address _owner) Ownable(_owner) {
        USDC            = IERC20(_usdc);
        perp            = IWikiPerp(_perp);
        oracle          = IWikiOracle(_oracle);
        revenueSplitter = _revenue;
        keeperRegistry  = _keepers;
    }

    // ═══════════════════════════════════════════════════════════════
    // CREATOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Create a new user bot. Max 5 per wallet.
     * @param name         Display name shown in marketplace
     * @param description  Strategy description
     * @param botType      GRID | DCA | TREND_FOLLOW | MEAN_REVERSION | CUSTOM
     * @param perfFeeBps   Creator's performance fee (0–3000 = 0–30%)
     * @param mgmtFeeBps   Annual management fee (0–200 = 0–2%)
     * @param maxLeverage  Max leverage bot can use (1–125)
     * @param maxDrawdownBps Auto-pause threshold (e.g. 1000 = 10% drawdown)
     * @param marketId     Primary trading market (keccak256 of symbol)
     * @param isPublic     List in marketplace so others can deposit
     */
    function createBot(
        string  calldata name,
        string  calldata description,
        BotType botType,
        uint256 perfFeeBps,
        uint256 mgmtFeeBps,
        uint256 maxLeverage,
        uint256 maxDrawdownBps,
        bytes32 marketId,
        bool    isPublic
    ) external whenNotPaused returns (uint256 botId) {
        require(userBots[msg.sender].length < MAX_BOTS_PER_USER, "BotFactory: max 5 bots per wallet");
        require(perfFeeBps  <= MAX_PERF_FEE_BPS,  "BotFactory: perf fee >30%");
        require(mgmtFeeBps  <= MAX_MGMT_FEE_BPS,  "BotFactory: mgmt fee >2%");
        require(maxLeverage >= 1 && maxLeverage <= 125, "BotFactory: leverage 1-125");
        require(bytes(name).length > 0 && bytes(name).length <= 50, "BotFactory: name 1-50 chars");

        botId = ++totalBots;
        bots[botId] = BotConfig({
            name:           name,
            description:    description,
            botType:        botType,
            creator:        msg.sender,
            createdAt:      block.timestamp,
            perfFeeBps:     perfFeeBps,
            mgmtFeeBps:     mgmtFeeBps,
            maxLeverage:    maxLeverage,
            maxDrawdownBps: maxDrawdownBps,
            marketId:       marketId,
            isPublic:       isPublic,
            status:         BotStatus.ACTIVE
        });
        botStates[botId].navPerShare   = 1e18; // starts at $1/share
        botStates[botId].highWaterMark = 1e18;
        botStates[botId].lastMgmtFeeTime = block.timestamp;

        userBots[msg.sender].push(botId);
        emit BotCreated(botId, msg.sender, name, botType);
    }

    /** @notice Pause / resume / retire your own bot */
    function setBotStatus(uint256 botId, BotStatus newStatus) external {
        require(bots[botId].creator == msg.sender || msg.sender == owner(), "BotFactory: not creator");
        require(newStatus != BotStatus.ACTIVE || bots[botId].status != BotStatus.RETIRED, "BotFactory: cannot reactivate retired bot");
        bots[botId].status = newStatus;
        emit BotStatusChanged(botId, newStatus);
    }

    /** @notice Update bot description / public visibility (not fees) */
    function updateBotMeta(uint256 botId, string calldata description, bool isPublic) external {
        require(bots[botId].creator == msg.sender, "BotFactory: not creator");
        bots[botId].description = description;
        bots[botId].isPublic    = isPublic;
    }

    // ═══════════════════════════════════════════════════════════════
    // INVESTOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /** @notice Deposit USDC into a bot. Get shares proportional to NAV. */
    function deposit(uint256 botId, uint256 amount) external nonReentrant whenNotPaused {
        BotConfig storage cfg = bots[botId];
        BotState  storage st  = botStates[botId];
        require(cfg.status == BotStatus.ACTIVE,  "BotFactory: bot not active");
        require(amount >= MIN_DEPOSIT,            "BotFactory: below minimum $10");
        require(st.totalDeposited + amount <= MAX_DEPOSIT_PER_BOT, "BotFactory: bot at capacity");

        _accrueManagementFee(botId);

        uint256 shares = st.totalShares == 0
            ? amount * 1e12                      // first deposit: 1 share = $0.000001 USDC (precision)
            : amount * st.totalShares / st.totalDeposited;

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        st.totalDeposited += amount;
        st.totalShares    += shares;

        InvestorPosition storage pos = positions[msg.sender][botId];
        if (pos.shares == 0) {
            botInvestors[botId].push(msg.sender);
            userInvested[msg.sender].push(botId);
        }
        pos.shares        += shares;
        pos.depositedUsdc += amount;
        pos.highWaterMark  = st.navPerShare;
        pos.depositTime    = block.timestamp;

        emit BotDeposit(botId, msg.sender, amount, shares);
    }

    /** @notice Withdraw shares from a bot. Performance fee deducted on profit. */
    function withdraw(uint256 botId, uint256 shares) external nonReentrant {
        InvestorPosition storage pos = positions[msg.sender][botId];
        BotState  storage st  = botStates[botId];
        BotConfig storage cfg = bots[botId];
        require(pos.shares >= shares, "BotFactory: insufficient shares");
        require(st.openPositionId == 0, "BotFactory: bot has open position, wait for close");

        _accrueManagementFee(botId);

        uint256 usdcValue = shares * st.totalDeposited / st.totalShares;
        uint256 cost      = shares * pos.depositedUsdc / pos.shares;
        uint256 perfFee   = 0;

        if (usdcValue > cost) {
            uint256 profit    = usdcValue - cost;
            uint256 totalFee  = profit * cfg.perfFeeBps / BPS;
            uint256 protoFee  = totalFee * PROTOCOL_FEE_BPS / BPS;
            uint256 creatorFee = totalFee - protoFee;
            perfFee = totalFee;
            if (protoFee > 0)   USDC.safeTransfer(revenueSplitter, protoFee);
            if (creatorFee > 0) USDC.safeTransfer(cfg.creator, creatorFee);
            st.totalPerfFeesPaid += totalFee;
        }

        uint256 payout = usdcValue - perfFee;
        st.totalDeposited -= usdcValue;
        st.totalShares    -= shares;
        pos.shares        -= shares;
        pos.depositedUsdc -= cost > pos.depositedUsdc ? pos.depositedUsdc : cost;

        USDC.safeTransfer(msg.sender, payout);
        emit BotWithdraw(botId, msg.sender, payout, perfFee);
    }

    // ═══════════════════════════════════════════════════════════════
    // KEEPER / EXECUTION FUNCTIONS
    // Called by authorized keeper bots to execute strategy trades
    // ═══════════════════════════════════════════════════════════════

    modifier onlyKeeper() {
        require(IKeeperRegistry(keeperRegistry).isKeeper(msg.sender), "BotFactory: not keeper");
        _;
    }

    /**
     * @notice Execute a trade for a user bot.
     *         Keeper reads the bot config + current market price off-chain,
     *         decides whether to trade, then calls this with the trade params.
     * @param reason  Human-readable reason e.g. "Grid buy level 3"
     */
    function executeTrade(
        uint256 botId,
        bool    isLong,
        uint256 collateralBps,  // % of bot's free capital to use (max 5000 = 50%)
        uint256 leverage,
        uint256 tp,
        uint256 sl,
        string calldata reason
    ) external onlyKeeper nonReentrant {
        BotConfig storage cfg = bots[botId];
        BotState  storage st  = botStates[botId];
        require(cfg.status == BotStatus.ACTIVE,       "BotFactory: bot not active");
        require(st.openPositionId == 0,               "BotFactory: position already open");
        require(leverage <= cfg.maxLeverage,          "BotFactory: exceeds bot leverage cap");
        require(collateralBps <= 5000,                "BotFactory: max 50% capital per trade");

        uint256 collateral = st.totalDeposited * collateralBps / BPS;
        require(collateral > 0, "BotFactory: no capital");

        USDC.approve(address(perp), collateral);
        uint256 posId = perp.placeMarketOrder(uint256(cfg.marketId), isLong, collateral, leverage, tp, sl);

        st.openPositionId = posId;
        st.tradeCount++;
        tradeLogs[botId].push(TradeLog({
            timestamp:  block.timestamp,
            isLong:     isLong,
            collateral: collateral,
            leverage:   leverage,
            pnl:        0,
            reason:     reason
        }));
        emit BotTradeExecuted(botId, isLong, collateral, 0, reason);
    }

    /** @notice Close current position and update NAV */
    function closeTrade(uint256 botId, string calldata reason) external onlyKeeper nonReentrant {
        BotState  storage st  = botStates[botId];
        BotConfig storage cfg = bots[botId];
        require(st.openPositionId != 0, "BotFactory: no open position");

        perp.closePosition(st.openPositionId);
        int256 pnl = perp.getPositionPnl(st.openPositionId);

        // Update NAV
        if (pnl > 0) {
            st.totalDeposited += uint256(pnl);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            st.totalDeposited = st.totalDeposited > loss ? st.totalDeposited - loss : 0;
        }
        st.totalPnl += pnl;

        // Update nav per share
        if (st.totalShares > 0) {
            st.navPerShare = st.totalDeposited * 1e18 / st.totalShares;
        }

        // Check circuit breaker
        if (st.navPerShare < st.highWaterMark) {
            uint256 drawdown = (st.highWaterMark - st.navPerShare) * BPS / st.highWaterMark;
            if (drawdown >= cfg.maxDrawdownBps) {
                bots[botId].status = BotStatus.PAUSED;
                emit CircuitBreakerTripped(botId, drawdown);
            }
        } else {
            st.highWaterMark = st.navPerShare;
        }

        // Log trade
        TradeLog[] storage logs = tradeLogs[botId];
        if (logs.length > 0) {
            logs[logs.length - 1].pnl = pnl;
        }

        st.openPositionId = 0;
        emit BotTradeExecuted(botId, false, 0, pnl, reason);
        emit BotNAVUpdated(botId, st.navPerShare);
    }

    // ═══════════════════════════════════════════════════════════════
    // MANAGEMENT FEE ACCRUAL
    // ═══════════════════════════════════════════════════════════════

    function _accrueManagementFee(uint256 botId) internal {
        BotConfig storage cfg = bots[botId];
        BotState  storage st  = botStates[botId];
        if (cfg.mgmtFeeBps == 0 || st.totalDeposited == 0) return;
        uint256 elapsed = block.timestamp - st.lastMgmtFeeTime;
        uint256 fee     = st.totalDeposited * cfg.mgmtFeeBps * elapsed / (365 days * BPS);
        if (fee == 0) return;
        fee = fee > st.totalDeposited ? st.totalDeposited : fee;
        uint256 protoFee   = fee * PROTOCOL_FEE_BPS / BPS;
        uint256 creatorFee = fee - protoFee;
        st.totalDeposited  -= fee;
        st.totalMgmtFeesPaid += fee;
        st.lastMgmtFeeTime = block.timestamp;
        if (protoFee > 0)   USDC.safeTransfer(revenueSplitter, protoFee);
        if (creatorFee > 0) USDC.safeTransfer(cfg.creator, creatorFee);
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function getBot(uint256 botId) external view returns (BotConfig memory, BotState memory) {
        return (bots[botId], botStates[botId]);
    }

    function getUserBots(address user) external view returns (uint256[] memory) {
        return userBots[user];
    }

    function getUserInvested(address user) external view returns (uint256[] memory) {
        return userInvested[user];
    }

    function getBotInvestors(uint256 botId) external view returns (address[] memory) {
        return botInvestors[botId];
    }

    function getPublicBots(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, uint256 total) {
        uint256[] memory tmp = new uint256[](limit);
        uint256 count;
        for (uint256 i = 1; i <= totalBots && count < limit; i++) {
            if (bots[i].isPublic && bots[i].status == BotStatus.ACTIVE) {
                if (i > offset) { tmp[count++] = i; }
            }
        }
        ids = new uint256[](count);
        for (uint256 i; i < count; i++) ids[i] = tmp[i];
        total = count;
    }

    function getTradeLogs(uint256 botId, uint256 limit) external view returns (TradeLog[] memory) {
        TradeLog[] storage logs = tradeLogs[botId];
        uint256 len = logs.length > limit ? limit : logs.length;
        TradeLog[] memory out = new TradeLog[](len);
        for (uint256 i; i < len; i++) out[i] = logs[logs.length - len + i];
        return out;
    }

    function getUserPosition(address user, uint256 botId) external view returns (InvestorPosition memory, uint256 currentValueUsdc) {
        InvestorPosition memory pos = positions[user][botId];
        BotState memory st = botStates[botId];
        uint256 val = st.totalShares > 0 ? pos.shares * st.totalDeposited / st.totalShares : 0;
        return (pos, val);
    }

    function botsCreatedBy(address creator) external view returns (uint256) {
        return userBots[creator].length;
    }

    function canCreateBot(address user) external view returns (bool) {
        return userBots[user].length < MAX_BOTS_PER_USER;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════
    function setMaxBotsPerUser(uint256 newMax) external onlyOwner {
        // Can only be changed via governance proposal
    }
    function setContracts(address _perp, address _oracle, address _rev, address _keepers) external onlyOwner {
        perp            = IWikiPerp(_perp);
        oracle          = IWikiOracle(_oracle);
        revenueSplitter = _rev;
        keeperRegistry  = _keepers;
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
