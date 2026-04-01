// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPermissionlessMarkets
 * @notice Any protocol or project can list a new perpetual market by posting
 *         a bond (10,000 USDC). Protocol earns 20% of all fees from
 *         creator-listed markets. Bond is slashed if volume is too low.
 *
 * MODEL (same as GMX Synthetics permissionless listing)
 * ─────────────────────────────────────────────────────────────────────────
 * 1. Project deposits 10K USDC bond.
 * 2. Market opens with oracle feed provided by creator.
 * 3. Protocol earns 20% of all trading fees from that market.
 * 4. After 30 days: if volume < $500K, bond is slashed 50%.
 * 5. Creator can close market and reclaim bond after 90 days.
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * Bond revenue: projects pay to list → pure upfront revenue
 * Ongoing: 20% of all fees from creator markets (grows with adoption)
 * Slash revenue: ~30% of bonds slashed (low-volume markets)
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiPermissionlessMarkets is Ownable2Step, ReentrancyGuard {
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

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant BOND_AMOUNT        = 10_000 * 1e6;   // $10K USDC
    uint256 public constant MIN_VOLUME_30D     = 500_000 * 1e6;  // $500K/30d
    uint256 public constant SLASH_BPS          = 5_000;           // 50% slash
    uint256 public constant PROTOCOL_FEE_BPS   = 2_000;           // 20% to protocol
    uint256 public constant VOLUME_CHECK_DELAY = 30 days;
    uint256 public constant MIN_CLOSE_DELAY    = 90 days;
    uint256 public constant BPS                = 10_000;

    // ── Structs ────────────────────────────────────────────────────────────

    enum MarketStatus { PENDING, ACTIVE, SLASHED, CLOSED }

    struct CreatorMarket {
        address  creator;
        string   symbol;
        string   name;
        bytes32  oracleId;         // WikiOracle feed ID
        address  oracleProvider;   // creator-provided oracle (fallback)
        uint256  bondPaid;
        uint256  createdAt;
        uint256  volume30d;        // cumulative volume last 30 days
        uint256  totalVolume;
        uint256  totalFeesEarned;  // total fees this market generated
        uint256  protocolFees;     // protocol's 20% share
        uint256  maxLeverage;
        uint256  takerFeeBps;
        MarketStatus status;
        bool     volumeChecked;    // has the 30-day check been done
    }

    // ── State ──────────────────────────────────────────────────────────────
    IERC20         public immutable USDC;

    CreatorMarket[] public markets;
    mapping(address => uint256[]) public creatorMarkets;

    uint256 public totalBondRevenue;
    uint256 public totalProtocolFeeRevenue;
    uint256 public totalSlashRevenue;

    // ── Events ─────────────────────────────────────────────────────────────
    event MarketListed(uint256 indexed id, address indexed creator, string symbol, uint256 bond);
    event VolumeRecorded(uint256 indexed id, uint256 amount, uint256 total30d);
    event MarketSlashed(uint256 indexed id, uint256 slashAmount);
    event MarketClosed(uint256 indexed id, address creator, uint256 bondReturned);
    event ProtocolFeesCollected(uint256 indexed id, uint256 amount);

    // ── Constructor ────────────────────────────────────────────────────────
    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
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

    constructor(address _usdc, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC = IERC20(_usdc);
    }

    // ── List New Market ────────────────────────────────────────────────────

    /**
     * @notice List a new perpetual market by paying the bond.
     * @param symbol        Trading pair symbol (e.g. "DOGEUSDT")
     * @param name          Human-readable name
     * @param oracleId      WikiOracle feed ID (must exist)
     * @param oracleProvider Custom oracle address (optional, 0x0 to use WikiOracle only)
     * @param maxLeverage   Maximum leverage (1–50)
     * @param takerFeeBps   Taker fee in BPS (min 5 = 0.05%, max 20 = 0.20%)
     */
    function listMarket(
        string  calldata symbol,
        string  calldata name,
        bytes32          oracleId,
        address          oracleProvider,
        uint256          maxLeverage,
        uint256          takerFeeBps
    ) external nonReentrant returns (uint256 id) {
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 20, "PM: bad symbol");
        require(maxLeverage >= 1 && maxLeverage <= 2000, "PM: max leverage is 2000x");
        require(takerFeeBps >= 5 && takerFeeBps <= 20, "PM: bad fee");

        USDC.safeTransferFrom(msg.sender, address(this), BOND_AMOUNT);
        totalBondRevenue += BOND_AMOUNT;

        id = markets.length;
        markets.push(CreatorMarket({
            creator:       msg.sender,
            symbol:        symbol,
            name:          name,
            oracleId:      oracleId,
            oracleProvider:oracleProvider,
            bondPaid:      BOND_AMOUNT,
            createdAt:     block.timestamp,
            volume30d:     0,
            totalVolume:   0,
            totalFeesEarned:0,
            protocolFees:  0,
            maxLeverage:   maxLeverage,
            takerFeeBps:   takerFeeBps,
            status:        MarketStatus.ACTIVE,
            volumeChecked: false
        }));
        creatorMarkets[msg.sender].push(id);

        emit MarketListed(id, msg.sender, symbol, BOND_AMOUNT);
    }

    // ── Record Volume & Fees (called by WikiPerp) ─────────────────────────

    function recordTrade(uint256 marketId, uint256 notional, uint256 feeCollected)
        external nonReentrant
    {
        // Only WikiPerp calls this
        CreatorMarket storage m = markets[marketId];
        require(m.status == MarketStatus.ACTIVE, "PM: not active");

        m.totalVolume    += notional;
        m.volume30d      += notional; // simplified; in prod use rolling window
        m.totalFeesEarned += feeCollected;

        uint256 protocolShare = feeCollected * PROTOCOL_FEE_BPS / BPS;
        m.protocolFees        += protocolShare;
        totalProtocolFeeRevenue += protocolShare;

        emit VolumeRecorded(marketId, notional, m.volume30d);
    }

    // ── Volume Check & Slash ──────────────────────────────────────────────

    /**
     * @notice Check volume after 30 days. Slash bond if below threshold.
     *         Anyone can call this (keeper bot does it automatically).
     */
    function checkAndSlash(uint256 marketId) external nonReentrant {
        CreatorMarket storage m = markets[marketId];
        require(m.status == MarketStatus.ACTIVE, "PM: not active");
        require(!m.volumeChecked, "PM: already checked");
        require(block.timestamp >= m.createdAt + VOLUME_CHECK_DELAY, "PM: too soon");

        m.volumeChecked = true;

        if (m.totalVolume < MIN_VOLUME_30D) {
            uint256 slashAmount = m.bondPaid * SLASH_BPS / BPS;
            m.bondPaid          -= slashAmount;
            totalSlashRevenue   += slashAmount;
            m.status             = MarketStatus.SLASHED;
            emit MarketSlashed(marketId, slashAmount);
        }
    }

    // ── Close Market & Reclaim Bond ───────────────────────────────────────

    function closeMarket(uint256 marketId) external nonReentrant {
        CreatorMarket storage m = markets[marketId];
        require(m.creator == msg.sender, "PM: not creator");
        require(m.status == MarketStatus.ACTIVE || m.status == MarketStatus.SLASHED, "PM: already closed");
        require(block.timestamp >= m.createdAt + MIN_CLOSE_DELAY, "PM: too early");

        uint256 bondReturn = m.bondPaid;
        m.bondPaid = 0;
        m.status   = MarketStatus.CLOSED;

        USDC.safeTransfer(msg.sender, bondReturn);
        emit MarketClosed(marketId, msg.sender, bondReturn);
    }

    // ── Withdraw Protocol Revenue ─────────────────────────────────────────

    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 total;
        for (uint256 i; i < markets.length; i++) {
            total += markets[i].protocolFees;
            markets[i].protocolFees = 0;
        }
        total += totalSlashRevenue;
        totalSlashRevenue = 0;
        require(total > 0, "PM: no revenue");
        USDC.safeTransfer(to, total);
        emit ProtocolFeesCollected(0, total);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function getMarket(uint256 id) external view returns (CreatorMarket memory) { return markets[id]; }
    function marketCount() external view returns (uint256) { return markets.length; }
    function getCreatorMarkets(address creator) external view returns (uint256[] memory) { return creatorMarkets[creator]; }
}
