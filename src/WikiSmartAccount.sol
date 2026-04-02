// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title WikiSmartAccount — ERC-4337 Smart Account (Account Abstraction Wallet)
 *
 * Each user deploys one WikiSmartAccount as their on-chain wallet.
 * Features:
 *   • Gasless trading (gas paid via WikiPaymaster in any token)
 *   • Session keys — delegate trading rights to a bot/hot wallet
 *   • Batch transactions — open position + set TP/SL in one UserOperation
 *   • Social recovery — recover via guardian signatures
 *   • Spending limits — protect against front-running / overspend
 *
 * ERC-4337 EntryPoint on Arbitrum: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
 */

interface IEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
}

struct PackedUserOperation {
    address sender; uint256 nonce; bytes initCode; bytes callData;
    bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees;
    bytes paymasterAndData; bytes signature;
}

contract WikiSmartAccount is ReentrancyGuard {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ERC-4337 EntryPoint (Arbitrum mainnet)
    address public constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    address public owner;
    address public pendingOwner;
    uint256 public nonce;

    // Session Keys — allow bots/algos to trade on behalf of user
    struct SessionKey {
        address key;
        uint256 expiresAt;
        uint256 maxSpendPerTx; // USDC 6dec
        uint256 totalSpent;
        uint256 maxTotalSpend;
        bool    active;
    }

    mapping(address => SessionKey) public sessionKeys;
    address[] public guardians;       // for social recovery
    uint256   public guardianThreshold;

    // Spending limits
    mapping(address => uint256) public tokenDailyLimit;
    mapping(address => mapping(uint256 => uint256)) public tokenDailySpent; // token → day → spent

    event SessionKeyAdded(address indexed key, uint256 expiresAt, uint256 maxSpend);
    event SessionKeyRevoked(address indexed key);
    event BatchExecuted(uint256 callCount);
    event GuardianAdded(address guardian);
    event OwnershipTransferred(address newOwner);

    modifier onlyOwnerOrEntry() {
        require(msg.sender == owner || msg.sender == ENTRY_POINT, "SA: not authorised");
        _;
    }

    modifier onlyAuthorised() {
        if (msg.sender == ENTRY_POINT) {
            // Validated via validateUserOp during execution
        } else {
            require(msg.sender == owner, "SA: not owner");
        }
        _;
    }

    constructor(address _owner, address[] memory _guardians, uint256 _threshold) {
        require(_owner != address(0), "Wiki: zero _owner");
        owner             = _owner;
        guardians         = _guardians;
        guardianThreshold = _threshold;
    }

    // ── ERC-4337 Interface ────────────────────────────────────────────────────

    /**
     * @notice Validate UserOperation. Called by EntryPoint before execution.
     * Accepts operations signed by owner OR active session keys.
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        require(msg.sender == ENTRY_POINT, "SA: not EntryPoint");

        // Pay missing funds to EntryPoint
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(ENTRY_POINT).call{value: missingAccountFunds}("");
            require(ok, "SA: fund transfer failed");
        }

        // Verify signature
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ethHash.recover(userOp.signature);

        if (signer == owner) return 0; // valid

        // Check session keys
        SessionKey storage sk = sessionKeys[signer];
        if (sk.active && sk.expiresAt > block.timestamp) {
            return 0; // valid session key
        }

        return 1; // invalid
    }

    // ── Execution ─────────────────────────────────────────────────────────────

    /**
     * @notice Execute a single call. Called by EntryPoint after validation.
     */
    function execute(address target, uint256 value, bytes calldata data) external onlyAuthorised nonReentrant {
        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) { assembly { revert(add(result, 32), mload(result)) } }
    }

    /**
     * @notice Execute multiple calls in one UserOperation (batch).
     * Example: openPosition + setTakeProfit + setStopLoss in one tx.
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata datas
    ) external onlyAuthorised nonReentrant {
        require(targets.length == values.length && values.length == datas.length, "SA: length mismatch");
        for (uint i; i < targets.length; i++) {
            (bool ok, bytes memory result) = targets[i].call{value: values[i]}(datas[i]);
            if (!ok) { assembly { revert(add(result, 32), mload(result)) } }
        }
        emit BatchExecuted(targets.length);
    }

    // ── Session Keys ──────────────────────────────────────────────────────────

    function addSessionKey(
        address key,
        uint256 durationSeconds,
        uint256 maxSpendPerTx,
        uint256 maxTotalSpend
    ) external {
        require(msg.sender == owner, "SA: not owner");
        sessionKeys[key] = SessionKey({
            key:           key,
            expiresAt:     block.timestamp + durationSeconds,
            maxSpendPerTx: maxSpendPerTx,
            totalSpent:    0,
            maxTotalSpend: maxTotalSpend,
            active:        true
        });
        emit SessionKeyAdded(key, block.timestamp + durationSeconds, maxTotalSpend);
    }

    function revokeSessionKey(address key) external {
        require(msg.sender == owner, "SA: not owner");
        sessionKeys[key].active = false;
        emit SessionKeyRevoked(key);
    }

    // ── Social Recovery ───────────────────────────────────────────────────────

    /**
     * @notice Recover ownership via guardian signatures.
     * Requires `guardianThreshold` valid guardian signatures.
     */
    function recoverOwnership(address newOwner, bytes[] calldata signatures) external {
        require(signatures.length >= guardianThreshold, "SA: not enough sigs");
        bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked("recover", newOwner, nonce++))
        );
        uint256 valid;
        for (uint i; i < signatures.length; i++) {
            address signer = msgHash.recover(signatures[i]);
            for (uint j; j < guardians.length; j++) {
                if (guardians[j] == signer) { valid++; break; }
            }
        }
        require(valid >= guardianThreshold, "SA: insufficient guardian approvals");
        owner = newOwner;
        emit OwnershipTransferred(newOwner);
    }

    // ── Spending Limits ───────────────────────────────────────────────────────

    function setDailyLimit(address token, uint256 amount) external {
        require(msg.sender == owner, "SA: not owner");
        tokenDailyLimit[token] = amount;
    }

    function _checkSpendingLimit(address token, uint256 amount) internal {
        uint256 day = block.timestamp / 1 days;
        uint256 limit = tokenDailyLimit[token];
        if (limit == 0) return;
        tokenDailySpent[token][day] += amount;
        require(tokenDailySpent[token][day] <= limit, "SA: daily limit exceeded");
    }

    // ── Token Management ──────────────────────────────────────────────────────

    function approveToken(address token, address spender, uint256 amount) external {
        require(msg.sender == owner || msg.sender == ENTRY_POINT, "SA: not authorised");
        IERC20(token).approve(spender, amount);
    }

    function withdrawToken(address token, address to, uint256 amount) external nonReentrant {
        require(msg.sender == owner, "SA: not owner");
        _checkSpendingLimit(token, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    function withdrawETH(address payable to, uint256 amount) external nonReentrant {
        require(msg.sender == owner, "SA: not owner");
        to.transfer(amount);
    }

    receive() external payable {}
    fallback() external payable {}

    // ERC-4337 compatible functions referenced by WikiPaymaster
    function addToken(address token) external {
        require(msg.sender == owner || msg.sender == factory, "SA: not authorised");
        acceptedPaymentTokens[token] = true;
    }

    function depositToEntryPoint(uint256 amount) external payable {
        require(msg.sender == owner, "SA: not owner");
        (bool ok,) = entryPointAddr.call{value: amount}(abi.encodeWithSignature("depositTo(address)", address(this)));
        require(ok, "SA: deposit failed");
    }

    mapping(address => bool) public acceptedPaymentTokens;
    address public factory;
    address public entryPointAddr;
    function setFactory(address f) external { if(factory == address(0)) factory = f; }
    function setEntryPoint(address ep) external { if(entryPointAddr == address(0)) entryPointAddr = ep; }

}
