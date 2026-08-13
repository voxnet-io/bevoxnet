// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";
import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";
import {LibVoxViewStructs} from "../libraries/LibVoxViewStructs.sol";

/**
 * @title GovernanceLensFacet
 * @author Vox Team
 * @notice View-only Diamond facet bundling governance read aggregators.
 * @dev Extracted from VoxGovernanceFacet to keep that facet under the
 *      EIP-170 24,576 byte runtime cap. All functions read governance state
 *      directly via `LibVoxGovernanceStorage` — they run in the Diamond's
 *      delegatecall context, so storage layout matches 1:1 with the writer
 *      facet. Selectors on the Diamond are unchanged.
 *
 *      Functions moved here: getCurrentGovernanceState, getAdminElectionState,
 *      getAllCurrentQuotas, getProposalState, getAdminApplicantStorageId,
 *      returnGovernanceStorage, getProposedOwnersAndVotes, getFullGovernanceDashboard,
 *      canVoteOnProposal, canVoteForAdmin, returnSigningAddress, returnStorageProviderAddress,
 *      getUserPlatformBanBlockNumber.
 */
contract GovernanceLensFacet {
    /// @dev Stored solely for parity with the deploy loop's
    ///      `Facet.deploy(diamondAddress)` invariant.
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    // ============================================
    // FRONTEND-AGGREGATOR STRUCTS
    // ============================================

    struct VoxAssistantSnapshot {
        // ── per-user (zero if user == address(0)) ──
        bool invitePending;
        uint256 inviteSentAt;
        bool userIsActiveVoxAssistant;
        // ── roster (always populated) ──
        uint256 totalCount;
        address[] activeVoxAssistants;
        address[] pendingVoxAssistantInvitations;
    }

    struct ProposalVotingSnapshot {
        // raw getProposalState tuple shape
        uint8 stateCode;
        bool canRatify;
        // per-user
        bool userCanVoteNow;
    }

    function _gov() internal pure returns (LibVoxGovernanceStorage.GovernanceStorage storage) {
        return LibVoxGovernanceStorage.governanceStorage();
    }

    // ============================================
    // SIMPLE GETTERS
    // ============================================

    /// @notice Returns the current signing address used for governance signature verification.
    function returnSigningAddress() public view returns (address) {
        return _gov().signingAddress;
    }

    /// @notice Returns the storage provider address that manages decentralized content.
    function returnStorageProviderAddress() public view returns (address) {
        return _gov().storageProviderAddress;
    }

    /// @notice Block number when a user was platform-banned (0 if never banned).
    function getUserPlatformBanBlockNumber(address user) public view returns (uint256) {
        return LibVoxStorage.mainStorage().userPlatformBanBlockNumber[user];
    }

    /// @notice Storage ID for a specific admin applicant in the current vote round.
    function getAdminApplicantStorageId(address applicant) external view returns (string memory storageId) {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();
        return gs.adminApplicantStorageId[applicant][gs.adminVoteId];
    }

    /// @notice Returns all current quota values in one call.
    function getAllCurrentQuotas() external view returns (LibVoxGovernanceStorage.CurrentQuotas memory currentQuotas) {
        return _gov().currentQuotas;
    }

    // ============================================
    // VOTING ELIGIBILITY CHECKS
    // ============================================

    /**
     * @notice Checks if an address can currently vote on the active proposal.
     * @param voter The address to check
     * @return eligible True if the address can vote right now
     */
    function canVoteOnProposal(address voter) external view returns (bool eligible) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        if (!gs.votingStruct.isProposalActive) return false;
        if (block.number >= gs.votingStruct.votingDeadline) return false;
        if (gs.hasVotedOnProposal[voter][gs.votingStruct.currentProposalId]) return false;
        if (ts.balances[voter] == 0) return false;
        if (block.number <= ts.lastTransferBlock[voter] + 1) return false;
        if (block.number <= ts.lastVoteBlock[voter] + 1) return false;
        return true;
    }

    /**
     * @notice Checks if an address can vote for a specific admin candidate.
     * @param voter The address to check
     * @param candidate The admin candidate
     * @return eligible True if the address can vote for this candidate right now
     */
    function canVoteForAdmin(address voter, address candidate) external view returns (bool eligible) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        if (!gs.isAdminApplicant[candidate][gs.adminVoteId]) return false;
        if (block.number >= gs.adminVoteDeadline) return false;
        if (ts.balances[voter] == 0) return false;
        if (gs.adminVotesByUser[voter][gs.adminVoteId][candidate] != 0) return false;
        if (block.number <= ts.lastTransferBlock[voter] + 1) return false;
        if (block.number <= ts.lastVoteBlock[voter] + 1) return false;
        return true;
    }

    // ============================================
    // STATE AGGREGATORS
    // ============================================

    /// @notice Current proposal voting state.
    function getCurrentGovernanceState()
        external
        view
        returns (
            bool proposalActive,
            uint256 proposalId,
            LibVoxGovernanceStorage.ProposalType proposalType,
            uint256 votingDeadline,
            uint256 supportVotes,
            uint256 opposeVotes
        )
    {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();
        return (
            gs.votingStruct.isProposalActive,
            gs.votingStruct.currentProposalId,
            gs.votingStruct.proposalType,
            gs.votingStruct.votingDeadline,
            gs.votingStruct.totalSupportVotesForCurrentProposal,
            gs.votingStruct.totalOpposeVotesForCurrentProposal
        );
    }

    /// @notice Current admin election state with candidate balances.
    function getAdminElectionState()
        external
        view
        returns (address[] memory candidates, uint256[] memory balances, uint256 voteId, uint256 deadline, uint256 candidateCount)
    {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        candidates = gs.proposedAdminAddresses;
        candidateCount = candidates.length;
        balances = new uint256[](candidateCount);
        for (uint256 i = 0; i < candidateCount; i++) {
            balances[i] = ts.balances[candidates[i]];
        }
        voteId = gs.adminVoteId;
        deadline = gs.adminVoteDeadline;
    }

    /**
     * @notice Returns the current state of the active proposal.
     * @return state 0=Active, 1=Passed, 2=Failed, 3=Expired, 4=None
     * @return canRatify Whether the proposal can be successfully ratified
     */
    function getProposalState() external view returns (uint8 state, bool canRatify) {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        if (!gs.votingStruct.isProposalActive) {
            return (4, false);
        }

        if (block.number < gs.votingStruct.votingDeadline) {
            return (0, false);
        }

        uint256 support = gs.votingStruct.totalSupportVotesForCurrentProposal;

        uint256 requiredQuorum;
        if (gs.votingStruct.proposalType == LibVoxGovernanceStorage.ProposalType.QuotaProposal) {
            requiredQuorum = (ts.totalSupply * gs.currentQuotas.QuotaProposalQuorum) / 100;
        } else {
            requiredQuorum = (ts.totalSupply * gs.currentQuotas.FacetProposalQuorum) / 100;
        }

        // Item 6: quorum measured on support (FOR) votes only — mirrors ratifyUpgrade().
        if (support < requiredQuorum) {
            return (2, false);
        }

        if (support > gs.votingStruct.totalOpposeVotesForCurrentProposal) {
            return (1, true);
        }

        return (2, false);
    }

    /// @notice Full governance storage snapshot including admin applicant storage IDs.
    function returnGovernanceStorage()
        public
        view
        returns (
            LibVoxGovernanceStorage.VotingStruct memory votingStruct,
            IDiamondCut.FacetCut[] memory proposedFacets,
            LibVoxGovernanceStorage.QuotaProposal memory quotaProposal,
            LibVoxGovernanceStorage.CurrentQuotas memory currentQuotas,
            address[] memory proposedAdminAddresses,
            uint256 adminVoteId,
            uint256 adminVoteDeadline,
            string[] memory adminStorageIds
        )
    {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        uint256 length = gs.proposedAdminAddresses.length;
        adminStorageIds = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            address applicant = gs.proposedAdminAddresses[i];
            adminStorageIds[i] = gs.adminApplicantStorageId[applicant][gs.adminVoteId];
        }

        return (
            gs.votingStruct,
            gs.proposedNewFacets,
            gs.quotaProposal,
            gs.currentQuotas,
            gs.proposedAdminAddresses,
            gs.adminVoteId,
            gs.adminVoteDeadline,
            adminStorageIds
        );
    }

    /// @notice Proposed owners + their FOR votes + storage IDs in parallel arrays.
    function getProposedOwnersAndVotes()
        external
        view
        returns (address[] memory proposedOwners, uint256[] memory forVotesArray, string[] memory storageIds)
    {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        uint256 length = gs.proposedAdminAddresses.length;

        proposedOwners = new address[](length);
        forVotesArray = new uint256[](length);
        storageIds = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            address ownerAddress = gs.proposedAdminAddresses[i];
            proposedOwners[i] = ownerAddress;
            forVotesArray[i] = gs.totalVotesPerAdminCandidate[gs.adminVoteId][ownerAddress];
            storageIds[i] = gs.adminApplicantStorageId[ownerAddress][gs.adminVoteId];
        }
    }

    /**
     * @notice Consolidated governance dashboard in a single call.
     * @dev Combines owner(), getTotalValueAndRewardDue(), returnGovernanceStorage(),
     *      and getProposedOwnersAndVotes() into one RPC round-trip.
     *      Designed for off-chain reads (eth_call). Not intended for on-chain composition.
     * @param user Address for per-user reward calculation. Pass address(0) for no user context.
     * @return dashboard GovernanceDashboard struct with all governance state
     */
    function getFullGovernanceDashboard(address user) external view returns (LibVoxViewStructs.GovernanceDashboard memory dashboard) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        dashboard.owner = ds.contractOwner;

        dashboard.totalPOLValue = address(this).balance;
        if (ts.usdcTokenAddress != address(0)) {
            dashboard.totalUSDCValue = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
        }

        if (user != address(0)) {
            uint256 userBalance = ts.balances[user];
            if (userBalance > 0 && ts.totalSupply > 0) {
                dashboard.polRewardDue = ts.unclaimedPOL[user];
                if (ts.totalAggregateRewardInPOLWei > ts.lastRewardClaimInPOL[user]) {
                    dashboard.polRewardDue += (userBalance * (ts.totalAggregateRewardInPOLWei - ts.lastRewardClaimInPOL[user])) / ts.totalSupply;
                }

                dashboard.usdcRewardDue = ts.unclaimedUSDC[user];
                if (ts.totalAggregateRewardInUSDC > ts.lastRewardClaimInUSDC[user]) {
                    dashboard.usdcRewardDue += (userBalance * (ts.totalAggregateRewardInUSDC - ts.lastRewardClaimInUSDC[user])) / ts.totalSupply;
                }
            } else {
                dashboard.polRewardDue = ts.unclaimedPOL[user];
                dashboard.usdcRewardDue = ts.unclaimedUSDC[user];
            }
        }

        dashboard.votingStruct = gs.votingStruct;
        dashboard.quotaProposal = gs.quotaProposal;
        dashboard.currentQuotas = gs.currentQuotas;
        dashboard.adminVoteId = gs.adminVoteId;
        dashboard.adminVoteDeadline = gs.adminVoteDeadline;

        uint256 length = gs.proposedAdminAddresses.length;
        dashboard.proposedOwners = new address[](length);
        dashboard.forVotesArray = new uint256[](length);
        dashboard.ownerStorageIds = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            address candidate = gs.proposedAdminAddresses[i];
            dashboard.proposedOwners[i] = candidate;
            dashboard.forVotesArray[i] = gs.totalVotesPerAdminCandidate[gs.adminVoteId][candidate];
            dashboard.ownerStorageIds[i] = gs.adminApplicantStorageId[candidate][gs.adminVoteId];
        }
    }

    // ============================================
    // PROMPT 8 — getVoxAssistantSnapshot(user)
    // ============================================

    /**
     * @notice Single-call aggregator for VoxAssistant roster + per-user invite/active state.
     * @dev Reads governance storage directly. Live VoxAssistant write paths
     *      remain on `VoxAssistantFacet`; this lens only reads. Pass
     *      `address(0)` to skip per-user fields (they default to zero/false).
     */
    function getVoxAssistantSnapshot(address user) external view returns (VoxAssistantSnapshot memory snapshot) {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();

        snapshot.activeVoxAssistants = gs.voxAssistants;
        snapshot.pendingVoxAssistantInvitations = gs.voxAssistantInvitations;
        snapshot.totalCount = gs.voxAssistants.length;

        if (user != address(0)) {
            snapshot.invitePending = gs.hasVoxAssistantInvite[user];
            snapshot.inviteSentAt = gs.voxAssistantInviteSentAt[user];
            snapshot.userIsActiveVoxAssistant = gs.isVoxAssistant[user];
        }
    }

    // ============================================
    // PROMPT 9 — getProposalVotingSnapshot(user)
    // ============================================

    /**
     * @notice Combined `getProposalState` + per-user `canVoteOnProposal` snapshot.
     * @dev `stateCode`/`canRatify` mirror `getProposalState()` exactly. Pass
     *      `address(0)` for `user` to skip the eligibility check (returns false).
     */
    function getProposalVotingSnapshot(address user) external view returns (ProposalVotingSnapshot memory snapshot) {
        LibVoxGovernanceStorage.GovernanceStorage storage gs = _gov();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        // ── stateCode + canRatify (mirrors getProposalState) ──
        if (!gs.votingStruct.isProposalActive) {
            snapshot.stateCode = 4;
        } else if (block.number < gs.votingStruct.votingDeadline) {
            snapshot.stateCode = 0;
        } else {
            uint256 support = gs.votingStruct.totalSupportVotesForCurrentProposal;
            uint256 requiredQuorum;
            if (gs.votingStruct.proposalType == LibVoxGovernanceStorage.ProposalType.QuotaProposal) {
                requiredQuorum = (ts.totalSupply * gs.currentQuotas.QuotaProposalQuorum) / 100;
            } else {
                requiredQuorum = (ts.totalSupply * gs.currentQuotas.FacetProposalQuorum) / 100;
            }

            // Item 6: quorum measured on support (FOR) votes only — mirrors ratifyUpgrade().
            if (support < requiredQuorum) {
                snapshot.stateCode = 2;
            } else if (support > gs.votingStruct.totalOpposeVotesForCurrentProposal) {
                snapshot.stateCode = 1;
                snapshot.canRatify = true;
            } else {
                snapshot.stateCode = 2;
            }
        }

        // ── userCanVoteNow (mirrors canVoteOnProposal) ──
        if (user == address(0)) return snapshot;
        if (!gs.votingStruct.isProposalActive) return snapshot;
        if (block.number >= gs.votingStruct.votingDeadline) return snapshot;
        if (gs.hasVotedOnProposal[user][gs.votingStruct.currentProposalId]) return snapshot;
        if (ts.balances[user] == 0) return snapshot;
        if (block.number <= ts.lastTransferBlock[user] + 1) return snapshot;
        if (block.number <= ts.lastVoteBlock[user] + 1) return snapshot;
        snapshot.userCanVoteNow = true;
    }
}
