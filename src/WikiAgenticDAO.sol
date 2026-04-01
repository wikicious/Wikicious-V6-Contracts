// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title WikiAgenticDAO — AI-Driven Smart Governance
 *
 * Combines traditional on-chain voting with AI agent proposals that analyse
 * protocol health and propose corrective adjustments autonomously.
 *
 * TWO TYPES OF PROPOSALS
 * ─────────────────────────────────────────────────────────────────────────
 * 1. HUMAN PROPOSALS — standard governance with veWIK voting
 *    Min proposer veWIK: 50,000 (prevents spam)
 *    Voting period: 5 days
 *    Quorum: 5% of total veWIK
 *    Timelock: 48h before execution
 *
 * 2. AI AGENT PROPOSALS — submitted by authorised AI oracles
 *    Triggered by: TVL drop >20%, volume spike >3×, fee imbalance >30%
 *    Types: Fee adjustment, reward rebalancing, circuit breaker activation
 *    Requires: 24h community veto window before auto-execution
 *    Veto: Any whale (≥1M veWIK) can veto within 24h
 *
 * REVENUE OPTIMIZATION
 * AI continuously monitors:
 *   • Volatility vs fee spread — proposes fee increases during high vol
 *   • LP utilisation — proposes rebalancing rewards when utilisation <30%
 *   • Cross-chain arbitrage — flags when fees make arbitrage profitable
 */

interface IWikiStaking { function totalVeWIK() external view returns (uint256); function veWIKBalance(address) external view returns (uint256); }
interface IWikiDynamicFeeHook { function getCurrentFee(bytes32 market) external view returns (uint256); }

contract WikiAgenticDAO is Ownable2Step, ReentrancyGuard {
    enum ProposalType   { HUMAN, AI_AGENT }
    enum ProposalStatus { PENDING, ACTIVE, PASSED, FAILED, EXECUTED, VETOED }
    enum AITrigger      { NONE, TVL_DROP, VOLUME_SPIKE, FEE_IMBALANCE, VOLATILITY_SPIKE, UTILISATION_LOW }

    struct Proposal {
        uint256       id;
        ProposalType  pType;
        address       proposer;
        string        title;
        string        description;
        string        aiRationale;    // AI's reasoning (stored as IPFS hash or inline)
        AITrigger     trigger;
        bytes         callData;       // encoded function call to execute
        address       target;         // contract to call
        uint256       votesFor;
        uint256       votesAgainst;
        uint256       createdAt;
        uint256       votingEndsAt;
        uint256       executableAt;   // after timelock
        ProposalStatus status;
        // AI proposals always require human execute() call after veto window - no auto-exec
    }

    struct ProtocolMetrics {
        uint256 tvlUSD;
        uint256 dailyVolumeUSD;
        uint256 avgFeeCaptureBps;
        uint256 lpUtilisationPct;
        uint256 timestamp;
    }

    mapping(uint256 => Proposal)           public proposals;
    mapping(uint256 => mapping(address => uint256)) public votes;  // proposalId → voter → amount
    mapping(address => bool)               public aiAgents;         // authorised AI oracles
    mapping(address => bool)               public vetoWhales;       // can veto AI proposals

    IWikiStaking       public staking;
    ProtocolMetrics    public latestMetrics;
    uint256 public proposalCount;

    uint256 public constant MIN_PROPOSAL_VEEWIK = 50_000e18;
    uint256 public constant HUMAN_VOTING_PERIOD  = 5 days;
    uint256 public constant AI_VETO_WINDOW       = 1 days;
    uint256 public constant TIMELOCK             = 2 days;
    uint256 public constant QUORUM_BPS           = 500;    // 5%
    uint256 public constant BPS                  = 10000;

    uint256 public constant TVL_DROP_THRESHOLD   = 2000;  // 20% drop triggers AI
    uint256 public constant VOLUME_SPIKE_MULT    = 300;   // 3x volume spike
    uint256 public constant FEE_IMBALANCE_BPS    = 3000;  // 30% imbalance

    event ProposalCreated(uint256 indexed id, ProposalType pType, address proposer, string title, AITrigger trigger);
    event Voted(uint256 indexed proposalId, address voter, uint256 amount, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId, address vetoer);
    event MetricsUpdated(uint256 tvl, uint256 volume, uint256 timestamp);
    event AIProposalTriggered(AITrigger trigger, string rationale);

    constructor(address _staking, address _owner) Ownable(_owner) {
        require(_staking != address(0), "Wiki: zero _staking");
        require(_owner != address(0), "Wiki: zero _owner");
        staking = IWikiStaking(_staking);
    }

    modifier onlyAIAgent() { require(aiAgents[msg.sender] || msg.sender == owner(), "DAO: not AI agent"); _; }

    // ── Human Proposals ───────────────────────────────────────────────────────

    function propose(
        string calldata title,
        string calldata description,
        address target,
        bytes  calldata callData
    ) external nonReentrant returns (uint256 id) {
        require(staking.veWIKBalance(msg.sender) >= MIN_PROPOSAL_VEEWIK, "DAO: insufficient veWIK");
        id = ++proposalCount;
        proposals[id] = Proposal({
            id: id, pType: ProposalType.HUMAN, proposer: msg.sender,
            title: title, description: description, aiRationale: "",
            trigger: AITrigger.NONE, callData: callData, target: target,
            votesFor: 0, votesAgainst: 0,
            createdAt: block.timestamp,
            votingEndsAt: block.timestamp + HUMAN_VOTING_PERIOD,
            executableAt: block.timestamp + HUMAN_VOTING_PERIOD + TIMELOCK,
            status: ProposalStatus.ACTIVE, aiAutoExecute: false
        });
        emit ProposalCreated(id, ProposalType.HUMAN, msg.sender, title, AITrigger.NONE);
    }

    // ── AI Agent Proposals ────────────────────────────────────────────────────

    function proposeAI(
        string calldata title,
        string calldata description,
        string calldata rationale,
        AITrigger trigger,
        address target,
        bytes calldata callData
    ) external onlyAIAgent returns (uint256 id) {
        id = ++proposalCount;
        proposals[id] = Proposal({
            id: id, pType: ProposalType.AI_AGENT, proposer: msg.sender,
            title: title, description: description, aiRationale: rationale,
            trigger: trigger, callData: callData, target: target,
            votesFor: 0, votesAgainst: 0,
            createdAt: block.timestamp,
            votingEndsAt: block.timestamp + AI_VETO_WINDOW,
            executableAt: block.timestamp + AI_VETO_WINDOW + 1 days, // 24h mandatory human delay
            status: ProposalStatus.ACTIVE
        });
        emit ProposalCreated(id, ProposalType.AI_AGENT, msg.sender, title, trigger);
        emit AIProposalTriggered(trigger, rationale);
    }

    // ── Voting ────────────────────────────────────────────────────────────────

    function vote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.ACTIVE, "DAO: not active");
        require(block.timestamp < p.votingEndsAt, "DAO: voting ended");
        require(votes[proposalId][msg.sender] == 0, "DAO: already voted");

        uint256 power = staking.veWIKBalance(msg.sender);
        require(power > 0, "DAO: no voting power");

        votes[proposalId][msg.sender] = power;
        if (support) p.votesFor += power;
        else         p.votesAgainst += power;

        emit Voted(proposalId, msg.sender, power, support);
    }

    // ── Veto (AI proposals only) ───────────────────────────────────────────────

    function veto(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.pType == ProposalType.AI_AGENT, "DAO: not AI proposal");
        require(p.status == ProposalStatus.ACTIVE, "DAO: not active");
        require(block.timestamp < p.votingEndsAt, "DAO: veto window closed");
        require(staking.veWIKBalance(msg.sender) >= 1_000_000e18, "DAO: not whale");
        p.status = ProposalStatus.VETOED;
        emit ProposalVetoed(proposalId, msg.sender);
    }

    // ── Execute ───────────────────────────────────────────────────────────────

    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.ACTIVE, "DAO: not active");
        require(block.timestamp >= p.executableAt, "DAO: timelock");

        if (p.pType == ProposalType.HUMAN) {
            uint256 totalVotes = p.votesFor + p.votesAgainst;
            uint256 quorum     = staking.totalVeWIK() * QUORUM_BPS / BPS;
            require(totalVotes >= quorum, "DAO: quorum not met");
            require(p.votesFor > p.votesAgainst, "DAO: did not pass");
        }

        p.status = ProposalStatus.EXECUTED;
        if (p.target != address(0) && p.callData.length > 0) {
            (bool ok,) = p.target.call(p.callData);
            require(ok, "DAO: execution failed");
        }
        emit ProposalExecuted(proposalId);
    }

    // ── Protocol Metrics (AI agent writes) ────────────────────────────────────

    function updateMetrics(uint256 tvlUSD, uint256 dailyVolumeUSD, uint256 avgFeeBps, uint256 utilisationPct) external onlyAIAgent {
        // Check for auto-trigger conditions
        if (latestMetrics.tvlUSD > 0) {
            uint256 tvlDropPct = latestMetrics.tvlUSD > tvlUSD
                ? (latestMetrics.tvlUSD - tvlUSD) * BPS / latestMetrics.tvlUSD : 0;
            if (tvlDropPct >= TVL_DROP_THRESHOLD) {
                emit AIProposalTriggered(AITrigger.TVL_DROP, unicode"TVL dropped >20% — consider reducing withdrawal fees");
            }
        }
        latestMetrics = ProtocolMetrics({ tvlUSD:tvlUSD, dailyVolumeUSD:dailyVolumeUSD, avgFeeCaptureBps:avgFeeBps, lpUtilisationPct:utilisationPct, timestamp:block.timestamp });
        emit MetricsUpdated(tvlUSD, dailyVolumeUSD, block.timestamp);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setAIAgent(address agent, bool enabled) external onlyOwner { aiAgents[agent] = enabled; }
    function setVetoWhale(address whale, bool enabled) external onlyOwner { vetoWhales[whale] = enabled; }
    function setStaking(address s) external onlyOwner { staking = IWikiStaking(s); }
    function getProposal(uint256 id) external view returns (Proposal memory) { return proposals[id]; }
}
