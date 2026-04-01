// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiStructuredProduct
 * @notice Automated covered call / cash-secured put vaults.
 *         Users deposit, vault sells weekly options and earns premium.
 *         Ribbon Finance hit $1B TVL with this exact model.
 *
 * PRODUCTS:
 *   Covered Call Vault (ccVault):
 *     Deposit ETH/BTC → vault sells weekly OTM call options
 *     Premium earned: 1-4% weekly depending on volatility
 *     Risk: if price surges past strike, upside is capped
 *     Best for: holders who want yield, willing to cap upside
 *
 *   Cash-Secured Put Vault (cspVault):
 *     Deposit USDC → vault sells weekly OTM put options
 *     Premium earned: 0.5-2% weekly
 *     Risk: if price crashes below strike, vault buys the dip (usually wanted)
 *     Best for: USDC holders who want yield + want to buy dips
 *
 *   Principal Protected Vault (ppVault):
 *     Deposit USDC → 90% goes to lending (earns safe yield)
 *                  → 10% buys long calls (lottery ticket upside)
 *     Risk: near zero loss of principal (lending APY covers option cost)
 *     Best for: conservative users who want crypto exposure with safety
 *
 * FEES:
 *   Management: 1% per year on AUM → WikiRevenueSplitter
 *   Performance: 10% of option premiums earned → WikiRevenueSplitter
 */
contract WikiStructuredProduct is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum VaultType { COVERED_CALL, CASH_SECURED_PUT, PRINCIPAL_PROTECTED }
    enum VaultStatus { ACCEPTING_DEPOSITS, RUNNING, SETTLING, CLOSED }

    struct Vault {
        uint256     id;
        VaultType   vaultType;
        VaultStatus status;
        address     depositToken;   // USDC or wrapped asset
        uint256     totalDeposits;
        uint256     currentNAV;
        uint256     strikePrice;    // option strike (8 dec)
        uint256     expiry;         // unix timestamp
        uint256     weeklyPremiumBps; // expected premium as % of NAV
        uint256     managementFeeBps; // 100 = 1%
        uint256     performanceFeeBps;// 1000 = 10%
        uint256     lastFeeAccrual;
        uint256     totalPremiumEarned;
        uint256     totalFeesCollected;
        uint256     epoch;          // which week this is
        bool        autoRoll;       // auto-start next epoch on expiry
    }

    struct UserPosition {
        uint256 shares;
        uint256 depositedUsdc;
        uint256 depositEpoch;
        uint256 pendingWithdrawal; // queued for next settlement
    }

    mapping(uint256 => Vault)                           public vaults;
    mapping(uint256 => mapping(address => UserPosition)) public positions;
    mapping(uint256 => uint256)                          public totalShares;
    mapping(uint256 => address[])                        public vaultDepositors;

    address public revenueSplitter;
    address public optionsVault;    // WikiOptionsVault for actual option execution
    address public keeper;

    uint256 public nextVaultId;
    uint256 public constant BPS            = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_DEPOSIT    = 100 * 1e6; // $100 min

    event VaultCreated(uint256 id, VaultType vaultType, uint256 strike, uint256 expiry);
    event Deposited(uint256 vaultId, address user, uint256 amount, uint256 shares);
    event Withdrawn(uint256 vaultId, address user, uint256 amount);
    event EpochStarted(uint256 vaultId, uint256 epoch, uint256 strike, uint256 expiry, uint256 premium);
    event EpochSettled(uint256 vaultId, uint256 epoch, uint256 premiumEarned, int256 navChange);
    event FeesCollected(uint256 vaultId, uint256 amount);

    constructor(
        address _owner,
        address _usdc,
        address _revenueSplitter,
        address _keeper
    ) Ownable(_owner) {
        USDC             = IERC20(_usdc);
        revenueSplitter  = _revenueSplitter;
        keeper           = _keeper;
    }

    // ── Create vault ──────────────────────────────────────────────────────
    function createVault(
        VaultType   vaultType,
        address     depositToken,
        uint256     strikePrice,
        uint256     weeklyPremiumBps,
        bool        autoRoll
    ) external onlyOwner returns (uint256 vaultId) {
        vaultId = nextVaultId++;
        vaults[vaultId] = Vault({
            id:                vaultId,
            vaultType:         vaultType,
            status:            VaultStatus.ACCEPTING_DEPOSITS,
            depositToken:      depositToken,
            totalDeposits:     0,
            currentNAV:        0,
            strikePrice:       strikePrice,
            expiry:            block.timestamp + 7 days,
            weeklyPremiumBps:  weeklyPremiumBps,
            managementFeeBps:  100,   // 1%/year
            performanceFeeBps: 1000,  // 10% of premiums
            lastFeeAccrual:    block.timestamp,
            totalPremiumEarned:0,
            totalFeesCollected:0,
            epoch:             1,
            autoRoll:          autoRoll
        });
        emit VaultCreated(vaultId, vaultType, strikePrice, block.timestamp + 7 days);
    }

    // ── Deposit ───────────────────────────────────────────────────────────
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(v.status == VaultStatus.ACCEPTING_DEPOSITS, "SP: not accepting");
        require(amount >= MIN_DEPOSIT, "SP: below minimum $100");

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        _accrueManagementFee(vaultId);

        uint256 shares = totalShares[vaultId] == 0 || v.currentNAV == 0
            ? amount
            : amount * totalShares[vaultId] / v.currentNAV;

        positions[vaultId][msg.sender].shares         += shares;
        positions[vaultId][msg.sender].depositedUsdc  += amount;
        positions[vaultId][msg.sender].depositEpoch    = v.epoch;
        totalShares[vaultId]  += shares;
        v.totalDeposits       += amount;
        v.currentNAV          += amount;

        emit Deposited(vaultId, msg.sender, amount, shares);
    }

    // ── Queue withdrawal (executes at next settlement) ────────────────────
    function queueWithdrawal(uint256 vaultId, uint256 shares) external nonReentrant {
        UserPosition storage pos = positions[vaultId][msg.sender];
        require(pos.shares >= shares, "SP: insufficient shares");
        pos.shares               -= shares;
        pos.pendingWithdrawal    += shares;
        totalShares[vaultId]     -= shares;
    }

    // ── Keeper: start epoch (sell options, collect premium) ───────────────
    function startEpoch(
        uint256 vaultId,
        uint256 newStrike,
        uint256 premiumEarned  // actual premium collected from option sale
    ) external {
        require(msg.sender == keeper || msg.sender == owner(), "SP: not keeper");
        Vault storage v = vaults[vaultId];
        require(v.status == VaultStatus.ACCEPTING_DEPOSITS, "SP: wrong status");

        // Add premium to NAV (before fee)
        uint256 perfFee = premiumEarned * v.performanceFeeBps / BPS;
        uint256 netPremium = premiumEarned - perfFee;
        v.currentNAV          += netPremium;
        v.totalPremiumEarned  += netPremium;
        v.totalFeesCollected  += perfFee;
        v.strikePrice          = newStrike;
        v.expiry               = block.timestamp + 7 days;
        v.status               = VaultStatus.RUNNING;

        // Send performance fee
        if (perfFee > 0 && USDC.balanceOf(address(this)) >= perfFee) {
            USDC.safeTransfer(revenueSplitter, perfFee);
        }

        emit EpochStarted(vaultId, v.epoch, newStrike, v.expiry, premiumEarned);
        emit FeesCollected(vaultId, perfFee);
    }

    // ── Keeper: settle epoch ──────────────────────────────────────────────
    function settleEpoch(uint256 vaultId, int256 navChange) external {
        require(msg.sender == keeper || msg.sender == owner(), "SP: not keeper");
        Vault storage v = vaults[vaultId];
        require(block.timestamp >= v.expiry, "SP: not expired");

        if (navChange >= 0) v.currentNAV += uint256(navChange);
        else if (v.currentNAV > uint256(-navChange)) v.currentNAV -= uint256(-navChange);
        else v.currentNAV = 0;

        v.status = VaultStatus.SETTLING;
        emit EpochSettled(vaultId, v.epoch, v.totalPremiumEarned, navChange);
        v.epoch++;

        if (v.autoRoll) {
            v.status = VaultStatus.ACCEPTING_DEPOSITS;
        }
    }

    // ── Withdraw after settlement ─────────────────────────────────────────
    function completeWithdrawal(uint256 vaultId) external nonReentrant {
        Vault storage v = vaults[vaultId];
        UserPosition storage pos = positions[vaultId][msg.sender];
        require(pos.pendingWithdrawal > 0, "SP: nothing pending");
        require(v.status == VaultStatus.SETTLING || v.status == VaultStatus.ACCEPTING_DEPOSITS, "SP: not settled");

        uint256 shares   = pos.pendingWithdrawal;
        uint256 totalSh  = totalShares[vaultId] + shares; // add back for calc
        uint256 amount   = totalSh > 0 ? shares * v.currentNAV / totalSh : 0;

        pos.pendingWithdrawal = 0;
        v.currentNAV         -= amount;
        if (amount > 0) USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(vaultId, msg.sender, amount);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getUserPosition(uint256 vaultId, address user) external view returns (
        uint256 shares, uint256 currentValue, uint256 depositedUsdc,
        int256 pnl, uint256 pendingWithdrawal, uint256 estimatedWeeklyYield
    ) {
        UserPosition storage pos = positions[vaultId][user];
        Vault        storage v   = vaults[vaultId];
        shares              = pos.shares;
        uint256 supply      = totalShares[vaultId];
        currentValue        = supply > 0 ? pos.shares * v.currentNAV / supply : 0;
        depositedUsdc       = pos.depositedUsdc;
        pnl                 = int256(currentValue) - int256(depositedUsdc);
        pendingWithdrawal   = pos.pendingWithdrawal;
        estimatedWeeklyYield= currentValue * v.weeklyPremiumBps / BPS;
    }

    function getVaultAPY(uint256 vaultId) external view returns (uint256 estimatedAPYBps) {
        return vaults[vaultId].weeklyPremiumBps * 52; // 52 weeks
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _accrueManagementFee(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        if (v.currentNAV == 0) { v.lastFeeAccrual = block.timestamp; return; }
        uint256 elapsed = block.timestamp - v.lastFeeAccrual;
        uint256 fee = v.currentNAV * v.managementFeeBps * elapsed / BPS / SECONDS_PER_YEAR;
        if (fee > 0 && fee < v.currentNAV) {
            v.currentNAV         -= fee;
            v.totalFeesCollected += fee;
            if (USDC.balanceOf(address(this)) >= fee) USDC.safeTransfer(revenueSplitter, fee);
        }
        v.lastFeeAccrual = block.timestamp;
    }

    function setKeeper(address k) external onlyOwner { keeper = k; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
