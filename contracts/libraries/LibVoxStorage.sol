// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

library LibVoxStorage {
    bytes32 constant STORAGE_POSITION = keccak256("vox.main.storage");

    struct VoxMainStorage {
        mapping(string => address) chapterAddresses;
        string[] chapterArray;
        string[] inactiveChapterArray;
        mapping(address => address) checkChapterAdminAddress;
        mapping(address => address) checkChapterAdminAddressOut;
        mapping(address => bool) isAdmin;
        // Multi-chapter subMod registry (replaces single-chapter isSubmod mapping).
        // A subMod may belong to multiple chapters simultaneously.
        mapping(address => address[]) subModChaptersList; // subMod → chapters they belong to
        mapping(address => mapping(address => bool)) isSubModOf; // subMod → chapter → bool
        mapping(address => mapping(address => uint256)) subModChapterIndex; // subMod → chapter → 1-based index for swap-and-pop
        // Platform-level user ban registry. Renamed (dev-phase) for naming
        // parity with chapter-level `isUserBannedFromChapter`. Slot layout
        // unchanged by rename — only field names differ.
        mapping(address => bool) isUserPlatformBanned;
        mapping(address => uint256) userPlatformBanBlockNumber;
        mapping(address => bool) isChapterBanned;
        mapping(address => uint256) chapterBanBlockNumber;
        mapping(address => bool) isChapterRemoved;
        mapping(address => uint256) chapterRemovalBlockNumber;
        mapping(string => uint256) chapterArrayIndex;
        mapping(string => uint256) inactiveChapterArrayIndex;
        /// @notice EIP-1167 master implementation address for chapter clones
        address chapterImplementation;
        // ------------------------------------------------------------
        // Global sub-mod roster (appended after audit — slot-compatible).
        // Purpose: support forward enumeration of every address that is
        // currently registered as a sub-mod in ≥1 chapter, for the
        // /PGovernance Platform Chapters admin panel.
        //
        // Invariants (maintained exclusively by _registerSubModInStorage /
        // _deregisterSubModFromStorage in VoxFacet):
        //   - An address appears in `allSubModsList` iff
        //     `subModChaptersList[addr].length > 0`.
        //   - `allSubModsIndex[addr]` is 1-based: 0 ⇒ not on roster;
        //     k>0 ⇒ `allSubModsList[k-1] == addr`.
        //   - Entry/exit only on the 0↔1 chapter-count transition.
        // ------------------------------------------------------------
        address[] allSubModsList;
        mapping(address => uint256) allSubModsIndex;
        // ------------------------------------------------------------
        // Global platform-ban roster (appended after sub-mod roster — slot-
        // compatible). Purpose: enumeration of every address currently banned
        // at the platform level, for admin panels and audit tooling. Mirrors
        // the chapter-level `bannedUsersArray` pattern.
        //
        // Invariants (maintained exclusively by banUserFromPlatform /
        // unbanUserFromPlatform in VoxGovernanceFacet):
        //   - An address appears in `platformBannedUsersList` iff
        //     `isUserPlatformBanned[addr]` is true.
        //   - `platformBannedUsersIndex[addr]` is 1-based: 0 ⇒ not present;
        //     k>0 ⇒ `platformBannedUsersList[k-1] == addr`.
        //   - Entry/exit is enforced by the existing 0↔1 require-guards on
        //     the ban/unban writers; existing UserBanned / UserUnbanned
        //     events already fire once per transition.
        // ------------------------------------------------------------
        address[] platformBannedUsersList;
        mapping(address => uint256) platformBannedUsersIndex;
    }

    function mainStorage() internal pure returns (VoxMainStorage storage ms) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }
}
