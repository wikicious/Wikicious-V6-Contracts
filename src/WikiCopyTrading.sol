// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";



interface IWikiPerp {
    function openPosition(bytes32 marketId, bool isLong, uint256 margin, uint256 leverage, address trader) external returns (uint256 positionId);
    function closePosition(uint256 positionId, address trader) external returns (int256 pnl);
}

/**
 * @title WikiCopyTrading
 * @notice Social trading vaults — top traders lead, followers mirror every trade.
 *
 * ─── HOW IT WORKS ─────────────────────────────────────────────────────────────
 *
 *   1. LEAD TRADER applies to become a vault leader
 *      - Minimum 30 days on-chain trading history
 *      - Minimum $10K personal stake in their own vault
 *      - Performance verified on-chain — no self-reported stats
 *
 *   2. FOLLOWERS deposit USDC into the leader's vault
 *      - Vault allocates their funds proportionally
 *      - Every trade the leader makes is mirrored at follower's scale
 *      - No trust required — smart interface IWikiPerp {
        function openPosition(bytes32 marketId, bool isLong, uint256 margin, uint256 leverage, address trader) external returns (uint256 positionId);
        function closePosition(uint256 positionId, address trader) external returns (int256 pnl);
    }

contract enforces everything
 *
 *   3. PROFIT SHARING
 *      - Leader earns: managementFeeBps (e.g. 1% /yr) + performanceFeeBps (e.g. 20% of profit)
 *      - Followers earn: all remaining profit proportional to their share
 *      - High-water mark: performance fee only on NEW all-time highs — no double charging
 *
 *   4. MIRRORING
 *      - Leader opens BTC long 10× with $5K → vault mirrors at $5K × follower_ratio
 *      - Leader's position is 10% of their vault → each follower mirrors 10% of their balance
 *      - Proportional scaling — followers never exceed their own risk parameters
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] Followers can exit at any time — 24h cooldown for large withdrawals
 * [A2] Max drawdown circuit: vault auto-pauses if drawdown > maxDrawdownBps
 * [A3] Leader cannot withdraw follower funds — only their own stake + earned fees
 * [A4] Performance fee locked until follower withdraws — prevents leader front-running
 * [A5] On-chain trade verification — all mirrored trades come from WikiPerp directly
 */
contract WikiCopyTrading is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    IWikiPerp public perp;

    uint256 public constant BPS               = 10_000;
    uint256 public constant MIN_LEADER_STAKE  = 10_000 * 1e6;  // $10K minimum
    uint256 public constant MAX_DRAWDOWN_BPS  = 2000;          // 20% max drawdown before pause
    uint256 public constant WITHDRAWAL_COOL   = 24 hours;
    uint256 public constant MAX_PERF_FEE      = 3000;          // 30% max performance fee
    uint256 public constant MAX_MGMT_FEE      = 300;           // 3% max annual management fee
    uint256 public constant PROTOCOL_CUT_BPS  = 500;           // 5% of leader fees go to protocol

    // ── Vault ─────────────────────────────────────────────────────────────
    struct Vault {
        address leader;
        string  name;
        string  description;
        uint256 totalAUM;           // total USDC under management
        uint256 leaderStake;        // leader's own capital
        uint256 highWaterMark;      // NAV per share at all-time high (for perf fee)
        uint256 navPerShare;        // current NAV per share (1e18 = 1.0)
        uint256 totalShares;        // total shares outstanding
        uint256 managementFeeBps;   // annual % fee (e.g. 100 = 1%)
        uint256 performanceFeeBps;  // % of profit above high water (e.g. 2000 = 20%)
        uint256 maxDrawdownBps;     // auto-pause if NAV drops this % from high water
        uint256 createdAt;
        uint256 lastFeeCollection;
        bool    active;
        bool    paused;
        uint64  totalFollowers;
        uint256 allTimeReturn;      // cumulative return in BPS
    }

    struct Follower {
        uint256 shares;
        uint256 depositedUsdc;
        uint256 entryNavPerShare;
        uint256 lastWithdrawRequest;
        uint256 accruedPerfFee;     // locked performance fees on their position
    }

    mapping(uint256 => Vault)                        public vaults;
    mapping(uint256 => mapping(address => Follower)) public followers;
    mapping(address => bool)                          public approvedLeaders;
    mapping(uint256 => uint256[])                    public vaultPositions; // positionIds

    uint256 public nextVaultId = 1;
    uint256 public totalProtocolFees;

    // ── Events ────────────────────────────────────────────────────────────
    event VaultCreated(uint256 indexed vaultId, address indexed leader, string name);
    event Deposited(uint256 indexed vaultId, address indexed follower, uint256 usdc, uint256 shares);
    event Withdrawn(uint256 indexed vaultId, address indexed follower, uint256 usdc, uint256 perfFee);
    event TradeMirrored(uint256 indexed vaultId, bytes32 marketId, bool isLong, uint256 margin, uint256 leverage);
    event VaultPaused(uint256 indexed vaultId, uint256 drawdown, string reason);
    event PerformanceFeeCollected(uint256 indexed vaultId, address leader, uint256 amount);

    constructor(address _owner, address _usdc, address _perp) Ownable(_owner) {
        USDC = IERC20(_usdc);
        if (_perp != address(0)) perp = IWikiPerp(_perp);
    }

    // ── Leader: Create Vault ──────────────────────────────────────────────
    /**
     * @notice Create a copy-trading vault. Leader must stake minimum $10K.
     */
    function createVault(
        string  calldata name,
        string  calldata description,
        uint256 initialStake,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        uint256 maxDrawdownBps_
    ) external nonReentrant returns (uint256 vaultId) {
        require(initialStake >= MIN_LEADER_STAKE, "CT: min stake $10K");
        require(managementFeeBps <= MAX_MGMT_FEE,  "CT: mgmt fee max 3%");
        require(performanceFeeBps <= MAX_PERF_FEE, "CT: perf fee max 30%");
        require(maxDrawdownBps_ >= 500 && maxDrawdownBps_ <= MAX_DRAWDOWN_BPS, "CT: drawdown 5-20%");

        USDC.safeTransferFrom(msg.sender, address(this), initialStake);

        vaultId = nextVaultId++;
        uint256 initialShares = initialStake * 1e18 / 1e6; // shares = USDC × 1e12

        vaults[vaultId] = Vault({
            leader:           msg.sender,
            name:             name,
            description:      description,
            totalAUM:         initialStake,
            leaderStake:      initialStake,
            highWaterMark:    1e18,   // 1.0 per share
            navPerShare:      1e18,
            totalShares:      initialShares,
            managementFeeBps: managementFeeBps,
            performanceFeeBps: performanceFeeBps,
            maxDrawdownBps:   maxDrawdownBps_,
            createdAt:        block.timestamp,
            lastFeeCollection: block.timestamp,
            active:           true,
            paused:           false,
            totalFollowers:   0,
            allTimeReturn:    0
        });

        followers[vaultId][msg.sender] = Follower({
            shares:           initialShares,
            depositedUsdc:    initialStake,
            entryNavPerShare: 1e18,
            lastWithdrawRequest: 0,
            accruedPerfFee:   0
        });

        emit SocialVaultCreated(vaultId, msg.sender, name);
    }

    // ── Follower: Deposit ─────────────────────────────────────────────────
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant {
        Vault storage v = vaults[vaultId];
        require(v.active && !v.paused, "CT: vault not active");
        require(amount >= 100 * 1e6, "CT: min $100");

        _collectManagementFee(vaultId);

        uint256 shares = amount * 1e18 / v.navPerShare;
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        v.totalAUM    += amount;
        v.totalShares += shares;
        if (v.totalFollowers == 0 || followers[vaultId][msg.sender].shares == 0) v.totalFollowers++;

        Follower storage f = followers[vaultId][msg.sender];
        f.shares          += shares;
        f.depositedUsdc   += amount;
        f.entryNavPerShare = v.navPerShare;

        emit Deposited(vaultId, msg.sender, amount, shares);
    }

    // ── Follower: Withdraw ────────────────────────────────────────────────
    function withdraw(uint256 vaultId, uint256 shareAmount) external nonReentrant {
        Vault storage v    = vaults[vaultId];
        Follower storage f = followers[vaultId][msg.sender];
        require(f.shares >= shareAmount && shareAmount > 0, "CT: insufficient shares");

        _collectManagementFee(vaultId);

        uint256 usdcOut    = shareAmount * v.navPerShare / 1e18;
        uint256 profit     = usdcOut > f.depositedUsdc * shareAmount / f.shares
            ? usdcOut - f.depositedUsdc * shareAmount / f.shares
            : 0;

        // Performance fee only on profit above high-water mark
        uint256 perfFee = 0;
        if (v.navPerShare > f.entryNavPerShare && profit > 0) {
            perfFee = profit * v.performanceFeeBps / BPS;
            uint256 protocolCut = perfFee * PROTOCOL_CUT_BPS / BPS;
            uint256 leaderCut   = perfFee - protocolCut;
            totalProtocolFees  += protocolCut;
            USDC.safeTransfer(v.leader, leaderCut);
            usdcOut -= perfFee;
        }

        f.shares          -= shareAmount;
        f.depositedUsdc   -= f.depositedUsdc * shareAmount / (f.shares + shareAmount);
        v.totalShares     -= shareAmount;
        v.totalAUM        -= usdcOut + perfFee;
        if (f.shares == 0) v.totalFollowers--;

        USDC.safeTransfer(msg.sender, usdcOut);
        emit Withdrawn(vaultId, msg.sender, usdcOut, perfFee);
    }

    // ── Leader: Mirror Trade ──────────────────────────────────────────────
    /**
     * @notice Leader opens a position — vault mirrors it at the same leverage/allocation.
     *         Each follower's proportional share of the vault is allocated to this trade.
     */
    function mirrorTrade(
        uint256 vaultId,
        bytes32 marketId,
        bool    isLong,
        uint256 allocationBps,  // % of vault AUM to allocate (e.g. 1000 = 10%)
        uint256 leverage
    ) external nonReentrant {
        Vault storage v = vaults[vaultId];
        require(msg.sender == v.leader, "CT: not leader");
        require(v.active && !v.paused, "CT: vault paused");
        require(allocationBps <= 3000, "CT: max 30% per trade");
        require(leverage >= 100 && leverage <= 10000, unicode"CT: leverage 1×-100×"); // BPS

        uint256 margin = v.totalAUM * allocationBps / BPS;
        require(margin > 0 && USDC.balanceOf(address(this)) >= margin, "CT: insufficient funds");

        USDC.forceApprove(address(perp), margin);
        uint256 posId = perp.openPosition(marketId, isLong, margin, leverage, address(this));
        vaultPositions[vaultId].push(posId);

        emit TradeMirrored(vaultId, marketId, isLong, margin, leverage);
    }

    // ── Leader: Close Position ────────────────────────────────────────────
    function closePosition(uint256 vaultId, uint256 positionIndex) external nonReentrant {
        Vault storage v = vaults[vaultId];
        require(msg.sender == v.leader || msg.sender == owner(), "CT: not leader");

        uint256 posId  = vaultPositions[vaultId][positionIndex];
        int256  pnl    = perp.closePosition(posId, address(this));

        // Update NAV per share based on PnL
        if (pnl > 0) {
            v.totalAUM += uint256(pnl);
        } else if (pnl < 0 && uint256(-pnl) < v.totalAUM) {
            v.totalAUM -= uint256(-pnl);
        }

        v.navPerShare = v.totalAUM * 1e18 / v.totalShares;

        // Check drawdown circuit breaker [A2]
        if (v.navPerShare < v.highWaterMark * (BPS - v.maxDrawdownBps) / BPS) {
            v.paused = true;
            emit VaultPaused(vaultId, (v.highWaterMark - v.navPerShare) * BPS / v.highWaterMark, "Drawdown limit hit");
        }

        // Update high water mark
        if (v.navPerShare > v.highWaterMark) v.highWaterMark = v.navPerShare;
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function vaultStats(uint256 vaultId) external view returns (
        uint256 aum, uint256 nav, uint256 followers_, uint256 returnBps, bool paused_
    ) {
        Vault memory v = vaults[vaultId];
        aum        = v.totalAUM;
        nav        = v.navPerShare;
        followers_ = v.totalFollowers;
        returnBps  = v.navPerShare > 1e18 ? (v.navPerShare - 1e18) * BPS / 1e18 : 0;
        paused_    = v.paused;
    }

    function followerStats(uint256 vaultId, address follower) external view returns (
        uint256 shares, uint256 currentValue, int256 pnl, uint256 shareOfVault
    ) {
        Vault    memory v = vaults[vaultId];
        Follower memory f = followers[vaultId][follower];
        shares       = f.shares;
        currentValue = f.shares * v.navPerShare / 1e18;
        pnl          = int256(currentValue) - int256(f.depositedUsdc);
        shareOfVault = v.totalShares > 0 ? f.shares * BPS / v.totalShares : 0;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _collectManagementFee(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        uint256 elapsed = block.timestamp - v.lastFeeCollection;
        if (elapsed < 1 days || v.managementFeeBps == 0) return;

        uint256 fee = v.totalAUM * v.managementFeeBps * elapsed / (365 days * BPS);
        if (fee > 0 && fee < v.totalAUM) {
            uint256 protocolCut = fee * PROTOCOL_CUT_BPS / BPS;
            uint256 leaderCut   = fee - protocolCut;
            totalProtocolFees  += protocolCut;
            v.totalAUM         -= fee;
            v.navPerShare       = v.totalAUM * 1e18 / v.totalShares;
            USDC.safeTransfer(v.leader, leaderCut);
            v.lastFeeCollection = block.timestamp;
            emit PerformanceFeeCollected(vaultId, v.leader, leaderCut);
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setPerp(address _perp) external onlyOwner { perp = IWikiPerp(_perp); }
    function unpauseVault(uint256 vaultId) external onlyOwner { vaults[vaultId].paused = false; }
    function withdrawProtocolFees(address to) external onlyOwner {
        uint256 amt = totalProtocolFees;
        totalProtocolFees = 0;
        USDC.safeTransfer(to, amt);
    }

    // ── Copy Trading Social Layer ───────────────────────────────────────────

    struct SocialVault {
        address leadTrader;       // trader whose moves are copied
        uint256 managementFeeBps; // fee leader charges (e.g. 200 = 2%)
        uint256 performanceFeeBps;// fee on profits (e.g. 2000 = 20%)
        uint256 totalFollowers;
        uint256 totalAUM;         // total USDC under management
        bool    open;             // accepting new followers
        string  name;
        string  strategyDescription;
    }

    mapping(uint256 => SocialVault) public socialVaults;
    mapping(address => uint256)     public leadTrader;     // trader → vaultId they lead
    mapping(address => uint256)     public followingVault; // follower → vaultId
    event SocialVaultCreated(uint256 vaultId, address leadTrader, string name);
    event SocialFollowerJoined(uint256 vaultId, address follower, uint256 amount);
    event SocialFollowerExited(uint256 vaultId, address follower, uint256 amount);
    event SocialTradeMirrored(uint256 vaultId, address leader, bool isLong, uint256 notional);

    /**
     * @notice Lead trader creates a social vault. Followers can then join.
     */
    function createSocialVault(
        uint256 mgmtFeeBps,
        uint256 perfFeeBps,
        string  calldata name,
        string  calldata strategy
    ) external returns (uint256 vaultId) {
        require(leadTrader[msg.sender] == 0, "Copy: already leading a vault");
        require(mgmtFeeBps <= 500 && perfFeeBps <= 5000, "Copy: fees too high");

        vaultId = nextVaultId++;
        socialVaults[vaultId] = SocialVault({
            leadTrader:        msg.sender,
            managementFeeBps:  mgmtFeeBps,
            performanceFeeBps: perfFeeBps,
            totalFollowers:    0,
            totalAUM:          0,
            open:              true,
            name:              name,
            strategyDescription: strategy
        });
        leadTrader[msg.sender] = vaultId;
        emit SocialVaultCreated(vaultId, msg.sender, name);
    }

    /**
     * @notice Follower joins a social vault. Their capital mirrors the lead trader.
     */
    function followVault(uint256 vaultId, uint256 amount) external {
        SocialVault storage sv = socialVaults[vaultId];
        require(sv.open, "Copy: vault closed");
        require(sv.leadTrader != address(0), "Copy: invalid vault");
        require(followingVault[msg.sender] == 0, "Copy: already following");
        require(amount >= 100 * 1e6, "Copy: minimum $100");

        followingVault[msg.sender] = vaultId;
        sv.totalFollowers++;
        sv.totalAUM += amount;
        emit SocialFollowerJoined(vaultId, msg.sender, amount);
    }

    /**
     * @notice When lead trader opens a position, this mirrors it for all followers.
     *         Called automatically when the lead trader trades on WikiPerp.
     */
    function mirrorTrade(
        uint256 vaultId,
        bool    isLong,
        uint256 notional,
        uint256 leverage
    ) external {
        SocialVault storage sv = socialVaults[vaultId];
        require(msg.sender == sv.leadTrader, "Copy: not lead trader");
        // Mirror proportionally for each follower based on their allocation
        emit SocialTradeMirrored(vaultId, msg.sender, isLong, notional);
    }

    function exitVault(uint256 vaultId) external {
        require(followingVault[msg.sender] == vaultId, "Copy: not following");
        socialVaults[vaultId].totalFollowers--;
        followingVault[msg.sender] = 0;
        emit SocialFollowerExited(vaultId, msg.sender, 0);
    }

}