// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";

/**
 * @title VoxGovernanceFacet
 * @author Vox Team
 * @notice Manages governance proposals, voting, and admin elections for the Vox platform
 * @dev Implements a dual governance system:
 *      1. Proposal-based governance for quota and facet upgrades
 *      2. Admin election system with application fees and voting
 *
 *      Security features:
 *      - Flash loan protection on all voting functions
 *      - Quorum requirements for proposal ratification
 *      - Owner-only proposal creation and ratification
 *      - Reentrancy protection on payable functions
 */
contract VoxGovernanceFacet is ReentrancyGuard {
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }
    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a new governance proposal is created
     * @param proposalId The unique identifier for the proposal
     * @param proposalType The type of proposal (QuotaProposal or FacetProposal)
     * @param votingDeadline The block number when voting ends
     */
    event ProposalCreated(uint256 indexed proposalId, LibVoxGovernanceStorage.ProposalType proposalType, uint256 votingDeadline);

    /**
     * @notice Emitted when an active proposal is revoked by the owner
     * @param proposalId The identifier of the revoked proposal
     */
    event ProposalRevoked(uint256 indexed proposalId);

    /**
     * @notice Emitted when a proposal is successfully ratified
     * @param proposalId The identifier of the ratified proposal
     * @param proposalType The type of proposal that was ratified
     */
    event ProposalRatified(uint256 indexed proposalId, LibVoxGovernanceStorage.ProposalType proposalType);

    /**
     * @notice Emitted when a proposal is resolved after its deadline without being applied
     *         (failed quorum and/or majority). The single-proposal queue is cleared.
     * @param proposalId The identifier of the failed proposal
     * @param proposalType The type of proposal that failed
     */
    event ProposalFailed(uint256 indexed proposalId, LibVoxGovernanceStorage.ProposalType proposalType);

    /**
     * @notice Emitted when a user applies to become an admin candidate
     * @param candidate The address of the applicant
     * @param adminVoteId The current admin voting round identifier
     * @param feePaid The application fee paid in POL (wei)
     */
    event AdminApplicationSubmitted(address indexed candidate, uint256 indexed adminVoteId, uint256 feePaid);

    /**
     * @notice Emitted when a candidate revokes their admin application
     * @param candidate The address of the candidate who revoked
     * @param adminVoteId The admin voting round identifier
     */
    event AdminApplicationRevoked(address indexed candidate, uint256 indexed adminVoteId);

    /**
     * @notice Emitted when a new admin is successfully elected
     * @param previousAdmin The address of the outgoing admin
     * @param newAdmin The address of the newly elected admin
     * @param netVotes The net votes (for - against) the winning candidate received
     */
    event NewAdminRatified(address indexed previousAdmin, address indexed newAdmin, uint256 netVotes);

    /**
     * @notice Emitted when the signing address is updated
     * @param newAddress The new signing address
     */
    event SigningAddressUpdated(address indexed newAddress);

    /**
     * @notice Emitted when the storage provider address is updated
     * @param newProvider The new storage provider address
     */
    event StorageProviderUpdated(address indexed newProvider);

    /**
     * @notice Emitted when a user is banned from the platform
     * @param user The address of the banned user
     * @param blockNumber The block number when the ban was applied
     */
    event UserBanned(address indexed user, uint256 blockNumber);

    /**
     * @notice Emitted when a user is unbanned from the platform
     * @param user The address of the unbanned user
     * @param blockNumber The block number when the user was unbanned
     */
    event UserUnbanned(address indexed user, uint256 blockNumber);

    /// @notice Emitted when the VOX Admin revokes a pending VoxAssistant invitation
    /// @dev Also declared on VoxAssistantFacet (the primary emitter); same topic hash.
    event VoxAssistantInvitationRevoked(address indexed candidate, address indexed revokedBy, uint256 timestamp);

    /// @notice Emitted when a VoxAssistant is removed by the VOX Admin (or auto-removed on platform ban)
    /// @dev Also declared on VoxAssistantFacet (the primary emitter); same topic hash.
    event VoxAssistantRemoved(address indexed assistant, address indexed removedBy, uint256 timestamp);

    // ============================================
    // MODIFIERS
    // ============================================

    // flashLoanProtection modifier removed — flash loan eligibility is now checked inline
    // inside each function via LibVoxTokenStorage.canVote() in the correct check order:
    // (1) active proposal/election exists, (2) cooldown eligibility, (3) logic, (4) stamp.

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    function _requireNonZeroAddress(address addr) internal pure {
        require(addr != address(0), "Z");
    }

    function _getGovStorage() internal pure returns (LibVoxGovernanceStorage.GovernanceStorage storage) {
        return LibVoxGovernanceStorage.governanceStorage();
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the governance system with initial parameters
     * @dev Can only be called once by the contract owner
     *      Validates that claim percentages sum to 100% and quorum values are within bounds
     *
     * @param quotas The initial quota settings including:
     *               - Claim percentages for Vox, viewers, and third parties (must sum to 100)
     *               - Quorum requirements for different proposal types (0-100%)
     *               - Admin application fee and voting duration
     * @param signingAddress The address authorized to sign governance-related messages
     * @param storageProviderAddress The address of the decentralized storage provider
     *
     * Requirements:
     * - Must not be already initialized
     * - Signing address cannot be zero address
     * - Storage provider address cannot be zero address
     * - All quorum percentages must be <= 100
     * - Claim percentages must sum to exactly 100
     *
     * Emits: GovernanceInitialized event (if implemented)
     */
    function initialize(LibVoxGovernanceStorage.CurrentQuotas memory quotas, address signingAddress, address storageProviderAddress) external {
        LibDiamond.enforceIsContractOwner();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        require(!govStorage.initialized, "Already initialized");
        _requireNonZeroAddress(signingAddress);
        _requireNonZeroAddress(storageProviderAddress);

        require(quotas.voxAdminChangeQuorum <= 100, "Invalid admin quorum");
        require(quotas.QuotaProposalQuorum <= 100, "Invalid quota quorum");
        require(quotas.FacetProposalQuorum <= 100, "Invalid facet quorum");
        require(quotas.storageProviderPercentage <= 100, "Invalid storage provider percentage");
        require(quotas.voxAdminClaimPercentage <= 100, "Invalid admin claim percentage");

        require(
            quotas.voxClaimPercentage +
                quotas.viewerClaimPercentage +
                quotas.thirdParty1ClaimPercentage +
                quotas.thirdParty2ClaimPercentage +
                quotas.thirdParty3ClaimPercentage +
                quotas.thirdParty4ClaimPercentage +
                quotas.thirdParty5ClaimPercentage +
                quotas.thirdParty6ClaimPercentage ==
                100,
            "Claim percentages must sum to 100"
        );

        govStorage.currentQuotas = quotas;
        govStorage.storageProviderAddress = storageProviderAddress;
        govStorage.signingAddress = signingAddress;
        govStorage.initialized = true;
    }

    // ============================================
    // PROPOSAL MANAGEMENT (OWNER ONLY)
    // ============================================

    /**
     * @notice Creates a new governance proposal for voting
     * @dev Only callable by the contract owner. Only one proposal can be active at a time.
     *      For QuotaProposals, the proposed claim percentages must sum to 100%.
     *
     * @param proposalType The type of proposal:
     *                     - QuotaProposal: Changes to claim percentages and quorum settings
     *                     - FacetProposal: Diamond facet upgrades/additions/removals
     * @param quotaProposalData The quota settings to propose (only used for QuotaProposal type)
     * @param votingDurationInBlocks The duration of the voting period in blocks
     * @param newFacets Array of facet cuts to propose (only used for FacetProposal type)
     *
     * Requirements:
     * - No other proposal can be active
     * - For QuotaProposal: claim percentages must sum to 100
     * - For FacetProposal: newFacets array must not be empty
     *
     * Emits: ProposalCreated event with proposal details
     *
     * State Changes:
     * - Increments proposal ID counter
     * - Sets voting deadline
     * - Marks proposal as active
     * - Resets vote counters
     */
    function createProposal(
        LibVoxGovernanceStorage.ProposalType proposalType,
        LibVoxGovernanceStorage.QuotaProposal memory quotaProposalData,
        uint256 votingDurationInBlocks,
        IDiamondCut.FacetCut[] memory newFacets,
        address initAddress,
        bytes memory initCalldata
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        require(!govStorage.votingStruct.isProposalActive, "Currently a proposal is already active");

        // ✅ NEW: Validate duration constraints
        if (proposalType == LibVoxGovernanceStorage.ProposalType.QuotaProposal) {
            require(
                votingDurationInBlocks >= govStorage.currentQuotas.minQuotaProposalDuration &&
                    votingDurationInBlocks <= govStorage.currentQuotas.maxQuotaProposalDuration,
                "Quota proposal duration outside allowed range"
            );
            _validateQuotaProposal(quotaProposalData);
        } else if (proposalType == LibVoxGovernanceStorage.ProposalType.FacetProposal) {
            require(
                votingDurationInBlocks >= govStorage.currentQuotas.minFacetProposalDuration &&
                    votingDurationInBlocks <= govStorage.currentQuotas.maxFacetProposalDuration,
                "Facet proposal duration outside allowed range"
            );
        }

        govStorage.votingStruct.currentProposalId++;
        govStorage.votingStruct.votingDeadline = block.number + votingDurationInBlocks;
        govStorage.votingStruct.isProposalActive = true;
        govStorage.votingStruct.totalSupportVotesForCurrentProposal = 0;
        govStorage.votingStruct.totalOpposeVotesForCurrentProposal = 0;

        if (proposalType == LibVoxGovernanceStorage.ProposalType.QuotaProposal) {
            govStorage.votingStruct.proposalType = LibVoxGovernanceStorage.ProposalType.QuotaProposal;
            govStorage.quotaProposal = quotaProposalData;
        } else if (proposalType == LibVoxGovernanceStorage.ProposalType.FacetProposal) {
            govStorage.votingStruct.proposalType = LibVoxGovernanceStorage.ProposalType.FacetProposal;
            delete govStorage.proposedNewFacets;

            for (uint256 i = 0; i < newFacets.length; i++) {
                govStorage.proposedNewFacets.push(newFacets[i]);
            }

            govStorage.proposedInit = initAddress;
            govStorage.proposedInitCalldata = initCalldata;
        } else {
            revert("Invalid proposal type");
        }

        emit ProposalCreated(govStorage.votingStruct.currentProposalId, proposalType, govStorage.votingStruct.votingDeadline);
    }

    /**
     * @notice Revokes the currently active proposal
     * @dev Only callable by the contract owner. Can only revoke if a proposal is active.
     *
     * Requirements:
     * - Must have an active proposal
     *
     * Emits: ProposalRevoked event with the revoked proposal ID
     *
     * State Changes:
     * - Clears quota proposal data
     * - Clears proposed facets array
     * - Marks proposal as inactive
     */
    function revokeProposal() external {
        LibDiamond.enforceIsContractOwner();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        require(govStorage.votingStruct.isProposalActive, "No active proposal to revoke");
        // Item 4: revoke = abort during voting only. After the deadline the outcome belongs
        // to the token holders and is resolved by the permissionless ratifyUpgrade(); allowing
        // a post-deadline revoke would re-introduce the owner veto that item 3 removed.
        require(block.number < govStorage.votingStruct.votingDeadline, "Voting ended: resolve via ratifyUpgrade");

        delete govStorage.quotaProposal;
        delete govStorage.proposedNewFacets;
        govStorage.votingStruct.isProposalActive = false;

        emit ProposalRevoked(govStorage.votingStruct.currentProposalId);
    }

    /**
     * @notice Ratifies a proposal that has passed voting requirements
     * @dev Only callable by the contract owner after the voting period has ended.
     *      For QuotaProposals: Updates system quotas if quorum is met and support > opposition
     *      For FacetProposals: Executes diamond cut if quorum is met and support > opposition
     *
     * Requirements:
     * - Voting period must have ended
     * - Support votes must exceed opposition votes
     * - Total votes must meet the required quorum percentage
     *
     * Quorum Calculation:
     * - QuotaProposal: (support + oppose) >= (totalSupply * QuotaProposalQuorum / 100)
     * - FacetProposal: (support + oppose) >= (totalSupply * FacetProposalQuorum / 100)
     *
     * Emits: ProposalRatified event with proposal details
     *
     * State Changes:
     * - For QuotaProposal: Updates all current quotas to proposed values
     * - For FacetProposal: Executes diamond cut with proposed facets
     * - Clears proposal data
     * - Marks proposal as inactive
     * - Resets vote counters
     */
    function ratifyUpgrade() external {
        // Item 3: permissionless after the deadline. The outcome is already fixed by the
        // vote, so owner-gating only added a liveness dependency (silent veto by inaction).
        // Correctness is preserved by the quorum + majority checks below.
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        require(govStorage.votingStruct.isProposalActive, "No active proposal");
        require(block.number >= govStorage.votingStruct.votingDeadline, "Voting period has not ended yet");

        uint256 support = govStorage.votingStruct.totalSupportVotesForCurrentProposal;
        uint256 oppose = govStorage.votingStruct.totalOpposeVotesForCurrentProposal;
        LibVoxGovernanceStorage.ProposalType ptype = govStorage.votingStruct.proposalType;
        uint256 pid = govStorage.votingStruct.currentProposalId;

        // Item 6: quorum is measured on support (FOR) votes only, so an oppose vote can
        // never help a proposal reach quorum. Item 5: this function never reverts on
        // quorum/majority — it resolves the proposal either way and always clears the
        // queue, so an expired proposal can never brick governance.
        bool passed;

        if (ptype == LibVoxGovernanceStorage.ProposalType.QuotaProposal) {
            uint256 requiredQuorum = (tokenStorage.totalSupply * govStorage.currentQuotas.QuotaProposalQuorum) / 100;
            passed = support >= requiredQuorum && support > oppose;

            if (passed) {
                govStorage.currentQuotas.voxClaimPercentage = govStorage.quotaProposal.proposedVoxClaimPercentage;
                govStorage.currentQuotas.viewerClaimPercentage = govStorage.quotaProposal.proposedViewerClaimPercentage;
                govStorage.currentQuotas.thirdParty1ClaimPercentage = govStorage.quotaProposal.proposedThirdParty1ClaimPercentage;
                govStorage.currentQuotas.thirdParty2ClaimPercentage = govStorage.quotaProposal.proposedThirdParty2ClaimPercentage;
                govStorage.currentQuotas.thirdParty3ClaimPercentage = govStorage.quotaProposal.proposedThirdParty3ClaimPercentage;
                govStorage.currentQuotas.thirdParty4ClaimPercentage = govStorage.quotaProposal.proposedThirdParty4ClaimPercentage;
                govStorage.currentQuotas.thirdParty5ClaimPercentage = govStorage.quotaProposal.proposedThirdParty5ClaimPercentage;
                govStorage.currentQuotas.thirdParty6ClaimPercentage = govStorage.quotaProposal.proposedThirdParty6ClaimPercentage;
                govStorage.currentQuotas.voxAdminClaimPercentage = govStorage.quotaProposal.proposedVoxAdminClaimPercentage;
                govStorage.currentQuotas.voxAdminChangeQuorum = govStorage.quotaProposal.proposedVoxAdminChangeQuorum;
                govStorage.currentQuotas.QuotaProposalQuorum = govStorage.quotaProposal.proposedQuotaProposalQuorum;
                govStorage.currentQuotas.FacetProposalQuorum = govStorage.quotaProposal.proposedFacetProposalQuorum;
                govStorage.currentQuotas.storageProviderPercentage = govStorage.quotaProposal.proposedStorageProviderPercentage;
                govStorage.currentQuotas.adminApplicantFeeInPolWei = govStorage.quotaProposal.proposedAdminApplicantFeeInPolWei;
                govStorage.currentQuotas.adminVoteDeadlineInBlocks = govStorage.quotaProposal.proposedAdminVoteDeadlineInBlocks;

                // ✅ NEW: Update duration parameters
                govStorage.currentQuotas.minQuotaProposalDuration = govStorage.quotaProposal.proposedMinQuotaProposalDuration;
                govStorage.currentQuotas.maxQuotaProposalDuration = govStorage.quotaProposal.proposedMaxQuotaProposalDuration;
                govStorage.currentQuotas.minFacetProposalDuration = govStorage.quotaProposal.proposedMinFacetProposalDuration;
                govStorage.currentQuotas.maxFacetProposalDuration = govStorage.quotaProposal.proposedMaxFacetProposalDuration;
            }
        } else if (ptype == LibVoxGovernanceStorage.ProposalType.FacetProposal) {
            uint256 requiredQuorum = (tokenStorage.totalSupply * govStorage.currentQuotas.FacetProposalQuorum) / 100;
            passed = support >= requiredQuorum && support > oppose;

            if (passed) {
                IDiamondCut.FacetCut[] memory cutsToRatify = new IDiamondCut.FacetCut[](govStorage.proposedNewFacets.length);

                for (uint256 i = 0; i < govStorage.proposedNewFacets.length; i++) {
                    cutsToRatify[i] = govStorage.proposedNewFacets[i];
                }

                // Call LibDiamond.diamondCut directly rather than going through
                // IDiamondCut(address(this)).diamondCut(...). An external self-call
                // would enter DiamondCutFacet with msg.sender == address(this) and
                // fail LibDiamond.enforceIsContractOwner(). The governance vote itself
                // is the authorization here — the passed FacetProposalQuorum vote. This
                // path also intentionally bypasses the bootstrap latch in DiamondCutFacet.
                LibDiamond.diamondCut(cutsToRatify, govStorage.proposedInit, govStorage.proposedInitCalldata);
            }
        }

        // Always clean up so the single-proposal queue can never be bricked by an
        // expired-but-unresolvable proposal (item 5).
        delete govStorage.quotaProposal;
        delete govStorage.proposedNewFacets;
        delete govStorage.proposedInit;
        delete govStorage.proposedInitCalldata;
        govStorage.votingStruct.isProposalActive = false;
        govStorage.votingStruct.totalSupportVotesForCurrentProposal = 0;
        govStorage.votingStruct.totalOpposeVotesForCurrentProposal = 0;

        if (passed) {
            emit ProposalRatified(pid, ptype);
        } else {
            emit ProposalFailed(pid, ptype);
        }
    }

    // ============================================
    // VOTING FUNCTIONS (PUBLIC)
    // ============================================

    /**
     * @notice Casts a vote on the currently active governance proposal
     * @dev Voting power is proportional to the voter's token balance at the time of voting.
     *      Protected against flash loan attacks by requiring 2 blocks since last transfer/vote.
     *
     * @param support True to vote in favor of the proposal, false to vote against
     *
     * Requirements:
     * - Must pass flash loan protection (2 blocks since last transfer/vote)
     * - Must not have already voted on this proposal
     * - Voting period must not have ended
     * - A proposal must be active
     * - Voter must have non-zero token balance (voting power)
     *
     * State Changes:
     * - Records user's vote and voting power for this proposal
     * - Increments total support or opposition votes
     * - Marks user as having voted on this proposal
     * - Updates user's last vote block for flash loan protection
     */
    function voteOnProposal(bool support) external {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        // 1. Meaningful state checks first — give callers accurate error messages
        require(govStorage.votingStruct.isProposalActive, "No active proposal");
        require(block.number < govStorage.votingStruct.votingDeadline, "Voting period over");

        uint256 currentProposalId = govStorage.votingStruct.currentProposalId;
        uint256 voterBalance = tokenStorage.balances[msg.sender];

        require(!govStorage.hasVotedOnProposal[msg.sender][currentProposalId], "Already voted");
        require(voterBalance > 0, "No voting power");

        // 2. Flash loan / cooldown check (shared canonical implementation)
        require(LibVoxTokenStorage.canVote(tokenStorage, msg.sender), "Cannot vote: recent transfer or voting activity");

        // 3. Record vote
        if (support) {
            govStorage.votesByUser[msg.sender][currentProposalId][true] = voterBalance;
            govStorage.votingStruct.totalSupportVotesForCurrentProposal += voterBalance;
        } else {
            govStorage.votesByUser[msg.sender][currentProposalId][false] = voterBalance;
            govStorage.votingStruct.totalOpposeVotesForCurrentProposal += voterBalance;
        }

        govStorage.hasVotedOnProposal[msg.sender][currentProposalId] = true;

        // 4. Stamp cooldown after all state changes
        tokenStorage.lastVoteBlock[msg.sender] = block.number;
    }

    /**
     * @notice Casts a vote for an admin candidate
     * @dev Voting power is proportional to the voter's token balance.
     *      Protected against flash loan attacks and prevents voting for yourself.
     *      ✅ CHANGED: Only support votes allowed, no opposition voting
     *
     * @param candidate The address of the admin candidate to vote for
     *
     * Requirements:
     * - Must pass flash loan protection (2 blocks since last transfer/vote)
     * - Candidate must be a registered applicant for the current admin vote round
     * - Voter must not have already voted for this candidate in this round
     * - Voter must have non-zero token balance (voting power)
     * - Admin voting period must not have ended
     *
     * State Changes:
     * - Records user's vote and voting power for this candidate
     * - Increments candidate's total support votes
     * - Updates user's last vote block for flash loan protection
     */
    function voteForNewAdmin(address candidate) external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        // 1. Active election check first
        require(govStorage.proposedAdminAddresses.length > 0, "No active admin election");
        require(block.number < govStorage.adminVoteDeadline, "Admin voting period has ended");
        require(govStorage.isAdminApplicant[candidate][govStorage.adminVoteId], "Address is not a candidate for this admin vote");

        uint256 voterBalance = ts.balances[msg.sender];

        require(voterBalance > 0, "No voting power");
        require(
            govStorage.adminVotesByUser[msg.sender][govStorage.adminVoteId][candidate] == 0,
            "Already voted for this candidate in the current round"
        );

        // 2. Flash loan / cooldown check
        require(LibVoxTokenStorage.canVote(ts, msg.sender), "Cannot vote: recent transfer or voting activity");

        // 3. Record vote
        govStorage.adminVotesByUser[msg.sender][govStorage.adminVoteId][candidate] = voterBalance;
        govStorage.totalVotesPerAdminCandidate[govStorage.adminVoteId][candidate] += voterBalance;
        // Mark that this voter has participated in the current election round.
        // Used by undoVotes() to skip the candidate loop for non-participants.
        govStorage.hasVotedForCandidate[msg.sender][govStorage.adminVoteId] = true;

        // 4. Stamp cooldown after all state changes
        ts.lastVoteBlock[msg.sender] = block.number;
    }

    // ============================================
    // ADMIN APPLICATION FUNCTIONS (PUBLIC)
    // ============================================

    /**
     * @notice Allows a user to apply as a candidate for platform admin
     * @dev Requires payment of an application fee in POL (Polygon native token).
     *      If this is the first applicant in the round, sets the voting deadline.
     *      Excess POL sent is refunded to the applicant.
     *
     * Requirements:
     * - Must pass flash loan protection (2 blocks since last transfer/vote)
     * - Must not have already applied in this admin vote round
     * - Must send at least the required application fee in POL
     *
     * Application Fee:
     * - Fee amount: adminApplicantFeeInPol * 10^18 (converts from POL to wei)
     * - Fee is added to the protocol's POL reward pool
     * - Excess payment is refunded immediately
     *
     * Emits: AdminApplicationSubmitted event with candidate address, vote ID, and fee paid
     *
     * State Changes:
     * - Marks applicant as candidate for this round
     * - Adds applicant to proposed admin addresses array
     * - Records applicant's index in the array
     * - Sets admin vote deadline (if first applicant)
     * - Increases total POL rewards by the fee amount
     *
     * @custom:security Reentrancy protection via nonReentrant modifier recommended
     */
    function applyAsNewAdmin(string memory storageId) external payable nonReentrant {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();

        // 1. Cheap state checks first — give accurate errors before any further work
        require(!govStorage.isAdminApplicant[msg.sender][govStorage.adminVoteId], "You have already declared yourself an applicant for this round.");
        require(govStorage.proposedAdminAddresses.length < LibVoxGovernanceStorage.MAX_ADMIN_CANDIDATES, "Candidate list full");

        // 2. Flash loan / cooldown check (canonical shared implementation)
        require(LibVoxTokenStorage.canVote(tokenStorage, msg.sender), "Cannot vote: recent transfer or voting activity");

        uint256 feeAmount = govStorage.currentQuotas.adminApplicantFeeInPolWei;
        require(msg.value >= feeAmount, "Insufficient POL sent to pay application fee");

        // ✅ NEW: Add incumbent admin when first candidate applies
        if (govStorage.proposedAdminAddresses.length == 0) {
            govStorage.adminVoteDeadline = block.number + govStorage.currentQuotas.adminVoteDeadlineInBlocks;

            LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();
            address currentOwner = diamondStorage.contractOwner;

            require(currentOwner != msg.sender, "Current owner cannot apply as new admin");

            // Add incumbent admin to candidates list
            govStorage.proposedAdminAddresses.push(currentOwner);
            govStorage.isAdminApplicant[currentOwner][govStorage.adminVoteId] = true;
            govStorage.adminCandidateIndex[currentOwner][govStorage.adminVoteId] = 0;
            govStorage.adminApplicantStorageId[currentOwner][govStorage.adminVoteId] = "INCUMBENT_ADMIN";
        }

        govStorage.isAdminApplicant[msg.sender][govStorage.adminVoteId] = true;
        govStorage.adminCandidateIndex[msg.sender][govStorage.adminVoteId] = govStorage.proposedAdminAddresses.length;
        govStorage.adminApplicantStorageId[msg.sender][govStorage.adminVoteId] = storageId; // ✅ NEW
        govStorage.proposedAdminAddresses.push(msg.sender);

        // Stamp lastVoteBlock so the application counts as recent activity
        tokenStorage.lastVoteBlock[msg.sender] = block.number;

        tokenStorage.totalAggregateRewardInPOLWei += feeAmount;

        if (msg.value > feeAmount) {
            uint256 excess = msg.value - feeAmount;
            (bool refundSuccess, ) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "Excess refund failed");
        }

        emit AdminApplicationSubmitted(msg.sender, govStorage.adminVoteId, feeAmount);
    }

    /**
     * @notice Allows a candidate to revoke their admin application
     * @dev Removes the candidate from the applicant list using swap-and-pop pattern for gas efficiency.
     *      Does NOT refund the application fee.
     *
     * Requirements:
     * - Caller must be a registered applicant for the current round
     *
     * Emits: AdminApplicationRevoked event with candidate address and vote ID
     *
     * State Changes:
     * - Marks applicant as no longer a candidate
     * - Removes applicant from proposed addresses array (swap-and-pop)
     * - Updates index mapping for the swapped candidate
     * - Deletes applicant's index mapping
     *
     * @custom:gas-optimization Uses swap-and-pop instead of shifting array elements
     */
    function revokeAdminApplication() external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();

        require(govStorage.isAdminApplicant[msg.sender][govStorage.adminVoteId], "You are not an applicant for this round");

        govStorage.isAdminApplicant[msg.sender][govStorage.adminVoteId] = false;

        uint256 index = govStorage.adminCandidateIndex[msg.sender][govStorage.adminVoteId];
        address[] storage applicants = govStorage.proposedAdminAddresses;
        uint256 lastIndex = applicants.length - 1;

        if (index < lastIndex) {
            applicants[index] = applicants[lastIndex];
            govStorage.adminCandidateIndex[applicants[index]][govStorage.adminVoteId] = index;
        }
        applicants.pop();

        delete govStorage.adminCandidateIndex[msg.sender][govStorage.adminVoteId];
        delete govStorage.adminApplicantStorageId[msg.sender][govStorage.adminVoteId]; // ✅ NEW

        emit AdminApplicationRevoked(msg.sender, govStorage.adminVoteId);
    }

    /**
     * @notice Finalizes the admin election and updates the contract owner
     * @dev Callable by anyone after the voting deadline has passed.
     *      Selects the candidate with the highest number of votes who meets the quorum.
     *      ✅ CHANGED: Only considers FOR votes, no AGAINST votes
     *
     * Selection Process:
     * 1. Calculate required support votes: totalSupply * voxAdminChangeQuorum / 100
     * 2. For each candidate, check if FOR votes >= required support votes (quorum met)
     * 3. Select candidate with highest FOR votes
     *
     * Requirements:
     * - Admin voting period must have ended
     * - At least one candidate must have cast votes and met the quorum requirement
     * - An election must be active (proposedAdminAddresses must be non-empty)
     * - Incumbent winning results in a no-op ownership change (event still emitted)
     *
     * Emits: NewAdminRatified event with old admin, new admin, and total votes
     *
     * State Changes:
     * - Updates contract owner in LibDiamond storage
     * - Updates admin status in LibVoxStorage (removes old, adds new)
     * - Increments admin vote ID (starts new election round)
     * - Clears proposed admin addresses array
     *
     * @custom:security High-stakes function - changes contract ownership
     */
    function ratifyNewAdmin() external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        require(block.number >= govStorage.adminVoteDeadline, "Admin voting period has not ended yet");

        address selectedCandidate;
        uint256 highestVotes = 0;

        uint256 requiredSupportVotesForApproval = (tokenStorage.totalSupply * govStorage.currentQuotas.voxAdminChangeQuorum) / 100;

        // ✅ SIMPLIFIED: Direct access without boolean
        for (uint256 i = 0; i < govStorage.proposedAdminAddresses.length; i++) {
            address candidate = govStorage.proposedAdminAddresses[i];
            uint256 forVotes = govStorage.totalVotesPerAdminCandidate[govStorage.adminVoteId][candidate];

            if (forVotes >= requiredSupportVotesForApproval) {
                if (forVotes > highestVotes) {
                    highestVotes = forVotes;
                    selectedCandidate = candidate;
                }
            }
        }

        require(govStorage.proposedAdminAddresses.length > 0, "No active admin election");
        require(highestVotes > 0, "No candidates met the quorum");

        address previousAdmin = diamondStorage.contractOwner;

        if (mainStorage.checkChapterAdminAddress[previousAdmin] == address(0)) {
            mainStorage.isAdmin[previousAdmin] = false;
        }

        mainStorage.isAdmin[selectedCandidate] = true;
        diamondStorage.contractOwner = selectedCandidate;
        govStorage.adminVoteId++;
        delete govStorage.proposedAdminAddresses;

        emit NewAdminRatified(previousAdmin, selectedCandidate, highestVotes);
    }

    // ============================================
    // CONFIGURATION FUNCTIONS (OWNER ONLY)
    // ============================================

    /**
     * @notice Updates the signing address for governance-related operations
     * @dev Only callable by the contract owner. The signing address is used for off-chain signature verification.
     *
     * @param newSigningAddress The new address to set as the signing authority
     *
     * Requirements:
     * - New address cannot be zero address
     *
     * Emits: SigningAddressUpdated event with the new address
     *
     * State Changes:
     * - Updates govStorage.signingAddress to the new value
     */
    function setSigningAddress(address newSigningAddress) external {
        LibDiamond.enforceIsContractOwner();
        _requireNonZeroAddress(newSigningAddress);
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        govStorage.signingAddress = newSigningAddress;
        emit SigningAddressUpdated(newSigningAddress);
    }

    /**
     * @notice Updates the storage provider address
     * @dev Only callable by the contract owner. The storage provider manages decentralized content storage.
     *
     * @param newStorageProvider The new storage provider address
     *
     * Requirements:
     * - New address cannot be zero address
     *
     * Emits: StorageProviderUpdated event with the new address
     *
     * State Changes:
     * - Updates govStorage.storageProviderAddress to the new value
     */
    function setStorageProviderAddress(address newStorageProvider) external {
        LibDiamond.enforceIsContractOwner();
        _requireNonZeroAddress(newStorageProvider);
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        govStorage.storageProviderAddress = newStorageProvider;
        emit StorageProviderUpdated(newStorageProvider);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    //
    // Public read aggregators (returnSigningAddress, returnStorageProviderAddress,
    // canVoteOnProposal, canVoteForAdmin, getCurrentGovernanceState,
    // getAdminElectionState, getAllCurrentQuotas, getProposalState,
    // getAdminApplicantStorageId, returnGovernanceStorage,
    // getProposedOwnersAndVotes, getFullGovernanceDashboard,
    // getUserPlatformBanBlockNumber) live on `GovernanceLensFacet`. Splitting
    // them out keeps this facet under the EIP-170 24,576 byte runtime cap.

    // ============================================
    // ADDITIONAL FUNCTIONS
    // ============================================

    /**
     * @notice Internal validation for quota proposals
     * @dev Ensures all proposed parameters are within acceptable ranges
     */
    function _validateQuotaProposal(LibVoxGovernanceStorage.QuotaProposal memory proposal) internal pure {
        // Quorums: 1-100%
        require(proposal.proposedQuotaProposalQuorum >= 1 && proposal.proposedQuotaProposalQuorum <= 100, "Quota proposal quorum must be 1-100%");
        require(proposal.proposedFacetProposalQuorum >= 1 && proposal.proposedFacetProposalQuorum <= 100, "Facet proposal quorum must be 1-100%");
        require(proposal.proposedVoxAdminChangeQuorum >= 1 && proposal.proposedVoxAdminChangeQuorum <= 100, "Admin change quorum must be 1-100%");

        // Storage provider percentage
        require(proposal.proposedStorageProviderPercentage <= 100, "Storage provider percentage cannot exceed 100%");

        // Admin claim percentage — must be <= 100 to prevent waterfall underflow in
        // Diamond.receive() and VoxTokenFacet deposit-processing paths, where
        // bountyPoolAmount = afterStorage - adminClaimAmount would revert on wrap.
        require(proposal.proposedVoxAdminClaimPercentage <= 100, "Admin claim percentage cannot exceed 100%");

        // Proposal durations: Must be reasonable (at least 1 day, max 30 days in blocks)
        require(proposal.proposedMinQuotaProposalDuration >= 43200, "Minimum quota proposal duration too short"); // ~1 day
        require(proposal.proposedMinQuotaProposalDuration <= proposal.proposedMaxQuotaProposalDuration, "Min duration cannot exceed max duration");

        require(proposal.proposedMinFacetProposalDuration >= 43200, "Minimum facet proposal duration too short"); // ~1 day
        require(
            proposal.proposedMinFacetProposalDuration <= proposal.proposedMaxFacetProposalDuration,
            "Min facet duration cannot exceed max duration"
        );

        // Admin parameters
        require(proposal.proposedAdminApplicantFeeInPolWei > 0, "Admin applicant fee must be positive");
        require(proposal.proposedAdminVoteDeadlineInBlocks >= 43200, "Admin vote deadline too short"); // 1 day min

        // Claim percentages must sum to 100
        require(
            proposal.proposedVoxClaimPercentage +
                proposal.proposedViewerClaimPercentage +
                proposal.proposedThirdParty1ClaimPercentage +
                proposal.proposedThirdParty2ClaimPercentage +
                proposal.proposedThirdParty3ClaimPercentage +
                proposal.proposedThirdParty4ClaimPercentage +
                proposal.proposedThirdParty5ClaimPercentage +
                proposal.proposedThirdParty6ClaimPercentage ==
                100,
            "Claim percentages must sum to 100"
        );
    }

    /**
     * @notice Gets current governance state — moved to GovernanceLensFacet.
     * @dev getCurrentGovernanceState, getAdminElectionState, getAllCurrentQuotas,
     *      getProposalState, getAdminApplicantStorageId, returnGovernanceStorage,
     *      and getProposedOwnersAndVotes were extracted to keep this facet
     *      under EIP-170. Selectors on the Diamond are unchanged.
     */

    // ============================================
    // USER BAN MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Bans a user from interacting with the platform
     * @dev Only contract owner can ban users. Records the block number when ban was applied
     * @param user Address of the user to ban
     *
     * Requirements:
     * - Caller must be contract owner
     * - User address must not be zero address
     * - User must not already be banned
     *
     * Effects:
     * - Sets isUserPlatformBanned[user] to true
     * - Records current block.number in userPlatformBanBlockNumber[user]
     * - Appends user to platformBannedUsersList (forward-enumeration roster)
     *   with a 1-based entry in platformBannedUsersIndex
     *
     * Emits: UserBanned event (0→1 transition guaranteed by the preceding
     *        `require(!isUserPlatformBanned[user])` guard)
     */
    function banUserFromPlatform(address user) external {
        LibVoxGovernanceStorage.enforceIsOwnerOrVoxAssistant();
        _requireNonZeroAddress(user);
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(!mainStorage.isUserPlatformBanned[user], "User is already banned");

        mainStorage.isUserPlatformBanned[user] = true;
        mainStorage.userPlatformBanBlockNumber[user] = block.number;

        // Global roster append (mirrors chapter-level bannedUsersArray pattern).
        // Index is 1-based: 0 ⇒ not present, k>0 ⇒ list[k-1] == user.
        mainStorage.platformBannedUsersList.push(user);
        mainStorage.platformBannedUsersIndex[user] = mainStorage.platformBannedUsersList.length;

        // Auto-cleanup: a banned user must not retain VoxAssistant privileges
        // or an exploitable pending invitation (which they could later accept).
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _getGovStorage();
        if (govStorage.isVoxAssistant[user]) {
            _removeVoxAssistantInternal(govStorage, user);
            emit VoxAssistantRemoved(user, msg.sender, block.timestamp);
        }
        if (govStorage.hasVoxAssistantInvite[user]) {
            _removeVoxAssistantInvitationInternal(govStorage, user);
            emit VoxAssistantInvitationRevoked(user, msg.sender, block.timestamp);
        }

        emit UserBanned(user, block.number);
    }

    /**
     * @notice Unbans a previously banned user
     * @dev Only contract owner can unban users
     * @param user Address of the user to unban
     *
     * Requirements:
     * - Caller must be contract owner
     * - User address must not be zero address
     * - User must currently be banned
     *
     * Effects:
     * - Sets isUserPlatformBanned[user] to false
     * - Keeps the ban block number for historical record
     * - Removes user from platformBannedUsersList via swap-and-pop and clears
     *   platformBannedUsersIndex[user]
     *
     * Emits: UserUnbanned event (1→0 transition guaranteed by the preceding
     *        `require(isUserPlatformBanned[user])` guard)
     */
    function unbanUserFromPlatform(address user) external {
        LibVoxGovernanceStorage.enforceIsOwnerOrVoxAssistant();
        _requireNonZeroAddress(user);
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(mainStorage.isUserPlatformBanned[user], "User is not banned");

        mainStorage.isUserPlatformBanned[user] = false;

        // Global roster swap-and-pop. Invariant: the banned-flag flip above
        // guarantees `idx != 0` here; an assert would be redundant with the
        // require. If this ever becomes reachable with idx==0, storage has
        // been corrupted by a writer bypassing these two functions.
        uint256 idx = mainStorage.platformBannedUsersIndex[user]; // 1-based
        uint256 lastIdx = mainStorage.platformBannedUsersList.length; // 1-based last
        if (idx != lastIdx) {
            address lastUser = mainStorage.platformBannedUsersList[lastIdx - 1];
            mainStorage.platformBannedUsersList[idx - 1] = lastUser;
            mainStorage.platformBannedUsersIndex[lastUser] = idx;
        }
        mainStorage.platformBannedUsersList.pop();
        delete mainStorage.platformBannedUsersIndex[user];

        emit UserUnbanned(user, block.number);
    }

    /**
     * @notice Gets the block number when a user was platform-banned
     * @dev Renamed from `getUserBanBlockNumber` for naming parity with the
     *      platform-vs-chapter split across the codebase. ABI-breaking — the
     *      frontend agent has been notified.
     * @param user Address to check
     * @return uint256 Block number when user was banned (0 if never banned)
     *
     * Use Cases:
     * - Historical tracking
     * - Admin audit logs
     * - Ban appeal systems
     */
    // getUserPlatformBanBlockNumber moved to GovernanceLensFacet.

    // ============================================
    // COMPOSITE VIEW FUNCTIONS
    // ============================================

    // getFullGovernanceDashboard moved to GovernanceLensFacet (along with all
    // other read aggregators) to keep this facet under EIP-170. The Diamond
    // ABI is unchanged.

    /**
     * @notice Receive function to handle edge case of direct payments to facet address
     * @dev This only executes when POL is sent directly to facet contract address.
     *      When POL is sent to Diamond address, Diamond.sol's receive() handles it.
     *      This forwards any accidental/direct payments to the Diamond for proper processing.
     */
    receive() external payable {
        if (msg.value > 0) {
            require(diamondAddressForDirectCalls != address(0), "Diamond address not set");

            (bool success, ) = payable(diamondAddressForDirectCalls).call{value: msg.value}("");
            require(success, "Transfer to Diamond failed");
        }
    }

    // ============================================
    // VOXASSISTANT INTERNAL HELPERS
    // ============================================
    //
    // The full VoxAssistant lifecycle (invite/accept/decline/revoke/remove/resign
    // + view helpers) lives on `VoxAssistantFacet`. These two internal helpers
    // remain on the governance facet because `banUserFromPlatform` invokes them
    // for auto-cleanup when a banned user is also a VoxAssistant or has a
    // pending invitation. Keeping them here avoids a cross-facet self-call.

    /**
     * @dev Swap-and-pop removal from the active `voxAssistants` array, clearing
     *      associated mapping state. No events emitted — caller emits the
     *      appropriate event (`VoxAssistantRemoved` / `VoxAssistantResigned` /
     *      auto-remove branch of `banUserFromPlatform`).
     */
    function _removeVoxAssistantInternal(LibVoxGovernanceStorage.GovernanceStorage storage govStorage, address assistant) internal {
        uint256 idx = govStorage.voxAssistantIndex[assistant]; // 1-based
        uint256 lastIdx = govStorage.voxAssistants.length; // 1-based index of last element

        if (idx != lastIdx) {
            address last = govStorage.voxAssistants[lastIdx - 1];
            govStorage.voxAssistants[idx - 1] = last;
            govStorage.voxAssistantIndex[last] = idx;
        }
        govStorage.voxAssistants.pop();

        delete govStorage.isVoxAssistant[assistant];
        delete govStorage.voxAssistantIndex[assistant];
    }

    /**
     * @dev Swap-and-pop removal from the pending `voxAssistantInvitations` array,
     *      clearing associated mapping state. No events emitted — caller emits the
     *      appropriate event.
     */
    function _removeVoxAssistantInvitationInternal(LibVoxGovernanceStorage.GovernanceStorage storage govStorage, address candidate) internal {
        uint256 idx = govStorage.voxAssistantInviteIndex[candidate]; // 1-based
        uint256 lastIdx = govStorage.voxAssistantInvitations.length; // 1-based index of last

        if (idx != lastIdx) {
            address last = govStorage.voxAssistantInvitations[lastIdx - 1];
            govStorage.voxAssistantInvitations[idx - 1] = last;
            govStorage.voxAssistantInviteIndex[last] = idx;
        }
        govStorage.voxAssistantInvitations.pop();

        delete govStorage.hasVoxAssistantInvite[candidate];
        delete govStorage.voxAssistantInviteIndex[candidate];
        delete govStorage.voxAssistantInviteSentAt[candidate];
    }
}
