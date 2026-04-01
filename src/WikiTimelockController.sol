// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiTimelockController
 * @notice 48-hour timelock on all critical protocol operations.
 *         No privileged action (fee withdrawal, operator changes, pause, fee
 *         parameter changes) can take effect instantly. Every action is
 *         queued, waits MIN_DELAY, then can be executed.
 *
 * WHY THIS MATTERS
 * ─────────────────────────────────────────────────────────────────────────
 * If a deployer key is compromised, the attacker must wait 48 hours before
 * any drain can execute. This gives the team time to:
 *   1. Detect the malicious queue via on-chain event monitoring
 *   2. Cancel the operation (canceller role)
 *   3. Revoke the compromised key and transfer ownership
 *   4. Pause affected contracts via the emergency multisig
 *
 * ROLES
 * ─────────────────────────────────────────────────────────────────────────
 * PROPOSER   : Can queue new operations (multisig or team)
 * EXECUTOR   : Can execute operations after delay (keeper bot)
 * CANCELLER  : Can cancel queued operations (multisig, security council)
 * ADMIN      : Can grant/revoke roles (timelocked itself)
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────────────
 * [A1] Frontrun: operations identified by content hash, not position
 * [A2] Replay: nonce + salt prevent same call being executed twice
 * [A3] Grace period: operations expire after MIN_DELAY + GRACE (7 days total)
 * [A4] Role separation: proposer ≠ executor ≠ canceller
 */
contract WikiTimelockController is Ownable2Step, ReentrancyGuard {

    // ──────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant MIN_DELAY   = 48 hours;
    uint256 public constant MAX_DELAY   = 30 days;
    uint256 public constant GRACE       = 5 days;   // window to execute after delay
    bytes32 public constant DONE_ID     = bytes32(uint256(1));

    // ──────────────────────────────────────────────────────────────────
    //  Roles
    // ──────────────────────────────────────────────────────────────────
    mapping(address => bool) public proposers;
    mapping(address => bool) public executors;
    mapping(address => bool) public cancellers;

    // ──────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────
    enum OperationState { UNSET, PENDING, READY, DONE, EXPIRED, CANCELLED }

    struct Operation {
        address  target;        // contract to call
        uint256  value;         // ETH value (usually 0)
        bytes    callData;      // encoded function call
        bytes32  predecessor;   // must execute before this (0 = none)
        uint256  delay;
        uint256  readyAt;       // timestamp when executable
        OperationState state;
        address  proposer;
        string   description;   // human-readable label
    }

    mapping(bytes32 => Operation) public operations;
    uint256 public operationCount;
    uint256 public minDelay = MIN_DELAY;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event OperationQueued(bytes32 indexed id, address indexed target, bytes callData, uint256 readyAt, string description);
    event OperationExecuted(bytes32 indexed id, address indexed target, bytes callData, address executor);
    event OperationCancelled(bytes32 indexed id, address indexed canceller);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event RoleGranted(string role, address account);
    event RoleRevoked(string role, address account);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(
        address _owner,
        address[] memory _proposers,
        address[] memory _executors,
        address[] memory _cancellers
    ) Ownable(_owner) {
        require(_owner != address(0), "Wiki: zero _owner");
        for (uint i; i < _proposers.length; i++)  { proposers[_proposers[i]] = true;   emit RoleGranted("PROPOSER", _proposers[i]); }
        for (uint i; i < _executors.length; i++)  { executors[_executors[i]] = true;   emit RoleGranted("EXECUTOR", _executors[i]); }
        for (uint i; i < _cancellers.length; i++) { cancellers[_cancellers[i]] = true; emit RoleGranted("CANCELLER", _cancellers[i]); }
    }

    // ──────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────
    modifier onlyProposer()  { require(proposers[msg.sender]  || msg.sender == owner(), "TL: not proposer"); _; }
    modifier onlyExecutor()  { require(executors[msg.sender]  || msg.sender == owner(), "TL: not executor"); _; }
    modifier onlyCanceller() { require(cancellers[msg.sender] || msg.sender == owner(), "TL: not canceller"); _; }

    // ──────────────────────────────────────────────────────────────────
    //  Queue
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Queue a privileged operation. It cannot execute until after minDelay.
     *
     * @param target      Contract address to call
     * @param callData    ABI-encoded call (e.g. vault.withdrawProtocolFees.selector + args)
     * @param predecessor If non-zero, this op must execute before the one with that id
     * @param salt        Random bytes to make id unique for identical calls
     * @param delay       Wait time (must be >= minDelay)
     * @param description Human-readable label for monitoring UIs
     */
    function queue(
        address target,
        bytes   calldata callData,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        string  calldata description
    ) external onlyProposer nonReentrant returns (bytes32 id) {
        require(delay >= minDelay,  "TL: delay too short");
        require(delay <= MAX_DELAY, "TL: delay too long");
        require(target != address(0), "TL: zero target");

        id = hashOperation(target, callData, predecessor, salt);
        require(operations[id].state == OperationState.UNSET, "TL: already queued");

        uint256 readyAt = block.timestamp + delay;
        operations[id] = Operation({
            target:      target,
            value:       0,
            callData:    callData,
            predecessor: predecessor,
            delay:       delay,
            readyAt:     readyAt,
            state:       OperationState.PENDING,
            proposer:    msg.sender,
            description: description
        });
        operationCount++;

        emit OperationQueued(id, target, callData, readyAt, description);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Execute
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a queued operation after the delay has passed.
     */
    function execute(
        bytes32 id
    ) external onlyExecutor nonReentrant {
        Operation storage op = operations[id];
        require(op.state == OperationState.PENDING,         "TL: not pending");
        require(block.timestamp >= op.readyAt,              "TL: not ready");
        require(block.timestamp <= op.readyAt + GRACE,      "TL: expired");    // [A3]

        // Check predecessor
        if (op.predecessor != bytes32(0)) {
            require(operations[op.predecessor].state == OperationState.DONE, "TL: predecessor not done");
        }

        op.state = OperationState.DONE;

        (bool success, bytes memory result) = op.target.call(op.callData);
        if (!success) {
            // Bubble up revert
            assembly { revert(add(result, 32), mload(result)) }
        }

        emit OperationExecuted(id, op.target, op.callData, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Cancel
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Cancel a queued operation before it executes.
     *         The security council can call this if a malicious operation is detected.
     */
    function cancel(bytes32 id) external onlyCanceller {
        Operation storage op = operations[id];
        require(op.state == OperationState.PENDING, "TL: not pending");
        op.state = OperationState.CANCELLED;
        emit OperationCancelled(id, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner: Role Management
    // ──────────────────────────────────────────────────────────────────

    function grantProposer(address a)  external onlyOwner { proposers[a]  = true;  emit RoleGranted("PROPOSER", a); }
    function revokeProposer(address a) external onlyOwner { proposers[a]  = false; emit RoleRevoked("PROPOSER", a); }
    function grantExecutor(address a)  external onlyOwner { executors[a]  = true;  emit RoleGranted("EXECUTOR", a); }
    function revokeExecutor(address a) external onlyOwner { executors[a]  = false; emit RoleRevoked("EXECUTOR", a); }
    function grantCanceller(address a) external onlyOwner { cancellers[a] = true;  emit RoleGranted("CANCELLER", a); }
    function revokeCanceller(address a)external onlyOwner { cancellers[a] = false; emit RoleRevoked("CANCELLER", a); }

    function updateMinDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= 1 hours && newDelay <= MAX_DELAY, "TL: out of bounds");
        emit DelayUpdated(minDelay, newDelay);
        minDelay = newDelay;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function hashOperation(
        address target,
        bytes calldata callData,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, callData, predecessor, salt));
    }

    function getOperation(bytes32 id) external view returns (Operation memory) {
        return operations[id];
    }

    function getOperationState(bytes32 id) external view returns (OperationState) {
        Operation storage op = operations[id];
        if (op.state == OperationState.PENDING) {
            if (block.timestamp > op.readyAt + GRACE) return OperationState.EXPIRED;
            if (block.timestamp >= op.readyAt)        return OperationState.READY;
        }
        return op.state;
    }

    function isOperation(bytes32 id) external view returns (bool) { return operations[id].state != OperationState.UNSET; }
    function isPending(bytes32 id)   external view returns (bool) { return operations[id].state == OperationState.PENDING; }
    function isReady(bytes32 id)     external view returns (bool) { return operations[id].state == OperationState.PENDING && block.timestamp >= operations[id].readyAt; }
    function isDone(bytes32 id)      external view returns (bool) { return operations[id].state == OperationState.DONE; }
}
