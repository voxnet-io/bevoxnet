// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibVoxGovernanceStorage} from "./LibVoxGovernanceStorage.sol";

/**
 * @title LibVoxViewStructs
 * @notice Shared struct definitions for composite view functions
 * @dev Imported by VoxGovernanceFacet and VoxFacet for their
 *      consolidated view functions. Designed for off-chain reads (eth_call).
 */
library LibVoxViewStructs {
    /**
     * @notice Consolidated governance dashboard data
     * @dev Returned by getFullGovernanceDashboard(). Combines data from
     *      owner(), getTotalValueAndRewardDue(), returnGovernanceStorage(),
     *      and getProposedOwnersAndVotes() into a single call.
     *
     *      FacetCut[] proposedFacets is intentionally excluded —
     *      the frontend does not consume it and the nested bytes4[]
     *      adds encoding complexity.
     *
     *      proposedAdminAddresses from governance storage is deduplicated —
     *      proposedOwners + forVotesArray + ownerStorageIds is the richer
     *      canonical source from getProposedOwnersAndVotes().
     */
    struct GovernanceDashboard {
        address owner;
        uint256 totalPOLValue;
        uint256 totalUSDCValue;
        uint256 polRewardDue;
        uint256 usdcRewardDue;
        LibVoxGovernanceStorage.VotingStruct votingStruct;
        LibVoxGovernanceStorage.QuotaProposal quotaProposal;
        LibVoxGovernanceStorage.CurrentQuotas currentQuotas;
        address[] proposedOwners;
        uint256[] forVotesArray;
        string[] ownerStorageIds;
        uint256 adminVoteId;
        uint256 adminVoteDeadline;
    }

    /**
     * @notice Consolidated user context across platform and chapter
     * @dev Returned by getFullUserContext(). Combines data from
     *      owner(), getUserAdminContext(), and chapter-level queries.
     */
    struct FullUserContext {
        address voxAdmin;
        bool isVoxAdmin;
        address userChapterContractAddress;
        bool isUserBannedPlatform;
        bool isUserBannedFromChapter;
        address chapterOwner;
        address[] subModsList;
    }

    /**
     * @notice Consolidated chapter context by name
     * @dev Returned by getChapterContext(). Combines data from
     *      chapterExists(), getChapterAddress(), and chapter-level queries.
     */
    struct ChapterContext {
        bool exists;
        address chapterContractAddress;
        address chapterOwner;
        address[] subModsList;
        bool isChapterBanned;
        bool isChapterRemoved;
    }
}
