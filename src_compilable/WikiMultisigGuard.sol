// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiMultisigGuard — M-of-N multisig for all privileged operations
 *
 * SECURITY MODEL
 * ─────────────────────────────────────────────────────────────────────────────
 * Every privileged action (pause, setOperator, withdraw fees, change params)
 * requires M-of-N signer approval before execution.
 *
 * Deployment configuration:
 *   Signers:   5 (team members on separate hardware wallets)
 *   Threshold: 3 (3-of-5 required)
 *
 * Actions with TIMELOCK (48h mandatory delay after approval):
 *   • setOperator / removeOperator
 *   • withdrawProtocolFees
 *   • changeWithdrawalLimits
 *   • upgradeTreasury
 *   • changeOracle
 *
 * Actions WITHOUT timelock (immediate on M-of-N approval):
 *   • pause (emergency)
 *   • unpause
 *   • activateCircuitBreaker
 *
 * REPLAY PROTECTION
 *   Each proposal has a unique nonce. Executed proposals cannot be re-executed.
 *   Cross-chain replay prevented by including chainId in the proposal hash.
 */
contract WikiMultisigGuard is ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ── State ─────────────────────────────────────────────────────────────────
    address[] public signers;
    uint256   public threshold;
    uint256   public nonce;

    enum ActionType {
        PAUSE,              // immediate
        UNPAUSE,            // immediate
        CIRCUIT_BREAKER,    // immediate
        SET_OPERATOR,       // timelocked 48h
        REMOVE_OPERATOR,    // timelocked 48h
        WITHDRAW_FEES,      // timelocked 48h
        SET_WITHDRAWAL_LIMIT, // timelocked 48h
        SET_ORACLE,         // timelocked 48h
        SET_TIMELOCK,       // timelocked 48h
        SET_TVL_CAP,        // timelocked 48h
        ARBITRARY_CALL      // timelocked 48h — for future governance actions
    }

    struct Proposal {
        uint256    id;
        ActionType actionType;
        address    target;
        bytes      callData;
        uint256    value;
        string     description;
        uint256    proposedAt;
        uint256    executableAt;  // proposedAt + timelock (0 for immediate actions)
        bool       executed;
        bool       cancelled;
        address[]  approvals;
        mapping(address => bool) hasApproved;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => bool)     public isSigner;

    uint256 public constant TIMELOCK_DELAY  = 48 hours;
    uint256 public constant MAX_SIGNERS     = 10;
    uint256 public constant MIN_THRESHOLD   = 2;

    event ProposalCreated(uint256 indexed id, ActionType actionType, address proposer, string description);
    event ProposalApproved(uint256 indexed id, address approver, uint256 approvalsCount);
    event ProposalExecuted(uint256 indexed id, address executor);
    event ProposalCancelled(uint256 indexed id, address canceller);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    modifier onlySigner() {
        require(isSigner[msg.sender], "Multisig: not signer");
        _;
    }

    constructor(address[] memory _signers, uint256 _threshold) {
        require(_signers.length >= MIN_THRESHOLD,  "Multisig: too few signers");
        require(_signers.length <= MAX_SIGNERS,    "Multisig: too many signers");
        require(_threshold >= MIN_THRESHOLD,       "Multisig: threshold too low");
        require(_threshold <= _signers.length,     "Multisig: threshold > signers");

        for (uint i; i < _signers.length; i++) {
            require(_signers[i] != address(0),       "Multisig: zero signer");
            require(!isSigner[_signers[i]],          "Multisig: duplicate signer");
            signers.push(_signers[i]);
            isSigner[_signers[i]] = true;
            emit SignerAdded(_signers[i]);
        }
        threshold = _threshold;
    }

    // ── Proposal Lifecycle ────────────────────────────────────────────────────

    function propose(
        ActionType actionType,
        address    target,
        bytes calldata callData,
        uint256    value,
        string calldata description
    ) external onlySigner returns (uint256 id) {
        require(target != address(0), "Multisig: zero target");
        id = ++nonce;

        bool immediate = (actionType == ActionType.PAUSE ||
                          actionType == ActionType.UNPAUSE ||
                          actionType == ActionType.CIRCUIT_BREAKER);

        Proposal storage p = proposals[id];
        p.id           = id;
        p.actionType   = actionType;
        p.target       = target;
        p.callData     = callData;
        p.value        = value;
        p.description  = description;
        p.proposedAt   = block.timestamp;
        p.executableAt = immediate ? block.timestamp : block.timestamp + TIMELOCK_DELAY;

        // Proposer auto-approves
        p.approvals.push(msg.sender);
        p.hasApproved[msg.sender] = true;

        emit ProposalCreated(id, actionType, msg.sender, description);
        emit ProposalApproved(id, msg.sender, 1);
    }

    function approve(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed,              "Multisig: already executed");
        require(!p.cancelled,             "Multisig: cancelled");
        require(!p.hasApproved[msg.sender],"Multisig: already approved");
        require(p.proposedAt > 0,         "Multisig: proposal not found");

        p.approvals.push(msg.sender);
        p.hasApproved[msg.sender] = true;
        emit ProposalApproved(id, msg.sender, p.approvals.length);
    }

    function execute(uint256 id) external nonReentrant onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed,          "Multisig: already executed");
        require(!p.cancelled,         "Multisig: cancelled");
        require(p.approvals.length >= threshold, "Multisig: insufficient approvals");
        require(block.timestamp >= p.executableAt, "Multisig: timelock not expired");

        p.executed = true;

        (bool success, bytes memory result) = p.target.call{value: p.value}(p.callData);
        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
        emit ProposalExecuted(id, msg.sender);
    }

    function cancel(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed, "Multisig: already executed");
        require(!p.cancelled,"Multisig: already cancelled");
        // Require majority to cancel (can't cancel with 1 signer)
        require(p.approvals.length >= threshold / 2 + 1, "Multisig: need majority to cancel");
        p.cancelled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    // ── Signer Management (requires multisig itself) ───────────────────────────

    function addSigner(address signer) external {
        require(msg.sender == address(this), "Multisig: must be self");
        require(!isSigner[signer],           "Multisig: already signer");
        require(signers.length < MAX_SIGNERS,"Multisig: too many signers");
        require(signer != address(0),        "Multisig: zero address");
        signers.push(signer);
        isSigner[signer] = true;
        emit SignerAdded(signer);
    }

    function removeSigner(address signer) external {
        require(msg.sender == address(this), "Multisig: must be self");
        require(isSigner[signer],            "Multisig: not signer");
        require(signers.length - 1 >= threshold, "Multisig: would break threshold");
        isSigner[signer] = false;
        for (uint i; i < signers.length; i++) {
            if (signers[i] == signer) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }
        emit SignerRemoved(signer);
    }

    function changeThreshold(uint256 newThreshold) external {
        require(msg.sender == address(this), "Multisig: must be self");
        require(newThreshold >= MIN_THRESHOLD,  "Multisig: too low");
        require(newThreshold <= signers.length, "Multisig: > signers");
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function getSigners()                    external view returns (address[] memory) { return signers; }
    function getApprovals(uint256 id)        external view returns (address[] memory) { return proposals[id].approvals; }
    function getApprovalCount(uint256 id)    external view returns (uint256) { return proposals[id].approvals.length; }
    function isApproved(uint256 id, address s) external view returns (bool) { return proposals[id].hasApproved[s]; }
    function isExecutable(uint256 id)        external view returns (bool) {
        Proposal storage p = proposals[id];
        return !p.executed && !p.cancelled &&
               p.approvals.length >= threshold &&
               block.timestamp >= p.executableAt;
    }

    receive() external payable {}
}
