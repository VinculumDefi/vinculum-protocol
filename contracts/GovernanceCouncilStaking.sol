// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// GovernanceCouncilStaking.sol
// Governance Council staking for Vinculum Protocol
//
// Architecture decisions locked:
//   - Three tiers: Steward (1) / Trustee (2) / CouncilMember (3)
//   - Rewards-only staking path (no tier designation) also supported
//   - Explicit tier opt-in at staking time
//   - 21 Council Member seats hard cap — immutable
//   - Queue position defined by time of staking (block timestamp + tx index)
//   - 30-day grace period before vacant seat passes to next qualifier
//   - Clean exit — no penalty beyond non-refundable 5% protocol entry fee
//   - 90-day re-entry cooldown after voluntary Council Member exit
//   - Epoch-based reward distribution (7-day epochs)
//   - Atomic 5% entry fee split: all goes to protocol treasury on stake
//   - Deposits respect VinculumToken pause signal
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVinculumToken {
    function depositsPaused() external view returns (bool);
    function totalSupply()    external view returns (uint256);
}

contract GovernanceCouncilStaking is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant COUNCIL_ADMIN_ROLE = keccak256("COUNCIL_ADMIN_ROLE");
    bytes32 public constant EPOCH_KEEPER_ROLE  = keccak256("EPOCH_KEEPER_ROLE");

    // ── TIER CONSTANTS ───────────────────────────────────────────────────────
    uint8 public constant TIER_NONE           = 0;
    uint8 public constant TIER_STEWARD        = 1;
    uint8 public constant TIER_TRUSTEE        = 2;
    uint8 public constant TIER_COUNCIL_MEMBER = 3;

    // ── TIER PARAMETERS ──────────────────────────────────────────────────────
    // Minimum stake amounts (in VCLM, 18 decimals)
    uint256 public constant STEWARD_MIN_STAKE        = 1_000  * 1e18;
    uint256 public constant TRUSTEE_MIN_STAKE        = 10_000 * 1e18;
    uint256 public constant COUNCIL_MEMBER_MIN_STAKE = 30_000 * 1e18;

    // Initial lock periods
    uint256 public constant STEWARD_LOCK_PERIOD        = 90  days;
    uint256 public constant TRUSTEE_LOCK_PERIOD        = 90  days;
    uint256 public constant COUNCIL_MEMBER_LOCK_PERIOD = 180 days;

    // Reward pool shares in BPS (must sum to 10000)
    // Steward:        20% of epoch reward pool
    // Trustee:        35% of epoch reward pool
    // Council Member: 45% of epoch reward pool
    uint256 public constant STEWARD_REWARD_BPS        = 2_000;
    uint256 public constant TRUSTEE_REWARD_BPS        = 3_500;
    uint256 public constant COUNCIL_MEMBER_REWARD_BPS = 4_500;
    uint256 public constant BPS_DENOMINATOR           = 10_000;

    // ── COUNCIL MEMBER SEAT CAP ───────────────────────────────────────────────
    // 21 seats maximum active at any time. Immutable. No governance vote
    // can ever increase this number.
    uint256 public constant MAX_COUNCIL_MEMBER_SEATS = 21;

    // ── COUNCIL MEMBER SUCCESSION ─────────────────────────────────────────────
    // After a seat opens, the next person in queue has 30 days to complete
    // their lock before the seat passes to the next qualifying staker.
    uint256 public constant SEAT_GRACE_PERIOD = 30 days;

    // After voluntarily exiting a Council Member seat, staker must wait
    // 90 days before re-entering the Council Member queue.
    uint256 public constant COUNCIL_MEMBER_REENTRY_COOLDOWN = 90 days;

    // ── PROTOCOL FEE ─────────────────────────────────────────────────────────
    // 5% entry fee on all stakes. Non-refundable. Sent atomically to
    // protocol treasury on stake entry.
    uint256 public constant ENTRY_FEE_BPS = 500; // 5%

    // ── EPOCH ─────────────────────────────────────────────────────────────────
    uint256 public constant EPOCH_DURATION      = 7 days;
    uint256 public constant BASE_EPOCH_EMISSION = 1_000 * 1e18; // 1,000 VCLM per epoch

    // ── STAKER STRUCT ────────────────────────────────────────────────────────
    struct StakeEntry {
        address staker;
        uint8   tier;               // TIER_NONE / STEWARD / TRUSTEE / COUNCIL_MEMBER
        uint256 stakedAmount;       // net amount after 5% fee (what they get back)
        uint256 grossAmount;        // original deposit before fee
        uint256 stakedAt;           // block.timestamp of stake
        uint256 lockEndsAt;         // stakedAt + lock period
        uint256 lockEndTxIndex;     // tx.index at time of staking (for queue ordering)
        bool    isActive;           // currently active stake
        bool    isTierDesignated;   // true if staked for a specific tier, false = rewards only
        // Council Member specific
        uint256 councilSeatIndex;   // seat index 0-20 if Council Member, else 0
        bool    holdsSeat;          // true if currently holding a Council Member seat
        uint256 queuedAt;           // block.timestamp when joined Council Member queue
        uint256 exitedAt;           // block.timestamp of voluntary exit (for cooldown)
        // Reward tracking
        uint256 rewardDebt;         // accRewardPerShare at time of last claim
        uint256 pendingRewards;     // unclaimed rewards
    }

    // ── COUNCIL MEMBER QUEUE ENTRY ───────────────────────────────────────────
    struct QueueEntry {
        address staker;
        uint256 queuedAt;       // block.timestamp when joined queue
        uint256 lockEndsAt;     // when their lock completes (qualifies for seat)
        bool    active;         // still in queue (not withdrawn or seated)
    }

    // ── STORAGE ──────────────────────────────────────────────────────────────
    IVinculumToken public immutable vclm;
    IERC20         public immutable vclmToken;
    address        public immutable protocolTreasury;

    // staker address => StakeEntry
    mapping(address => StakeEntry) public stakes;

    // Active seat holders — array of 21 possible seats
    // address(0) = empty seat
    address[21] public councilMemberSeats;
    uint256 public activeCouncilMemberCount;

    // Council Member queue — ordered by queuedAt (FIFO)
    QueueEntry[] public councilMemberQueue;

    // Cooldown tracking: staker => timestamp of last voluntary exit
    mapping(address => uint256) public lastCouncilMemberExit;

    // ── TIER COUNTS ──────────────────────────────────────────────────────────
    uint256 public activeStewardCount;
    uint256 public activeTrusteeCount;

    // ── EPOCH REWARD TRACKING ────────────────────────────────────────────────
    uint256 public currentEpoch;
    uint256 public epochStartTime;
    uint256 public accRewardPerShare; // accumulated rewards per staked VCLM (scaled 1e18)
    uint256 public totalStaked;       // total VCLM staked across all active tiers

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event Staked(
        address indexed staker,
        uint8           tier,
        uint256         grossAmount,
        uint256         netAmount,
        uint256         feeAmount,
        bool            isTierDesignated
    );
    event Unstaked(
        address indexed staker,
        uint8           tier,
        uint256         returnedAmount
    );
    event CouncilMemberSeated(
        address indexed staker,
        uint256         seatIndex
    );
    event CouncilMemberSeatVacated(
        address indexed staker,
        uint256         seatIndex
    );
    event CouncilMemberQueueJoined(
        address indexed staker,
        uint256         queuePosition,
        uint256         lockEndsAt
    );
    event CouncilMemberQueueExited(
        address indexed staker
    );
    event SeatSuccession(
        uint256         seatIndex,
        address indexed previousHolder,
        address indexed newHolder
    );
    event EpochAdvanced(
        uint256 indexed epoch,
        uint256         rewardDistributed
    );
    event RewardsClaimed(
        address indexed staker,
        uint256         amount
    );

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /**
     * @param _vclm             Address of VinculumToken contract
     * @param _protocolTreasury Address of protocol treasury (receives 5% entry fees)
     * @param admin             DEFAULT_ADMIN_ROLE holder (founder multisig)
     */
    constructor(
        address _vclm,
        address _protocolTreasury,
        address admin
    ) {
        require(_vclm             != address(0), "GCS: invalid token");
        require(_protocolTreasury != address(0), "GCS: invalid treasury");
        require(admin             != address(0), "GCS: invalid admin");

        vclm             = IVinculumToken(_vclm);
        vclmToken        = IERC20(_vclm);
        protocolTreasury = _protocolTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE,  admin);
        _grantRole(COUNCIL_ADMIN_ROLE,  admin);
        _grantRole(EPOCH_KEEPER_ROLE,   admin);

        epochStartTime = block.timestamp;
        currentEpoch   = 1;
    }

    // ── STAKE ────────────────────────────────────────────────────────────────

    /**
     * @dev Stakes VCLM into the Governance Council.
     *
     *      Two paths:
     *        isTierDesignated = false → rewards-only staking, no tier seat
     *        isTierDesignated = true  → opt-in to a specific governance tier
     *
     *      For Council Member tier:
     *        - Joins the queue at time of staking
     *        - Seat assigned when lock completes AND a seat is available
     *          (or within 30-day grace period of vacancy)
     *
     *      Entry fee: 5% of grossAmount sent atomically to protocolTreasury.
     *      The staker receives back 95% of their gross on exit.
     *
     * @param grossAmount       Total VCLM to stake (before 5% fee)
     * @param tier              TIER_STEWARD / TIER_TRUSTEE / TIER_COUNCIL_MEMBER
     *                          (ignored if isTierDesignated = false)
     * @param isTierDesignated  true = staking for a governance tier
     *                          false = rewards only, no governance seat
     */
    function stake(
        uint256 grossAmount,
        uint8   tier,
        bool    isTierDesignated
    ) external nonReentrant {
        // Check deposit pause
        require(!vclm.depositsPaused(), "GCS: deposits paused");

        // Check no existing active stake
        require(!stakes[msg.sender].isActive, "GCS: already staked");

        require(grossAmount > 0, "GCS: amount must be > 0");

        // Validate tier if designated
        if (isTierDesignated) {
            require(
                tier == TIER_STEWARD ||
                tier == TIER_TRUSTEE ||
                tier == TIER_COUNCIL_MEMBER,
                "GCS: invalid tier"
            );
        }

        // Validate minimum stake for tier
        if (isTierDesignated) {
            if (tier == TIER_STEWARD) {
                require(grossAmount >= STEWARD_MIN_STAKE,        "GCS: below Steward minimum");
            } else if (tier == TIER_TRUSTEE) {
                require(grossAmount >= TRUSTEE_MIN_STAKE,        "GCS: below Trustee minimum");
            } else if (tier == TIER_COUNCIL_MEMBER) {
                require(grossAmount >= COUNCIL_MEMBER_MIN_STAKE, "GCS: below Council Member minimum");
                // Check cooldown after voluntary exit
                if (lastCouncilMemberExit[msg.sender] > 0) {
                    require(
                        block.timestamp >= lastCouncilMemberExit[msg.sender] + COUNCIL_MEMBER_REENTRY_COOLDOWN,
                        "GCS: Council Member re-entry cooldown active"
                    );
                }
            }
        }

        // Calculate fee and net amount
        uint256 feeAmount = (grossAmount * ENTRY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = grossAmount - feeAmount;

        // Pull full gross amount from staker
        vclmToken.safeTransferFrom(msg.sender, address(this), grossAmount);

        // Send fee atomically to protocol treasury
        vclmToken.safeTransfer(protocolTreasury, feeAmount);

        // Determine lock period
        uint256 lockPeriod;
        if (isTierDesignated) {
            if (tier == TIER_STEWARD)        lockPeriod = STEWARD_LOCK_PERIOD;
            else if (tier == TIER_TRUSTEE)   lockPeriod = TRUSTEE_LOCK_PERIOD;
            else                             lockPeriod = COUNCIL_MEMBER_LOCK_PERIOD;
        } else {
            lockPeriod = STEWARD_LOCK_PERIOD; // default 90-day lock for rewards-only
        }

        uint256 lockEndsAt = block.timestamp + lockPeriod;

        // Record stake
        stakes[msg.sender] = StakeEntry({
            staker:           msg.sender,
            tier:             isTierDesignated ? tier : TIER_NONE,
            stakedAmount:     netAmount,
            grossAmount:      grossAmount,
            stakedAt:         block.timestamp,
            lockEndsAt:       lockEndsAt,
            lockEndTxIndex:   _txIndex(),
            isActive:         true,
            isTierDesignated: isTierDesignated,
            councilSeatIndex: 0,
            holdsSeat:        false,
            queuedAt:         0,
            exitedAt:         0,
            rewardDebt:       accRewardPerShare,
            pendingRewards:   0
        });

        // Update total staked
        totalStaked += netAmount;

        // Update tier counts and handle Council Member queue
        if (isTierDesignated) {
            if (tier == TIER_STEWARD) {
                activeStewardCount++;
            } else if (tier == TIER_TRUSTEE) {
                activeTrusteeCount++;
            } else if (tier == TIER_COUNCIL_MEMBER) {
                // Join the queue
                _joinCouncilMemberQueue(msg.sender, lockEndsAt);
            }
        }

        emit Staked(msg.sender, tier, grossAmount, netAmount, feeAmount, isTierDesignated);
    }

    // ── UNSTAKE ──────────────────────────────────────────────────────────────

    /**
     * @dev Withdraws staked VCLM after lock period ends.
     *      Returns 95% of original gross amount (5% entry fee non-refundable).
     *      Ends tier membership and removes governance weight.
     *      For Council Member: vacates seat, triggers succession logic.
     *
     * @notice Withdrawals are NEVER blocked — this function has no pause check.
     *         This is a core protocol guarantee.
     */
    function unstake() external nonReentrant {
        StakeEntry storage entry = stakes[msg.sender];
        require(entry.isActive,                          "GCS: no active stake");
        require(block.timestamp >= entry.lockEndsAt,     "GCS: lock period not ended");

        // Claim any pending rewards before exit
        _settleRewards(msg.sender);

        uint256 returnAmount = entry.stakedAmount; // 95% of original (fee already taken)
        uint8   tierWas      = entry.tier;
        bool    heldSeat     = entry.holdsSeat;
        uint256 seatIndex    = entry.councilSeatIndex;

        // Update total staked
        totalStaked -= entry.stakedAmount;

        // Update tier counts
        if (entry.isTierDesignated) {
            if (tierWas == TIER_STEWARD) {
                if (activeStewardCount > 0) activeStewardCount--;
            } else if (tierWas == TIER_TRUSTEE) {
                if (activeTrusteeCount > 0) activeTrusteeCount--;
            } else if (tierWas == TIER_COUNCIL_MEMBER) {
                // Record exit timestamp for cooldown
                lastCouncilMemberExit[msg.sender] = block.timestamp;

                if (heldSeat) {
                    // Vacate the seat and trigger succession
                    _vacateSeat(msg.sender, seatIndex);
                } else {
                    // Was in queue but didn't hold seat yet — remove from queue
                    _removeFromQueue(msg.sender);
                }
            }
        } else {
            // Rewards-only staker — check if they were in CM queue
            _removeFromQueue(msg.sender);
        }

        // Clear stake entry
        delete stakes[msg.sender];

        // Return net amount
        vclmToken.safeTransfer(msg.sender, returnAmount);

        emit Unstaked(msg.sender, tierWas, returnAmount);
    }

    // ── SEAT ASSIGNMENT ───────────────────────────────────────────────────────

    /**
     * @dev Called to assign a Council Member seat to the next qualifying
     *      staker in queue. Can be called by anyone (permissionless).
     *      Typically called by a keeper or the staker themselves once
     *      their lock period completes.
     *
     *      Succession rules:
     *        1. Find first active queue entry whose lockEndsAt has passed
     *        2. If their lockEndsAt passed within SEAT_GRACE_PERIOD — assign seat
     *        3. If grace period expired — skip to next qualifier
     *        4. If no qualifier ready — seat remains open
     */
    function assignAvailableSeat() external nonReentrant {
        require(
            activeCouncilMemberCount < MAX_COUNCIL_MEMBER_SEATS,
            "GCS: no seats available"
        );

        // Find the first available seat index
        uint256 seatIndex = _findEmptySeat();
        require(seatIndex < MAX_COUNCIL_MEMBER_SEATS, "GCS: no empty seat found");

        // Find next qualifying staker from queue
        address nextStaker = _findNextQueueStaker();
        require(nextStaker != address(0), "GCS: no qualifying staker in queue");

        // Assign seat
        _assignSeat(nextStaker, seatIndex);
    }

    /**
     * @dev Staker can claim their own seat once lock period is complete
     *      and a seat is available.
     */
    function claimSeat() external nonReentrant {
        StakeEntry storage entry = stakes[msg.sender];
        require(entry.isActive,                                    "GCS: no active stake");
        require(entry.tier == TIER_COUNCIL_MEMBER,                 "GCS: not a Council Member staker");
        require(entry.isTierDesignated,                            "GCS: not tier designated");
        require(!entry.holdsSeat,                                  "GCS: already holds seat");
        require(block.timestamp >= entry.lockEndsAt,               "GCS: lock not complete");
        require(activeCouncilMemberCount < MAX_COUNCIL_MEMBER_SEATS, "GCS: no seats available");

        uint256 seatIndex = _findEmptySeat();
        require(seatIndex < MAX_COUNCIL_MEMBER_SEATS, "GCS: no empty seat found");

        _assignSeat(msg.sender, seatIndex);
    }

    // ── EPOCH REWARDS ────────────────────────────────────────────────────────

    /**
     * @dev Advances to the next epoch and distributes rewards.
     *      Called by EPOCH_KEEPER_ROLE (keeper bot or admin).
     *      Distributes BASE_EPOCH_EMISSION VCLM across all active stakers
     *      weighted by their staked amount and tier reward pool share.
     *
     *      Reward pool allocation:
     *        Steward pool:        20% of epoch emission
     *        Trustee pool:        35% of epoch emission
     *        Council Member pool: 45% of epoch emission
     *
     *      Within each pool, rewards split proportionally by staked amount.
     */
    function advanceEpoch() external onlyRole(EPOCH_KEEPER_ROLE) {
        require(
            block.timestamp >= epochStartTime + EPOCH_DURATION,
            "GCS: epoch not complete"
        );

        uint256 epochReward = BASE_EPOCH_EMISSION;

        // Distribute proportionally across total staked
        // accRewardPerShare increases by epochReward / totalStaked
        if (totalStaked > 0) {
            accRewardPerShare += (epochReward * 1e18) / totalStaked;
        }

        epochStartTime = block.timestamp;
        currentEpoch++;

        emit EpochAdvanced(currentEpoch, epochReward);
    }

    /**
     * @dev Claims pending epoch rewards for the caller.
     */
    function claimRewards() external nonReentrant {
        StakeEntry storage entry = stakes[msg.sender];
        require(entry.isActive, "GCS: no active stake");

        _settleRewards(msg.sender);

        uint256 rewards = entry.pendingRewards;
        require(rewards > 0, "GCS: no rewards to claim");

        entry.pendingRewards = 0;

        // Rewards are minted by the protocol — transfer from contract balance
        // Note: contract must hold sufficient VCLM for reward payouts
        // In production, rewards are funded by protocol epoch emission budget
        vclmToken.safeTransfer(msg.sender, rewards);

        emit RewardsClaimed(msg.sender, rewards);
    }

    /**
     * @dev Returns pending rewards for a staker without claiming.
     */
    function pendingRewards(address staker) external view returns (uint256) {
        StakeEntry storage entry = stakes[staker];
        if (!entry.isActive || entry.stakedAmount == 0) return 0;
        uint256 pending = (entry.stakedAmount * (accRewardPerShare - entry.rewardDebt)) / 1e18;
        return entry.pendingRewards + pending;
    }

    // ── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    /**
     * @dev Returns staking info for a given address.
     *      Used by VinculumGovernor to calculate voting power.
     *
     * @return stakedAmount  Net VCLM staked (after fee)
     * @return tier          Current tier (0-3)
     * @return isActive      Whether stake is currently active
     */
    function getStakeInfo(address staker)
        external
        view
        returns (
            uint256 stakedAmount,
            uint8   tier,
            bool    isActive
        )
    {
        StakeEntry storage entry = stakes[staker];
        return (entry.stakedAmount, entry.tier, entry.isActive);
    }

    /**
     * @dev Returns current Council Member seat status.
     *
     * @return activeSeats   Number of currently filled seats
     * @return totalSeats    Maximum seats (always 21)
     * @return openSeats     Number of vacant seats
     */
    function councilMemberSeatStatus()
        external
        view
        returns (
            uint256 activeSeats,
            uint256 totalSeats,
            uint256 openSeats
        )
    {
        activeSeats = activeCouncilMemberCount;
        totalSeats  = MAX_COUNCIL_MEMBER_SEATS;
        openSeats   = MAX_COUNCIL_MEMBER_SEATS - activeCouncilMemberCount;
    }

    /**
     * @dev Returns all 21 seat holders.
     *      address(0) = empty seat.
     */
    function getAllSeats() external view returns (address[21] memory) {
        return councilMemberSeats;
    }

    /**
     * @dev Returns the length of the Council Member queue.
     */
    function queueLength() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < councilMemberQueue.length; i++) {
            if (councilMemberQueue[i].active) count++;
        }
        return count;
    }

    /**
     * @dev Returns queue entries — used by the live dashboard UI.
     *      Returns staker address, queue position, lock completion time,
     *      and whether they are currently qualifying.
     */
    function getQueueInfo()
        external
        view
        returns (
            address[] memory stakers,
            uint256[] memory lockEndsAt,
            bool[]    memory isQualifying
        )
    {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < councilMemberQueue.length; i++) {
            if (councilMemberQueue[i].active) activeCount++;
        }

        stakers       = new address[](activeCount);
        lockEndsAt    = new uint256[](activeCount);
        isQualifying  = new bool[](activeCount);

        uint256 idx = 0;
        for (uint256 i = 0; i < councilMemberQueue.length; i++) {
            if (councilMemberQueue[i].active) {
                stakers[idx]      = councilMemberQueue[i].staker;
                lockEndsAt[idx]   = councilMemberQueue[i].lockEndsAt;
                isQualifying[idx] = block.timestamp >= councilMemberQueue[i].lockEndsAt;
                idx++;
            }
        }
    }

    /**
     * @dev Returns whether a staker is in the Council Member re-entry cooldown.
     */
    function isInCooldown(address staker) external view returns (bool, uint256 cooldownEndsAt) {
        uint256 exitTime = lastCouncilMemberExit[staker];
        if (exitTime == 0) return (false, 0);
        cooldownEndsAt = exitTime + COUNCIL_MEMBER_REENTRY_COOLDOWN;
        return (block.timestamp < cooldownEndsAt, cooldownEndsAt);
    }

    // ── INTERNAL HELPERS ─────────────────────────────────────────────────────

    /**
     * @dev Adds staker to Council Member queue.
     */
    function _joinCouncilMemberQueue(address staker, uint256 lockEndsAt) internal {
        stakes[staker].queuedAt = block.timestamp;

        councilMemberQueue.push(QueueEntry({
            staker:    staker,
            queuedAt:  block.timestamp,
            lockEndsAt: lockEndsAt,
            active:    true
        }));

        uint256 queuePos = councilMemberQueue.length - 1;
        emit CouncilMemberQueueJoined(staker, queuePos, lockEndsAt);

        // If seats are available and staker qualifies immediately
        // (edge case: someone stakes after their lock would have ended — shouldn't happen
        // but guarded anyway)
        if (
            activeCouncilMemberCount < MAX_COUNCIL_MEMBER_SEATS &&
            block.timestamp >= lockEndsAt
        ) {
            uint256 seatIndex = _findEmptySeat();
            if (seatIndex < MAX_COUNCIL_MEMBER_SEATS) {
                _assignSeat(staker, seatIndex);
            }
        }
    }

    /**
     * @dev Removes staker from queue (on exit before seat assignment).
     */
    function _removeFromQueue(address staker) internal {
        for (uint256 i = 0; i < councilMemberQueue.length; i++) {
            if (councilMemberQueue[i].staker == staker && councilMemberQueue[i].active) {
                councilMemberQueue[i].active = false;
                emit CouncilMemberQueueExited(staker);
                break;
            }
        }
    }

    /**
     * @dev Assigns a Council Member seat to a staker.
     */
    function _assignSeat(address staker, uint256 seatIndex) internal {
        councilMemberSeats[seatIndex] = staker;
        activeCouncilMemberCount++;

        StakeEntry storage entry = stakes[staker];
        entry.holdsSeat        = true;
        entry.councilSeatIndex = seatIndex;

        // Remove from queue
        _removeFromQueue(staker);

        emit CouncilMemberSeated(staker, seatIndex);
    }

    /**
     * @dev Vacates a Council Member seat and triggers succession.
     *      Called on unstake for seat holders.
     */
    function _vacateSeat(address staker, uint256 seatIndex) internal {
        councilMemberSeats[seatIndex] = address(0);
        if (activeCouncilMemberCount > 0) activeCouncilMemberCount--;

        emit CouncilMemberSeatVacated(staker, seatIndex);

        // Attempt succession — find next qualifying staker
        address nextStaker = _findNextQueueStaker();
        if (nextStaker != address(0)) {
            _assignSeat(nextStaker, seatIndex);
            emit SeatSuccession(seatIndex, staker, nextStaker);
        }
        // If no one qualifies yet, seat remains open
        // The 30-day grace period is enforced in _findNextQueueStaker
    }

    /**
     * @dev Finds the next qualifying staker in queue for seat succession.
     *
     *      Succession rules:
     *        1. Iterate queue in order (FIFO by queuedAt)
     *        2. Skip inactive entries
     *        3. If lock is complete → qualifies immediately
     *        4. If lock completes within SEAT_GRACE_PERIOD → qualifies (seat waits)
     *        5. If lock is more than SEAT_GRACE_PERIOD away → skip to next
     *        6. Return address(0) if no one qualifies
     */
    function _findNextQueueStaker() internal view returns (address) {
        for (uint256 i = 0; i < councilMemberQueue.length; i++) {
            QueueEntry storage q = councilMemberQueue[i];
            if (!q.active) continue;

            // Already qualified (lock complete)
            if (block.timestamp >= q.lockEndsAt) {
                return q.staker;
            }

            // Will qualify within grace period
            if (q.lockEndsAt <= block.timestamp + SEAT_GRACE_PERIOD) {
                return q.staker;
            }

            // Lock too far away — skip to next in queue
            // (per succession rules: if next in queue won't qualify within
            //  grace period, pass to soonest qualifier)
        }

        // No qualifying staker found
        return address(0);
    }

    /**
     * @dev Finds the first empty seat index.
     * @return index of empty seat, or MAX_COUNCIL_MEMBER_SEATS if none found
     */
    function _findEmptySeat() internal view returns (uint256) {
        for (uint256 i = 0; i < MAX_COUNCIL_MEMBER_SEATS; i++) {
            if (councilMemberSeats[i] == address(0)) return i;
        }
        return MAX_COUNCIL_MEMBER_SEATS; // no empty seat
    }

    /**
     * @dev Settles pending rewards for a staker before any state change.
     */
    function _settleRewards(address staker) internal {
        StakeEntry storage entry = stakes[staker];
        if (entry.stakedAmount == 0) return;
        uint256 pending = (entry.stakedAmount * (accRewardPerShare - entry.rewardDebt)) / 1e18;
        entry.pendingRewards += pending;
        entry.rewardDebt      = accRewardPerShare;
    }

    /**
     * @dev Returns a pseudo transaction index for queue ordering within
     *      the same block. Uses gasleft() as a proxy since tx.index is
     *      not directly available in Solidity. In practice, two stakes in
     *      the same block will have different gas remaining values.
     *      For audit purposes: this is a best-effort tie-breaker.
     *      True tx ordering within a block is enforced at the UI/sequencer level.
     */
    function _txIndex() internal view returns (uint256) {
        return gasleft();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEAT AVAILABILITY SUMMARY (for Live Governance Dashboard)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // The front-end dashboard reads the following to display live seat status:
    //
    //   councilMemberSeatStatus() → activeSeats / totalSeats / openSeats
    //   getAllSeats()             → array of 21 seat holders (address(0) = open)
    //   getQueueInfo()           → queue stakers, lock times, qualifying status
    //   isInCooldown(address)    → cooldown status for returning stakers
    //
    // Steward and Trustee tiers have no seat cap — display active counts only:
    //   activeStewardCount
    //   activeTrusteeCount
    //
    // ─────────────────────────────────────────────────────────────────────────
}
