// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";

/**
 * @title VoxAssistantFacet
 * @author Vox Team
 * @notice Manages the VoxAssistant role: invitation lifecycle (invite / accept /
 *         decline / revoke) and active-role lifecycle (remove / resign), plus
 *         read-only views over the active and pending rosters.
 * @dev Extracted from VoxGovernanceFacet to keep the governance facet under
 *      the EIP-170 24,576 byte runtime cap. Storage layout is unchanged:
 *      everything still reads/writes `LibVoxGovernanceStorage`. ABI on the
 *      Diamond is unchanged — selectors simply route to this facet now.
 *
 *      Auto-cleanup of VoxAssistant state when a user is platform-banned still
 *      lives in `VoxGovernanceFacet.banUserFromPlatform` because the bulk
 *      of the saved bytecode here is the public-function dispatch, not the
 *      ~30-line internal helpers. Both facets therefore declare the shared
 *      `VoxAssistantRemoved` and `VoxAssistantInvitationRevoked` events — same
 *      signature, same topic hash, transparent to off-chain subscribers.
 */
contract VoxAssistantFacet {
    /// @dev Stored solely for parity with the deploy loop's
    ///      `Facet.deploy(diamondAddress)` invariant. Not used at runtime —
    ///      delegate-called from the Diamond means address(this) == Diamond.
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when the VOX Admin invites a candidate to the VoxAssistant role
    event VoxAssistantInvited(address indexed candidate, address indexed invitedBy, uint256 timestamp);

    /// @notice Emitted when an invitee accepts the VoxAssistant invitation and activates the role
    event VoxAssistantInvitationAccepted(address indexed assistant, uint256 timestamp);

    /// @notice Emitted when an invitee declines the VoxAssistant invitation
    event VoxAssistantInvitationDeclined(address indexed candidate, uint256 timestamp);

    /// @notice Emitted when the VOX Admin revokes a pending VoxAssistant invitation
    /// @dev Also declared on VoxGovernanceFacet for the auto-cleanup branch in banUserFromPlatform; same topic hash.
    event VoxAssistantInvitationRevoked(address indexed candidate, address indexed revokedBy, uint256 timestamp);

    /// @notice Emitted when a VoxAssistant is removed by the VOX Admin (or auto-removed on platform ban)
    /// @dev Also declared on VoxGovernanceFacet for the auto-cleanup branch in banUserFromPlatform; same topic hash.
    event VoxAssistantRemoved(address indexed assistant, address indexed removedBy, uint256 timestamp);

    /// @notice Emitted when a VoxAssistant resigns from the role
    event VoxAssistantResigned(address indexed assistant, uint256 timestamp);

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    function _requireNonZeroAddress(address addr) internal pure {
        require(addr != address(0), "Z");
    }

    function _gov() internal pure returns (LibVoxGovernanceStorage.GovernanceStorage storage) {
        return LibVoxGovernanceStorage.governanceStorage();
    }

    // ============================================
    // ROLE MANAGEMENT
    // ============================================
    //
    // Opt-in invitation flow (mirrors VoxChapter.inviteSubMod / accept / decline / revoke):
    //   1. VOX Admin calls inviteVoxAssistant(candidate)       — pending invitation
    //   2a. Candidate calls acceptVoxAssistantInvitation()    — role activated
    //   2b. Candidate calls declineVoxAssistantInvitation()   — invitation cleared
    //   2c. VOX Admin calls revokeVoxAssistantInvitation(...)  — invitation cleared
    //
    // Once active, a VoxAssistant has a limited moderation power set:
    //   - VoxFacet.platformBanChapter / platformUnbanChapter
    //   - VoxGovernanceFacet.banUserFromPlatform / unbanUserFromPlatform
    // No fund movement, no setters, no governance, no role management, no diamond cuts.
    //
    // Role-granting functions (invite / revoke / remove) are VOX-Admin-only.
    // Self-service functions (accept / decline / resign) gate on caller's own state.

    /**
     * @notice Invite a candidate to become a VoxAssistant.
     * @dev VOX-Admin-only. Creates a pending invitation; the candidate must call
     *      `acceptVoxAssistantInvitation()` to activate the role. Reverts if the
     *      candidate is the VOX Admin themselves, already active, already invited,
     *      or currently platform-banned.
     * @param candidate Address to invite
     */
    function inviteVoxAssistant(address candidate) external {
        LibDiamond.enforceIsContractOwner();
        _requireNonZeroAddress(candidate);
        require(candidate != msg.sender, "SELF");

        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(!govStorage.isVoxAssistant[candidate], "VOXA");
        require(!govStorage.hasVoxAssistantInvite[candidate], "INV");

        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(!mainStorage.isUserPlatformBanned[candidate], "BAN");

        govStorage.voxAssistantInvitations.push(candidate);
        govStorage.voxAssistantInviteIndex[candidate] = govStorage.voxAssistantInvitations.length; // 1-based
        govStorage.hasVoxAssistantInvite[candidate] = true;
        govStorage.voxAssistantInviteSentAt[candidate] = block.timestamp;

        emit VoxAssistantInvited(candidate, msg.sender, block.timestamp);
    }

    /**
     * @notice Revoke a pending VoxAssistant invitation.
     * @dev VOX-Admin-only. Only valid while the invitation is still pending.
     * @param candidate Address whose invitation to revoke
     */
    function revokeVoxAssistantInvitation(address candidate) external {
        LibDiamond.enforceIsContractOwner();
        _requireNonZeroAddress(candidate);

        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(govStorage.hasVoxAssistantInvite[candidate], "INV");

        _removeInvitation(govStorage, candidate);

        emit VoxAssistantInvitationRevoked(candidate, msg.sender, block.timestamp);
    }

    /**
     * @notice Accept a pending VoxAssistant invitation and activate the role.
     * @dev Self-service; caller must be the invitee. Re-validates platform-ban status
     *      and checks the invitee is not the current VOX Admin (defensive guard against
     *      race conditions where the invitee becomes VOX Admin via election/transfer
     *      between invite and accept).
     */
    function acceptVoxAssistantInvitation() external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(govStorage.hasVoxAssistantInvite[msg.sender], "INV");
        require(msg.sender != LibDiamond.diamondStorage().contractOwner, "VOX");

        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(!mainStorage.isUserPlatformBanned[msg.sender], "BAN");

        // Clear invitation first, then activate.
        _removeInvitation(govStorage, msg.sender);

        govStorage.voxAssistants.push(msg.sender);
        govStorage.voxAssistantIndex[msg.sender] = govStorage.voxAssistants.length; // 1-based
        govStorage.isVoxAssistant[msg.sender] = true;

        emit VoxAssistantInvitationAccepted(msg.sender, block.timestamp);
    }

    /**
     * @notice Decline a pending VoxAssistant invitation.
     * @dev Self-service; caller must be the invitee.
     */
    function declineVoxAssistantInvitation() external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(govStorage.hasVoxAssistantInvite[msg.sender], "INV");

        _removeInvitation(govStorage, msg.sender);

        emit VoxAssistantInvitationDeclined(msg.sender, block.timestamp);
    }

    /**
     * @notice Remove an active VoxAssistant.
     * @dev VOX-Admin-only.
     * @param assistant Active VoxAssistant address to remove
     */
    function removeVoxAssistant(address assistant) external {
        LibDiamond.enforceIsContractOwner();
        _requireNonZeroAddress(assistant);

        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(govStorage.isVoxAssistant[assistant], "VOXA");

        _removeAssistant(govStorage, assistant);

        emit VoxAssistantRemoved(assistant, msg.sender, block.timestamp);
    }

    /**
     * @notice Resign from the VoxAssistant role.
     * @dev Self-service; caller must be an active VoxAssistant.
     */
    function resignAsVoxAssistant() external {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        require(govStorage.isVoxAssistant[msg.sender], "VOXA");

        _removeAssistant(govStorage, msg.sender);

        emit VoxAssistantResigned(msg.sender, block.timestamp);
    }

    // ============================================
    // VIEW HELPERS
    // ============================================

    /// @notice Returns the full list of active VoxAssistants. May be expensive at scale; prefer `isVoxAssistantAddress` for point checks.
    function getVoxAssistants() external view returns (address[] memory) {
        return _gov().voxAssistants;
    }

    /// @notice O(1) check whether an address is currently an active VoxAssistant.
    function isVoxAssistantAddress(address account) external view returns (bool) {
        return _gov().isVoxAssistant[account];
    }

    /// @notice Count of active VoxAssistants.
    function getVoxAssistantCount() external view returns (uint256) {
        return _gov().voxAssistants.length;
    }

    /// @notice Returns the full list of addresses with pending VoxAssistant invitations.
    function getPendingVoxAssistantInvitations() external view returns (address[] memory) {
        return _gov().voxAssistantInvitations;
    }

    /**
     * @notice Returns invitation state for a given address.
     * @return pending Whether the address has a pending invitation
     * @return sentAt  block.timestamp when the invitation was recorded (0 if none)
     */
    function getVoxAssistantInvitationDetails(address candidate) external view returns (bool pending, uint256 sentAt) {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = _gov();
        return (govStorage.hasVoxAssistantInvite[candidate], govStorage.voxAssistantInviteSentAt[candidate]);
    }

    // ============================================
    // INTERNAL ROSTER HELPERS
    // ============================================

    /**
     * @dev Swap-and-pop removal from the active `voxAssistants` array, clearing
     *      associated mapping state. No event emitted — caller emits the
     *      appropriate event (`VoxAssistantRemoved` / `VoxAssistantResigned`).
     */
    function _removeAssistant(LibVoxGovernanceStorage.GovernanceStorage storage govStorage, address assistant) internal {
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
     *      clearing associated mapping state. No event emitted — caller emits the
     *      appropriate event.
     */
    function _removeInvitation(LibVoxGovernanceStorage.GovernanceStorage storage govStorage, address candidate) internal {
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
