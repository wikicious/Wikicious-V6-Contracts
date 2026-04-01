// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * @title WikiTelegramGateway
 * @notice On-chain registry for Telegram bot sessions.
 *         Users link their Telegram account to their wallet once.
 *         Then trade directly from Telegram with /long /short /close commands.
 *
 * FLOW:
 *   1. User sends /start to @WikiciousBot on Telegram
 *   2. Bot generates a unique linkCode
 *   3. User calls linkTelegram(linkCode) from their wallet (one-time)
 *   4. Bot verifies on-chain that wallet is linked
 *   5. User can now trade: /long BTC 1000 10x
 *   6. Bot calls executeOrder() on-chain using the linked wallet
 *
 * SECURITY:
 *   Bot has a separate executor key (not the user's key)
 *   Bot can only execute orders, never withdraw funds
 *   User can unlink at any time → bot loses all access immediately
 *   Per-session limits: max order size, daily volume cap
 *
 * COMMANDS:
 *   /long BTC 1000 10x     → open $1,000 BTC long at 10×
 *   /short ETH 500 5x      → open $500 ETH short at 5×
 *   /close 1               → close position #1
 *   /balance               → show wallet balance
 *   /positions             → show all open positions
 *   /pnl                   → show P&L summary
 *   /leaderboard           → show top traders
 *   /alerts 65000          → set BTC price alert at $65,000
 */
contract WikiTelegramGateway is Ownable2Step, ReentrancyGuard {

    struct TelegramSession {
        address wallet;
        uint256 telegramUserId;  // Telegram user ID (hashed for privacy)
        uint256 linkedAt;
        uint256 maxOrderUsdc;    // per-order limit set by user
        uint256 dailyVolumeLimit;
        uint256 volumeToday;
        uint256 lastResetDay;
        bool    active;
        bool    canTrade;
        bool    tradingEnabled;  // user can pause bot access
    }

    struct PriceAlert {
        address wallet;
        uint256 marketId;
        uint256 targetPrice;
        bool    isAbove;     // alert when price goes above (true) or below (false)
        bool    triggered;
        bool    active;
    }

    mapping(address => TelegramSession) public sessions;          // wallet → session
    mapping(uint256 => address)         public telegramToWallet;  // telegramId → wallet
    mapping(bytes32 => bool)            public usedLinkCodes;     // prevent replay
    mapping(uint256 => PriceAlert)      public alerts;
    mapping(address => uint256[])       public userAlerts;

    address public botExecutor;   // Telegram bot's signing wallet
    uint256 public nextAlertId;

    event WalletLinked(address indexed wallet, uint256 telegramUserId);
    event WalletUnlinked(address indexed wallet);
    event OrderPlacedViaTelegram(address indexed wallet, uint256 marketId, bool isLong, uint256 size, uint256 leverage);
    event PriceAlertSet(uint256 alertId, address wallet, uint256 marketId, uint256 price, bool isAbove);
    event PriceAlertTriggered(uint256 alertId, address wallet, uint256 marketId, uint256 currentPrice);

    constructor(address _owner, address _botExecutor) Ownable(_owner) {
        botExecutor = _botExecutor;
    }

    // ── Link wallet to Telegram ───────────────────────────────────────────
    function linkTelegram(
        bytes32  linkCode,
        uint256  telegramUserId,
        uint256  maxOrderUsdc,
        uint256  dailyVolumeLimit
    ) external {
        require(!usedLinkCodes[linkCode],                "TG: code already used");
        require(sessions[msg.sender].wallet == address(0) || !sessions[msg.sender].active, "TG: already linked");
        require(telegramToWallet[telegramUserId] == address(0), "TG: Telegram ID already linked");

        usedLinkCodes[linkCode] = true;
        telegramToWallet[telegramUserId] = msg.sender;

        sessions[msg.sender] = TelegramSession({
            wallet:           msg.sender,
            telegramUserId:   telegramUserId,
            linkedAt:         block.timestamp,
            maxOrderUsdc:     maxOrderUsdc > 0 ? maxOrderUsdc : 10_000 * 1e6,  // default $10K
            dailyVolumeLimit: dailyVolumeLimit > 0 ? dailyVolumeLimit : 100_000 * 1e6, // default $100K
            volumeToday:      0,
            lastResetDay:     block.timestamp / 1 days,
            active:           true,
            canTrade:         true,
            tradingEnabled:   true
        });
        emit WalletLinked(msg.sender, telegramUserId);
    }

    function unlinkTelegram() external {
        TelegramSession storage s = sessions[msg.sender];
        require(s.active, "TG: not linked");
        delete telegramToWallet[s.telegramUserId];
        s.active       = false;
        s.tradingEnabled = false;
        emit WalletUnlinked(msg.sender);
    }

    function toggleTrading(bool enabled) external {
        require(sessions[msg.sender].active, "TG: not linked");
        sessions[msg.sender].tradingEnabled = enabled;
    }

    function updateLimits(uint256 maxOrder, uint256 dailyVol) external {
        require(sessions[msg.sender].active, "TG: not linked");
        sessions[msg.sender].maxOrderUsdc     = maxOrder;
        sessions[msg.sender].dailyVolumeLimit = dailyVol;
    }

    // ── Bot executor: validate and record orders ──────────────────────────
    function validateTelegramOrder(
        address wallet,
        uint256 orderSize
    ) external returns (bool valid, string memory reason) {
        require(msg.sender == botExecutor || msg.sender == owner(), "TG: not bot");
        TelegramSession storage s = sessions[wallet];

        if (!s.active)          return (false, "TG: wallet not linked");
        if (!s.tradingEnabled)  return (false, "TG: trading paused by user");
        if (orderSize > s.maxOrderUsdc) return (false, "TG: exceeds per-order limit");

        // Reset daily volume
        uint256 today = block.timestamp / 1 days;
        if (today > s.lastResetDay) { s.volumeToday = 0; s.lastResetDay = today; }

        if (s.volumeToday + orderSize > s.dailyVolumeLimit) return (false, "TG: daily limit hit");

        s.volumeToday += orderSize;
        return (true, "");
    }

    // ── Price alerts ──────────────────────────────────────────────────────
    function setAlert(uint256 marketId, uint256 targetPrice, bool isAbove) external returns (uint256 alertId) {
        require(sessions[msg.sender].active, "TG: not linked");
        alertId = nextAlertId++;
        alerts[alertId] = PriceAlert({
            wallet:       msg.sender,
            marketId:     marketId,
            targetPrice:  targetPrice,
            isAbove:      isAbove,
            triggered:    false,
            active:       true
        });
        userAlerts[msg.sender].push(alertId);
        emit PriceAlertSet(alertId, msg.sender, marketId, targetPrice, isAbove);
    }

    function triggerAlert(uint256 alertId, uint256 currentPrice) external {
        require(msg.sender == botExecutor || msg.sender == owner(), "TG: not bot");
        PriceAlert storage a = alerts[alertId];
        require(a.active && !a.triggered, "TG: already triggered");
        a.triggered = true;
        a.active    = false;
        emit PriceAlertTriggered(alertId, a.wallet, a.marketId, currentPrice);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getSession(address wallet) external view returns (TelegramSession memory) {
        return sessions[wallet];
    }

    function getWalletByTelegram(uint256 telegramUserId) external view returns (address) {
        return telegramToWallet[telegramUserId];
    }

    function isLinked(address wallet) external view returns (bool) {
        return sessions[wallet].active;
    }

    function setBotExecutor(address bot) external onlyOwner { botExecutor = bot; }
}
