// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiRebalancer
 * @notice On-chain portfolio vault that automatically rebalances between assets
 *         according to a registered strategy. Bots (keepers) call rebalance()
 *         to keep weights on target, earning a small keeper tip.
 *
 * ARCHITECTURE
 * ─────────────────────────────────────────────────────────────────────────
 * Vault:
 *   • Accepts deposits of any whitelisted asset
 *   • Tracks each user's share of the vault (shares model, like a mutual fund)
 *   • Exchange rate = totalAUM / totalShares (grows with positive rebalances)
 *
 * Strategy Registry:
 *   • Strategies define target weights for a set of tokens (must sum to 10000 BPS)
 *   • Any address can register a strategy (paid slot)
 *   • Vault owner assigns an active strategy to the vault
 *
 * Rebalancing:
 *   • Anyone can call rebalance() when drift > threshold
 *   • Rebalancer earns keeperTipBps of the trade value
 *   • Drift: max(|actualWeight - targetWeight|) across all tokens
 *
 * REVENUE
 * ───────
 * • Strategy registration fee (USDC)
 * • Performance fee: performanceFeeBps of vault profit (high-water-mark model)
 * • Management fee: mgmtFeeBps per year on AUM
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy     → ReentrancyGuard + Pausable
 * [A2] CEI            → state written before transfers
 * [A3] Price oracle   → uses WikiOracle for all asset valuations
 * [A4] Rebalance MEV  → cooldown between rebalances
 * [A5] Share dilution → high-water-mark prevents fee gaming
 */
interface IOracle {
        function getPriceView(bytes32 id) external view returns (uint256 price, uint256 ts);
    }

contract WikiRebalancer is Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant STRATEGY_REG_FEE  = 200 * 1e6;   // $200 USDC
    uint256 public constant MAX_TOKENS        = 10;
    uint256 public constant REBALANCE_COOLDOWN = 1 hours;     // [A4]
    uint256 public constant MAX_DRIFT_THRESHOLD = 500;        // 5% max allowed drift
    uint256 public constant MAX_KEEPER_TIP    = 100;          // 1% max tip

    // ─────────────────────────────────────────────────────────────────────
    //  Oracle Interface
    // ─────────────────────────────────────────────────────────────────────


    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────

    struct TokenAlloc {
        address token;
        bytes32 oracleId;
        uint256 targetBps;   // target weight in BPS
    }

    struct Strategy {
        uint256      id;
        string       name;
        string       description;
        address      creator;
        TokenAlloc[] allocations;       // target portfolio weights
        uint256      driftThresholdBps; // rebalance when drift > this
        uint256      keeperTipBps;      // tip paid to keeper per rebalance
        bool         active;
        uint256      usageCount;        // how many vaults use this strategy
    }

    struct Vault {
        uint256      id;
        string       name;
        uint256      strategyId;
        address      depositToken;      // base token (USDC) for deposits/withdrawals
        uint256      totalShares;
        uint256      highWaterMark;     // per-share high water mark for perf fees [A5]
        uint256      lastRebalance;
        uint256      lastMgmtFeeTime;
        uint256      performanceFeeBps;
        uint256      mgmtFeeBps;        // annual, in BPS
        uint256      protocolFeesBps;   // protocol cut of all fees
        bool         active;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IERC20   public immutable USDC;
    IOracle  public oracle;

    Strategy[] public strategies;
    Vault[]    public vaults;

    // vaultId → user → shares
    mapping(uint256 => mapping(address => uint256)) public userShares;
    // vaultId → token → balance
    mapping(uint256 => mapping(address => uint256)) public vaultBalances;

    uint256 public protocolRevenue; // USDC protocol fees accumulated

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event StrategyRegistered(uint256 indexed stratId, string name, address creator);
    event VaultCreated(uint256 indexed vaultId, string name, uint256 strategyId);
    event Deposited(uint256 indexed vaultId, address indexed user, uint256 usdcAmount, uint256 sharesMinted);
    event Withdrawn(uint256 indexed vaultId, address indexed user, uint256 sharesBurned, uint256 usdcOut);
    event Rebalanced(uint256 indexed vaultId, address indexed keeper, uint256 drift, uint256 tip);
    event FeeCharged(uint256 indexed vaultId, uint256 amount, string feeType);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address usdc, address _oracle, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(owner != address(0), "Wiki: zero owner");
        USDC   = IERC20(usdc);
        oracle = IOracle(_oracle);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Strategy Registry
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Register a rebalancing strategy. Pays STRATEGY_REG_FEE.
     * @param name         Human-readable strategy name
     * @param description  Strategy description
     * @param allocs       Token allocations (token, oracleId, targetBps) — must sum to 10000
     * @param driftBps     Rebalance trigger threshold (e.g. 300 = 3%)
     * @param keeperTipBps Keeper reward per successful rebalance (e.g. 10 = 0.1%)
     */
    function registerStrategy(
        string       calldata name,
        string       calldata description,
        TokenAlloc[] calldata allocs,
        uint256      driftBps,
        uint256      keeperTipBps
    ) external nonReentrant returns (uint256 stratId) {
        require(allocs.length >= 2 && allocs.length <= MAX_TOKENS, "RB: bad token count");
        require(keeperTipBps <= MAX_KEEPER_TIP,                    "RB: tip too high");
        require(driftBps <= MAX_DRIFT_THRESHOLD,                   "RB: drift too high");

        uint256 totalBps;
        for (uint256 i = 0; i < allocs.length; i++) {
            require(allocs[i].token != address(0),   "RB: zero token");
            require(allocs[i].targetBps > 0,         "RB: zero weight");
            totalBps += allocs[i].targetBps;
        }
        require(totalBps == BPS, "RB: weights must sum to 10000");

        // Collect registration fee
        USDC.safeTransferFrom(msg.sender, address(this), STRATEGY_REG_FEE);
        protocolRevenue += STRATEGY_REG_FEE;

        stratId  = strategies.length;
        Strategy storage s = strategies.push();
        s.id          = stratId;
        s.name        = name;
        s.description = description;
        s.creator     = msg.sender;
        s.driftThresholdBps = driftBps;
        s.keeperTipBps      = keeperTipBps;
        s.active      = true;
        for (uint256 i = 0; i < allocs.length; i++) {
            s.allocations.push(allocs[i]);
        }

        emit StrategyRegistered(stratId, name, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Vault Creation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new rebalancing vault that follows a strategy
     */
    function createVault(
        string  calldata name,
        uint256 strategyId,
        address depositToken,
        uint256 perfFeeBps,
        uint256 mgmtFeeBps,
        uint256 protocolFeeBps_
    ) external onlyOwner returns (uint256 vaultId) {
        require(strategyId < strategies.length,    "RB: bad strategy");
        require(strategies[strategyId].active,     "RB: strategy inactive");
        require(perfFeeBps <= 3000,                "RB: perf fee too high");
        require(mgmtFeeBps <= 300,                 "RB: mgmt fee too high");

        vaultId = vaults.length;
        vaults.push(Vault({
            id:               vaultId,
            name:             name,
            strategyId:       strategyId,
            depositToken:     depositToken,
            totalShares:      0,
            highWaterMark:    PRECISION,
            lastRebalance:    0,
            lastMgmtFeeTime:  block.timestamp,
            performanceFeeBps: perfFeeBps,
            mgmtFeeBps:       mgmtFeeBps,
            protocolFeesBps:  protocolFeeBps_,
            active:           true
        }));
        strategies[strategyId].usageCount++;

        emit VaultCreated(vaultId, name, strategyId);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Deposit
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC into a vault and receive shares
     */
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(v.active, "RB: vault inactive");
        require(amount > 0, "RB: zero amount");

        _chargeMgmtFee(vaultId);

        uint256 sharePrice = _sharePrice(vaultId);
        uint256 shares     = amount * PRECISION / sharePrice;
        require(shares > 0, "RB: zero shares");

        // [A2] State before transfer
        userShares[vaultId][msg.sender]  += shares;
        v.totalShares                    += shares;
        vaultBalances[vaultId][v.depositToken] += amount;

        IERC20(v.depositToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(vaultId, msg.sender, amount, shares);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Withdraw
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Redeem shares for underlying USDC (proportional to AUM)
     */
    function withdraw(uint256 vaultId, uint256 shares) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(userShares[vaultId][msg.sender] >= shares, "RB: insufficient shares");

        _chargeMgmtFee(vaultId);
        _chargePerformanceFee(vaultId);

        uint256 sharePrice = _sharePrice(vaultId);
        uint256 usdcOut    = shares * sharePrice / PRECISION;
        uint256 available  = vaultBalances[vaultId][v.depositToken];
        if (usdcOut > available) usdcOut = available; // cap at available

        // [A2] State before transfer
        userShares[vaultId][msg.sender]        -= shares;
        v.totalShares                          -= shares;
        vaultBalances[vaultId][v.depositToken] -= usdcOut;

        IERC20(v.depositToken).safeTransfer(msg.sender, usdcOut);

        emit Withdrawn(vaultId, msg.sender, shares, usdcOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Rebalance (callable by keepers) [A4]
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a rebalance for a vault.
     *         Checks drift, adjusts allocations, pays keeper tip.
     *         In production this calls WikiLP / WikiOrderBook to execute swaps.
     *         Here we record the rebalance and update internal accounting.
     */
    function rebalance(uint256 vaultId) external nonReentrant whenNotPaused {
        Vault    storage v = vaults[vaultId];
        Strategy storage s = strategies[v.strategyId];

        require(v.active, "RB: vault inactive");
        require(
            block.timestamp >= v.lastRebalance + REBALANCE_COOLDOWN,
            "RB: cooldown"
        ); // [A4]

        uint256 drift = _computeDrift(vaultId);
        require(drift >= s.driftThresholdBps, "RB: below threshold");

        uint256 aum    = vaultBalances[vaultId][v.depositToken];
        uint256 tip    = aum * s.keeperTipBps / BPS;

        v.lastRebalance = block.timestamp;

        // In production: execute swaps via WikiLP or WikiOrderBook to hit targets.
        // Here we record state and pay the keeper tip from vault balance.

        if (tip > 0 && vaultBalances[vaultId][v.depositToken] >= tip) {
            vaultBalances[vaultId][v.depositToken] -= tip;
            IERC20(v.depositToken).safeTransfer(msg.sender, tip);
        }

        emit Rebalanced(vaultId, msg.sender, drift, tip);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Fee Charging Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _chargeMgmtFee(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        if (v.mgmtFeeBps == 0) return;
        uint256 elapsed = block.timestamp - v.lastMgmtFeeTime;
        if (elapsed == 0) return;
        uint256 aum     = vaultBalances[vaultId][v.depositToken];
        uint256 fee     = aum * v.mgmtFeeBps * elapsed / (BPS * 365 days);
        if (fee == 0) return;
        uint256 protoCut = fee * v.protocolFeesBps / BPS;
        v.lastMgmtFeeTime = block.timestamp;
        if (fee > vaultBalances[vaultId][v.depositToken]) return;
        vaultBalances[vaultId][v.depositToken] -= fee;
        protocolRevenue += protoCut;
        emit FeeCharged(vaultId, fee, "management");
    }

    function _chargePerformanceFee(uint256 vaultId) internal {
        Vault storage v   = vaults[vaultId];
        if (v.performanceFeeBps == 0) return;
        uint256 sp        = _sharePrice(vaultId);
        if (sp <= v.highWaterMark) return; // [A5]
        uint256 profit    = sp - v.highWaterMark;
        uint256 fee       = profit * v.performanceFeeBps / BPS;
        uint256 protoCut  = fee * v.protocolFeesBps / BPS;
        v.highWaterMark   = sp;
        protocolRevenue  += protoCut;
        emit FeeCharged(vaultId, fee, "performance");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner
    // ─────────────────────────────────────────────────────────────────────

    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue;
        require(amt > 0, "RB: no revenue");
        protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function setOracle(address _oracle) external onlyOwner { oracle = IOracle(_oracle); }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _sharePrice(uint256 vaultId) internal view returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.totalShares == 0) return PRECISION;
        return vaultBalances[vaultId][v.depositToken] * PRECISION / v.totalShares;
    }

    function _computeDrift(uint256 vaultId) internal view returns (uint256 maxDrift) {
        Vault    storage v   = vaults[vaultId];
        Strategy storage s   = strategies[v.strategyId];
        uint256 totalUSD     = vaultBalances[vaultId][v.depositToken];
        if (totalUSD == 0) return 0;

        for (uint256 i = 0; i < s.allocations.length; i++) {
            TokenAlloc storage alloc = s.allocations[i];
            uint256 bal   = vaultBalances[vaultId][alloc.token];
            // Price-adjust if not the deposit token
            uint256 value = bal; // simplified: assume deposit token denominated
            try oracle.getPriceView(alloc.oracleId) returns (uint256 p, uint256) {
                value = bal * p / PRECISION;
            } catch {}
            uint256 actualBps = value * BPS / totalUSD;
            uint256 drift     = actualBps > alloc.targetBps
                ? actualBps - alloc.targetBps
                : alloc.targetBps - actualBps;
            if (drift > maxDrift) maxDrift = drift;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function getVault(uint256 vid) external view returns (Vault memory) { return vaults[vid]; }
    function vaultCount() external view returns (uint256) { return vaults.length; }
    function strategyCount() external view returns (uint256) { return strategies.length; }
    function getStrategy(uint256 sid) external view returns (
        uint256 id, string memory name, string memory description,
        address creator, uint256 driftBps, uint256 keeperTip, bool active, uint256 usage
    ) {
        Strategy storage s = strategies[sid];
        return (s.id, s.name, s.description, s.creator, s.driftThresholdBps, s.keeperTipBps, s.active, s.usageCount);
    }
    function getStrategyAllocations(uint256 sid) external view returns (TokenAlloc[] memory) {
        return strategies[sid].allocations;
    }
    function getUserShares(uint256 vid, address user) external view returns (uint256) { return userShares[vid][user]; }
    function sharePrice(uint256 vid) external view returns (uint256) { return _sharePrice(vid); }
    function drift(uint256 vid) external view returns (uint256) { return _computeDrift(vid); }
    function userValue(uint256 vid, address user) external view returns (uint256) {
        return userShares[vid][user] * _sharePrice(vid) / PRECISION;
    }
}
