// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title WikiTVLGuard — Protocol-wide TVL caps for staged rollout
 *
 * STAGED ROLLOUT SECURITY PATTERN
 * ─────────────────────────────────────────────────────────────────────────────
 * Limiting TVL during early protocol life dramatically reduces exploit impact.
 * A $500K TVL cap means a total exploit costs at most $500K — not $50M.
 *
 * Stages (governance upgrades cap as confidence builds):
 *   Stage 0 (launch):     $500K  — whitelist only, team testing
 *   Stage 1 (beta):       $5M    — invite-only, KOLs and partners
 *   Stage 2 (public):     $50M   — open to all, audit published
 *   Stage 3 (growth):     $500M  — post 6 months without incident
 *   Stage 4 (unlimited):  no cap — post 12 months with multiple audits
 *
 * Any contract that holds user funds imports this and calls _checkTVLCap()
 * before accepting deposits.
 *
 * The TVLGuard is controlled by the multisig — TVL cap increases require
 * 3-of-5 approval + 48h timelock.
 */
contract WikiTVLGuard is Ownable2Step {

    enum Stage { LAUNCH, BETA, PUBLIC, GROWTH, UNLIMITED }

    struct VaultCap {
        uint256 maxTVL;       // USDC 6dec — max total deposits allowed
        uint256 maxPerUser;   // USDC 6dec — max per single user
        uint256 maxPerTx;     // USDC 6dec — max single deposit
        bool    whitelistOnly;
        bool    active;
    }

    Stage   public currentStage;
    uint256 public globalTVL;         // total tracked across all vaults (USDC)
    uint256 public globalTVLCap;      // hard global cap

    mapping(address => VaultCap)    public vaultCaps;
    mapping(address => uint256)     public vaultTVL;
    mapping(address => bool)        public whitelisted;   // for Stage 0/1
    mapping(address => bool)        public registeredVaults;

    // Stage caps (USDC 6dec)
    uint256 public constant STAGE_LAUNCH_CAP   = 500_000   * 1e6;  // $500K
    uint256 public constant STAGE_BETA_CAP     = 5_000_000 * 1e6;  // $5M
    uint256 public constant STAGE_PUBLIC_CAP   = 50_000_000 * 1e6; // $50M
    uint256 public constant STAGE_GROWTH_CAP   = 500_000_000 * 1e6;// $500M
    uint256 public constant STAGE_UNLIMITED    = type(uint256).max;

    event StageAdvanced(Stage oldStage, Stage newStage, uint256 newCap);
    event VaultRegistered(address indexed vault, uint256 maxTVL, uint256 maxPerUser);
    event VaultTVLUpdated(address indexed vault, uint256 oldTVL, uint256 newTVL);
    event WhitelistUpdated(address indexed user, bool allowed);
    event DepositBlocked(address indexed vault, address indexed user, uint256 amount, string reason);

    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "TVLGuard: zero owner");
        currentStage  = Stage.LAUNCH;
        globalTVLCap  = STAGE_LAUNCH_CAP;
    }

    // ── Vault Registration ────────────────────────────────────────────────────

    function registerVault(
        address vault,
        uint256 maxTVL,
        uint256 maxPerUser,
        uint256 maxPerTx,
        bool    whitelistOnly
    ) external onlyOwner {
        require(vault != address(0), "TVLGuard: zero vault");
        vaultCaps[vault] = VaultCap({
            maxTVL:        maxTVL,
            maxPerUser:    maxPerUser,
            maxPerTx:      maxPerTx,
            whitelistOnly: whitelistOnly,
            active:        true
        });
        registeredVaults[vault] = true;
        emit VaultRegistered(vault, maxTVL, maxPerUser);
    }

    // ── Deposit Check (called by vault before accepting funds) ────────────────

    /**
     * @notice Check if a deposit is allowed. Reverts with reason if not.
     * @param user   Depositor address
     * @param amount Deposit amount in USDC 6dec
     * @param userCurrentBalance User's current balance in this vault
     */
    function checkDeposit(
        address user,
        uint256 amount,
        uint256 userCurrentBalance
    ) external {
        require(registeredVaults[msg.sender], "TVLGuard: vault not registered");
        VaultCap storage cap = vaultCaps[msg.sender];
        require(cap.active, "TVLGuard: vault inactive");

        // Whitelist check for early stages
        if (cap.whitelistOnly || currentStage == Stage.LAUNCH || currentStage == Stage.BETA) {
            if (!whitelisted[user]) {
                emit DepositBlocked(msg.sender, user, amount, "not whitelisted");
                revert("TVLGuard: not whitelisted");
            }
        }

        // Per-tx cap
        if (cap.maxPerTx > 0 && amount > cap.maxPerTx) {
            emit DepositBlocked(msg.sender, user, amount, "exceeds per-tx cap");
            revert("TVLGuard: exceeds per-tx cap");
        }

        // Per-user cap
        if (cap.maxPerUser > 0 && userCurrentBalance + amount > cap.maxPerUser) {
            emit DepositBlocked(msg.sender, user, amount, "exceeds per-user cap");
            revert("TVLGuard: exceeds per-user cap");
        }

        // Per-vault TVL cap
        if (cap.maxTVL > 0 && vaultTVL[msg.sender] + amount > cap.maxTVL) {
            emit DepositBlocked(msg.sender, user, amount, "vault TVL cap reached");
            revert("TVLGuard: vault TVL cap reached");
        }

        // Global TVL cap
        if (globalTVLCap > 0 && globalTVL + amount > globalTVLCap) {
            emit DepositBlocked(msg.sender, user, amount, "global TVL cap reached");
            revert("TVLGuard: global TVL cap reached");
        }
    }

    // ── TVL Tracking ──────────────────────────────────────────────────────────

    function recordDeposit(uint256 amount) external {
        require(registeredVaults[msg.sender], "TVLGuard: not registered");
        uint256 old = vaultTVL[msg.sender];
        vaultTVL[msg.sender] += amount;
        globalTVL            += amount;
        emit VaultTVLUpdated(msg.sender, old, vaultTVL[msg.sender]);
    }

    function recordWithdrawal(uint256 amount) external {
        require(registeredVaults[msg.sender], "TVLGuard: not registered");
        uint256 toSub = amount > vaultTVL[msg.sender] ? vaultTVL[msg.sender] : amount;
        uint256 old   = vaultTVL[msg.sender];
        vaultTVL[msg.sender] -= toSub;
        globalTVL             = globalTVL > toSub ? globalTVL - toSub : 0;
        emit VaultTVLUpdated(msg.sender, old, vaultTVL[msg.sender]);
    }

    // ── Stage Advancement (governance only) ───────────────────────────────────

    function advanceStage() external onlyOwner {
        require(uint8(currentStage) < uint8(Stage.UNLIMITED), "TVLGuard: already unlimited");
        Stage old = currentStage;
        currentStage = Stage(uint8(currentStage) + 1);
        globalTVLCap = _stageCap(currentStage);
        emit StageAdvanced(old, currentStage, globalTVLCap);
    }

    function setStageManual(Stage stage, uint256 customCap) external onlyOwner {
        Stage old = currentStage;
        currentStage = stage;
        globalTVLCap = customCap > 0 ? customCap : _stageCap(stage);
        emit StageAdvanced(old, stage, globalTVLCap);
    }

    // ── Whitelist Management ──────────────────────────────────────────────────

    function setWhitelisted(address user, bool allowed) external onlyOwner {
        whitelisted[user] = allowed;
        emit WhitelistUpdated(user, allowed);
    }

    function batchWhitelist(address[] calldata users, bool allowed) external onlyOwner {
        for (uint i; i < users.length; i++) {
            whitelisted[users[i]] = allowed;
            emit WhitelistUpdated(users[i], allowed);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function getStageInfo() external view returns (Stage stage, uint256 cap, uint256 current) {
        return (currentStage, globalTVLCap, globalTVL);
    }

    function getVaultInfo(address vault) external view returns (VaultCap memory cap, uint256 currentTVL) {
        return (vaultCaps[vault], vaultTVL[vault]);
    }

    function _stageCap(Stage s) internal pure returns (uint256) {
        if (s == Stage.LAUNCH)    return STAGE_LAUNCH_CAP;
        if (s == Stage.BETA)      return STAGE_BETA_CAP;
        if (s == Stage.PUBLIC)    return STAGE_PUBLIC_CAP;
        if (s == Stage.GROWTH)    return STAGE_GROWTH_CAP;
        return STAGE_UNLIMITED;
    }

    function setVaultCap(address vault, uint256 maxTVL) external onlyOwner {
        require(registeredVaults[vault], "TVLGuard: not registered");
        vaultCaps[vault].maxTVL = maxTVL;
    }
}
