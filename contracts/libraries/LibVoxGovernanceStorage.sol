// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "./LibDiamond.sol";

library LibVoxGovernanceStorage {
    bytes32 constant STORAGE_POSITION = keccak256("vox.governance.storage");

    /// @notice Maximum number of admin candidates allowed per election round (includes incumbent)
    uint256 constant MAX_ADMIN_CANDIDATES = 100;

    enum ProposalType {
        QuotaProposal, // Represents a quota proposal
        FacetProposal // Represents a facet proposal
    }

    struct QuotaProposal {
        uint256 proposedVoxClaimPercentage;
        uint256 proposedViewerClaimPercentage;
        uint256 proposedThirdParty1ClaimPercentage;
        uint256 proposedThirdParty2ClaimPercentage;
        uint256 proposedThirdParty3ClaimPercentage;
        uint256 proposedThirdParty4ClaimPercentage;
        uint256 proposedThirdParty5ClaimPercentage;
        uint256 proposedThirdParty6ClaimPercentage;
        uint256 proposedVoxAdminClaimPercentage;
        uint256 proposedVoxAdminChangeQuorum;
        uint256 proposedQuotaProposalQuorum;
        uint256 proposedFacetProposalQuorum;
        uint256 proposedStorageProviderPercentage;
        uint256 proposedAdminApplicantFeeInPolWei;
        uint256 proposedAdminVoteDeadlineInBlocks;
        // ✅ NEW: Proposal duration constraints
        uint256 proposedMinQuotaProposalDuration;
        uint256 proposedMaxQuotaProposalDuration;
        uint256 proposedMinFacetProposalDuration;
        uint256 proposedMaxFacetProposalDuration;
    }

    struct CurrentQuotas {
        uint256 voxClaimPercentage;
        uint256 viewerClaimPercentage;
        uint256 thirdParty1ClaimPercentage;
        uint256 thirdParty2ClaimPercentage;
        uint256 thirdParty3ClaimPercentage;
        uint256 thirdParty4ClaimPercentage;
        uint256 thirdParty5ClaimPercentage;
        uint256 thirdParty6ClaimPercentage;
        uint256 voxAdminClaimPercentage;
        uint256 voxAdminChangeQuorum;
        uint256 QuotaProposalQuorum;
        uint256 FacetProposalQuorum;
        uint256 storageProviderPercentage;
        uint256 adminApplicantFeeInPolWei;
        uint256 adminVoteDeadlineInBlocks;
        // ✅ NEW: Proposal duration constraints
        uint256 minQuotaProposalDuration;
        uint256 maxQuotaProposalDuration;
        uint256 minFacetProposalDuration;
        uint256 maxFacetProposalDuration;
    }

    struct VotingStruct {
        uint256 currentProposalId;
        bool isProposalActive;
        ProposalType proposalType;
        uint256 minVotingDuration;
        uint256 votingDeadline;
        uint256 totalSupportVotesForCurrentProposal;
        uint256 totalOpposeVotesForCurrentProposal;
    }

    struct GovernanceStorage {
        bool initialized;
        VotingStruct votingStruct;
        IDiamondCut.FacetCut[] proposedNewFacets;
        mapping(address => mapping(uint256 => bool)) hasVotedOnProposal;
        mapping(address => mapping(uint256 => mapping(bool => uint256))) votesByUser;
        QuotaProposal quotaProposal;
        CurrentQuotas currentQuotas;
        // Admin Voting Structure - ✅ UPDATED: Removed boolean from mappings
        address[] proposedAdminAddresses;
        uint256 adminVoteId;
        uint256 adminVoteDeadline;
        address storageProviderAddress;
        address signingAddress;
        mapping(address => mapping(uint256 => bool)) isAdminApplicant;
        // ✅ CHANGED: Only track FOR votes (removed bool key)
        mapping(address => mapping(uint256 => mapping(address => uint256))) adminVotesByUser; // voter => voteId => candidate => votes
        mapping(uint256 => mapping(address => uint256)) totalVotesPerAdminCandidate; // voteId => candidate => total votes
        mapping(address => mapping(uint256 => uint256)) adminCandidateIndex;
        mapping(address => mapping(uint256 => bool)) hasVotedForCandidate;
        // ✅ NEW: Storage IDs for admin applicants
        mapping(address => mapping(uint256 => string)) adminApplicantStorageId;
        // ✅ NEW: Initializer for governance-voted facet upgrades
        address proposedInit;
        bytes proposedInitCalldata;
        // ============================================
        // VoxAssistant role registry (append-only)
        // ============================================
        // Active assistants
        address[] voxAssistants;
        mapping(address => bool) isVoxAssistant;
        mapping(address => uint256) voxAssistantIndex; // 1-based; 0 = not present
        // Pending invitations (opt-in pattern, mirrors VoxChapter SubMod invites)
        address[] voxAssistantInvitations;
        mapping(address => bool) hasVoxAssistantInvite;
        mapping(address => uint256) voxAssistantInviteIndex; // 1-based; 0 = not present
        mapping(address => uint256) voxAssistantInviteSentAt;
    }

    function governanceStorage() internal pure returns (GovernanceStorage storage gs) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            gs.slot := position
        }
    }

    /**
     * @notice Reverts unless msg.sender is the Diamond contract owner OR an active VoxAssistant.
     * @dev Used by moderation functions (platformBanChapter/platformUnbanChapter/banUserFromPlatform/
     *      unbanUserFromPlatform) to permit a limited delegated role. Role-granting
     *      functions MUST continue to use LibDiamond.enforceIsContractOwner() directly.
     */
    function enforceIsOwnerOrVoxAssistant() internal view {
        if (msg.sender == LibDiamond.diamondStorage().contractOwner) {
            return;
        }
        require(governanceStorage().isVoxAssistant[msg.sender], "VOXA");
    }
}
