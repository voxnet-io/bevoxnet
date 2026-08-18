// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../VoxChapter.sol";
import "../interfaces/IVoxChapter.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import {LibVoxViewStructs} from "../libraries/LibVoxViewStructs.sol";

/**
 * @title VoxFacet
 * @author Vox Team
 * @notice Manages chapter creation and administration for the Vox platform
 * @dev This facet handles:
 *      - Chapter contract deployment and registration
 *      - Chapter admin assignment and verification
 *      - Signature-based authorization for chapter creation
 *      - Chapter lookup and enumeration
 *
 *      Security features:
 *      - ECDSA signature verification for chapter creation
 *      - One chapter per admin limit (unless platform owner)
 *      - Prevents duplicate chapter names
 *      - Admin status tracking and verification
 *
 *      Architecture:
 *      - Each chapter is a separate VoxChapter contract
 *      - Bidirectional mapping between admins and chapters
 *      - Chapter registry for enumeration and lookup
 */
contract VoxFacet is ReentrancyGuard {
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    using Clones for address;

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a new chapter is created
     * @param chapterName The name of the newly created chapter
     * @param chapterID The unique identifier for the chapter
     * @param chapterAddress The deployed contract address of the chapter
     * @param admin The address of the chapter administrator
     */
    event ChapterCreated(string indexed chapterName, string chapterID, address indexed chapterAddress, address indexed admin);

    /**
     * @notice Emitted when an admin is assigned to a chapter
     * @param admin The address of the administrator
     * @param chapterAddress The chapter contract address
     */
    event AdminAssigned(address indexed admin, address indexed chapterAddress);

    /// @notice Emitted when chapter implementation is upgraded
    event ChapterImplementationUpgraded(address indexed oldImplementation, address indexed newImplementation);

    /**
     * @notice Emitted when a chapter is banned by platform owner
     * @param chapterName The name of the banned chapter
     * @param chapterAddress The address of the banned chapter
     * @param bannedBy The address that issued the ban (platform owner)
     * @param blockNumber Block number when ban was applied
     */
    event ChapterBanned(string indexed chapterName, address indexed chapterAddress, address indexed bannedBy, uint256 blockNumber);

    /**
     * @notice Emitted when a chapter is unbanned by platform owner
     * @param chapterName The name of the unbanned chapter
     * @param chapterAddress The address of the unbanned chapter
     * @param unbannedBy The address that removed the ban
     * @param blockNumber Block number when chapter was unbanned
     */
    event ChapterUnbanned(string indexed chapterName, address indexed chapterAddress, address indexed unbannedBy, uint256 blockNumber);

    /**
     * @notice Emitted when a chapter is removed (permanently)
     * @param chapterName The name of the removed chapter
     * @param chapterAddress The address of the removed chapter
     * @param removedBy Address that removed the chapter (platform owner or chapter admin)
     * @param blockNumber Block number when chapter was removed
     */
    event ChapterRemoved(string indexed chapterName, address indexed chapterAddress, address indexed removedBy, uint256 blockNumber);

    /**
     * @notice Emitted when an address enters the global sub-mod roster
     * @dev Fires only on the 0→1 chapter-count transition, i.e. the first time
     *      the address becomes a sub-mod of any chapter. Subsequent registrations
     *      in additional chapters do NOT re-emit this event; track those via the
     *      per-chapter `SubModAdded`/`SubModRegisteredForChapter`-style events
     *      on VoxChapter.
     * @param subMod The address now present in `getAllRegisteredSubMods()`
     */
    event SubModRegistered(address indexed subMod);

    /**
     * @notice Emitted when an address leaves the global sub-mod roster
     * @dev Fires only on the 1→0 chapter-count transition, i.e. the last chapter
     *      they belonged to has deregistered them. If the address is still a
     *      sub-mod of ≥1 other chapter, this event does NOT fire.
     * @param subMod The address removed from `getAllRegisteredSubMods()`
     */
    event SubModDeregistered(address indexed subMod);

    // ============================================
    // STATE VARIABLES
    // ============================================

    // chapterImplementation was previously stored as a bare contract variable (slot 0).
    // It is now stored in LibVoxStorage.VoxMainStorage.chapterImplementation
    // to prevent Diamond storage collisions. All accesses go through mainStorage().

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Sets the initial chapter implementation
     * @dev Should be called once during deployment
     * @param _implementation Address of VoxChapter implementation
     */
    function setChapterImplementation(address _implementation) external {
        LibDiamond.enforceIsContractOwner();
        require(_implementation != address(0), "Invalid implementation");
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        address oldImplementation = mainStorage.chapterImplementation;
        mainStorage.chapterImplementation = _implementation;
        emit ChapterImplementationUpgraded(oldImplementation, _implementation);
    }

    // ============================================
    // CHAPTER CREATION FUNCTIONS
    // ============================================

    /**
     * @notice Creates a new chapter with cryptographic signature verification
     * @dev Deploys a new VoxChapter contract and registers it in the platform.
     *      The chapter name must be signed by the platform's signing address to prevent unauthorized creation.
     *
     *      Creation Process:
     *      1. Verify signature authenticity (must be signed by platform signing address)
     *      2. Validate caller eligibility (owner can create multiple, others limited to one)
     *      3. Check chapter name uniqueness
     *      4. Deploy new VoxChapter contract
     *      5. Register chapter in storage mappings
     *      6. Assign admin status to creator
     *      7. Add to chapter enumeration array
     *
     * @param chapterName The name of the new chapter (must be unique and non-empty)
     * @param chapterID The unique identifier for the chapter (stored in chapter contract)
     * @param signature ECDSA signature of the chapterName signed by platform signing address
     * @return bool True if the chapter was created successfully
     *
     * Signature Verification:
     * - Message: keccak256(chapterName)
     * - Signer: Must be the platform's registered signing address
     * - Format: Ethereum signed message (EIP-191)
     *
     * Requirements:
     * - Signature must be valid and from platform signing address
     * - Non-owner callers must not already be chapter admins
     * - Chapter name must not be empty
     * - Chapter name must not already exist
     *
     * Emits: ChapterCreated event with chapter details
     * Emits: AdminAssigned event linking admin to chapter
     *
     * State Changes:
     * - Deploys new VoxChapter contract
     * - Adds chapter to chapterAddresses mapping
     * - Sets checkChapterAdminAddress[creator] to chapter address
     * - Sets checkChapterAdminAddressOut[chapter] to creator
     * - Marks creator as admin (isAdmin[creator] = true)
     * - Appends chapter name to chapterArray
     *
     * @custom:security Uses ECDSA signature to prevent unauthorized chapter creation
     * @custom:limit Non-owner users can only create one chapter
     */
    function createChapter(string memory chapterName, string memory chapterID, bytes memory signature) external nonReentrant returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = LibVoxGovernanceStorage.governanceStorage();

        // Check if user is banned
        require(!mainStorage.isUserPlatformBanned[msg.sender], "User is banned");

        // Verify signature — payload binds chapter name, caller address, and chain ID
        // to prevent front-running (reuse of a sig by a different wallet) and replay
        // across chains. The platform signing key signs keccak256(chapterName || msg.sender || chainid).
        address platformSigningAddress = govStorage.signingAddress;
        bytes32 messageHash = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(chapterName, msg.sender, block.chainid)));
        address recoveredSigner = ECDSA.recover(messageHash, signature);
        require(recoveredSigner == platformSigningAddress, "Invalid signature");

        // Validate caller eligibility
        if (msg.sender != diamondStorage.contractOwner) {
            require(mainStorage.checkChapterAdminAddress[msg.sender] == address(0), "Caller is already an admin of another chapter");
        }

        // Validate chapter name
        require(bytes(chapterName).length > 0, "Chapter name cannot be empty");
        require(mainStorage.chapterAddresses[chapterName] == address(0), "Chapter with this name already exists");
        require(mainStorage.chapterImplementation != address(0), "Chapter implementation not set");

        // Deploy minimal proxy clone instead of new contract
        address chapterAddress = mainStorage.chapterImplementation.clone();

        // Initialize the clone
        VoxChapter(payable(chapterAddress)).initialize(chapterName, chapterID, address(this), msg.sender);

        // Register chapter in storage
        mainStorage.chapterAddresses[chapterName] = chapterAddress;
        mainStorage.checkChapterAdminAddress[msg.sender] = chapterAddress;
        mainStorage.checkChapterAdminAddressOut[chapterAddress] = msg.sender;
        mainStorage.isAdmin[msg.sender] = true;
        mainStorage.chapterArrayIndex[chapterName] = mainStorage.chapterArray.length;
        mainStorage.chapterArray.push(chapterName);

        emit ChapterCreated(chapterName, chapterID, chapterAddress, msg.sender);
        emit AdminAssigned(msg.sender, chapterAddress);

        return true;
    }

    // ============================================
    // MIGRATION FUNCTIONS
    // ============================================

    /**
     * @notice Migrates a chapter to new implementation
     * @dev Creates new proxy pointing to new implementation, transfers state
     * @param chapterName Name of chapter to migrate
     * @return newChapterAddress Address of migrated chapter
     */
    function migrateChapter(string memory chapterName) public nonReentrant returns (address newChapterAddress) {
        LibDiamond.enforceIsContractOwner();
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        address oldChapterAddress = mainStorage.chapterAddresses[chapterName];
        require(oldChapterAddress != address(0), "Chapter does not exist");
        require(!mainStorage.isChapterBanned[oldChapterAddress], "Cannot migrate banned chapter");
        require(!mainStorage.isChapterRemoved[oldChapterAddress], "Cannot migrate removed chapter");
        require(mainStorage.chapterImplementation != address(0), "New implementation not set");

        address admin = mainStorage.checkChapterAdminAddressOut[oldChapterAddress];
        newChapterAddress = mainStorage.chapterImplementation.clone();

        // --- Initialize ---
        {
            VoxChapter old = VoxChapter(payable(oldChapterAddress));
            VoxChapter(payable(newChapterAddress)).initialize(chapterName, old.chapterID(), address(this), admin);
        }

        // --- Migrate subMods (kept in memory for later claim migration) ---
        address[] memory subMods = VoxChapter(payable(oldChapterAddress)).getAllSubMods();
        for (uint256 i = 0; i < subMods.length; i++) {
            // Clean up Diamond-side registry entry for old chapter, register for new chapter
            _deregisterSubModFromStorage(mainStorage, subMods[i], oldChapterAddress);
            VoxChapter(payable(newChapterAddress)).addSubMod(subMods[i]);
            _registerSubModInStorage(mainStorage, subMods[i], newChapterAddress);
        }

        // --- Transfer funds ---
        // Capture balance BEFORE calling migratePOL so we can stamp lastKnownPOLBalance
        uint256 migratedPOL = oldChapterAddress.balance;
        if (migratedPOL > 0) {
            VoxChapter(payable(oldChapterAddress)).migratePOL(payable(newChapterAddress));
        }
        uint256 migratedUSDC;
        {
            LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
            address usdcAddress = tokenStorage.usdcTokenAddress;
            if (usdcAddress != address(0)) {
                migratedUSDC = IERC20(usdcAddress).balanceOf(oldChapterAddress);
                if (migratedUSDC > 0) {
                    VoxChapter(payable(oldChapterAddress)).migrateUSDC(newChapterAddress, migratedUSDC);
                }
            }
        }

        // --- Restore scalar state (struct = 1 stack slot) ---
        {
            VoxChapter.MigrationSnapshot memory snap = VoxChapter(payable(oldChapterAddress)).getMigrationSnapshot();
            VoxChapter(payable(newChapterAddress)).migrateState(snap, migratedPOL, migratedUSDC);
        }

        // --- Restore per-user claim accounting ---
        {
            VoxChapter old = VoxChapter(payable(oldChapterAddress));
            uint256 count = subMods.length + 1;
            address[] memory claimUsers = new address[](count);
            uint256[] memory polClaimed = new uint256[](count);
            uint256[] memory usdcClaimed = new uint256[](count);
            claimUsers[0] = admin;
            polClaimed[0] = old.polClaimedByUser(admin);
            usdcClaimed[0] = old.usdcClaimedByUser(admin);
            for (uint256 i = 0; i < subMods.length; i++) {
                claimUsers[i + 1] = subMods[i];
                polClaimed[i + 1] = old.polClaimedByUser(subMods[i]);
                usdcClaimed[i + 1] = old.usdcClaimedByUser(subMods[i]);
            }
            VoxChapter(payable(newChapterAddress)).migrateUserClaims(claimUsers, polClaimed, usdcClaimed);
        }

        // --- Restore chapter-level bans ---
        {
            address[] memory banned = VoxChapter(payable(oldChapterAddress)).getBannedUsersArray();
            if (banned.length > 0) {
                VoxChapter(payable(newChapterAddress)).migrateBannedUsers(banned);
            }
        }

        // --- Update diamond storage ---
        mainStorage.chapterAddresses[chapterName] = newChapterAddress;
        mainStorage.checkChapterAdminAddress[admin] = newChapterAddress;
        mainStorage.checkChapterAdminAddressOut[newChapterAddress] = admin;
        delete mainStorage.checkChapterAdminAddressOut[oldChapterAddress];
    }

    /**
     * @notice Batch migrate multiple chapters
     * @param chapterNames Array of chapter names to migrate
     */
    function batchMigrateChapters(string[] memory chapterNames) external {
        LibDiamond.enforceIsContractOwner();
        for (uint256 i = 0; i < chapterNames.length; i++) {
            migrateChapter(chapterNames[i]);
        }
    }

    // ============================================
    // CHAPTER QUERY FUNCTIONS (VIEW)
    // ============================================

    /// @notice Returns the current EIP-1167 chapter implementation address
    function getChapterImplementation() external view returns (address) {
        return LibVoxStorage.mainStorage().chapterImplementation;
    }

    /**
     * @notice Checks if a chapter with the given name exists
     * @dev Verifies existence by checking if the chapter address is non-zero
     *
     * @param chapterName The name of the chapter to check
     * @return bool True if the chapter exists, false otherwise
     *
     * Use Cases:
     * - Front-end validation before chapter creation
     * - Duplicate name checking
     * - Chapter lookup verification
     */
    function chapterExists(string memory chapterName) external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterAddresses[chapterName] != address(0);
    }

    /**
     * @notice Retrieves the admin address for a given chapter contract
     * @dev Reverse lookup from chapter address to admin address
     *
     * @param _contractAddress The chapter contract address to query
     * @return address The admin address for the chapter, or address(0) if not found
     *
     * Use Cases:
     * - Verifying chapter ownership
     * - Admin contact lookup
     * - Permission verification for chapter operations
     */
    function getChapterAdminAddressOut(address _contractAddress) external view returns (address) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.checkChapterAdminAddressOut[_contractAddress];
    }

    /**
     * @notice Retrieves the total number of chapters created
     * @dev Returns the length of the chapter array for enumeration
     *
     * @return uint256 The total number of chapters in the platform
     *
     * Use Cases:
     * - Statistics and analytics
     * - Pagination calculation
     * - Platform growth tracking
     */
    function getTotalChapters() external view returns (uint256) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterArray.length;
    }

    /**
     * @notice Retrieves all chapter names in the platform
     * @dev Returns the complete array of chapter names for enumeration
     *
     * @return string[] Array containing all chapter names in creation order
     *
     * Use Cases:
     * - Full chapter listing
     * - Search and filter operations
     * - Platform-wide chapter discovery
     *
     * @custom:gas-warning May be expensive for large numbers of chapters
     * @custom:recommendation Use pagination in front-end for better UX
     */
    function getAllChapterNames() external view returns (string[] memory) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterArray;
    }

    /**
     * @notice Retrieves the contract address of a chapter by its name
     * @dev Primary lookup function for chapter contracts
     *
     * @param chapterName The name of the chapter to look up
     * @return address The chapter contract address, or address(0) if not found
     *
     * Use Cases:
     * - Chapter contract interaction
     * - Chapter existence verification
     * - Direct chapter contract calls
     *
     * Example:
     * ```solidity
     * address chapterAddr = getChapterAddress("MyChapter");
     * if (chapterAddr != address(0)) {
     *     VoxChapter(chapterAddr).someFunction();
     * }
     * ```
     */
    function getChapterAddress(string memory chapterName) external view returns (address) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterAddresses[chapterName];
    }

    /**
     * @notice Retrieves the chapter name at a specific index
     * @dev Provides indexed access to the chapter array for iteration
     *
     * @param index The zero-based index in the chapter array
     * @return string The name of the chapter at the specified index
     *
     * Requirements:
     * - Index must be less than the total number of chapters
     *
     * Use Cases:
     * - Paginated chapter listing
     * - Iterative chapter processing
     * - Random chapter access
     *
     * Reverts: If index is out of bounds
     *
     * @custom:note Consider removing if only used for off-chain operations
     */
    function getChapterNameAtIndex(uint256 index) external view returns (string memory) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(index < mainStorage.chapterArray.length, "Index out of bounds");
        return mainStorage.chapterArray[index];
    }

    /**
     * @notice Checks if the caller is an admin or platform owner
     * @dev Returns both admin status and owner status for comprehensive permission checking
     *
     * @return isAdmin True if the caller is a chapter administrator
     * @return isOwner True if the caller is the platform owner (contract owner)
     *
     * Use Cases:
     * - Permission verification before operations
     * - UI conditional rendering
     * - Access control checks in front-end
     *
     * Permission Levels:
     * - isAdmin only: Can manage their own chapter
     * - isOwner only: Can manage all chapters and platform settings
     * - Both: Platform owner who also created a chapter
     * - Neither: Regular user with no admin privileges
     */
    function getIsAdmin() external view returns (bool isAdmin, bool isOwner) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();

        isAdmin = mainStorage.isAdmin[msg.sender];
        isOwner = msg.sender == diamondStorage.contractOwner;
    }

    // ============================================
    // ADDITIONAL VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Retrieves paginated list of chapter names
     * @dev Provides gas-efficient pagination for large chapter lists
     *
     * @param offset The starting index (0-based)
     * @param limit The maximum number of chapters to return
     * @return chapters Array of chapter names within the specified range
     * @return total The total number of chapters available
     *
     * Example:
     * ```solidity
     * // Get first 10 chapters
     * (string[] memory chapters, uint256 total) = getChaptersPaginated(0, 10);
     *
     * // Get next 10 chapters
     * (chapters, total) = getChaptersPaginated(10, 10);
     * ```
     *
     * @custom:gas-optimization More efficient than getAllChapterNames() for large datasets
     */
    function getChaptersPaginated(uint256 offset, uint256 limit) external view returns (string[] memory chapters, uint256 total) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        total = mainStorage.chapterArray.length;

        if (offset >= total) {
            return (new string[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        chapters = new string[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            chapters[i] = mainStorage.chapterArray[offset + i];
        }
    }

    /**
     * @notice Retrieves detailed information about a chapter
     * @dev Combines multiple view calls into one for gas efficiency
     *
     * @param chapterName The name of the chapter to query
     * @return exists Whether the chapter exists
     * @return chapterAddress The chapter contract address
     * @return admin The admin address for the chapter
     *
     * Use Cases:
     * - Single call to get all chapter info
     * - Front-end chapter detail pages
     * - Batch information retrieval
     *
     * @custom:gas-optimization Reduces multiple calls to single call
     */
    function getChapterInfo(string memory chapterName) external view returns (bool exists, address chapterAddress, address admin) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        chapterAddress = mainStorage.chapterAddresses[chapterName];
        exists = chapterAddress != address(0);

        if (exists) {
            admin = mainStorage.checkChapterAdminAddressOut[chapterAddress];
        }
    }

    /**
     * @notice Checks if an address is a chapter administrator
     * @dev Direct admin status check without returning chapter address
     *
     * @param account The address to check
     * @return bool True if the address is a chapter admin
     *
     * Use Cases:
     * - Quick admin verification
     * - Permission checks
     * - Access control validation
     */
    function isChapterAdmin(address account) external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.isAdmin[account];
    }

    /**
     * @notice Retrieves multiple chapter addresses in a single call
     * @dev Batch lookup function for gas efficiency
     *
     * @param chapterNames Array of chapter names to look up
     * @return addresses Array of corresponding chapter addresses (address(0) if not found)
     *
     * Use Cases:
     * - Batch chapter lookups
     * - Multi-chapter operations
     * - Front-end data loading
     *
     * @custom:gas-optimization More efficient than multiple individual calls
     */
    function getChapterAddressesBatch(string[] memory chapterNames) external view returns (address[] memory addresses) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        addresses = new address[](chapterNames.length);

        for (uint256 i = 0; i < chapterNames.length; i++) {
            addresses[i] = mainStorage.chapterAddresses[chapterNames[i]];
        }
    }

    // ============================================
    // CHAPTER CALLBACK FUNCTIONS
    // ============================================

    /**
     * @notice Updates diamond storage when a chapter admin is changed
     * @dev Can ONLY be called by registered chapter contracts
     *      This callback allows chapter contracts to keep diamond storage in sync
     *
     * @param oldAdmin The previous admin address (to be removed)
     * @param newAdmin The new admin address (to be added)
     *
     * Flow:
     * 1. Verify caller is a registered chapter contract
     * 2. Remove old admin's chapter association (if not platform owner with multiple chapters)
     * 3. Assign new admin to the chapter
     * 4. Update admin status flags
     *
     * Requirements:
     * - Caller must be a registered chapter contract address
     * - New admin must not be zero address
     *
     * Called By:
     * - VoxChapter.revokeChapterAdmin()
     * - VoxChapter.setChapterAdmin()
     *
     * @custom:security Only registered chapter contracts can call this
     */
    function updateChapterAdmin(address oldAdmin, address newAdmin) external {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();

        address chapterAddress = msg.sender;

        // CRITICAL: Verify caller is a registered chapter
        require(mainStorage.checkChapterAdminAddressOut[chapterAddress] != address(0), "Caller is not a registered chapter");
        // Verify oldAdmin is actually this chapter's current admin, so a chapter can
        // never clear an unrelated address's admin association.
        require(mainStorage.checkChapterAdminAddressOut[chapterAddress] == oldAdmin, "oldAdmin is not this chapter's admin");

        require(newAdmin != address(0), "Invalid new admin address");

        // Remove old admin's association (unless platform owner managing multiple chapters)
        if (oldAdmin != diamondStorage.contractOwner || mainStorage.checkChapterAdminAddress[oldAdmin] == chapterAddress) {
            mainStorage.checkChapterAdminAddress[oldAdmin] = address(0);
            mainStorage.isAdmin[oldAdmin] = false;
        }

        // Check if new admin is eligible (unless platform owner)
        if (newAdmin != diamondStorage.contractOwner) {
            require(mainStorage.checkChapterAdminAddress[newAdmin] == address(0), "New admin already manages another chapter");
        }

        // Assign new admin
        mainStorage.checkChapterAdminAddress[newAdmin] = chapterAddress;
        mainStorage.checkChapterAdminAddressOut[chapterAddress] = newAdmin;
        mainStorage.isAdmin[newAdmin] = true;

        emit AdminAssigned(newAdmin, chapterAddress);
    }

    /**
     * @notice Verifies if the caller is a registered chapter contract
     * @dev Helper function for chapter contracts to validate their registration
     *
     * @return bool True if caller is a registered chapter
     *
     * Use Cases:
     * - Chapter contracts can verify they're properly registered
     * - Debugging registration issues
     * - Access control in chapter contracts
     */
    function isRegisteredChapter() external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.checkChapterAdminAddressOut[msg.sender] != address(0);
    }

    /**
     * @notice Gets the current admin for the calling chapter
     * @dev Allows chapter contracts to verify their current admin in diamond storage
     *
     * @return address The current admin address for the calling chapter
     *
     * Requirements:
     * - Caller must be a registered chapter contract
     */
    function getChapterCurrentAdmin() external view returns (address) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        address chapterAddress = msg.sender;
        require(mainStorage.checkChapterAdminAddressOut[chapterAddress] != address(0), "Caller is not a registered chapter");

        return mainStorage.checkChapterAdminAddressOut[chapterAddress];
    }

    /**
     * @notice Checks if a user is banned at platform level
     * @dev Public view function that chapters can call to check platform ban status
     * @param user Address to check
     * @return bool True if user is banned at platform level
     *
     * Use Cases:
     * - Chapter contracts checking platform ban status
     * - Frontend checking if user is platform-banned
     * - Combined with chapter-level ban checks
     */
    function isUserBannedFromPlatform(address user) external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.isUserPlatformBanned[user];
    }

    /**
     * @notice Forward enumeration of every address currently banned at the
     *         platform level
     * @dev Companion to `isUserBannedFromPlatform(address)` which is a
     *      point-lookup. Mirrors the chapter-level `getBannedUsersArray()`
     *      pattern for admin panels and audit tooling.
     *
     *      Ordering: stable within a single call, but NOT guaranteed across
     *      calls. The underlying storage uses swap-and-pop, so the positions
     *      of surviving entries shift when others are unbanned.
     *
     *      No pagination. The roster is admin-curated and expected to stay
     *      small (low thousands worst case). At 256 entries a cold read is
     *      ~256 SLOADs, well within any RPC gas cap. Revisit with a
     *      paginated variant before mainnet if growth is observed.
     *
     *      Access: public view — no restriction.
     * @return bannedUsers Snapshot of the global platform-ban roster
     */
    function getAllPlatformBannedUsers() external view returns (address[] memory bannedUsers) {
        return LibVoxStorage.mainStorage().platformBannedUsersList;
    }

    // ============================================
    // SUBMOD GLOBAL REGISTRY FUNCTIONS
    // ============================================

    // Internal helpers — shared by the external callbacks, migrateChapter, and removeChapter.

    function _registerSubModInStorage(LibVoxStorage.VoxMainStorage storage ms, address subMod, address chapterAddr) internal {
        if (ms.isSubModOf[subMod][chapterAddr]) return; // idempotent
        // Capture pre-push chapter count to detect 0→1 transition for the global roster.
        uint256 priorChapterCount = ms.subModChaptersList[subMod].length;
        ms.subModChaptersList[subMod].push(chapterAddr);
        ms.subModChapterIndex[subMod][chapterAddr] = ms.subModChaptersList[subMod].length; // 1-based
        ms.isSubModOf[subMod][chapterAddr] = true;
        // Global roster: add on first chapter association only.
        if (priorChapterCount == 0) {
            ms.allSubModsList.push(subMod);
            ms.allSubModsIndex[subMod] = ms.allSubModsList.length; // 1-based
            emit SubModRegistered(subMod);
        }
    }

    function _deregisterSubModFromStorage(LibVoxStorage.VoxMainStorage storage ms, address subMod, address chapterAddr) internal {
        if (!ms.isSubModOf[subMod][chapterAddr]) return; // idempotent
        uint256 idx = ms.subModChapterIndex[subMod][chapterAddr]; // 1-based
        uint256 lastIdx = ms.subModChaptersList[subMod].length; // 1-based last
        if (idx != lastIdx) {
            address lastChapter = ms.subModChaptersList[subMod][lastIdx - 1];
            ms.subModChaptersList[subMod][idx - 1] = lastChapter;
            ms.subModChapterIndex[subMod][lastChapter] = idx;
        }
        ms.subModChaptersList[subMod].pop();
        delete ms.subModChapterIndex[subMod][chapterAddr];
        ms.isSubModOf[subMod][chapterAddr] = false;
        // Global roster: remove on last chapter association only.
        if (ms.subModChaptersList[subMod].length == 0) {
            uint256 rIdx = ms.allSubModsIndex[subMod]; // 1-based
            // rIdx MUST be non-zero here: invariant is that roster membership
            // tracks `subModChaptersList[subMod].length > 0`. If this assert
            // ever fails, a writer has bypassed these helpers — investigate.
            assert(rIdx != 0);
            uint256 rLast = ms.allSubModsList.length; // 1-based last
            if (rIdx != rLast) {
                address lastSubMod = ms.allSubModsList[rLast - 1];
                ms.allSubModsList[rIdx - 1] = lastSubMod;
                ms.allSubModsIndex[lastSubMod] = rIdx;
            }
            ms.allSubModsList.pop();
            delete ms.allSubModsIndex[subMod];
            emit SubModDeregistered(subMod);
        }
    }

    /**
     * @notice Registers the calling chapter's new subMod in the Diamond-side multi-chapter registry
     * @dev Only callable by registered chapter contracts.
     *      A single subMod address may appear in multiple chapters' lists.
     * @param subMod Address of the subMod to register for the calling chapter
     */
    function registerSubMod(address subMod) external {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(mainStorage.checkChapterAdminAddressOut[msg.sender] != address(0), "NOT_CHAPTER");
        require(!mainStorage.isSubModOf[subMod][msg.sender], "ALREADY_SUBMOD");
        _registerSubModInStorage(mainStorage, subMod, msg.sender);
    }

    /**
     * @notice Deregisters the calling chapter's subMod from the Diamond-side multi-chapter registry
     * @dev Only callable by registered chapter contracts.
     * @param subMod Address of the subMod to deregister for the calling chapter
     */
    function deregisterSubMod(address subMod) external {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        require(mainStorage.checkChapterAdminAddressOut[msg.sender] != address(0), "NOT_CHAPTER");
        require(mainStorage.isSubModOf[subMod][msg.sender], "NOT_SUBMOD");
        _deregisterSubModFromStorage(mainStorage, subMod, msg.sender);
    }

    /**
     * @notice Returns all chapters a given subMod is currently registered in
     * @param subMod Address of the subMod to query
     * @return address[] Array of chapter contract addresses
     */
    function getSubModChapters(address subMod) external view returns (address[] memory) {
        return LibVoxStorage.mainStorage().subModChaptersList[subMod];
    }

    /**
     * @notice Forward enumeration of every address currently registered as a
     *         sub-mod in ≥1 chapter
     * @dev Companion to `getSubModChapters(address)` which is a reverse lookup.
     *      Use cases:
     *        - /PGovernance Platform Chapters admin panel roster render
     *        - Off-chain indexing without replaying SubModRegistered/Deregistered events
     *
     *      Ordering: stable within a single call but NOT guaranteed across calls.
     *      Entries are maintained by swap-and-pop, so the positions of surviving
     *      addresses change as others are deregistered.
     *
     *      Gas / size: no pagination. Roster size = distinct-addresses-currently-a-
     *      sub-mod-anywhere, which in practice is bounded by chapter-admin curation.
     *      At ~256 entries a view call reads ~256 SLOADs (cold ~2.1k each on
     *      post-Berlin; well within any RPC gas cap). If the roster grows past
     *      low-thousands, introduce a paginated variant before mainnet rather
     *      than relying on RPC-side heuristics.
     *
     *      Access: public view — no restriction.
     * @return subMods Snapshot of the global sub-mod roster
     */
    function getAllRegisteredSubMods() external view returns (address[] memory subMods) {
        return LibVoxStorage.mainStorage().allSubModsList;
    }

    /**
     * @notice Companion forward enumeration that also returns each sub-mod's
     *         chapters list, saving N+1 RPC round-trips for the UI
     * @dev For every `i`, `chaptersPerSubMod[i]` equals `getSubModChapters(subMods[i])`
     *      taken at the same block. No intermediate state changes between inner
     *      reads because this is a single view call.
     *
     *      Gas: O(N + ΣMᵢ) SLOADs where N = roster length and Mᵢ = chapter count
     *      per sub-mod. The inner arrays are the same storage arrays returned by
     *      `getSubModChapters`; no O(N·M) recomputation, just copies into memory.
     *      Acceptable at expected scale; if the product blows up, fall back to
     *      the per-address fan-out from the frontend.
     *
     *      Access: public view — no restriction.
     * @return subMods            Snapshot of the global sub-mod roster
     * @return chaptersPerSubMod  Parallel array — chaptersPerSubMod[i] is the
     *                            chapter list for subMods[i] at this block
     */
    function getAllRegisteredSubModsWithChapters() external view returns (address[] memory subMods, address[][] memory chaptersPerSubMod) {
        LibVoxStorage.VoxMainStorage storage ms = LibVoxStorage.mainStorage();
        subMods = ms.allSubModsList;
        chaptersPerSubMod = new address[][](subMods.length);
        for (uint256 i = 0; i < subMods.length; i++) {
            chaptersPerSubMod[i] = ms.subModChaptersList[subMods[i]];
        }
    }

    /**
     * @notice Retrieves comprehensive admin context for a user address
     * @dev Aggregates multiple admin and ban status checks into a single view call
     *      Performs pure storage reads without validation or external calls
     *
     * @param user The address to query admin context for
     * @return voxAdmin The current VOX Admin address
     * @return isVoxAdmin True if the queried user is the VOX Admin
     * @return chapterContractAddress The chapter contract address the user administers (address(0) if none)
     * @return isUserPlatformBanned True if the user is banned at platform level
     *
     * Use Cases:
     * - Frontend dashboard context loading
     * - Permission verification before UI rendering
     * - Admin status aggregation for arbitrary addresses
     * - Wallet-independent lookups (works with any address, not just msg.sender)
     *
     * Storage Reads:
     * - contractOwner from LibDiamond.diamondStorage()
     * - checkChapterAdminAddress[user] for chapter lookup
     * - isUserPlatformBanned[user] for platform ban status
     *
     * @custom:security Does not revert on zero address or unregistered users
     * @custom:gas-optimization Single call replaces 4+ separate view calls
     */
    function getUserAdminContext(
        address user
    ) external view returns (address voxAdmin, bool isVoxAdmin, address chapterContractAddress, bool isUserPlatformBanned) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();

        voxAdmin = diamondStorage.contractOwner;
        isVoxAdmin = (user == voxAdmin);
        chapterContractAddress = mainStorage.checkChapterAdminAddress[user];
        isUserPlatformBanned = mainStorage.isUserPlatformBanned[user];
    }

    /**
     * @notice Retrieves ban status for a user at both chapter and platform levels
     * @dev Performs defensive staticcall to chapter contract for chapter-level ban status
     *      Never reverts - returns false for chapter ban on any failure
     *
     * @param user The address to check ban status for
     * @param chapterAddress The chapter contract address to query
     * @return userIsBannedFromChapter True if user is banned from the specified chapter
     * @return userIsBannedFromPlatform True if user is banned at platform level
     *
     * Use Cases:
     * - Frontend permission checks before displaying chapter content
     * - Thread interaction validation
     * - Combined ban status for content moderation UIs
     * - Safe lookups even for removed/invalid chapters
     *
     * Behavior:
     * - Platform ban: Direct storage read from mainStorage.isUserPlatformBanned[user]
     * - Chapter ban: Staticcall to chapterAddress.isUserBannedFromChapter(user)
     *   - Returns false if chapterAddress is zero address
     *   - Returns false if staticcall fails (removed chapter, invalid address, etc.)
     *   - Returns false if return data is malformed
     *   - Only returns true if call succeeds and decodes to true
     *
     * @custom:security Never reverts - designed for safe frontend consumption
     * @custom:security Uses staticcall to prevent state modifications
     * @custom:note Chapter ban check is defensive because chapters can be removed/migrated
     */
    function getBanStatus(address user, address chapterAddress) external view returns (bool userIsBannedFromChapter, bool userIsBannedFromPlatform) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        // Platform ban is a simple storage read
        userIsBannedFromPlatform = mainStorage.isUserPlatformBanned[user];

        // Chapter ban requires defensive staticcall
        if (chapterAddress == address(0)) {
            userIsBannedFromChapter = false;
            return (userIsBannedFromChapter, userIsBannedFromPlatform);
        }

        // Encode the function call: isUserBannedFromChapter(address)
        bytes memory callData = abi.encodeWithSignature("isUserBannedFromChapter(address)", user);

        // Perform staticcall
        (bool success, bytes memory returnData) = chapterAddress.staticcall(callData);

        // Defensively decode: only if success and sufficient return data
        if (success && returnData.length >= 32) {
            userIsBannedFromChapter = abi.decode(returnData, (bool));
        } else {
            userIsBannedFromChapter = false;
        }
    }

    // ============================================
    // CHAPTER BAN MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Bans a chapter from the platform
     * @dev Only platform owner can ban chapters. Prevents reward distribution and most operations
     * @param chapterName Name of the chapter to ban
     *
     * Effects:
     * - Chapter cannot distribute rewards
     * - Chapter cannot add/remove submods
     * - Chapter owner cannot change share percentage
     * - Chapter owner cannot transfer admin (except owner can still revoke)
     * - Chapter added to inactiveChapterArray
     *
     * Requirements:
     * - Caller must be platform owner
     * - Chapter must exist
     * - Chapter must not already be banned
     * - Chapter must not be removed
     *
     * Emits: ChapterBanned event
     */
    function platformBanChapter(string memory chapterName) external {
        LibVoxGovernanceStorage.enforceIsOwnerOrVoxAssistant();
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        address chapterAddress = mainStorage.chapterAddresses[chapterName];
        require(chapterAddress != address(0), "Chapter does not exist");
        require(!mainStorage.isChapterBanned[chapterAddress], "Chapter is already banned");
        require(!mainStorage.isChapterRemoved[chapterAddress], "Chapter has been removed");

        mainStorage.isChapterBanned[chapterAddress] = true;
        mainStorage.chapterBanBlockNumber[chapterAddress] = block.number;

        // Add to inactiveChapterArray using mapping for O(1) lookup
        mainStorage.inactiveChapterArrayIndex[chapterName] = mainStorage.inactiveChapterArray.length;
        mainStorage.inactiveChapterArray.push(chapterName);

        // Call setChapterBannedByPlatform on chapter contract using interface
        IVoxChapter(chapterAddress).setChapterBannedByPlatform(true);

        emit ChapterBanned(chapterName, chapterAddress, msg.sender, block.number);
    }

    /**
     * @notice Unbans a chapter from the platform
     * @dev Only platform owner can unban chapters. Removes from inactiveChapterArray
     * @param chapterName Name of the chapter to unban
     *
     * Requirements:
     * - Caller must be platform owner
     * - Chapter must exist
     * - Chapter must currently be banned
     *
     * Emits: ChapterUnbanned event
     */
    function platformUnbanChapter(string memory chapterName) external {
        LibVoxGovernanceStorage.enforceIsOwnerOrVoxAssistant();
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();

        address chapterAddress = mainStorage.chapterAddresses[chapterName];
        require(chapterAddress != address(0), "Chapter does not exist");
        require(mainStorage.isChapterBanned[chapterAddress], "Chapter is not banned");

        mainStorage.isChapterBanned[chapterAddress] = false;

        // Remove from inactiveChapterArray using swap-and-pop with index mapping
        uint256 indexToRemove = mainStorage.inactiveChapterArrayIndex[chapterName];
        uint256 lastIndex = mainStorage.inactiveChapterArray.length - 1;

        if (indexToRemove < mainStorage.inactiveChapterArray.length) {
            if (indexToRemove != lastIndex) {
                // Swap with last element
                string memory lastChapterName = mainStorage.inactiveChapterArray[lastIndex];
                mainStorage.inactiveChapterArray[indexToRemove] = lastChapterName;
                mainStorage.inactiveChapterArrayIndex[lastChapterName] = indexToRemove;
            }
            // Remove last element
            mainStorage.inactiveChapterArray.pop();
            delete mainStorage.inactiveChapterArrayIndex[chapterName];
        }

        // Call setChapterBannedByPlatform on chapter contract using interface
        IVoxChapter(chapterAddress).setChapterBannedByPlatform(false);

        emit ChapterUnbanned(chapterName, chapterAddress, msg.sender, block.number);
    }

    /**
     * @notice Checks if a chapter is banned by the platform
     * @param chapterAddress Address of the chapter to check
     * @return bool True if the chapter is banned, false otherwise
     */
    function isChapterBannedByPlatform(address chapterAddress) external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.isChapterBanned[chapterAddress];
    }

    /**
     * @notice Gets the block number when a chapter was banned
     * @param chapterAddress Address of the chapter to check
     * @return uint256 Block number when chapter was banned (0 if never banned)
     */
    function getChapterBanBlockNumber(address chapterAddress) external view returns (uint256) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterBanBlockNumber[chapterAddress];
    }

    // ============================================
    // CHAPTER REMOVAL MANAGEMENT FUNCTIONS
    // ============================================

    /**
     * @notice Permanently removes a chapter from the platform
     * @dev Can be called by platform owner OR the chapter's admin. Irreversible action.
     * @param chapterName Name of the chapter to remove
     *
     * Flow:
     * 1. Validate caller authorization (platform owner OR chapter admin)
     * 2. Get chapter address and verify it exists
     * 3. Call chapter.prepareForRemoval() to:
     *    - Distribute ALL remaining rewards
     *    - Clean up all subMods from global storage
     *    - Set chapter's isRemoved flag
     * 4. Update diamond storage:
     *    - Mark chapter as removed
     *    - Free up admin to create new chapters
     *    - Add to inactiveChapterArray
     * 5. Emit ChapterRemoved event
     *
     * Requirements:
     * - Caller must be platform owner OR the chapter's admin
     * - Chapter must exist and not already be removed
     *
     * Effects:
     * - Chapter permanently deactivated (cannot be reactivated)
     * - All funds distributed to owner and subMods
     * - Admin freed to create new chapters
     * - SubMods freed to join other chapters
     * - Chapter added to inactiveChapterArray
     * - Historical data preserved
     *
     * @custom:warning This action is PERMANENT and IRREVERSIBLE
     * @custom:security Distributes all funds before removal
     */
    function removeChapter(string memory chapterName) external nonReentrant returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();

        address chapterAddress = mainStorage.chapterAddresses[chapterName];
        require(chapterAddress != address(0), "Chapter does not exist");
        require(!mainStorage.isChapterRemoved[chapterAddress], "Chapter already removed");

        address chapterAdmin = mainStorage.checkChapterAdminAddressOut[chapterAddress];

        // Authorization: platform owner OR chapter admin
        require(msg.sender == diamondStorage.contractOwner || msg.sender == chapterAdmin, "Only platform owner or chapter admin can remove");

        // Banned chapter admins may not self-remove (platform owner always allowed)
        if (msg.sender != diamondStorage.contractOwner) {
            require(!mainStorage.isUserPlatformBanned[msg.sender], "Banned users cannot remove chapters");
        }

        // Clean up Diamond-side subMod registry before the chapter is removed.
        // This is done here (not inside prepareForRemoval) to avoid a reentrant
        // call path: removeChapter (nonReentrant) → chapter → diamond.
        address[] memory chapterSubMods = VoxChapter(payable(chapterAddress)).getAllSubMods();
        for (uint256 i = 0; i < chapterSubMods.length; i++) {
            _deregisterSubModFromStorage(mainStorage, chapterSubMods[i], chapterAddress);
        }

        // Call chapter to prepare for removal (distributes funds, marks as removed)
        IVoxChapter(chapterAddress).prepareForRemoval();

        // Update diamond storage
        mainStorage.isChapterRemoved[chapterAddress] = true;
        mainStorage.chapterRemovalBlockNumber[chapterAddress] = block.number;

        // Free up admin
        if (chapterAdmin != address(0)) {
            mainStorage.isAdmin[chapterAdmin] = false;
            delete mainStorage.checkChapterAdminAddress[chapterAdmin];
        }
        delete mainStorage.checkChapterAdminAddressOut[chapterAddress];

        // Add to inactiveChapterArray if not already present.
        // A banned chapter is already in the inactive array (added by platformBanChapter),
        // so we use the isChapterBanned flag as the canonical check.
        if (!mainStorage.isChapterBanned[chapterAddress]) {
            mainStorage.inactiveChapterArrayIndex[chapterName] = mainStorage.inactiveChapterArray.length;
            mainStorage.inactiveChapterArray.push(chapterName);
        }

        // Unban if banned (removal supersedes ban)
        if (mainStorage.isChapterBanned[chapterAddress]) {
            mainStorage.isChapterBanned[chapterAddress] = false;
            delete mainStorage.chapterBanBlockNumber[chapterAddress];
        }

        emit ChapterRemoved(chapterName, chapterAddress, msg.sender, block.number);

        return true;
    }

    /**
     * @notice Checks if a chapter has been removed
     * @param chapterAddress Address of the chapter to check
     * @return bool True if the chapter has been removed, false otherwise
     */
    function isChapterRemoved(address chapterAddress) external view returns (bool) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.isChapterRemoved[chapterAddress];
    }

    /**
     * @notice Gets the block number when a chapter was removed
     * @param chapterAddress Address of the chapter to check
     * @return uint256 Block number when chapter was removed (0 if not removed)
     */
    function getChapterRemovalBlockNumber(address chapterAddress) external view returns (uint256) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.chapterRemovalBlockNumber[chapterAddress];
    }

    /**
     * @notice Gets all inactive chapter names (banned or removed)
     * @return string[] Array of inactive chapter names
     */
    function getInactiveChapters() external view returns (string[] memory) {
        LibVoxStorage.VoxMainStorage storage mainStorage = LibVoxStorage.mainStorage();
        return mainStorage.inactiveChapterArray;
    }

    // ============================================
    // COMPOSITE VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Consolidated user context across platform and chapter in a single call
     * @dev Combines owner(), getUserAdminContext(), and chapter-level queries.
     *      Cross-contract calls use try/catch for defensive failure handling.
     *      Designed for off-chain reads (eth_call).
     *
     * @param user Address to query context for
     * @param chapterAddress Chapter contract address (pass address(0) if no chapter context needed)
     * @return ctx FullUserContext struct
     */
    function getFullUserContext(address user, address chapterAddress) external view returns (LibVoxViewStructs.FullUserContext memory ctx) {
        LibVoxStorage.VoxMainStorage storage ms = LibVoxStorage.mainStorage();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();

        ctx.voxAdmin = ds.contractOwner;
        ctx.isVoxAdmin = (user == ctx.voxAdmin);
        ctx.userChapterContractAddress = ms.checkChapterAdminAddress[user];
        ctx.isUserBannedPlatform = ms.isUserPlatformBanned[user];

        if (chapterAddress != address(0)) {
            // chapterOwner from Diamond storage (canonical source)
            ctx.chapterOwner = ms.checkChapterAdminAddressOut[chapterAddress];

            // Chapter-level ban via try/catch
            try IVoxChapter(chapterAddress).isUserBannedFromChapter(user) returns (bool banned) {
                ctx.isUserBannedFromChapter = banned;
            } catch {
                ctx.isUserBannedFromChapter = false;
            }
            // SubMods list via try/catch
            try IVoxChapter(chapterAddress).getAllSubMods() returns (address[] memory subs) {
                ctx.subModsList = subs;
            } catch {
                ctx.subModsList = new address[](0);
            }
        }
    }

    /**
     * @notice Consolidated chapter context by name in a single call
     * @dev Combines chapterExists(), getChapterAddress(), Diamond storage reads,
     *      and chapter-level subMods query.
     *      Cross-contract calls use try/catch for defensive failure handling.
     *      Designed for off-chain reads (eth_call).
     *
     * @param chapterName Name of the chapter to query
     * @return ctx ChapterContext struct
     */
    function getChapterContext(string memory chapterName) external view returns (LibVoxViewStructs.ChapterContext memory ctx) {
        LibVoxStorage.VoxMainStorage storage ms = LibVoxStorage.mainStorage();

        ctx.chapterContractAddress = ms.chapterAddresses[chapterName];
        ctx.exists = ctx.chapterContractAddress != address(0);

        if (ctx.exists) {
            ctx.chapterOwner = ms.checkChapterAdminAddressOut[ctx.chapterContractAddress];
            ctx.isChapterBanned = ms.isChapterBanned[ctx.chapterContractAddress];
            ctx.isChapterRemoved = ms.isChapterRemoved[ctx.chapterContractAddress];

            // SubMods list via try/catch
            try IVoxChapter(ctx.chapterContractAddress).getAllSubMods() returns (address[] memory subs) {
                ctx.subModsList = subs;
            } catch {
                ctx.subModsList = new address[](0);
            }
        }
    }

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
}
