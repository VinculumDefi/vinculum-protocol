// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// VinculumGovernor.sol
// On-chain governance for Vinculum Protocol
//
// Architecture decisions locked:
//   - Three proposal tiers: Steward / Trustee / CouncilMember
//   - Real-time balance voting (no snapshot/ERC20Votes dependency)
//   - Voting power = VCLM balance + GovernanceCouncil stake bonus
//   - Council Members get 2.0× voting weight on staked VCLM
//   - Trustees get 1.5× voting weight on staked VCLM
//   - Stewards get 1.0× voting weight on staked VCLM
//   - GUARDIAN_ROLE can emergency cancel any active proposal
//   - Proposer can cancel their own proposal before execution
//   - Timelock delay: 2 days after queue before execution
//   - Founder → DAO transition via three milestones (see bottom)
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVinculumToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IGovernanceCouncilStaking {
    function getStakeInfo(address staker) external view returns (
        uint256 stakedAmount,
        uint8   tier,           // 0 = none, 1 = Steward, 2 = Trustee, 3 = CouncilMember
        bool    isActive
    );
}

contract VinculumGovernor is AccessControl, ReentrancyGuard {

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ── TIER CONSTANTS ───────────────────────────────────────────────────────
    uint8 public constant TIER_NONE          = 0;
    uint8 public constant TIER_STEWARD       = 1;
    uint8 public constant TIER_TRUSTEE       = 2;
    uint8 public constant TIER_COUNCIL_MEMBER = 3;

    // Voting weight multipliers in BPS (10000 = 1.0×)
    uint256 public constant STEWARD_VOTE_BPS        = 10_000; // 1.0×
    uint256 public constant TRUSTEE_VOTE_BPS        = 15_000; // 1.5×
    uint256 public constant COUNCIL_MEMBER_VOTE_BPS = 20_000; // 2.0×
    uint256 public constant BPS_DENOMINATOR         = 10_000;

    // ── PROPOSAL TYPES ───────────────────────────────────────────────────────
    // Steward:       Standard proposals — parameter changes, general actions
    //                4% quorum, >51% approval threshold
    // Trustee:       Treasury proposals — reserve allocation, fund movements
    //                10% quorum, >67% approval threshold
    // CouncilMember: Constitutional proposals — core governance rule changes
    //                20% quorum, >75% approval threshold

    enum ProposalType { Steward, Trustee, CouncilMember }

    struct ProposalThreshold {
        uint256 quorumBps;      // minimum participation as % of supply
        uint256 approvalBps;    // minimum yes votes as % of votes cast
    }

    mapping(ProposalType => ProposalThreshold) public thresholds;

    // ── GOVERNANCE PARAMETERS ────────────────────────────────────────────────
    uint256 public constant VOTING_PERIOD        = 3 days;
    uint256 public constant TIMELOCK_DELAY       = 2 days;
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 100; // 1% of supply to propose

    // ── PROPOSAL STATUS ──────────────────────────────────────────────────────
    enum ProposalStatus {
        Active,     // voting open
        Defeated,   // failed quorum or approval
        Succeeded,  // passed, awaiting queue
        Queued,     // queued, awaiting timelock
        Executed,   // successfully executed
        Cancelled   // cancelled by proposer or guardian
    }

    // ── PROPOSAL STRUCT ──────────────────────────────────────────────────────
    struct Proposal {
        uint256      id;
        address      proposer;
        ProposalType proposalType;
        ProposalStatus status;

        // Execution target
        address      target;
        uint256      value;
        bytes        callData;

        // Description — store IPFS hash for full forum post
        // Format: "ipfs://Qm..." or plain text for simple proposals
        string       description;

        // Voting window
        uint256      voteStart;   // block.timestamp when created
        uint256      voteEnd;     // voteStart + VOTING_PERIOD

        // Timelock
        uint256      queuedAt;    // block.timestamp when queued
        uint256      executeAfter; // queuedAt + TIMELOCK_DELAY

        // Vote tallies
        uint256      votesFor;
        uint256      votesAgainst;
        uint256      votesAbstain;
        uint256      totalVotingPower; // snapshot of supply at proposal creation

        // Replay protection
        bool         executed;
    }

    // ── STORAGE ──────────────────────────────────────────────────────────────
    IVinculumToken            public immutable vclm;
    IGovernanceCouncilStaking public           councilStaking;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    // voter => proposalId => hasVoted
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    // proposalId => executed action hash (replay protection)
    mapping(bytes32 => bool) public executedActions;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType    proposalType,
        address         target,
        string          description,
        uint256         voteEnd
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8           support,   // 0=against, 1=for, 2=abstain
        uint256         weight
    );
    event ProposalQueued(uint256 indexed proposalId, uint256 executeAfter);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId, address indexed cancelledBy);
    event CouncilStakingUpdated(address indexed newStaking);

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /**
     * @param _vclm    Address of VinculumToken contract
     * @param admin    DEFAULT_ADMIN_ROLE holder (founder multisig at launch)
     * @param guardian GUARDIAN_ROLE holder (founder multisig at launch)
     *                 The guardian can emergency cancel any active proposal.
     *                 This role transfers to governance at Milestone 2.
     */
    constructor(address _vclm, address admin, address guardian) {
        require(_vclm    != address(0), "VinculumGovernor: invalid token");
        require(admin    != address(0), "VinculumGovernor: invalid admin");
        require(guardian != address(0), "VinculumGovernor: invalid guardian");

        vclm = IVinculumToken(_vclm);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);

        // Set proposal thresholds
        thresholds[ProposalType.Steward] = ProposalThreshold({
            quorumBps:   400,   // 4% of supply must participate
            approvalBps: 5100   // >51% of votes cast must be yes
        });
        thresholds[ProposalType.Trustee] = ProposalThreshold({
            quorumBps:   1000,  // 10% of supply must participate
            approvalBps: 6700   // >67% of votes cast must be yes
        });
        thresholds[ProposalType.CouncilMember] = ProposalThreshold({
            quorumBps:   2000,  // 20% of supply must participate
            approvalBps: 7500   // >75% of votes cast must be yes
        });
    }

    // ── COUNCIL STAKING WIRING ───────────────────────────────────────────────

    /**
     * @dev Sets the GovernanceCouncilStaking contract address.
     *      Can only be called once after deployment when staking contract
     *      is deployed. Cannot be changed after initial set.
     * @param _councilStaking Address of GovernanceCouncilStaking contract
     */
    function setCouncilStaking(address _councilStaking)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_councilStaking != address(0), "VinculumGovernor: invalid staking");
        require(address(councilStaking) == address(0), "VinculumGovernor: already set");
        councilStaking = IGovernanceCouncilStaking(_councilStaking);
        emit CouncilStakingUpdated(_councilStaking);
    }

    // ── VOTING POWER ─────────────────────────────────────────────────────────

    /**
     * @dev Calculates voting power for an address.
     *      Base = VCLM balance (real-time, no snapshot)
     *      Bonus = staked VCLM in GovernanceCouncil × tier multiplier
     *
     *      Tier multipliers:
     *        Steward:        1.0× on staked VCLM (no bonus)
     *        Trustee:        1.5× on staked VCLM
     *        Council Member: 2.0× on staked VCLM
     *
     *      Total = walletBalance + (stakedAmount × multiplier)
     *
     * @param voter Address to calculate voting power for
     * @return power Total voting power in VCLM units (18 decimals)
     */
    function votingPower(address voter) public view returns (uint256 power) {
        // Base: wallet balance
        power = vclm.balanceOf(voter);

        // Bonus: council stake with tier multiplier
        if (address(councilStaking) != address(0)) {
            (uint256 stakedAmount, uint8 tier, bool isActive) =
                councilStaking.getStakeInfo(voter);

            if (isActive && stakedAmount > 0) {
                uint256 multiplierBps;
                if (tier == TIER_COUNCIL_MEMBER) {
                    multiplierBps = COUNCIL_MEMBER_VOTE_BPS;
                } else if (tier == TIER_TRUSTEE) {
                    multiplierBps = TRUSTEE_VOTE_BPS;
                } else if (tier == TIER_STEWARD) {
                    multiplierBps = STEWARD_VOTE_BPS;
                }

                if (multiplierBps > 0) {
                    power += (stakedAmount * multiplierBps) / BPS_DENOMINATOR;
                }
            }
        }
    }

    // ── PROPOSE ──────────────────────────────────────────────────────────────

    /**
     * @dev Creates a new governance proposal.
     *      Proposer must hold at least 1% of total VCLM supply.
     *
     * @param proposalType  Steward / Trustee / CouncilMember
     * @param target        Contract address to call on execution
     * @param value         ETH value to send with call (usually 0)
     * @param callData      Encoded function call
     * @param description   Human readable description or IPFS hash
     *                      Recommended format: "ipfs://Qm..." for full proposal
     * @return proposalId   The ID of the newly created proposal
     */
    function propose(
        ProposalType proposalType,
        address      target,
        uint256      value,
        bytes calldata callData,
        string calldata description
    ) external returns (uint256 proposalId) {
        // Check proposer has enough voting power (1% of supply)
        uint256 supply    = vclm.totalSupply();
        uint256 threshold = (supply * PROPOSAL_THRESHOLD_BPS) / BPS_DENOMINATOR;
        require(
            votingPower(msg.sender) >= threshold,
            "VinculumGovernor: insufficient voting power to propose"
        );

        require(target      != address(0), "VinculumGovernor: invalid target");
        require(bytes(description).length > 0, "VinculumGovernor: empty description");

        proposalCount++;
        proposalId = proposalCount;

        proposals[proposalId] = Proposal({
            id:               proposalId,
            proposer:         msg.sender,
            proposalType:     proposalType,
            status:           ProposalStatus.Active,
            target:           target,
            value:            value,
            callData:         callData,
            description:      description,
            voteStart:        block.timestamp,
            voteEnd:          block.timestamp + VOTING_PERIOD,
            queuedAt:         0,
            executeAfter:     0,
            votesFor:         0,
            votesAgainst:     0,
            votesAbstain:     0,
            totalVotingPower: supply,
            executed:         false
        });

        emit ProposalCreated(
            proposalId,
            msg.sender,
            proposalType,
            target,
            description,
            block.timestamp + VOTING_PERIOD
        );
    }

    // ── VOTE ─────────────────────────────────────────────────────────────────

    /**
     * @dev Cast a vote on an active proposal.
     *
     * @param proposalId  ID of the proposal to vote on
     * @param support     0 = against, 1 = for, 2 = abstain
     */
    function castVote(uint256 proposalId, uint8 support)
        external
        nonReentrant
    {
        require(support <= 2, "VinculumGovernor: invalid support value");

        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0,                          "VinculumGovernor: proposal does not exist");
        require(proposal.status == ProposalStatus.Active,  "VinculumGovernor: proposal not active");
        require(block.timestamp >= proposal.voteStart,     "VinculumGovernor: voting not started");
        require(block.timestamp <= proposal.voteEnd,       "VinculumGovernor: voting ended");
        require(!hasVoted[msg.sender][proposalId],         "VinculumGovernor: already voted");

        uint256 weight = votingPower(msg.sender);
        require(weight > 0, "VinculumGovernor: no voting power");

        hasVoted[msg.sender][proposalId] = true;

        if (support == 1) {
            proposal.votesFor     += weight;
        } else if (support == 0) {
            proposal.votesAgainst += weight;
        } else {
            proposal.votesAbstain += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    // ── FINALIZE ─────────────────────────────────────────────────────────────

    /**
     * @dev Finalizes a proposal after the voting period ends.
     *      Transitions status to Succeeded or Defeated.
     *      Anyone can call this — it is permissionless.
     *
     * @param proposalId  ID of the proposal to finalize
     */
    function finalize(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0,                         "VinculumGovernor: proposal does not exist");
        require(proposal.status == ProposalStatus.Active, "VinculumGovernor: proposal not active");
        require(block.timestamp > proposal.voteEnd,       "VinculumGovernor: voting still open");

        ProposalThreshold memory t = thresholds[proposal.proposalType];

        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst + proposal.votesAbstain;

        // Check quorum: total votes cast must be >= quorumBps % of supply
        uint256 quorumRequired = (proposal.totalVotingPower * t.quorumBps) / BPS_DENOMINATOR;
        bool quorumMet = totalVotes >= quorumRequired;

        // Check approval: yes votes must be >= approvalBps % of votes cast (excluding abstain)
        uint256 votesCounted  = proposal.votesFor + proposal.votesAgainst;
        bool approvalMet = votesCounted > 0 &&
            (proposal.votesFor * BPS_DENOMINATOR) / votesCounted >= t.approvalBps;

        if (quorumMet && approvalMet) {
            proposal.status = ProposalStatus.Succeeded;
        } else {
            proposal.status = ProposalStatus.Defeated;
        }
    }

    // ── QUEUE ────────────────────────────────────────────────────────────────

    /**
     * @dev Queues a succeeded proposal for timelock execution.
     *      Anyone can call this — it is permissionless.
     *
     * @param proposalId  ID of the proposal to queue
     */
    function queue(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.Succeeded, "VinculumGovernor: proposal not succeeded");

        proposal.status       = ProposalStatus.Queued;
        proposal.queuedAt     = block.timestamp;
        proposal.executeAfter = block.timestamp + TIMELOCK_DELAY;

        emit ProposalQueued(proposalId, proposal.executeAfter);
    }

    // ── EXECUTE ──────────────────────────────────────────────────────────────

    /**
     * @dev Executes a queued proposal after the timelock delay.
     *      Anyone can call this — it is permissionless.
     *      Replay protection via executedActions mapping.
     *
     * @param proposalId  ID of the proposal to execute
     */
    function execute(uint256 proposalId)
        external
        nonReentrant
    {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.Queued,    "VinculumGovernor: proposal not queued");
        require(block.timestamp >= proposal.executeAfter,     "VinculumGovernor: timelock not expired");
        require(!proposal.executed,                           "VinculumGovernor: already executed");

        // Replay protection
        bytes32 actionHash = keccak256(abi.encode(
            proposal.target,
            proposal.value,
            proposal.callData,
            proposal.id
        ));
        require(!executedActions[actionHash], "VinculumGovernor: action already executed");

        proposal.status   = ProposalStatus.Executed;
        proposal.executed = true;
        executedActions[actionHash] = true;

        // Execute the call
        (bool success, bytes memory returnData) = proposal.target.call{
            value: proposal.value
        }(proposal.callData);

        require(success, _getRevertMsg(returnData));

        emit ProposalExecuted(proposalId);
    }

    // ── CANCEL ───────────────────────────────────────────────────────────────

    /**
     * @dev Cancels a proposal.
     *      Can be called by:
     *        - The original proposer (at any time before execution)
     *        - A GUARDIAN_ROLE holder (emergency cancel, any active/queued proposal)
     *
     * @param proposalId  ID of the proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id != 0, "VinculumGovernor: proposal does not exist");
        require(
            proposal.status == ProposalStatus.Active  ||
            proposal.status == ProposalStatus.Succeeded ||
            proposal.status == ProposalStatus.Queued,
            "VinculumGovernor: cannot cancel at this stage"
        );
        require(!proposal.executed, "VinculumGovernor: already executed");

        bool isProposer  = msg.sender == proposal.proposer;
        bool isGuardian  = hasRole(GUARDIAN_ROLE, msg.sender);
        require(isProposer || isGuardian, "VinculumGovernor: not authorised to cancel");

        proposal.status = ProposalStatus.Cancelled;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ── VIEW HELPERS ─────────────────────────────────────────────────────────

    /**
     * @dev Returns the current status of a proposal.
     */
    function proposalStatus(uint256 proposalId)
        external
        view
        returns (ProposalStatus)
    {
        return proposals[proposalId].status;
    }

    /**
     * @dev Returns full vote tally for a proposal.
     */
    function proposalVotes(uint256 proposalId)
        external
        view
        returns (
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 votesAbstain,
            uint256 totalVotingPower
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.votesFor, p.votesAgainst, p.votesAbstain, p.totalVotingPower);
    }

    /**
     * @dev Returns whether an address has voted on a proposal.
     */
    function getHasVoted(address voter, uint256 proposalId)
        external
        view
        returns (bool)
    {
        return hasVoted[voter][proposalId];
    }

    /**
     * @dev Returns the quorum required for a given proposal type
     *      based on the current total supply.
     */
    function quorumRequired(ProposalType proposalType)
        external
        view
        returns (uint256)
    {
        return (vclm.totalSupply() * thresholds[proposalType].quorumBps) / BPS_DENOMINATOR;
    }

    // ── INTERNAL HELPERS ─────────────────────────────────────────────────────

    /**
     * @dev Extracts revert message from failed call return data.
     */
    function _getRevertMsg(bytes memory returnData)
        internal
        pure
        returns (string memory)
    {
        if (returnData.length < 68) return "VinculumGovernor: execution failed";
        assembly {
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string));
    }

    // ── ETH RECEIVE ──────────────────────────────────────────────────────────
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    // FOUNDER → DAO TRANSITION MILESTONES
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Milestone 1 — Post-audit / Launch
    //   DEFAULT_ADMIN_ROLE: founder 3-of-5 multisig
    //   GUARDIAN_ROLE:      founder multisig
    //   Governance controls: asset approvals, Core Reserve treasury (82%)
    //   Founder controls:   Dev Fund (12%), operational roles
    //
    // Milestone 2 — 6 months live + 1,000 active vaults
    //   ASSET_MANAGER_ROLE transfers fully to governance
    //   GUARDIAN_ROLE transfers to a community-elected guardian multisig
    //   Founder multisig reduced to DEFAULT_ADMIN_ROLE only
    //   Triggered by: Constitutional proposal passed by Council Members
    //
    // Milestone 3 — 12 months live + full Council seated (21/21)
    //   DEFAULT_ADMIN_ROLE transfers to this Governor contract itself
    //   Founder becomes a Council Member like everyone else
    //   Dev Fund remains founder-controlled permanently (by design)
    //   Triggered by: Constitutional proposal passed by Council Members
    //
    // Note: The Dev Fund (12% of treasury) remains under founder operational
    // control through all three milestones and permanently thereafter.
    // This is a published protocol guarantee, not a backdoor.
    // ─────────────────────────────────────────────────────────────────────────
}
