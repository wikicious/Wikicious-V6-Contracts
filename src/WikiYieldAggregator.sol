// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiYieldAggregator
 * @notice Single entry point for all yield strategies in Wikicious.
 *         Shows current APY for each option, routes deposits to best yield.
 *         Keeps user capital inside the protocol.
 *
 * STRATEGIES RANKED BY CURRENT APY:
 *   1. WikiBackstopVault      ~15-25% APY  (medium risk, 7-day exit)
 *   2. WikiDeltaNeutralVault  ~11-28% APY  (low risk, 7-day exit)
 *   3. WikiFundingArbVault    ~10-15% APY  (low risk, 1-3 day exit)
 *   4. WikiStructuredProduct  ~8-20% APY   (varies by vault)
 *   5. WikiLeveragedYield     ~5-15% APY   (medium risk)
 *   6. WikiLending            ~4-8% APY    (lowest risk, instant exit)
 *   7. WikiStaking (veWIK)    ~18% APY     (locked, best for WIK holders)
 *
 * AUTO-ROUTER:
 *   User calls depositBest(amount) → interface IYieldVault {
        function deposit(uint256 amount, uint256 minShares) external;
        function deposit(uint256 amount) external;
        function currentAPYBps() external view returns (uint256);
        function availableCapacity() external view returns (uint256);
        function totalAssets() external view returns (uint256);
        function balanceOf(address user) external view returns (uint256);
    }

contract finds highest APY strategy
 *   with available capacity and deposits there.
 *   User can also manually select by calling depositTo(strategyId, amount).
 */
contract WikiYieldAggregator is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;


    IERC20 public immutable USDC;

    struct Strategy {
        string  name;
        address vault;
        uint256 riskLevel;      // 1=lowest, 5=highest
        uint256 minDeposit;
        uint256 exitDelayDays;  // 0=instant, 7=seven day lock
        bool    active;
        uint256 cachedAPYBps;
        uint256 apyCacheTs;
    }

    Strategy[] public strategies;
    uint256 public constant APY_CACHE_TTL = 1 hours;

    event DepositRouted(address indexed user, uint256 strategyId, string name, uint256 amount, uint256 apyBps);
    event StrategyAdded(uint256 id, string name, address vault);

    constructor(address _owner, address _usdc) Ownable(_owner) {
        USDC = IERC20(_usdc);
    }

    // ── Add strategies ─────────────────────────────────────────────────────
    function addStrategy(string calldata name, address vault, uint256 risk, uint256 minDep, uint256 exitDays) external onlyOwner {
        strategies.push(Strategy({
            name: name, vault: vault, riskLevel: risk,
            minDeposit: minDep, exitDelayDays: exitDays,
            active: true, cachedAPYBps: 0, apyCacheTs: 0
        }));
        emit StrategyAdded(strategies.length - 1, name, vault);
    }

    // ── Deposit to best APY ────────────────────────────────────────────────
    function depositBest(uint256 amount, uint256 maxRisk) external nonReentrant {
        require(amount > 0, "YA: zero amount");
        uint256 bestId  = type(uint256).max;
        uint256 bestAPY = 0;

        for (uint i; i < strategies.length; i++) {
            Strategy storage s = strategies[i];
            if (!s.active) continue;
            if (s.riskLevel > maxRisk) continue;
            if (amount < s.minDeposit) continue;

            uint256 apy = _getAPY(i);
            if (apy > bestAPY) { bestAPY = apy; bestId = i; }
        }

        require(bestId != type(uint256).max, "YA: no suitable strategy");
        _depositTo(msg.sender, bestId, amount);
    }

    function depositTo(uint256 strategyId, uint256 amount) external nonReentrant {
        require(strategyId < strategies.length, "YA: invalid strategy");
        require(strategies[strategyId].active,  "YA: strategy inactive");
        require(amount >= strategies[strategyId].minDeposit, "YA: below minimum");
        _depositTo(msg.sender, strategyId, amount);
    }

    function _depositTo(address user, uint256 stratId, uint256 amount) internal {
        Strategy storage s = strategies[stratId];
        USDC.safeTransferFrom(user, address(this), amount);
        USDC.forceApprove(s.vault, amount);

        // Try each signature variant (different vaults have different interfaces)
        (bool ok,) = s.vault.call(abi.encodeWithSignature("deposit(uint256,uint256)", amount, 0));
        if (!ok) {
            (ok,) = s.vault.call(abi.encodeWithSignature("deposit(uint256)", amount));
        }
        require(ok, "YA: deposit failed");

        uint256 apy = _getAPY(stratId);
        emit DepositRouted(user, stratId, s.name, amount, apy);
    }

    // ── Dashboard — all strategies with live APY ───────────────────────────
    function getAllStrategies() external view returns (
        string[] memory names,
        uint256[] memory apyBps,
        uint256[] memory riskLevels,
        uint256[] memory exitDays,
        uint256[] memory minDeposits,
        bool[]    memory active
    ) {
        uint256 n = strategies.length;
        names      = new string[](n);
        apyBps     = new uint256[](n);
        riskLevels = new uint256[](n);
        exitDays   = new uint256[](n);
        minDeposits= new uint256[](n);
        active     = new bool[](n);

        for (uint i; i < n; i++) {
            Strategy storage s = strategies[i];
            names[i]      = s.name;
            apyBps[i]     = _getAPY(i);
            riskLevels[i] = s.riskLevel;
            exitDays[i]   = s.exitDelayDays;
            minDeposits[i]= s.minDeposit;
            active[i]     = s.active;
        }
    }

    function getBestAPY(uint256 maxRisk) external view returns (
        uint256 strategyId, string memory name, uint256 apyBps, uint256 exitDays
    ) {
        uint256 bestAPY = 0;
        for (uint i; i < strategies.length; i++) {
            Strategy storage s = strategies[i];
            if (!s.active || s.riskLevel > maxRisk) continue;
            uint256 apy = _getAPY(i);
            if (apy > bestAPY) {
                bestAPY    = apy;
                strategyId = i;
                name       = s.name;
                apyBps     = apy;
                exitDays   = s.exitDelayDays;
            }
        }
    }

    function _getAPY(uint256 stratId) internal view returns (uint256) {
        Strategy storage s = strategies[stratId];
        if (block.timestamp < s.apyCacheTs + APY_CACHE_TTL && s.cachedAPYBps > 0) {
            return s.cachedAPYBps;
        }
        try IYieldVault(s.vault).currentAPYBps() returns (uint256 apy) { return apy; }
        catch { return s.cachedAPYBps; }
    }

    function refreshAPYCache(uint256 stratId) external {
        Strategy storage s = strategies[stratId];
        try IYieldVault(s.vault).currentAPYBps() returns (uint256 apy) {
            s.cachedAPYBps = apy;
            s.apyCacheTs   = block.timestamp;
        } catch {}
    }

    function setStrategyActive(uint256 id, bool on) external onlyOwner { strategies[id].active = on; }
}
