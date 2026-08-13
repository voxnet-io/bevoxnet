// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IVoxDiamond
 * @notice Interface to interact with the main diamond contract
 * @dev Used to retrieve configuration values and update admin state
 */
interface IVoxDiamond {
    /**
     * @notice Returns the USDC token contract address
     * @return The address of the USDC token contract used for rewards
     */
    function getUSDCAddress() external view returns (address);

    /**
     * @notice Updates diamond storage when chapter admin changes
     * @param oldAdmin The previous admin address
     * @param newAdmin The new admin address
     */
    function updateChapterAdmin(address oldAdmin, address newAdmin) external;

    /**
     * @notice Checks if caller is a registered chapter
     * @return True if caller is registered
     */
    function isRegisteredChapter() external view returns (bool);

    /**
     * @notice Checks if a user is banned at platform level
     * @param user Address to check
     * @return True if user is banned at platform level
     */
    function isUserBannedFromPlatform(address user) external view returns (bool);

    /**
     * @notice Checks if a chapter is banned by the platform
     * @param chapterAddress Address of the chapter to check
     * @return True if chapter is banned at platform level
     */
    function isChapterBannedByPlatform(address chapterAddress) external view returns (bool);

    /**
     * @notice Checks if a chapter has been removed
     * @param chapterAddress Address of the chapter to check
     * @return True if chapter has been removed
     */
    function isChapterRemoved(address chapterAddress) external view returns (bool);

    /**
     * @notice Registers the calling chapter's subMod in the Diamond-side multi-chapter registry
     * @param subMod Address of the subMod to register
     */
    function registerSubMod(address subMod) external;

    /**
     * @notice Deregisters the calling chapter's subMod from the Diamond-side multi-chapter registry
     * @param subMod Address of the subMod to deregister
     */
    function deregisterSubMod(address subMod) external;

    /**
     * @notice Routes forfeited chapter funds (POL via msg.value, USDC via transferFrom)
     *         100% to the token-holder reward pool, bypassing the admin-claim cut.
     * @param usdcAmount Amount of USDC the Diamond should pull from the calling chapter
     */
    function depositForfeitedFunds(uint256 usdcAmount) external payable;
}

/**
 * @title IOwnershipFacet
 * @notice Interface to get diamond owner
 */
interface IOwnershipFacet {
    /**
     * @notice Get the diamond contract owner
     * @return owner_ The owner address
     */
    function owner() external view returns (address owner_);
}

/**
 * @title VoxChapter
 * @notice Manages individual content creator chapters with reward distribution
 * @dev Handles POL (native token) and USDC rewards for chapter owners and sub-moderators
 *
 * Key Features:
 * - Balance-based reward distribution (no aggregate tracking)
 * - Pro-rata distribution: owner gets configurable share %, submods split remainder
 * - Supports both POL and USDC rewards
 * - Maximum 150 sub-moderators per chapter for gas safety
 * - Anyone can trigger reward distribution
 *
 * Reward Distribution Logic:
 * - ChapterOwner receives: (totalBalance * chapterOwnerShare) / 100
 * - Each SubMod receives: (totalBalance * (100 - chapterOwnerShare)) / 100 / subModCount
 */
contract VoxChapter is ReentrancyGuard {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Name of the chapter
    string public chapterName;

    /// @notice Address of this chapter contract
    address public chapterAddress;

    /// @notice Current owner/admin of the chapter
    address public chapterOwner;

    /// @notice Unique identifier for the chapter
    string public chapterID;

    /// @notice Total share percentage (always 100)
    uint256 public totalShare;

    /// @notice Percentage share for chapter owner (0-100)
    uint256 public chapterOwnerShare;

    /// @notice Address of the main diamond contract
    address public diamondAddress;

    /// @notice Maximum number of sub-moderators allowed per chapter
    /// @dev Set to 150 to ensure safe gas usage with dual token distribution
    uint256 public constant MAX_SUBMODS = 150;

    /// @notice Array of all sub-moderator addresses
    address[] public subMods;

    /// @notice Mapping from sub-mod address to their index in the array
    mapping(address => uint256) public subModIndex;

    /// @notice Mapping to check if an address is a sub-moderator
    mapping(address => bool) public isSubMod;

    /// @notice Mapping to track users banned at chapter level
    mapping(address => bool) public chapterBannedUsers;

    /// @notice Enumerable array of currently banned users (maintained alongside chapterBannedUsers)
    address[] public bannedUsersArray;

    /// @notice Index of each address in bannedUsersArray (1-based; 0 means not present)
    mapping(address => uint256) private bannedUsersArrayIndex;

    /// @notice Mapping to track block number when user was banned from chapter
    mapping(address => uint256) public chapterBanBlockNumber;

    /// @notice Flag indicating if this chapter is banned by platform owner
    bool public isBanned;

    /// @notice Flag indicating if this chapter has been permanently removed
    bool public isRemoved;

    // ============================================
    // HISTORICAL REWARD TRACKING
    // ============================================

    /// @notice Lifetime POL earnings per user
    mapping(address => uint256) public totalPOLEarnedByUser;

    /// @notice Lifetime USDC earnings per user
    mapping(address => uint256) public totalUSDCEarnedByUser;

    /// @notice Total POL distributed by this chapter
    uint256 public totalPOLDistributed;

    /// @notice Total USDC distributed by this chapter
    uint256 public totalUSDCDistributed;

    /// @notice Timestamp of last distribution
    uint256 public lastDistributionTimestamp;

    // ============================================
    // AGGREGATE TRACKING (BALANCE DELTA DETECTION)
    // ============================================

    /// @notice Total aggregate POL available for chapter owner
    uint256 public totalAggregateOwnerPOL;

    /// @notice Total aggregate POL available for all subMods combined
    uint256 public totalAggregateSubModsPOL;

    /// @notice Total aggregate USDC available for chapter owner
    uint256 public totalAggregateOwnerUSDC;

    /// @notice Total aggregate USDC available for all subMods combined
    uint256 public totalAggregateSubModsUSDC;

    /// @notice Last known POL balance for delta detection
    uint256 public lastKnownPOLBalance;

    /// @notice Last known USDC balance for delta detection
    uint256 public lastKnownUSDCBalance;

    /// @notice Tracks how much POL each user has already claimed
    mapping(address => uint256) public polClaimedByUser;

    /// @notice Tracks how much USDC each user has already claimed
    mapping(address => uint256) public usdcClaimedByUser;

    // ============================================
    // CONFIGURABLE CLAIM THRESHOLDS
    // ============================================

    /// @notice Minimum POL balance required to claim rewards (configurable)
    uint256 public minClaimThresholdPOL;

    /// @notice Minimum USDC balance required to claim rewards (configurable)
    uint256 public minClaimThresholdUSDC;

    // ============================================
    // SUBMOD INVITATION SYSTEM
    // ============================================

    /// @notice Pending subMod invitations
    mapping(address => bool) public subModInvitations;

    /// @notice Timestamp when invitation was sent
    mapping(address => uint256) public invitationSentAt;

    /// @notice Array of invited addresses for enumeration
    address[] private invitedAddresses;

    /// @notice Index of invited address in array
    mapping(address => uint256) private invitedAddressIndex;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a sub-moderator is added
    /// @param subMod Address of the added sub-moderator
    /// @param addedBy Address that added the sub-moderator
    event SubModAdded(address indexed subMod, address indexed addedBy);

    /// @notice Emitted when a sub-moderator is removed
    /// @param subMod Address of the removed sub-moderator
    /// @param removedBy Address that removed the sub-moderator
    event SubModRemoved(address indexed subMod, address indexed removedBy);

    /// @notice Emitted when chapter ownership changes
    /// @param oldOwner Previous chapter owner
    /// @param newOwner New chapter owner
    event ChapterOwnerChanged(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when chapter owner's share percentage changes
    /// @param oldShare Previous share percentage
    /// @param newShare New share percentage
    event ChapterOwnerShareChanged(uint256 oldShare, uint256 newShare);

    /// @notice Emitted when a user is banned from this chapter
    /// @param user Address of the banned user
    /// @param bannedBy Address that issued the ban (chapter admin or platform owner)
    /// @param blockNumber Block number when ban was applied
    event UserBannedFromChapter(address indexed user, address indexed bannedBy, uint256 blockNumber);

    /// @notice Emitted when a user is unbanned from this chapter
    /// @param user Address of the unbanned user
    /// @param unbannedBy Address that removed the ban
    /// @param blockNumber Block number when user was unbanned
    event UserUnbannedFromChapter(address indexed user, address indexed unbannedBy, uint256 blockNumber);

    /// @notice Emitted when chapter is prepared for removal
    /// @param chapterAddress Address of this chapter
    /// @param polDistributed Amount of POL distributed
    /// @param usdcDistributed Amount of USDC distributed
    /// @param subModsFreed Number of subMods freed
    event ChapterPreparedForRemoval(address indexed chapterAddress, uint256 polDistributed, uint256 usdcDistributed, uint256 subModsFreed);

    /// @notice Emitted when rewards are distributed
    /// @param polAmount Amount of POL distributed
    /// @param usdcAmount Amount of USDC distributed
    /// @param timestamp When distribution occurred
    /// @param recipientCount Number of recipients
    event RewardsDistributed(uint256 polAmount, uint256 usdcAmount, uint256 timestamp, uint256 recipientCount);

    /// @notice Emitted when min claim thresholds are updated
    /// @param newPOLThreshold New POL threshold
    /// @param newUSDCThreshold New USDC threshold
    /// @param updatedBy Address that made the update
    event MinClaimThresholdsUpdated(uint256 newPOLThreshold, uint256 newUSDCThreshold, address indexed updatedBy);

    /// @notice Emitted when a subMod is invited
    /// @param user Address of invited user
    /// @param invitedBy Address that sent invitation
    /// @param timestamp When invitation was sent
    event SubModInvited(address indexed user, address indexed invitedBy, uint256 timestamp);

    /// @notice Emitted when invitation is accepted
    /// @param user Address that accepted
    /// @param timestamp When accepted
    event SubModInvitationAccepted(address indexed user, uint256 timestamp);

    /// @notice Emitted when invitation is declined
    /// @param user Address that declined
    /// @param timestamp When declined
    event SubModInvitationDeclined(address indexed user, uint256 timestamp);

    /// @notice Emitted when invitation is revoked
    /// @param user Address whose invitation was revoked
    /// @param revokedBy Address that revoked
    /// @param timestamp When revoked
    event SubModInvitationRevoked(address indexed user, address indexed revokedBy, uint256 timestamp);

    /// @notice Emitted when subMod removes themselves
    /// @param user Address that removed themselves
    /// @param timestamp When removed
    event SubModRemovedSelf(address indexed user, uint256 timestamp);

    /// @notice Emitted when admin succession is completed
    /// @param oldAdmin Previous admin
    /// @param newAdmin New admin
    /// @param timestamp When succession occurred
    event AdminSuccessionCompleted(address indexed oldAdmin, address indexed newAdmin, uint256 timestamp);

    /// @notice Emitted when a chapter is parked under the platform owner
    /// @param oldOwner Previous chapter owner who initiated the park
    /// @param platformOwner The platform owner now custodian of the chapter
    /// @param timestamp When the chapter was parked
    event ChapterParked(address indexed oldOwner, address indexed platformOwner, uint256 timestamp);

    /// @notice Emitted when new POL deposits are detected
    /// @param totalAmount Total POL detected
    /// @param ownerAmount Amount allocated to owner
    /// @param subModsAmount Amount allocated to subMods
    event POLDeposited(uint256 totalAmount, uint256 ownerAmount, uint256 subModsAmount);

    /// @notice Emitted when new USDC deposits are detected
    /// @param totalAmount Total USDC detected
    /// @param ownerAmount Amount allocated to owner
    /// @param subModsAmount Amount allocated to subMods
    event USDCDeposited(uint256 totalAmount, uint256 ownerAmount, uint256 subModsAmount);

    /// @notice Emitted when a USDC transfer fails during distribution (funds remain in contract)
    event USDCTransferFailed(address indexed recipient, uint256 amount);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    // Add initialization flag to prevent re-initialization
    bool private initialized;

    /**
     * @notice Locks the master implementation so it can never be initialized directly.
     * @dev EIP-1167 clones copy bytecode but not storage, so `initialized` in the clone
     *      starts at false. The master's constructor sets it to true, permanently
     *      preventing direct initialization of the implementation contract.
     */
    constructor() {
        initialized = true;
    }

    // Remove constructor, replace with initialize
    /**
     * @notice Creates a new chapter contract
     * @dev Sets the original transaction sender as chapter owner
     * @param _chapterName The name of the chapter
     * @param _chapterID Unique identifier for the chapter
     * @param _diamondAddress Address of the main diamond contract
     * @param _chapterOwner Address of the initial chapter owner
     */
    function initialize(string memory _chapterName, string memory _chapterID, address _diamondAddress, address _chapterOwner) external {
        require(!initialized, "INIT");
        initialized = true;

        chapterAddress = address(this);
        chapterName = _chapterName;
        chapterOwner = _chapterOwner;
        chapterID = _chapterID;
        totalShare = 100;
        chapterOwnerShare = totalShare;
        diamondAddress = _diamondAddress;
        isBanned = false;
        isRemoved = false;

        // Set default thresholds: 1 POL and 1 USDC
        minClaimThresholdPOL = 1 ether;
        minClaimThresholdUSDC = 1e6; // 1 USDC (6 decimals)
    }

    // ============================================
    // INTERNAL HELPER FUNCTIONS
    // ============================================

    function _getPlatformOwner() internal view returns (address) {
        return IOwnershipFacet(diamondAddress).owner();
    }

    function _requireNotBanned() internal view {
        require(!isRemoved, "RMV");
        require(!isBanned, "BAN");
    }

    function _requireOwnerOrPlatformOwner() internal view {
        require(msg.sender == chapterOwner || msg.sender == _getPlatformOwner(), "AUTH");
    }

    // ============================================
    // EXTERNAL CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Gets the USDC token address from the diamond contract
     * @dev Calls the diamond to retrieve the current USDC address dynamically
     * @return The USDC token contract address
     */
    function getUSDCAddress() public view returns (address) {
        return IVoxDiamond(diamondAddress).getUSDCAddress();
    }

    /**
     * @notice Manually trigger deposit detection (optional convenience function)
     * @dev Anyone can call this to process pending deposits without claiming rewards
     *      Useful for updating aggregates before checking getPendingRewards()
     * @return polDetected Amount of new POL detected
     * @return usdcDetected Amount of new USDC detected
     */
    function updateAggregates() external returns (uint256 polDetected, uint256 usdcDetected) {
        uint256 polBefore = totalAggregateOwnerPOL + totalAggregateSubModsPOL;
        uint256 usdcBefore = totalAggregateOwnerUSDC + totalAggregateSubModsUSDC;

        processNewDeposits();

        uint256 polAfter = totalAggregateOwnerPOL + totalAggregateSubModsPOL;
        uint256 usdcAfter = totalAggregateOwnerUSDC + totalAggregateSubModsUSDC;

        polDetected = polAfter - polBefore;
        usdcDetected = usdcAfter - usdcBefore;
    }

    // ============================================
    // ADMIN MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Revokes current chapter admin and transfers ownership to platform owner
     * @dev Can only be called by platform owner. Distributes all pending rewards before transfer
     *
     * Flow:
     * 1. Verify caller is platform owner
     * 2. Distribute all rewards to current owner and all subMods
     * 3. Update diamond storage via callback
     * 4. Transfer ownership to platform owner
     *
     * Requirements:
     * - Caller must be platform owner (diamond contract owner)
     */
    function revokeChapterAdmin() public {
        require(msg.sender == _getPlatformOwner(), "AUTH");
        require(!isRemoved, "RMV");

        // Distribute all rewards before changing ownership
        claimChapterRewards();

        address oldOwner = chapterOwner;
        address newOwner = msg.sender;

        // Update diamond storage via callback
        IVoxDiamond(diamondAddress).updateChapterAdmin(oldOwner, newOwner);

        // Update chapter contract state
        chapterOwner = newOwner;

        // Rebaseline the incoming owner's claim stamp to the current owner aggregate
        // so they start at a zero owner-gap. Without this, the new owner would
        // inherit (totalAggregateOwnerX - their prior claim stamp) as an immediate
        // phantom claim. Mirrors the rebaseline in setChapterAdmin / _handoffOwnership.
        polClaimedByUser[newOwner] = totalAggregateOwnerPOL;
        usdcClaimedByUser[newOwner] = totalAggregateOwnerUSDC;

        emit ChapterOwnerChanged(oldOwner, newOwner);
    }

    /**
     * @notice Sets a new chapter admin/owner
     * @dev Can only be called by platform owner. Does not distribute rewards
     * @param _newChapterAdmin Address of the new chapter admin
     *
     * Flow:
     * 1. Verify caller is platform owner
     * 2. Validate new admin address
     * 3. Update diamond storage via callback
     * 4. Transfer ownership in chapter contract
     *
     * Requirements:
     * - Caller must be platform owner
     * - New admin address must not be zero address
     * - New admin should not already be admin of another chapter (checked in diamond)
     */
    function setChapterAdmin(address _newChapterAdmin) public {
        require(msg.sender == _getPlatformOwner(), "AUTH");
        require(_newChapterAdmin != address(0), "ADDR");
        _requireNotBanned();

        // Check platform-level ban via Diamond callback (reads Diamond's own storage, not ours)
        require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(_newChapterAdmin), "BAN");

        address oldOwner = chapterOwner;

        // Process any pending deposits to ensure aggregates are up to date
        processNewDeposits();

        // Mark all unclaimed rewards of old owner as "claimed" so new owner doesn't inherit them
        // This effectively gives the old owner rights to their accumulated rewards
        polClaimedByUser[oldOwner] = totalAggregateOwnerPOL;
        usdcClaimedByUser[oldOwner] = totalAggregateOwnerUSDC;

        // Reset aggregates for new owner to start fresh
        totalAggregateOwnerPOL = 0;
        totalAggregateOwnerUSDC = 0;

        // Update diamond storage via callback (this will revert if newAdmin is already admin elsewhere)
        IVoxDiamond(diamondAddress).updateChapterAdmin(oldOwner, _newChapterAdmin);

        // Update chapter contract state
        chapterOwner = _newChapterAdmin;

        emit ChapterOwnerChanged(oldOwner, _newChapterAdmin);
    }

    /**
     * @notice Allows chapter owner to adjust their reward share percentage
     * @dev SubMods split the remaining percentage (100 - chapterOwnerShare) equally
     * @param newShare New share percentage for chapter owner (0-100)
     *
     * Example:
     * - If newShare = 70, owner gets 70%, subMods split remaining 30%
     * - If newShare = 0, owner gets nothing, subMods split 100%
     * - If newShare = 100, owner gets all, subMods get nothing
     *
     * Requirements:
     * - Caller must be chapter owner
     * - New share must be between 0 and 100 inclusive
     */
    function changeChapterOwnerShare(uint256 newShare) public {
        require(msg.sender == chapterOwner, "AUTH");

        require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(msg.sender), "BAN");
        _requireNotBanned();

        require(newShare <= totalShare, "SHR");

        uint256 oldShare = chapterOwnerShare;
        chapterOwnerShare = newShare;

        emit ChapterOwnerShareChanged(oldShare, newShare);
    }

    // ============================================
    // CHAPTER-LEVEL BAN MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Bans a user from this specific chapter
     * @dev Can be called by chapter owner or platform owner
     * @param user Address of the user to ban from this chapter
     *
     * Requirements:
     * - Caller must be chapter owner or platform owner
     * - User address must not be zero address
     * - User must not already be banned from this chapter
     *
     * Effects:
     * - Sets chapterBannedUsers[user] to true
     * - Records current block.number in chapterBanBlockNumber[user]
     * - If user is a subMod, they are automatically removed
     *
     * Emits: UserBannedFromChapter event
     */
    function banUserFromChapter(address user) external {
        _requireOwnerOrPlatformOwner();
        require(!isRemoved, "RMV");
        require(user != address(0), "ADDR");
        require(user != chapterOwner, "OWN");
        require(!chapterBannedUsers[user], "BAN");

        chapterBannedUsers[user] = true;
        chapterBanBlockNumber[user] = block.number;

        // Maintain enumerable banned-users array (1-based index)
        bannedUsersArrayIndex[user] = bannedUsersArray.length + 1;
        bannedUsersArray.push(user);

        // If user is a subMod, automatically remove them
        if (isSubMod[user]) {
            _removeSubModInternal(user);
        }

        emit UserBannedFromChapter(user, msg.sender, block.number);
    }

    /**
     * @notice Unbans a user from this specific chapter
     * @dev Can be called by chapter owner or platform owner
     * @param user Address of the user to unban from this chapter
     *
     * Requirements:
     * - Caller must be chapter owner or platform owner
     * - User address must not be zero address
     * - User must currently be banned from this chapter
     *
     * Effects:
     * - Sets chapterBannedUsers[user] to false
     * - Keeps the ban block number for historical record
     *
     * Emits: UserUnbannedFromChapter event
     */
    function unbanUserFromChapter(address user) external {
        _requireOwnerOrPlatformOwner();
        require(!isRemoved, "RMV");
        require(user != address(0), "ADDR");
        require(chapterBannedUsers[user], "BAN");

        chapterBannedUsers[user] = false;

        // Swap-and-pop from bannedUsersArray
        uint256 idx = bannedUsersArrayIndex[user];
        if (idx != 0) {
            uint256 lastIdx = bannedUsersArray.length; // 1-based index of last element
            if (idx != lastIdx) {
                address last = bannedUsersArray[lastIdx - 1];
                bannedUsersArray[idx - 1] = last;
                bannedUsersArrayIndex[last] = idx;
            }
            bannedUsersArray.pop();
            delete bannedUsersArrayIndex[user];
        }

        emit UserUnbannedFromChapter(user, msg.sender, block.number);
    }

    /**
     * @notice Checks if a user is banned from this chapter
     * @param user Address to check
     * @return bool True if user is banned from this chapter, false otherwise
     */
    function isUserBannedFromChapter(address user) public view returns (bool) {
        return chapterBannedUsers[user];
    }

    /**
     * @notice Returns the full list of currently banned users for this chapter
     * @dev Used during chapter migration to carry ban state to the new clone
     * @return address[] Addresses currently banned from this chapter
     */
    function getBannedUsersArray() external view returns (address[] memory) {
        return bannedUsersArray;
    }

    /**
     * @notice Gets the block number when a user was banned from this chapter
     * @param user Address to check
     * @return uint256 Block number when user was banned from this chapter (0 if never banned)
     */
    function getUserChapterBanBlockNumber(address user) public view returns (uint256) {
        return chapterBanBlockNumber[user];
    }

    /**
     * @notice Checks if a user is banned at either platform or chapter level
     * @param user Address to check
     * @return platformBanned True if banned at platform level
     * @return chapterBanned True if banned at chapter level
     * @return userIsBanned True if banned at either level (convenience)
     */
    function getUserBanStatus(address user) external view returns (bool platformBanned, bool chapterBanned, bool userIsBanned) {
        platformBanned = IVoxDiamond(diamondAddress).isUserBannedFromPlatform(user);
        chapterBanned = chapterBannedUsers[user];
        userIsBanned = platformBanned || chapterBanned;
    }

    /**
     * @notice Sets the ban status of this chapter
     * @dev Can only be called by the diamond contract. Updates the local isBanned flag.
     *      When set to true the chapter is suspended; false restores normal operation.
     *      Banned chapters cannot distribute rewards or perform most state-changing operations.
     *      Any accumulated (unclaimed) funds remain in the contract and can be swept by the
     *      platform owner via rescueChapterFunds().
     * @param _banned True to ban the chapter, false to unban
     *
     * Requirements:
     * - Caller must be the diamond contract (called via VoxFacet.platformBanChapter/platformUnbanChapter)
     *
     * Effects:
     * - Updates isBanned state variable
     * - This works in conjunction with platform-level ban tracking in diamond storage
     */
    function setChapterBannedByPlatform(bool _banned) external {
        require(msg.sender == diamondAddress, "AUTH");
        require(!isRemoved, "RMV");
        isBanned = _banned;
    }

    /**
     * @notice Prepares this chapter for permanent removal
     * @dev Can only be called by the diamond contract. Distributes all funds and frees subMods
     *
     * Flow:
     * 1. Verify caller is diamond contract
     * 2. Distribute ALL remaining rewards (POL + USDC)
     * 3. Free all subMods from global storage
     * 4. Set isRemoved flag to true
     *
     * Requirements:
     * - Caller must be diamond contract
     * - Chapter must not already be removed
     *
     * Effects:
     * - All POL and USDC distributed to owner and subMods
     * - All subMods freed from global isSubmod mapping
     * - Chapter marked as permanently removed
     * - All future operations blocked (except view functions)
     *
     * Emits: ChapterPreparedForRemoval event
     */
    function prepareForRemoval() external nonReentrant returns (uint256 polDistributed, uint256 usdcDistributed) {
        require(msg.sender == diamondAddress, "AUTH");
        require(!isRemoved, "RMV");

        uint256 subModCount = subMods.length;

        // Temporarily allow distribution if banned
        bool wasBanned = isBanned;
        if (wasBanned) {
            isBanned = false;
        }

        // Distribute all funds (reuse existing logic)
        if (address(this).balance > 0 || _getUSDCBalance() > 0) {
            (polDistributed, usdcDistributed) = _distributeFunds();
        }

        // Diamond-side subMod registry cleanup is handled by VoxFacet.removeChapter()
        // before this function is called, so no Diamond writes are needed here.

        // Mark as removed
        isRemoved = true;
        if (wasBanned) {
            isBanned = true;
        }

        emit ChapterPreparedForRemoval(address(this), polDistributed, usdcDistributed, subModCount);
    }

    /**
     * @notice Internal helper to get USDC balance
     */
    function _getUSDCBalance() internal view returns (uint256) {
        address usdcAddress = getUSDCAddress();
        if (usdcAddress != address(0)) {
            return IERC20(usdcAddress).balanceOf(address(this));
        }
        return 0;
    }

    /**
     * @notice Internal helper to distribute funds
     */
    function _distributeFunds() internal returns (uint256 polDistributed, uint256 usdcDistributed) {
        uint256 totalPOL = address(this).balance;
        uint256 totalUSDC = _getUSDCBalance();
        address usdcAddr = getUSDCAddress();

        uint256 ownerPOL = (totalPOL * chapterOwnerShare) / totalShare;
        uint256 ownerUSDC = (totalUSDC * chapterOwnerShare) / totalShare;

        // Pre-compute subMod per-head amounts; fold truncation dust into the owner
        // share so no funds are permanently stranded in the contract.
        if (subMods.length > 0) {
            ownerPOL += (totalPOL - ownerPOL) % subMods.length;
            ownerUSDC += (totalUSDC - ownerUSDC) % subMods.length;
        }

        // Send to owner
        if (ownerPOL > 0) {
            (bool success, ) = payable(chapterOwner).call{value: ownerPOL}("");
            if (success) {
                polDistributed = ownerPOL;
                totalPOLEarnedByUser[chapterOwner] += ownerPOL;
            }
        }
        if (ownerUSDC > 0 && usdcAddr != address(0)) {
            try IERC20(usdcAddr).transfer(chapterOwner, ownerUSDC) returns (bool transferSuccess) {
                if (transferSuccess) {
                    usdcDistributed = ownerUSDC;
                    totalUSDCEarnedByUser[chapterOwner] += ownerUSDC;
                }
            } catch {
                emit USDCTransferFailed(chapterOwner, ownerUSDC);
            }
        }

        // Send to subMods — use snapshot of totalPOL/totalUSDC minus the (dust-adjusted) owner portion
        if (subMods.length > 0) {
            uint256 polPerSubMod = (totalPOL - ownerPOL) / subMods.length;
            uint256 usdcPerSubMod = (totalUSDC - ownerUSDC) / subMods.length;

            for (uint256 i = 0; i < subMods.length; i++) {
                address subMod = subMods[i];
                if (polPerSubMod > 0) {
                    (bool success, ) = payable(subMod).call{value: polPerSubMod}("");
                    if (success) {
                        polDistributed += polPerSubMod;
                        totalPOLEarnedByUser[subMod] += polPerSubMod;
                    }
                }
                if (usdcPerSubMod > 0 && usdcAddr != address(0)) {
                    try IERC20(usdcAddr).transfer(subMod, usdcPerSubMod) returns (bool transferSuccess) {
                        if (transferSuccess) {
                            usdcDistributed += usdcPerSubMod;
                            totalUSDCEarnedByUser[subMod] += usdcPerSubMod;
                        }
                    } catch {
                        emit USDCTransferFailed(subMod, usdcPerSubMod);
                    }
                }
            }
        }

        // Update chapter-level tracking
        totalPOLDistributed += polDistributed;
        totalUSDCDistributed += usdcDistributed;
        lastDistributionTimestamp = block.timestamp;
    }

    /**
     * @notice Sweeps all POL and USDC from this chapter to the diamond contract
     * @dev PLATFORM-SIDE SWEEP — NOT an owner refund. Callable ONLY by the diamond
     *      contract owner (the platform owner), and ONLY while the chapter is banned
     *      or removed. This is NOT delegated to VoxAssistants and the CHAPTER OWNER
     *      CANNOT call it (they would revert "AUTH").
     *
     *      Funds are routed through the Diamond's depositForfeitedFunds() entry point,
     *      which credits them 100% to the token-holder reward pool — bypassing the
     *      storage-provider and admin-claim slices of the normal deposit waterfall, so
     *      no portion accrues to operator revenue. The funds do NOT go to the caller and
     *      do NOT go to the chapter owner. This is a one-way, non-refundable sweep;
     *      unbanning the chapter does NOT return these funds.
     *
     *      Covers two scenarios:
     *      1. Banned chapter — the platform owner sweeps the frozen balance to the
     *         diamond during suspension (claimChapterRewards is blocked while banned).
     *      2. Removed chapter — recovers residual funds stranded in the chapter after
     *         failed push distributions in prepareForRemoval().
     *
     * Requirements:
     * - Caller must be the platform owner (diamond contract owner) — VoxAssistants are NOT permitted
     * - Chapter must be banned or permanently removed
     */
    function rescueChapterFunds() external nonReentrant {
        require(msg.sender == _getPlatformOwner(), "AUTH");
        require(isBanned || isRemoved, "Not banned or removed");

        uint256 polBalance = address(this).balance;

        // Measure USDC and grant the Diamond a one-shot pull allowance for it.
        uint256 usdcBalance = 0;
        address usdcAddress = getUSDCAddress();
        if (usdcAddress != address(0)) {
            usdcBalance = IERC20(usdcAddress).balanceOf(address(this));
            if (usdcBalance > 0) {
                SafeERC20.forceApprove(IERC20(usdcAddress), diamondAddress, usdcBalance);
            }
        }

        // Route everything through the Diamond's forfeiture entry point, which credits
        // 100% to the token-holder reward pool (no storage-provider or admin-claim cut).
        if (polBalance > 0 || usdcBalance > 0) {
            IVoxDiamond(diamondAddress).depositForfeitedFunds{value: polBalance}(usdcBalance);
        }
    }

    // ============================================
    // THRESHOLD MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Sets minimum claim thresholds for rewards
     * @dev Can be called by chapter owner OR platform owner
     * @param _polThreshold New minimum POL threshold
     * @param _usdcThreshold New minimum USDC threshold
     *
     * Requirements:
     * - Caller must be chapter owner or platform owner
     */
    function setMinClaimThresholds(uint256 _polThreshold, uint256 _usdcThreshold) external {
        _requireOwnerOrPlatformOwner();

        minClaimThresholdPOL = _polThreshold;
        minClaimThresholdUSDC = _usdcThreshold;

        emit MinClaimThresholdsUpdated(_polThreshold, _usdcThreshold, msg.sender);
    }

    /**
     * @notice Gets current minimum claim thresholds
     * @return polThreshold Current POL threshold
     * @return usdcThreshold Current USDC threshold
     */
    function getMinClaimThresholds() external view returns (uint256 polThreshold, uint256 usdcThreshold) {
        return (minClaimThresholdPOL, minClaimThresholdUSDC);
    }

    // ============================================
    // HISTORICAL TRACKING VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the lifetime earnings of a user across all distributions
     * @param user Address to check
     * @return pol Total POL earned by the user
     * @return usdc Total USDC earned by the user
     */
    function getUserLifetimeEarnings(address user) external view returns (uint256 pol, uint256 usdc) {
        return (totalPOLEarnedByUser[user], totalUSDCEarnedByUser[user]);
    }

    /**
     * @notice Returns chapter-level distribution statistics
     * @return totalPOL Total POL distributed across all time
     * @return totalUSDC Total USDC distributed across all time
     * @return lastTimestamp Timestamp of last distribution
     */
    function getChapterDistributionStats() external view returns (uint256 totalPOL, uint256 totalUSDC, uint256 lastTimestamp) {
        return (totalPOLDistributed, totalUSDCDistributed, lastDistributionTimestamp);
    }

    // ============================================
    // SUB-MODERATOR MANAGEMENT FUNCTIONS
    // ============================================

    // ============================================
    // SUBMOD INVITATION SYSTEM
    // ============================================

    /**
     * @notice Invites a user to become a sub-moderator
     * @dev Only chapter owner or platform owner can invite
     * @param user Address to invite
     *
     * Requirements:
     * - Caller must be chapter owner or platform owner
     * - User must not already be a subMod
     * - User must not already have pending invitation
     * - User must not be banned
     * - Chapter must not be removed or banned
     */
    function inviteSubMod(address user) external {
        _requireOwnerOrPlatformOwner();
        require(user != address(0), "ADDR");
        require(!isSubMod[user], "SUB");
        require(!subModInvitations[user], "INV");
        require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(user), "BAN");
        require(!chapterBannedUsers[user], "BAN");
        _requireNotBanned();

        // Create invitation
        subModInvitations[user] = true;
        invitationSentAt[user] = block.timestamp;

        // Add to tracking array
        invitedAddressIndex[user] = invitedAddresses.length;
        invitedAddresses.push(user);

        emit SubModInvited(user, msg.sender, block.timestamp);
    }

    /**
     * @notice Accept a subMod invitation
     * @dev Called by the invited user to accept and become a subMod.
     *      Pre-pays out all existing subMods at the current headcount before the
     *      new seat is added, preventing dilution of accrued-but-unclaimed rewards.
     */
    function acceptSubModInvitation() external nonReentrant {
        require(subModInvitations[msg.sender], "INV");

        // Pre-payout existing subMods before the headcount changes (T2-2).
        // This ensures no reward dilution: existing members receive their full
        // per-seat share at the current count before the new member is counted.
        if (subMods.length > 0) {
            processNewDeposits();
            address usdcAddr = getUSDCAddress();
            uint256 usdcBal = usdcAddr != address(0) ? IERC20(usdcAddr).balanceOf(address(this)) : 0;
            if (address(this).balance >= minClaimThresholdPOL || usdcBal >= minClaimThresholdUSDC) {
                _claimChapterRewardsInternal();
            }
        }

        // Remove invitation
        _removeInvitation(msg.sender);

        // Add as subMod (local chapter state only)
        _addSubModInternal(msg.sender);

        // Register in Diamond-side multi-chapter subMod registry
        IVoxDiamond(diamondAddress).registerSubMod(msg.sender);

        emit SubModInvitationAccepted(msg.sender, block.timestamp);
    }

    /**
     * @notice Decline a subMod invitation
     * @dev Called by the invited user to decline
     */
    function declineSubModInvitation() external {
        require(subModInvitations[msg.sender], "INV");

        _removeInvitation(msg.sender);

        emit SubModInvitationDeclined(msg.sender, block.timestamp);
    }

    /**
     * @notice Revoke a pending subMod invitation
     * @dev Only chapter owner can revoke
     * @param user Address whose invitation to revoke
     */
    function revokeSubModInvitation(address user) external {
        require(msg.sender == chapterOwner, "AUTH");
        require(subModInvitations[user], "INV");

        _removeInvitation(user);

        emit SubModInvitationRevoked(user, msg.sender, block.timestamp);
    }

    /**
     * @notice Returns all pending invitation addresses
     * @dev Only chapter owner can view
     * @return Array of addresses with pending invitations
     */
    function returnInvitations() external view returns (address[] memory) {
        require(msg.sender == chapterOwner, "AUTH");
        return invitedAddresses;
    }

    /**
     * @notice Get details of a pending invitation
     * @param user Address to check
     * @return invited Whether user has pending invitation
     * @return timestamp When invitation was sent
     */
    function getPendingInvitationDetails(address user) external view returns (bool invited, uint256 timestamp) {
        return (subModInvitations[user], invitationSentAt[user]);
    }

    /**
     * @notice Internal function to remove invitation tracking
     * @param user Address to remove
     */
    function _removeInvitation(address user) internal {
        delete subModInvitations[user];
        delete invitationSentAt[user];

        // Remove from array using swap-and-pop
        uint256 index = invitedAddressIndex[user];
        uint256 lastIndex = invitedAddresses.length - 1;

        if (index < invitedAddresses.length) {
            if (index != lastIndex) {
                address lastUser = invitedAddresses[lastIndex];
                invitedAddresses[index] = lastUser;
                invitedAddressIndex[lastUser] = index;
            }
            invitedAddresses.pop();
            delete invitedAddressIndex[user];
        }
    }

    /**
     * @notice Internal function to add a sub-moderator
     * @dev Called after invitation is accepted or by migration
     * @param _subMod Address of the new sub-moderator
     */
    function _addSubModInternal(address _subMod) internal {
        require(_subMod != address(0), "ADDR");
        require(!isSubMod[_subMod], "SUB");
        require(subMods.length < MAX_SUBMODS, "MAX");
        _requireNotBanned();
        require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(_subMod), "BAN");
        require(!chapterBannedUsers[_subMod], "BAN");

        // Add to array and mappings
        subModIndex[_subMod] = subMods.length;
        subMods.push(_subMod);
        isSubMod[_subMod] = true;

        // Stamp the new submod's claim baseline to the current per-seat value so
        // they do not inherit historical rewards accumulated before they joined.
        // We use the updated subMods.length (after push) for the new seat count.
        if (subMods.length > 0 && totalAggregateSubModsPOL > 0) {
            polClaimedByUser[_subMod] = totalAggregateSubModsPOL / subMods.length;
        }
        if (subMods.length > 0 && totalAggregateSubModsUSDC > 0) {
            usdcClaimedByUser[_subMod] = totalAggregateSubModsUSDC / subMods.length;
        }

        emit SubModAdded(_subMod, msg.sender);
    }

    /**
     * @notice Adds a new sub-moderator to the chapter (MIGRATION ONLY)
     * @dev This function is kept public ONLY for migrateChapter() compatibility
     * @param _subMod Address of the new sub-moderator
     *
     * Requirements:
     * - Caller must be diamond contract (for migration)
     */
    function addSubMod(address _subMod) public {
        require(msg.sender == diamondAddress, "AUTH");
        _addSubModInternal(_subMod);
    }

    /**
     * @notice Allows a subMod to voluntarily leave the chapter
     * @dev Distributes final rewards before removal
     */
    function removeMyself() external nonReentrant {
        require(isSubMod[msg.sender], "SUB");
        require(!isRemoved, "RMV");

        // Distribute final rewards (use internal to avoid nested nonReentrant)
        _requireNotBanned();
        _claimChapterRewardsInternal();

        // Remove from chapter
        _removeSubModInternal(msg.sender);

        emit SubModRemovedSelf(msg.sender, block.timestamp);
    }

    /**
     * @notice Removes a sub-moderator from the chapter
     * @dev Distributes all pending rewards before removal to ensure fairness
     * @param _subMod Address of the sub-moderator to remove
     *
     * Flow:
     * 1. Validate caller and subMod
     * 2. Distribute ALL rewards (subMod gets their final share)
     * 3. Remove subMod from array using swap-and-pop
     * 4. Clean up mappings
     *
     * Requirements:
     * - Caller must be chapter owner or platform owner
     * - Address must be a current subMod
     * - Address must not be zero address
     *
     * @custom:security Uses swap-and-pop for gas-efficient array removal
     */
    function removeSubMod(address _subMod) public nonReentrant {
        address platformOwner = _getPlatformOwner();

        require(_subMod != address(0), "ADDR");
        require(msg.sender == chapterOwner || msg.sender == platformOwner, "AUTH");

        if (msg.sender != platformOwner) {
            require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(msg.sender), "BAN");
        }

        _requireNotBanned();

        require(isSubMod[_subMod], "SUB");

        // Distribute all rewards before removal (use internal to avoid nested nonReentrant)
        _claimChapterRewardsInternal();

        // Remove from array using swap-and-pop
        uint256 index = subModIndex[_subMod];
        uint256 lastIndex = subMods.length - 1;

        if (index != lastIndex) {
            address lastSubMod = subMods[lastIndex];
            subMods[index] = lastSubMod;
            subModIndex[lastSubMod] = index;
        }

        subMods.pop();

        // Clean up mappings
        isSubMod[_subMod] = false;
        delete subModIndex[_subMod];

        // Deregister from Diamond-side multi-chapter subMod registry
        IVoxDiamond(diamondAddress).deregisterSubMod(_subMod);

        emit SubModRemoved(_subMod, msg.sender);
    }

    /**
     * @notice Internal function to remove a subMod without distributing rewards
     * @dev Used when banning a user - no rewards should be distributed
     * @param _subMod Address of the sub-moderator to remove
     */
    function _removeSubModInternal(address _subMod) internal {
        // Remove from array using swap-and-pop
        uint256 index = subModIndex[_subMod];
        uint256 lastIndex = subMods.length - 1;

        if (index != lastIndex) {
            address lastSubMod = subMods[lastIndex];
            subMods[index] = lastSubMod;
            subModIndex[lastSubMod] = index;
        }

        subMods.pop();

        // Clean up mappings
        isSubMod[_subMod] = false;
        delete subModIndex[_subMod];

        // Deregister from Diamond-side multi-chapter subMod registry
        IVoxDiamond(diamondAddress).deregisterSubMod(_subMod);

        emit SubModRemoved(_subMod, msg.sender);
    }

    // ============================================
    // REWARD DISTRIBUTION FUNCTIONS
    // ============================================

    /**
     * @notice Internal function to detect and process new POL and USDC deposits
     * @dev Implements balance delta detection pattern, matching the diamond facet approach.
     *      Compares current balances with last known balances to detect new deposits.
     *      Automatically splits new deposits between owner and subMods based on chapterOwnerShare.
     *
     * POL Split:
     * - Owner: (newDeposits * chapterOwnerShare) / 100
     * - SubMods: newDeposits - ownerAmount
     *
     * USDC Split:
     * - Owner: (newDeposits * chapterOwnerShare) / 100
     * - SubMods: newDeposits - ownerAmount
     *
     * Process:
     * 1. Check current POL balance vs lastKnownPOLBalance
     * 2. If increased, calculate delta and split
     * 3. Check current USDC balance vs lastKnownUSDCBalance
     * 4. If increased, calculate delta and split
     * 5. Update aggregate trackers
     * 6. Update last known balances
     *
     * Emits: POLDeposited and/or USDCDeposited if new deposits detected
     *
     * @custom:pattern Called at start of claim operations to catch external deposits
     * @custom:safety Handles direct transfers that contract can't normally detect
     */
    function processNewDeposits() internal {
        // Process POL deposits
        uint256 currentPOLBalance = address(this).balance;
        if (currentPOLBalance > lastKnownPOLBalance) {
            uint256 newPOLDeposits = currentPOLBalance - lastKnownPOLBalance;

            uint256 ownerPOLAmount;
            uint256 subModsPOLAmount;

            if (subMods.length == 0) {
                // No submods — owner takes everything so the submod pool stays at zero
                ownerPOLAmount = newPOLDeposits;
                subModsPOLAmount = 0;
            } else {
                // Split based on chapter owner share
                ownerPOLAmount = (newPOLDeposits * chapterOwnerShare) / totalShare;
                subModsPOLAmount = newPOLDeposits - ownerPOLAmount;
            }

            // Update aggregates
            totalAggregateOwnerPOL += ownerPOLAmount;
            totalAggregateSubModsPOL += subModsPOLAmount;
            lastKnownPOLBalance = currentPOLBalance;

            emit POLDeposited(newPOLDeposits, ownerPOLAmount, subModsPOLAmount);
        }

        // Process USDC deposits
        address usdcAddress = getUSDCAddress();
        if (usdcAddress != address(0)) {
            IERC20 usdcToken = IERC20(usdcAddress);
            uint256 currentUSDCBalance = usdcToken.balanceOf(address(this));

            if (currentUSDCBalance > lastKnownUSDCBalance) {
                uint256 newUSDCDeposits = currentUSDCBalance - lastKnownUSDCBalance;

                uint256 ownerUSDCAmount;
                uint256 subModsUSDCAmount;

                if (subMods.length == 0) {
                    ownerUSDCAmount = newUSDCDeposits;
                    subModsUSDCAmount = 0;
                } else {
                    // Split based on chapter owner share
                    ownerUSDCAmount = (newUSDCDeposits * chapterOwnerShare) / totalShare;
                    subModsUSDCAmount = newUSDCDeposits - ownerUSDCAmount;
                }

                // Update aggregates
                totalAggregateOwnerUSDC += ownerUSDCAmount;
                totalAggregateSubModsUSDC += subModsUSDCAmount;
                lastKnownUSDCBalance = currentUSDCBalance;

                emit USDCDeposited(newUSDCDeposits, ownerUSDCAmount, subModsUSDCAmount);
            }
        }
    }

    /**
     * @notice Internal helper to distribute rewards to chapter owner
     * @return polDist POL distributed to owner
     * @return usdcDist USDC distributed to owner
     * @return polRemaining Remaining POL balance after distribution
     * @return usdcRemaining Remaining USDC balance after distribution
     */
    function _distributeToOwner(
        uint256 polBalance,
        uint256 usdcBalance,
        address usdcAddress,
        IERC20 usdcToken
    ) internal returns (uint256 polDist, uint256 usdcDist, uint256 polRemaining, uint256 usdcRemaining) {
        polRemaining = polBalance;
        usdcRemaining = usdcBalance;

        // Calculate owner's claimable amounts.
        // Saturating subtraction: after an admin rotation (setChapterAdmin /
        // removeMyselfAndAppointSuccessor) a newly-promoted address may already
        // carry a non-zero polClaimedByUser / usdcClaimedByUser stamp from a
        // prior subMod seat or from the old-owner payout path. That residual
        // can temporarily exceed the owner aggregate for the new owner, so
        // the naive subtraction would underflow and brick every claim.
        address ownerAddr = chapterOwner;
        uint256 ownerPOLClaimable = totalAggregateOwnerPOL > polClaimedByUser[ownerAddr] ? totalAggregateOwnerPOL - polClaimedByUser[ownerAddr] : 0;
        uint256 ownerUSDCClaimable = totalAggregateOwnerUSDC > usdcClaimedByUser[ownerAddr]
            ? totalAggregateOwnerUSDC - usdcClaimedByUser[ownerAddr]
            : 0;

        // Distribute POL to chapter owner
        if (ownerPOLClaimable > 0 && polBalance > 0) {
            uint256 transfer = ownerPOLClaimable > polBalance ? polBalance : ownerPOLClaimable;
            (bool success, ) = payable(chapterOwner).call{value: transfer}("");
            if (success) {
                polClaimedByUser[chapterOwner] += transfer;
                polDist = transfer;
                totalPOLEarnedByUser[chapterOwner] += transfer;
                polRemaining -= transfer;
            }
        }

        // Distribute USDC to chapter owner
        if (ownerUSDCClaimable > 0 && usdcAddress != address(0) && usdcBalance > 0) {
            uint256 transfer = ownerUSDCClaimable > usdcBalance ? usdcBalance : ownerUSDCClaimable;
            try usdcToken.transfer(chapterOwner, transfer) returns (bool transferSuccess) {
                if (transferSuccess) {
                    usdcClaimedByUser[chapterOwner] += transfer;
                    usdcDist = transfer;
                    totalUSDCEarnedByUser[chapterOwner] += transfer;
                    usdcRemaining -= transfer;
                }
            } catch {
                emit USDCTransferFailed(chapterOwner, transfer);
            }
        }
    }

    /**
     * @notice Internal helper to distribute rewards to subMods
     * @return polDist Total POL distributed to all subMods
     * @return usdcDist Total USDC distributed to all subMods
     */
    function _distributeToSubMods(
        uint256 polBalance,
        uint256 usdcBalance,
        address usdcAddress,
        IERC20 usdcToken
    ) internal returns (uint256 polDist, uint256 usdcDist) {
        if (subMods.length == 0) {
            // No submods at claim time. Redirect any residual submod pool to the owner.
            // processNewDeposits() already routes new deposits to owner when subMods.length==0,
            // so totalAggregateSubModsPOL here is only the prior-accumulated residual.
            if (totalAggregateSubModsPOL > 0 && polBalance > 0) {
                uint256 transfer = totalAggregateSubModsPOL > polBalance ? polBalance : totalAggregateSubModsPOL;
                (bool success, ) = payable(chapterOwner).call{value: transfer}("");
                if (success) {
                    totalAggregateOwnerPOL += transfer;
                    polClaimedByUser[chapterOwner] += transfer;
                    totalAggregateSubModsPOL -= transfer;
                    polDist = transfer;
                    totalPOLEarnedByUser[chapterOwner] += transfer;
                }
            }
            if (totalAggregateSubModsUSDC > 0 && usdcAddress != address(0) && usdcBalance > 0) {
                uint256 transfer = totalAggregateSubModsUSDC > usdcBalance ? usdcBalance : totalAggregateSubModsUSDC;
                try usdcToken.transfer(chapterOwner, transfer) returns (bool transferSuccess) {
                    if (transferSuccess) {
                        totalAggregateOwnerUSDC += transfer;
                        usdcClaimedByUser[chapterOwner] += transfer;
                        totalAggregateSubModsUSDC -= transfer;
                        usdcDist = transfer;
                        totalUSDCEarnedByUser[chapterOwner] += transfer;
                    }
                } catch {
                    emit USDCTransferFailed(chapterOwner, transfer);
                }
            }
            return (polDist, usdcDist);
        }

        uint256 polPerSubMod = totalAggregateSubModsPOL / subMods.length;
        uint256 usdcPerSubMod = totalAggregateSubModsUSDC / subMods.length;

        // Invariant: integer-division residue (totalAggregateSubModsX % subMods.length)
        // is INTENTIONALLY not redistributed here. totalAggregateSubModsX is never
        // decremented in the per-seat payout path — only each subMod's
        // polClaimedByUser / usdcClaimedByUser advances toward polPerSubMod /
        // usdcPerSubMod. The undivided remainder therefore carries forward and is
        // absorbed into the next round's per-seat quotient once the next deposit
        // lands. Do NOT "fix" this by adding `totalAggregateSubModsX -= ...` — it
        // would double-deduct the residue once it is eventually paid out.

        for (uint256 i = 0; i < subMods.length; i++) {
            address subMod = subMods[i];

            // POL distribution
            if (polBalance > 0) {
                uint256 claimable = polPerSubMod > polClaimedByUser[subMod] ? polPerSubMod - polClaimedByUser[subMod] : 0;
                if (claimable > 0) {
                    uint256 transfer = claimable > polBalance ? polBalance : claimable;
                    (bool success, ) = payable(subMod).call{value: transfer}("");
                    if (success) {
                        polClaimedByUser[subMod] += transfer;
                        polDist += transfer;
                        totalPOLEarnedByUser[subMod] += transfer;
                        polBalance -= transfer;
                    }
                }
            }

            // USDC distribution
            if (usdcBalance > 0 && usdcAddress != address(0)) {
                uint256 claimable = usdcPerSubMod > usdcClaimedByUser[subMod] ? usdcPerSubMod - usdcClaimedByUser[subMod] : 0;
                if (claimable > 0) {
                    uint256 transfer = claimable > usdcBalance ? usdcBalance : claimable;
                    try usdcToken.transfer(subMod, transfer) returns (bool transferSuccess) {
                        if (transferSuccess) {
                            usdcClaimedByUser[subMod] += transfer;
                            usdcDist += transfer;
                            totalUSDCEarnedByUser[subMod] += transfer;
                            usdcBalance -= transfer;
                        }
                    } catch {
                        emit USDCTransferFailed(subMod, transfer);
                    }
                }
            }
        }
    }

    /**
     * @notice Distributes accumulated POL and USDC rewards to chapter owner and subMods
     * @dev Can be called by ANYONE. Uses aggregate tracking with balance delta detection.
     *      Matches the diamond facet pattern for consistent reward handling.
     *
     * Distribution Logic (NEW - Aggregate Based):
     * 1. Process new deposits first (balance delta detection)
     * 2. Owner claims: totalAggregateOwnerPOL/USDC - polClaimedByUser[owner]
     * 3. Each SubMod claims: their proportional share of totalAggregateSubModsPOL/USDC
     *
     * SubMod Share Calculation:
     * - Each subMod gets: totalAggregateSubModsPOL / subModCount (equal split)
     * - Same for USDC
     *
     * Example with 1000 POL, 70% owner share, 3 subMods:
     * - Owner aggregate: 700 POL
     * - SubMods aggregate: 300 POL total → 100 POL each
     *
     * @return polDistributed Total POL successfully distributed in this call
     * @return usdcDistributed Total USDC successfully distributed in this call
     *
     * Requirements:
     * - Chapter must not be removed or banned
     * - Must have claimable amounts > 0
     *
     * @custom:security Uses low-level call for POL to prevent gas griefing
     * @custom:security Continues distribution even if individual transfers fail
     * @custom:pattern Aggregate-based distribution prevents reward calculation issues
     */
    function claimChapterRewards() public nonReentrant returns (uint256 polDistributed, uint256 usdcDistributed) {
        _requireNotBanned();

        // Restrict to authorized callers: chapter owner, subMods, or platform owner
        require(msg.sender == chapterOwner || isSubMod[msg.sender] || msg.sender == _getPlatformOwner(), "AUTH");

        return _claimChapterRewardsInternal();
    }

    /**
     * @dev Internal distribution logic without access control.
     *      Used by claimChapterRewards (after AUTH check) and by internal
     *      callers such as acceptSubModInvitation that have their own guards.
     */
    function _claimChapterRewardsInternal() internal returns (uint256 polDistributed, uint256 usdcDistributed) {
        // Process any new deposits first (balance delta detection)
        processNewDeposits();

        // Get token info
        address usdcAddress = getUSDCAddress();
        IERC20 usdcToken = usdcAddress != address(0) ? IERC20(usdcAddress) : IERC20(address(0));

        uint256 polBalance = address(this).balance;
        uint256 usdcBalance = usdcAddress != address(0) ? usdcToken.balanceOf(address(this)) : 0;

        require(polBalance >= minClaimThresholdPOL || usdcBalance >= minClaimThresholdUSDC, "BAL");

        // Distribute to owner
        (uint256 ownerPOL, uint256 ownerUSDC, uint256 polRemaining, uint256 usdcRemaining) = _distributeToOwner(
            polBalance,
            usdcBalance,
            usdcAddress,
            usdcToken
        );

        polDistributed += ownerPOL;
        usdcDistributed += ownerUSDC;

        // Distribute to subMods
        (uint256 subModsPOL, uint256 subModsUSDC) = _distributeToSubMods(polRemaining, usdcRemaining, usdcAddress, usdcToken);

        polDistributed += subModsPOL;
        usdcDistributed += subModsUSDC;

        // Update chapter-level tracking
        totalPOLDistributed += polDistributed;
        totalUSDCDistributed += usdcDistributed;
        lastDistributionTimestamp = block.timestamp;

        // Update last known balances to actual current balances
        lastKnownPOLBalance = address(this).balance;
        lastKnownUSDCBalance = usdcAddress != address(0) ? usdcToken.balanceOf(address(this)) : 0;

        // Emit event with distribution details
        uint256 recipientCount = 1 + subMods.length;
        emit RewardsDistributed(polDistributed, usdcDistributed, block.timestamp, recipientCount);

        return (polDistributed, usdcDistributed);
    }

    // ============================================
    // ADMIN SUCCESSION FUNCTIONS
    // ============================================

    /**
     * @dev Shared ownership-handoff core. Settles accrued rewards to the outgoing
     *      owner + subMods (or, when balances sit below the claim threshold, folds
     *      any pending deposits into the aggregates without paying out so the call
     *      does not revert "BAL"), transfers ownership via the Diamond callback,
     *      drops the incoming/outgoing addresses from the subMod roster if present,
     *      and rebaselines the new owner's claim stamp to a zero owner-gap.
     *
     *      The rebaseline is critical: without it the new owner would inherit
     *      (totalAggregateOwnerX - their prior claim stamp) as an immediate phantom
     *      claim that over-draws the chapter on the next deposit.
     *
     *      Caller is responsible for ALL authorization and input validation (owner
     *      check, zero-address, removed/banned, platform-ban of newAdmin).
     * @param newAdmin Address receiving ownership. Must differ from the current owner.
     * @return oldOwner The address that held ownership before the handoff.
     */
    function _handoffOwnership(address newAdmin) internal returns (address oldOwner) {
        oldOwner = chapterOwner;
        require(newAdmin != oldOwner, "SELF");

        // Settle rewards if at/above threshold; otherwise just fold pending deposits
        // into the aggregates so the rebaseline below uses up-to-date totals.
        if (address(this).balance >= minClaimThresholdPOL || _getUSDCBalance() >= minClaimThresholdUSDC) {
            _claimChapterRewardsInternal();
        } else {
            processNewDeposits();
        }

        // Update diamond storage via callback. Reverts if newAdmin already manages
        // another chapter, unless newAdmin is the platform owner (exempt).
        IVoxDiamond(diamondAddress).updateChapterAdmin(oldOwner, newAdmin);

        // Update chapter ownership
        chapterOwner = newAdmin;

        // The new owner can no longer hold a subMod seat; the outgoing owner may have one.
        if (isSubMod[newAdmin]) {
            _removeSubModInternal(newAdmin);
        }
        if (isSubMod[oldOwner]) {
            _removeSubModInternal(oldOwner);
        }

        // Rebaseline: new owner starts at a zero owner-gap and earns only from the
        // next deposit onward.
        polClaimedByUser[newAdmin] = totalAggregateOwnerPOL;
        usdcClaimedByUser[newAdmin] = totalAggregateOwnerUSDC;

        emit ChapterOwnerChanged(oldOwner, newAdmin);
    }

    /**
     * @notice Allows the chapter owner to step down and appoint ANY address as the
     *         new owner (no subMod or on-chain consent requirement).
     * @dev Settles rewards, transfers ownership, and rebaselines the new owner. If
     *      the appointee does not want the role they may call this again (or
     *      parkChapter) to pass it on. An appointee that never acts can only be
     *      replaced by the platform owner via setChapterAdmin / revokeChapterAdmin.
     * @param newAdmin Address to appoint as the new chapter owner.
     *
     * Requirements:
     * - Caller must be the current chapter owner
     * - newAdmin must be non-zero, differ from the current owner, and not platform-banned
     * - Chapter must not be removed or banned
     */
    function removeMyselfAndAppointSuccessor(address newAdmin) external nonReentrant {
        require(msg.sender == chapterOwner, "AUTH");
        require(newAdmin != address(0), "ADDR");
        require(!isRemoved, "RMV");
        require(!isBanned, "BAN");

        require(!IVoxDiamond(diamondAddress).isUserBannedFromPlatform(newAdmin), "BAN");

        address oldOwner = _handoffOwnership(newAdmin);

        emit AdminSuccessionCompleted(oldOwner, newAdmin, block.timestamp);
    }

    /**
     * @notice Allows the chapter owner to "park" the chapter under the platform
     *         owner instead of permanently removing it.
     * @dev Softer alternative to removeChapter: ownership transfers to the platform
     *      owner (exempt from the single-chapter eligibility check), rewards are
     *      settled to the outgoing owner + subMods, and the chapter stays active.
     *      The platform owner receives the owner share until reassigning the chapter
     *      via setChapterAdmin. SubMods are retained.
     *
     * Requirements:
     * - Caller must be the current chapter owner
     * - Chapter must not be removed or banned
     * - Chapter must not already be owned by the platform owner
     */
    function parkChapter() external nonReentrant {
        require(msg.sender == chapterOwner, "AUTH");
        require(!isRemoved, "RMV");
        require(!isBanned, "BAN");

        address platformOwner = _getPlatformOwner();
        require(chapterOwner != platformOwner, "ALREADY");

        address oldOwner = _handoffOwnership(platformOwner);

        emit ChapterParked(oldOwner, platformOwner, block.timestamp);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Gets the claimable rewards for a user including unprocessed deposits
     * @dev Returns actual claimable amounts, INCLUDING unprocessed deposits
     * @param user Address to check rewards for
     * @return polReward Claimable POL reward for the user
     * @return usdcReward Claimable USDC reward for the user
     *
     * Note: This simulates deposit detection to show true pending rewards.
     *       The actual claim will process deposits and may differ slightly.
     *
     * Returns (0, 0) if:
     * - User is not chapter owner or subMod
     * - User has already claimed all available rewards
     */
    function getPendingRewards(address user) external view returns (uint256 polReward, uint256 usdcReward) {
        // Simulate deposit detection for accurate pending calculation
        uint256 currentPOLBalance = address(this).balance;
        uint256 tempAggregateOwnerPOL = totalAggregateOwnerPOL;
        uint256 tempAggregateSubModsPOL = totalAggregateSubModsPOL;
        uint256 tempAggregateOwnerUSDC = totalAggregateOwnerUSDC;
        uint256 tempAggregateSubModsUSDC = totalAggregateSubModsUSDC;

        // Process POL deposits virtually
        if (currentPOLBalance > lastKnownPOLBalance) {
            uint256 newPOLDeposits = currentPOLBalance - lastKnownPOLBalance;
            uint256 ownerPOLAmount = (newPOLDeposits * chapterOwnerShare) / totalShare;
            uint256 subModsPOLAmount = newPOLDeposits - ownerPOLAmount;
            tempAggregateOwnerPOL += ownerPOLAmount;
            tempAggregateSubModsPOL += subModsPOLAmount;
        }

        // Process USDC deposits virtually
        address usdcAddress = getUSDCAddress();
        if (usdcAddress != address(0)) {
            IERC20 usdcToken = IERC20(usdcAddress);
            uint256 currentUSDCBalance = usdcToken.balanceOf(address(this));

            if (currentUSDCBalance > lastKnownUSDCBalance) {
                uint256 newUSDCDeposits = currentUSDCBalance - lastKnownUSDCBalance;
                uint256 ownerUSDCAmount = (newUSDCDeposits * chapterOwnerShare) / totalShare;
                uint256 subModsUSDCAmount = newUSDCDeposits - ownerUSDCAmount;
                tempAggregateOwnerUSDC += ownerUSDCAmount;
                tempAggregateSubModsUSDC += subModsUSDCAmount;
            }
        }

        // Calculate pending rewards based on virtual aggregates
        if (user == chapterOwner) {
            // Saturating subtraction: mirrors _distributeToOwner. A newly-promoted
            // owner may carry a residual polClaimedByUser / usdcClaimedByUser stamp
            // that temporarily exceeds the owner aggregate.
            polReward = tempAggregateOwnerPOL > polClaimedByUser[user] ? tempAggregateOwnerPOL - polClaimedByUser[user] : 0;
            usdcReward = tempAggregateOwnerUSDC > usdcClaimedByUser[user] ? tempAggregateOwnerUSDC - usdcClaimedByUser[user] : 0;
        } else if (isSubMod[user] && subMods.length > 0) {
            uint256 polPerSubMod = tempAggregateSubModsPOL / subMods.length;
            uint256 usdcPerSubMod = tempAggregateSubModsUSDC / subMods.length;

            // Guard against underflow: a new submod's claim baseline may already equal polPerSubMod
            polReward = polPerSubMod > polClaimedByUser[user] ? polPerSubMod - polClaimedByUser[user] : 0;
            usdcReward = usdcPerSubMod > usdcClaimedByUser[user] ? usdcPerSubMod - usdcClaimedByUser[user] : 0;
        }
    }

    /**
     * @notice Returns all sub-moderator addresses
     * @return Array of all current sub-moderator addresses
     */
    function getAllSubMods() external view returns (address[] memory) {
        return subMods;
    }

    /**
     * @notice Gets the total number of sub-moderators
     * @return Number of sub-moderators in this chapter
     */
    function getSubModCount() external view returns (uint256) {
        return subMods.length;
    }

    /**
     * @notice Checks if an address is authorized (owner or subMod)
     * @param user Address to check
     * @return True if address is chapter owner or a sub-moderator
     */
    function isAuthorized(address user) external view returns (bool) {
        return user == chapterOwner || isSubMod[user];
    }

    /**
     * @notice Gets comprehensive chapter statistics
     * @return name Chapter name
     * @return id Chapter ID
     * @return owner Current chapter owner address
     * @return ownerShare Owner's share percentage
     * @return subModCount Number of sub-moderators
     * @return polBalance Current POL balance
     * @return usdcBalance Current USDC balance
     * @return subModsList Array of all sub-moderator addresses
     */
    function getChapterStats()
        external
        view
        returns (
            string memory name,
            string memory id,
            address owner,
            uint256 ownerShare,
            uint256 subModCount,
            uint256 polBalance,
            uint256 usdcBalance,
            address[] memory subModsList
        )
    {
        address usdcAddress = getUSDCAddress();

        return (
            chapterName,
            chapterID,
            chapterOwner,
            chapterOwnerShare,
            subMods.length,
            address(this).balance,
            usdcAddress != address(0) ? IERC20(usdcAddress).balanceOf(address(this)) : 0,
            subMods
        );
    }

    // ============================================
    // RECEIVE FUNCTION
    // ============================================

    /**
     * @notice Allows the contract to receive POL (native token)
     * @dev POL is detected via balance delta detection in processNewDeposits()
     *      Matches the diamond facet pattern for consistent behavior.
     *      No immediate processing needed - lazy evaluation on claim.
     */
    receive() external payable {
        // POL received - will be detected and split in processNewDeposits()
        // Called lazily during claimChapterRewards() or other operations
    }

    /**
     * @notice Migrates USDC to new chapter (only callable by diamond)
     * @param newChapter Address of new chapter
     * @param amount Amount to transfer
     */
    function migrateUSDC(address newChapter, uint256 amount) external {
        require(msg.sender == diamondAddress, "AUTH");
        address usdcAddress = getUSDCAddress();
        require(usdcAddress != address(0), "USDC");
        SafeERC20.safeTransfer(IERC20(usdcAddress), newChapter, amount);
    }

    /**
     * @notice Migrates POL to new chapter (only callable by diamond)
     * @param newChapter Address of new chapter
     */
    function migratePOL(address payable newChapter) external {
        require(msg.sender == diamondAddress, "AUTH");
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = newChapter.call{value: balance}("");
            require(success, "POL");
        }
    }

    // ============================================
    // MIGRATION STATE FUNCTIONS (diamond-gated)
    // ============================================

    /**
     * @notice Packed snapshot of scalar state used during chapter migration
     * @dev Returned by getMigrationSnapshot() and consumed by migrateState().
     *      Bundled into a struct so the caller needs only one stack slot.
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
     * @notice Returns all migration-relevant scalar state in a single call
     * @dev Called by the diamond during migrateChapter to reduce stack pressure on the caller.
     */
    function getMigrationSnapshot() external view returns (MigrationSnapshot memory snap) {
        snap.ownerShare = chapterOwnerShare;
        snap.aggOwnerPOL = totalAggregateOwnerPOL;
        snap.aggOwnerUSDC = totalAggregateOwnerUSDC;
        snap.aggSubModsPOL = totalAggregateSubModsPOL;
        snap.aggSubModsUSDC = totalAggregateSubModsUSDC;
        snap.minPOL = minClaimThresholdPOL;
        snap.minUSDC = minClaimThresholdUSDC;
    }

    /**
     * @notice Restores scalar state fields from the old chapter during migration
     * @dev Only callable by the diamond during migrateChapter. Sets all numeric state
     *      that cannot be expressed via initialize() without exposing it publicly.
     *      lastKnownPOLBalance and lastKnownUSDCBalance are set to the migrated fund
     *      amounts so that processNewDeposits() does not double-count the transfer.
     * @param snap Packed scalar state snapshot from getMigrationSnapshot()
     * @param _lastKnownPOL lastKnownPOLBalance to stamp on new chapter (= transferred POL)
     * @param _lastKnownUSDC lastKnownUSDCBalance to stamp on new chapter (= transferred USDC)
     */
    function migrateState(MigrationSnapshot calldata snap, uint256 _lastKnownPOL, uint256 _lastKnownUSDC) external {
        require(msg.sender == diamondAddress, "AUTH");
        chapterOwnerShare = snap.ownerShare;
        totalAggregateOwnerPOL = snap.aggOwnerPOL;
        totalAggregateOwnerUSDC = snap.aggOwnerUSDC;
        totalAggregateSubModsPOL = snap.aggSubModsPOL;
        totalAggregateSubModsUSDC = snap.aggSubModsUSDC;
        minClaimThresholdPOL = snap.minPOL;
        minClaimThresholdUSDC = snap.minUSDC;
        lastKnownPOLBalance = _lastKnownPOL;
        lastKnownUSDCBalance = _lastKnownUSDC;
    }

    /**
     * @notice Restores per-user claim accounting from the old chapter during migration
     * @dev Only callable by the diamond during migrateChapter. Iterates owner + active subMods.
     *      Arrays must be same length; mismatched input is caller error.
     * @param users Addresses to restore (owner + all subMods at migration time)
     * @param polClaimed polClaimedByUser values from old chapter
     * @param usdcClaimed usdcClaimedByUser values from old chapter
     */
    function migrateUserClaims(address[] calldata users, uint256[] calldata polClaimed, uint256[] calldata usdcClaimed) external {
        require(msg.sender == diamondAddress, "AUTH");
        require(users.length == polClaimed.length && users.length == usdcClaimed.length, "LEN");
        for (uint256 i = 0; i < users.length; i++) {
            polClaimedByUser[users[i]] = polClaimed[i];
            usdcClaimedByUser[users[i]] = usdcClaimed[i];
        }
    }

    /**
     * @notice Restores chapter-level user bans from the old chapter during migration
     * @dev Only callable by the diamond during migrateChapter. Rebuilds both the mapping
     *      and the enumerable bannedUsersArray.
     * @param users Addresses that were banned in the old chapter (from getBannedUsersArray())
     */
    function migrateBannedUsers(address[] calldata users) external {
        require(msg.sender == diamondAddress, "AUTH");
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!chapterBannedUsers[user]) {
                chapterBannedUsers[user] = true;
                bannedUsersArrayIndex[user] = bannedUsersArray.length + 1;
                bannedUsersArray.push(user);
            }
        }
    }
}
