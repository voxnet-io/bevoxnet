// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";

/**
 * @title ChapterLensFacet
 * @notice Pure view-only aggregator facet that bundles per-chapter and
 *         cross-chapter reads into single RPC calls for the front-end.
 * @dev   - Lives on the Diamond (cut as a normal facet).
 *        - Performs `staticcall`s to chapter clones for per-chapter data.
 *        - Reads Diamond `LibVoxStorage` directly for cross-chapter walks.
 *        - All functions are `view`. No state mutation. No auth checks
 *          (everything exposed here is already publicly readable via the
 *          underlying chapter / facet getters).
 *        - Failure-tolerant: missing/un-deployed chapter clones return
 *          zero-initialised structs rather than reverting the whole call.
 *
 * Phase-1 scope:
 *   - getChapterAdminSnapshot(address chapter)
 *   - getUserChapterSnapshot(address chapter, address user)
 *   - getBannedUsersWithBlocks(address chapter)
 *   - getCrossChapterUserContext(address user, uint256 offset, uint256 pageSize)
 *
 * NOTE: Bytes added by this facet land on the Diamond (24 KiB cap applies
 *       per-facet, not aggregated). Zero bytes are added to VoxChapter.sol,
 *       which is the EIP-170-pressured contract.
 */
contract ChapterLensFacet {
    /// @dev Stored solely for parity with the deploy loop's
    ///      `Facet.deploy(diamondAddress)` invariant. Not used at runtime —
    ///      delegate-called from the Diamond means address(this) == Diamond.
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    // ============================================================
    // STRUCTS — exposed in ABI so the front-end decoder can drop in
    // ============================================================

    /// @notice Mirrors VoxChapter.getChapterStats() return tuple exactly.
    struct ChapterStats {
        string name;
        string id;
        address owner;
        uint256 ownerShare;
        uint256 subModCount;
        uint256 polBalance;
        uint256 usdcBalance;
        address[] subModsList;
    }

    /// @notice Single-call admin-panel hydrate.
    /// @dev Each storage slot is represented exactly once; fields that exist
    ///      inside `stats` (chapterName, chapterID, ownerShare, subModsList)
    ///      are NOT duplicated at the top level.
    struct ChapterAdminSnapshot {
        ChapterStats stats;
        address[] pendingInvitations; // returnInvitations() — auth-gated; empty on revert
        address[] bannedUsers; // getBannedUsersArray()
        uint256 polThreshold; // getMinClaimThresholds()[0]
        uint256 usdcThreshold; // getMinClaimThresholds()[1]
        uint256 totalShare;
        uint256 totalPOLDistributed;
        uint256 totalUSDCDistributed;
        uint256 lastKnownPOLBalance;
        uint256 lastKnownUSDCBalance;
        uint256 lastDistributionTimestamp;
        address diamondAddressRef; // chapter.diamondAddress()
    }

    /// @notice Per-user, per-chapter view bundle.
    struct UserChapterSnapshot {
        bool invited; // subModInvitations(user)
        bool pendingInvited; // getPendingInvitationDetails(user).isPending
        uint256 invitedAt; // getPendingInvitationDetails(user).timestamp
        uint256 pendingPOL; // getPendingRewards(user).polReward
        uint256 pendingUSDC; // getPendingRewards(user).usdcReward
        uint256 lifetimePOL; // getUserLifetimeEarnings(user).pol
        uint256 lifetimeUSDC; // getUserLifetimeEarnings(user).usdc
    }

    /// @notice Row in the cross-chapter walk result.
    struct UserChapterRow {
        string chapterName;
        address chapterAddress;
        bool invited;
        bool pendingInvited;
        uint256 invitedAt;
        uint256 pendingPOL;
        uint256 pendingUSDC;
        uint256 lifetimePOL;
        uint256 lifetimeUSDC;
    }

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Hard cap on getCrossChapterUserContext page size to bound
    ///         worst-case gas (each row triggers 1 cross-contract staticcall).
    uint256 public constant MAX_CROSS_CHAPTER_PAGE_SIZE = 100;

    // ============================================================
    // PUBLIC VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice One-shot admin panel hydrate for a single chapter.
     * @param chapter Chapter clone address. If `address(0)` or has no code,
     *                returns a fully zero-initialised struct.
     * @return snapshot Aggregated admin-panel state.
     */
    function getChapterAdminSnapshot(address chapter) external view returns (ChapterAdminSnapshot memory snapshot) {
        if (!_hasCode(chapter)) {
            return snapshot;
        }

        // --- getChapterStats (8-tuple) ---
        // Use staticcall so we can tolerate any future signature drift /
        // un-migrated clones gracefully. On failure, leave `stats` zeroed.
        (bool ok, bytes memory data) = chapter.staticcall(abi.encodeWithSignature("getChapterStats()"));
        if (ok && data.length > 0) {
            (
                string memory name_,
                string memory id_,
                address owner_,
                uint256 ownerShare_,
                uint256 subModCount_,
                uint256 polBalance_,
                uint256 usdcBalance_,
                address[] memory subModsList_
            ) = abi.decode(data, (string, string, address, uint256, uint256, uint256, uint256, address[]));
            snapshot.stats = ChapterStats({
                name: name_,
                id: id_,
                owner: owner_,
                ownerShare: ownerShare_,
                subModCount: subModCount_,
                polBalance: polBalance_,
                usdcBalance: usdcBalance_,
                subModsList: subModsList_
            });
        }

        // --- returnInvitations() — auth-gated to chapter owner; expected to
        //     revert when called from the Diamond. Swallow and return empty.
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("returnInvitations()"));
        if (ok && data.length > 0) {
            snapshot.pendingInvitations = abi.decode(data, (address[]));
        }

        // --- getBannedUsersArray() ---
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("getBannedUsersArray()"));
        if (ok && data.length > 0) {
            snapshot.bannedUsers = abi.decode(data, (address[]));
        }

        // --- getMinClaimThresholds() ---
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("getMinClaimThresholds()"));
        if (ok && data.length >= 64) {
            (snapshot.polThreshold, snapshot.usdcThreshold) = abi.decode(data, (uint256, uint256));
        }

        // --- Scalar storage getters (auto-generated public) ---
        snapshot.totalShare = _readUint(chapter, "totalShare()");
        snapshot.totalPOLDistributed = _readUint(chapter, "totalPOLDistributed()");
        snapshot.totalUSDCDistributed = _readUint(chapter, "totalUSDCDistributed()");
        snapshot.lastKnownPOLBalance = _readUint(chapter, "lastKnownPOLBalance()");
        snapshot.lastKnownUSDCBalance = _readUint(chapter, "lastKnownUSDCBalance()");
        snapshot.lastDistributionTimestamp = _readUint(chapter, "lastDistributionTimestamp()");
        snapshot.diamondAddressRef = _readAddress(chapter, "diamondAddress()");
    }

    /**
     * @notice Aggregates the four per-user reads (invited / pending-invite /
     *         pending-rewards / lifetime-earnings) into one struct.
     * @param chapter Chapter clone address. Zero/codeless ⇒ zero struct.
     * @param user    Target user. `address(0)` ⇒ zero struct (does not revert).
     * @return snapshot Aggregated per-user state.
     */
    function getUserChapterSnapshot(address chapter, address user) public view returns (UserChapterSnapshot memory snapshot) {
        if (user == address(0) || !_hasCode(chapter)) {
            return snapshot;
        }

        // subModInvitations(address) — auto-generated mapping getter
        (bool ok, bytes memory data) = chapter.staticcall(abi.encodeWithSignature("subModInvitations(address)", user));
        if (ok && data.length >= 32) {
            snapshot.invited = abi.decode(data, (bool));
        }

        // getPendingInvitationDetails(address) → (bool, uint256)
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("getPendingInvitationDetails(address)", user));
        if (ok && data.length >= 64) {
            (snapshot.pendingInvited, snapshot.invitedAt) = abi.decode(data, (bool, uint256));
        }

        // getPendingRewards(address) → (uint256, uint256)
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("getPendingRewards(address)", user));
        if (ok && data.length >= 64) {
            (snapshot.pendingPOL, snapshot.pendingUSDC) = abi.decode(data, (uint256, uint256));
        }

        // getUserLifetimeEarnings(address) → (uint256, uint256)
        (ok, data) = chapter.staticcall(abi.encodeWithSignature("getUserLifetimeEarnings(address)", user));
        if (ok && data.length >= 64) {
            (snapshot.lifetimePOL, snapshot.lifetimeUSDC) = abi.decode(data, (uint256, uint256));
        }
    }

    /**
     * @notice Returns banned users paired with their per-user ban-block.
     * @dev Order matches `getBannedUsersArray()`. `bannedUsers.length ==
     *      banBlockNumbers.length`. Codeless chapter ⇒ both arrays empty.
     * @param chapter Chapter clone address.
     */
    function getBannedUsersWithBlocks(address chapter) external view returns (address[] memory bannedUsers, uint256[] memory banBlockNumbers) {
        if (!_hasCode(chapter)) {
            return (new address[](0), new uint256[](0));
        }

        (bool ok, bytes memory data) = chapter.staticcall(abi.encodeWithSignature("getBannedUsersArray()"));
        if (!ok || data.length == 0) {
            return (new address[](0), new uint256[](0));
        }
        bannedUsers = abi.decode(data, (address[]));

        uint256 len = bannedUsers.length;
        banBlockNumbers = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            (bool okB, bytes memory dataB) = chapter.staticcall(abi.encodeWithSignature("getUserChapterBanBlockNumber(address)", bannedUsers[i]));
            if (okB && dataB.length >= 32) {
                banBlockNumbers[i] = abi.decode(dataB, (uint256));
            }
        }
    }

    /**
     * @notice Walks a paginated slice of the chapter registry and aggregates
     *         per-chapter user state for `user` in a single RPC call.
     * @dev    Reads the chapter registry directly from `LibVoxStorage`
     *         (no self-staticcall). Each row triggers per-chapter
     *         staticcalls via `getUserChapterSnapshot`.
     *
     *         Failure semantics:
     *         - `user == address(0)` ⇒ returns empty `rows`, real `totalChapters`.
     *         - `pageSize > MAX_CROSS_CHAPTER_PAGE_SIZE` ⇒ revert `"pageSize too large"`.
     *         - Chapter name → address resolves to `address(0)` ⇒ row skipped.
     *         - Codeless chapter address ⇒ row written with zeroed user data.
     *
     * @param user      Target user.
     * @param offset    Starting index into the chapter registry.
     * @param pageSize  Max chapters to read in this page (≤ 100).
     * @return rows           Per-chapter user-state rows (skips zero-address resolutions).
     * @return totalChapters  Total chapter-registry length (regardless of page bounds).
     */
    function getCrossChapterUserContext(
        address user,
        uint256 offset,
        uint256 pageSize
    ) external view returns (UserChapterRow[] memory rows, uint256 totalChapters) {
        require(pageSize <= MAX_CROSS_CHAPTER_PAGE_SIZE, "pageSize too large");

        LibVoxStorage.VoxMainStorage storage ms = LibVoxStorage.mainStorage();
        totalChapters = ms.chapterArray.length;

        if (user == address(0) || offset >= totalChapters || pageSize == 0) {
            return (new UserChapterRow[](0), totalChapters);
        }

        uint256 end = offset + pageSize;
        if (end > totalChapters) {
            end = totalChapters;
        }
        uint256 windowLen = end - offset;

        // Two-pass: first count non-zero resolutions, then write.
        // Avoids dynamic array growth and keeps returndata tight.
        UserChapterRow[] memory tmp = new UserChapterRow[](windowLen);
        uint256 written = 0;

        for (uint256 i = 0; i < windowLen; i++) {
            string memory name_ = ms.chapterArray[offset + i];
            address chapterAddr = ms.chapterAddresses[name_];
            if (chapterAddr == address(0)) {
                continue;
            }

            UserChapterSnapshot memory s = getUserChapterSnapshot(chapterAddr, user);

            tmp[written] = UserChapterRow({
                chapterName: name_,
                chapterAddress: chapterAddr,
                invited: s.invited,
                pendingInvited: s.pendingInvited,
                invitedAt: s.invitedAt,
                pendingPOL: s.pendingPOL,
                pendingUSDC: s.pendingUSDC,
                lifetimePOL: s.lifetimePOL,
                lifetimeUSDC: s.lifetimeUSDC
            });
            written++;
        }

        // Trim
        rows = new UserChapterRow[](written);
        for (uint256 j = 0; j < written; j++) {
            rows[j] = tmp[j];
        }
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /// @dev `extcodesize`-based liveness check. Cheap, single SLOAD-equivalent.
    function _hasCode(address a) internal view returns (bool) {
        if (a == address(0)) return false;
        uint256 size;
        assembly {
            size := extcodesize(a)
        }
        return size > 0;
    }

    /// @dev Best-effort uint256 reader for zero-arg public getters.
    function _readUint(address target, string memory sig) internal view returns (uint256 value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        if (ok && data.length >= 32) {
            value = abi.decode(data, (uint256));
        }
    }

    /// @dev Best-effort address reader for zero-arg public getters.
    function _readAddress(address target, string memory sig) internal view returns (address value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        if (ok && data.length >= 32) {
            value = abi.decode(data, (address));
        }
    }
}
