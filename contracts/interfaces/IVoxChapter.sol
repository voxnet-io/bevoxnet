// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IVoxChapter
 * @notice Interface for VoxChapter contracts
 * @dev Used by VoxFacet to interact with chapter contracts
 */
interface IVoxChapter {
    /**
     * @notice Sets the banned status of this chapter (platform-level action)
     * @dev Only callable by the platform diamond contract. Renamed from
     *      `setBanned` to disambiguate platform-level vs chapter-level
     *      moderation surfaces.
     * @param _isBanned True to ban, false to unban
     */
    function setChapterBannedByPlatform(bool _isBanned) external;

    /**
     * @notice Prepares chapter for permanent removal
     * @dev Distributes all funds, frees subMods, sets isRemoved flag
     */
    function prepareForRemoval() external;

    /**
     * @notice Gets all subMods for the chapter
     * @return Array of subMod addresses
     */
    function getAllSubMods() external view returns (address[] memory);

    /**
     * @notice Initializes the chapter contract
     * @param _chapterName Name of the chapter
     * @param _chapterID Unique identifier
     * @param _diamondAddress Address of the diamond contract
     * @param _admin Initial admin address
     */
    function initialize(string memory _chapterName, string memory _chapterID, address _diamondAddress, address _admin) external;

    /**
     * @notice Packed snapshot of scalar state used during chapter migration
     */
    struct MigrationSnapshot {
        uint256 ownerShare;
        uint256 aggOwnerPOL;
        uint256 aggOwnerUSDC;
        uint256 aggSubModsPOL;
        uint256 aggSubModsUSDC;
        uint256 minPOL;
        uint256 minUSDC;
    }

    /**
     * @notice Changes the chapter owner's share percentage
     * @param newOwnerShare New share percentage (1-99)
     */
    function changeChapterOwnerShare(uint256 newOwnerShare) external;

    /**
     * @notice Adds a sub-moderator to the chapter
     * @param subModAddress Address of the sub-moderator
     */
    function addSubMod(address subModAddress) external;

    /**
     * @notice Returns the full list of currently banned users for this chapter
     * @return address[] Addresses currently banned from this chapter
     */
    function getBannedUsersArray() external view returns (address[] memory);

    /**
     * @notice Returns all migration-relevant scalar state in a single call
     */
    function getMigrationSnapshot() external view returns (MigrationSnapshot memory snap);

    /**
     * @notice Restores scalar state fields during migration (diamond-gated)
     */
    function migrateState(MigrationSnapshot calldata snap, uint256 _lastKnownPOL, uint256 _lastKnownUSDC) external;

    /**
     * @notice Restores per-user claim accounting during migration (diamond-gated)
     */
    function migrateUserClaims(address[] calldata users, uint256[] calldata polClaimed, uint256[] calldata usdcClaimed) external;

    /**
     * @notice Restores chapter-level user bans during migration (diamond-gated)
     */
    function migrateBannedUsers(address[] calldata users) external;

    /**
     * @notice Migrates USDC to a new address
     * @param to Destination address
     * @param amount Amount to migrate
     */
    function migrateUSDC(address to, uint256 amount) external;

    /**
     * @notice Gets the chapter ID
     * @return string Chapter ID
     */
    function chapterID() external view returns (string memory);

    /**
     * @notice Gets the chapter owner's share percentage
     * @return uint256 Owner share percentage
     */
    function chapterOwnerShare() external view returns (uint256);

    /**
     * @notice Sets minimum claim thresholds for rewards
     * @param _polThreshold New minimum POL threshold
     * @param _usdcThreshold New minimum USDC threshold
     */
    function setMinClaimThresholds(uint256 _polThreshold, uint256 _usdcThreshold) external;

    /**
     * @notice Gets current minimum claim thresholds
     * @return polThreshold Minimum POL threshold
     * @return usdcThreshold Minimum USDC threshold
     */
    function getMinClaimThresholds() external view returns (uint256 polThreshold, uint256 usdcThreshold);

    /**
     * @notice Returns the lifetime earnings of a user across all distributions
     * @param user Address to check
     * @return pol Total POL earned by the user
     * @return usdc Total USDC earned by the user
     */
    function getUserLifetimeEarnings(address user) external view returns (uint256 pol, uint256 usdc);

    /**
     * @notice Returns chapter-level distribution statistics
     * @return totalPOL Total POL distributed across all time
     * @return totalUSDC Total USDC distributed across all time
     * @return lastTimestamp Timestamp of last distribution
     */
    function getChapterDistributionStats() external view returns (uint256 totalPOL, uint256 totalUSDC, uint256 lastTimestamp);

    /**
     * @notice Invites a user to become a subMod
     * @param user Address to invite
     */
    function inviteSubMod(address user) external;

    /**
     * @notice Accepts a pending subMod invitation
     */
    function acceptSubModInvitation() external;

    /**
     * @notice Declines a pending subMod invitation
     */
    function declineSubModInvitation() external;

    /**
     * @notice Revokes a pending invitation
     * @param user Address whose invitation to revoke
     */
    function revokeSubModInvitation(address user) external;

    /**
     * @notice Returns all pending invitations
     * @return addresses Array of addresses with pending invitations
     */
    function returnInvitations() external view returns (address[] memory addresses);

    /**
     * @notice Gets details of a pending invitation
     * @param user Address to check
     * @return isPending Whether invitation is pending
     * @return timestamp When invitation was sent
     */
    function getPendingInvitationDetails(address user) external view returns (bool isPending, uint256 timestamp);

    /**
     * @notice Allows a subMod to voluntarily remove themselves
     */
    function removeMyself() external;

    /**
     * @notice Allows chapter owner to step down and appoint a subMod as successor
     * @param newAdmin Address of the subMod to appoint as new owner
     */
    function removeMyselfAndAppointSuccessor(address newAdmin) external;

    /**
     * @notice Checks if a user is banned from this chapter
     * @param user Address to check
     * @return bool True if user is banned from this chapter
     */
    function isUserBannedFromChapter(address user) external view returns (bool);
}
