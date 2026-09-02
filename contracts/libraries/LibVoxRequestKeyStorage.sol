// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title LibVoxRequestKeyStorage
/// @author Vox Team
/// @notice Diamond storage slot for the protocol requestKey.
/// @dev Storage-only by design (mirrors every other LibVox*Storage): it holds the slot, struct and
///      accessor and NOTHING else. All read/validate/rotate logic lives in VoxRequestKeyFacet so the
///      size-constrained VoxGovernanceFacet stays under the EIP-170 24,576-byte cap.
///
///      The requestKey is the second protocol address the off-chain signing service authenticates
///      request callers against. It is PUBLISH-ONLY: stored and emitted on-chain, never `ecrecover`'d
///      here and never part of any signature payload (the VoxFacet chapter-creation gate keeps using
///      `chapterSignerAddress`). It rotates atomically with ownership, so a rotated-out owner immediately
///      loses the ability to request signatures.
library LibVoxRequestKeyStorage {
    bytes32 constant STORAGE_POSITION = keccak256("vox.requestkey.storage");

    struct RequestKeyStorage {
        address requestKey;
    }

    function requestKeyStorage() internal pure returns (RequestKeyStorage storage rks) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            rks.slot := position
        }
    }
}
