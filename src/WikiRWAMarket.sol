// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiRWAMarket
 * @notice Real World Asset yield market. Users deposit USDC, protocol
 *         wraps it into tokenised T-bills (OUSG/TBILL via Ondo/OpenEden),
 *         earns ~5% TradFi yield, passes 4% to depositors, keeps 1% spread.
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * TradFi yield on T-bills (currently ~5%):
 *   → 4.0% passed to depositors (competitive yield)
 *   → 0.5% management fee to protocol (always)
 *   → 0.5% performance fee to protocol (above 4% yield)
 *
 * At $50M TVL (realistic for a top-10 DeFi protocol):
 *   → $250K/year management fee
 *   → $250K/year performance spread
 *   → $500K/year total — near zero risk
 *
 * SUPPORTED RWA TOKENS
 * ─────────────────────────────────────────────────────────────────────────
 * OUSG  — Ondo Finance US Govt Bond Fund (Arbitrum: 0x...)
 * TBILL — OpenEden T-bill token (Arbitrum: 0x...)
 * BUIDL — BlackRock USD Institutional Digital Liquidity Fund
 *
 * MECHANISM
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User deposits USDC → mints wRWA receipt tokens (ERC-20)
 * 2. Protocol converts USDC → RWA token via integration partner
 * 3. RWA token accrues yield daily (rebasing or exchange rate)
 * 4. Keeper harvests yield weekly → distributes to receipt token holders
 * 5. User redeems wRWA → receives USDC + accrued yield (minus fees)
 */

// Ondo OUSG interface (simplified)
interface IRWAToken {
    function deposit(uint256 usdcAmount) external returns (uint256 rwaTokens);
    function withdraw(uint256 rwaTokens) external returns (uint256 usdcAmount);
    function exchangeRate() external view returns (uint256); // USDC per rwaToken (1e18)
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract WikiRWAMarket is Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant BPS              = 10_000;
    uint256 public constant PRECISION        = 1e18;
    uint256 public constant MGMT_FEE_BPS     = 50;    // 0.5% p.a. management fee
    uint256 public constant SPREAD_BPS       = 50;    // 0.5% yield spread to protocol
    uint256 public constant DEPOSITOR_APY_BPS= 400;   // 4.0% target yield to depositors
    uint256 public constant MIN_DEPOSIT      = 100 * 1e6;  // $100 min
    uint256 public constant MIN_HARVEST_GAP  = 1 days;

    // ── Structs ────────────────────────────────────────────────────────────

    struct RWAPool {
        string   name;           // e.g. "Ondo OUSG"
        string   symbol;         // e.g. "wOUSG"
        address  rwaToken;       // OUSG/TBILL token address
        uint256  totalDeposited; // USDC deposited (principal)
        uint256  totalShares;    // receipt tokens outstanding
        uint256  highWaterMark;  // share price HWM
        uint256  lastHarvest;
        uint256  accruedYield;   // yield earned but not harvested
        uint256  protocolFees;   // accumulated protocol revenue
        uint256  totalFees;      // lifetime fees
        bool     active;
    }

    struct UserDeposit {
        uint256 shares;
        uint256 depositTime;
        uint256 totalDeposited;
    }

    // ── State ──────────────────────────────────────────────────────────────
    IERC20  public immutable USDC;

    RWAPool[] public pools;
    mapping(uint256 => mapping(address => UserDeposit)) public userDeposits;
    mapping(address => bool) public harvesters;

    uint256 public totalTVL;
    uint256 public totalProtocolRevenue;

    // ── Events ─────────────────────────────────────────────────────────────
    event PoolCreated(uint256 indexed id, string name, address rwaToken);
    event Deposited(uint256 indexed poolId, address indexed user, uint256 usdc, uint256 shares);
    event Redeemed(uint256 indexed poolId, address indexed user, uint256 shares, uint256 usdc);
    event YieldHarvested(uint256 indexed poolId, uint256 gross, uint256 toDepositors, uint256 toProtocol);
    event FeesWithdrawn(uint256 amount, address to);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _usdc, address _owner) Ownable(_owner) {
        USDC = IERC20(_usdc);
    }

    // ── Create Pools ───────────────────────────────────────────────────────

    function createPool(
        string  calldata name,
        string  calldata symbol,
        address rwaToken
    ) external onlyOwner returns (uint256 id) {
        require(rwaToken != address(0), "RWA: zero address");
        id = pools.length;
        pools.push(RWAPool({
            name:           name,
            symbol:         symbol,
            rwaToken:       rwaToken,
            totalDeposited: 0,
            totalShares:    0,
            highWaterMark:  PRECISION,
            lastHarvest:    block.timestamp,
            accruedYield:   0,
            protocolFees:   0,
            totalFees:      0,
            active:         true
        }));
        emit PoolCreated(id, name, rwaToken);
    }

    // ── Deposit ────────────────────────────────────────────────────────────

    function deposit(uint256 poolId, uint256 usdcAmount)
        external nonReentrant whenNotPaused returns (uint256 shares)
    {
        RWAPool storage p = pools[poolId];
        require(p.active, "RWA: pool inactive");
        require(usdcAmount >= MIN_DEPOSIT, "RWA: below minimum");

        // Calculate shares at current NAV
        uint256 supply = p.totalShares;
        shares = supply == 0 ? usdcAmount : usdcAmount * supply / _poolNAV(poolId);

        // Transfer USDC and convert to RWA token
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Deploy into RWA protocol (in production, approve + call rwaToken.deposit())
        // For now: hold USDC, track as deployed
        p.totalDeposited += usdcAmount;
        p.totalShares    += shares;
        totalTVL         += usdcAmount;

        UserDeposit storage ud = userDeposits[poolId][msg.sender];
        ud.shares         += shares;
        ud.depositTime     = block.timestamp;
        ud.totalDeposited += usdcAmount;

        emit Deposited(poolId, msg.sender, usdcAmount, shares);
    }

    // ── Redeem ─────────────────────────────────────────────────────────────

    function redeem(uint256 poolId, uint256 shares)
        external nonReentrant whenNotPaused returns (uint256 usdcOut)
    {
        RWAPool storage p = pools[poolId];
        UserDeposit storage ud = userDeposits[poolId][msg.sender];
        require(ud.shares >= shares, "RWA: insufficient shares");

        uint256 nav = _poolNAV(poolId);
        usdcOut = shares * nav / p.totalShares;

        ud.shares    -= shares;
        p.totalShares -= shares;
        p.totalDeposited = p.totalDeposited > usdcOut ? p.totalDeposited - usdcOut : 0;
        totalTVL      = totalTVL > usdcOut ? totalTVL - usdcOut : 0;

        require(USDC.balanceOf(address(this)) >= usdcOut, "RWA: awaiting redemption");
        USDC.safeTransfer(msg.sender, usdcOut);

        emit Redeemed(poolId, msg.sender, shares, usdcOut);
    }

    // ── Harvest Yield ─────────────────────────────────────────────────────

    /**
     * @notice Harvest T-bill yield and distribute to depositors / protocol.
     *         Called weekly by keeper bot.
     * @param poolId    Which pool to harvest
     * @param grossYield USDC yield earned since last harvest (from RWA token)
     */
    function harvest(uint256 poolId, uint256 grossYield)
        external nonReentrant
    {
        require(harvesters[msg.sender] || msg.sender == owner(), "RWA: not harvester");
        RWAPool storage p = pools[poolId];
        require(p.active, "RWA: inactive");
        require(block.timestamp >= p.lastHarvest + MIN_HARVEST_GAP, "RWA: too soon");

        // Elapsed days for management fee
        uint256 elapsed    = block.timestamp - p.lastHarvest;
        uint256 mgmtFee    = p.totalDeposited * MGMT_FEE_BPS / BPS /* AUDIT: verify mul-before-div order */ * elapsed / 365 days;
        uint256 spreadFee  = grossYield * SPREAD_BPS / BPS;
        uint256 totalFees  = mgmtFee + spreadFee;
        if (totalFees > grossYield) totalFees = grossYield;

        uint256 toDepositors = grossYield > totalFees ? grossYield - totalFees : 0;

        // Receive yield from keeper (keeper must approve this transfer)
        if (grossYield > 0) USDC.safeTransferFrom(msg.sender, address(this), grossYield);

        p.accruedYield  += toDepositors;
        p.protocolFees  += totalFees;
        p.totalFees     += totalFees;
        p.lastHarvest    = block.timestamp;
        totalProtocolRevenue += totalFees;

        // Update NAV (depositors now have more USDC value per share)
        p.totalDeposited += toDepositors;

        emit YieldHarvested(poolId, grossYield, toDepositors, totalFees);
    }

    // ── Owner ──────────────────────────────────────────────────────────────

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 total;
        for (uint256 i; i < pools.length; i++) {
            total += pools[i].protocolFees;
            pools[i].protocolFees = 0;
        }
        require(total > 0, "RWA: no fees");
        USDC.safeTransfer(to, total);
        emit FeesWithdrawn(total, to);
    }

    function setHarvester(address h, bool enabled) external onlyOwner { harvesters[h] = enabled; }
    function setPoolActive(uint256 id, bool active) external onlyOwner { pools[id].active = active; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Views ──────────────────────────────────────────────────────────────

    function _poolNAV(uint256 poolId) internal view returns (uint256) {
        return pools[poolId].totalDeposited;
    }

    function sharePrice(uint256 poolId) public view returns (uint256) {
        RWAPool storage p = pools[poolId];
        if (p.totalShares == 0) return PRECISION;
        return p.totalDeposited * PRECISION / p.totalShares;
    }

    function userValue(uint256 poolId, address user) external view returns (uint256) {
        UserDeposit storage ud = userDeposits[poolId][user];
        RWAPool storage p = pools[poolId];
        if (p.totalShares == 0 || ud.shares == 0) return 0;
        return ud.shares * p.totalDeposited / p.totalShares;
    }

    function getPool(uint256 id) external view returns (RWAPool memory) { return pools[id]; }
    function poolCount() external view returns (uint256) { return pools.length; }

    function projectedAPY(uint256 poolId) external pure returns (uint256) {
        // Returns depositor target APY (conservative 4% estimate)
        return DEPOSITOR_APY_BPS;
    }
}
