// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

library LibVoxChapterStorage {
    bytes32 constant STORAGE_POSITION = keccak256("vox.chapter.storage");

    struct VoxChapterStorage {
        string chapterName;
    }

    function chapterStorage() internal pure returns (VoxChapterStorage storage cs) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            cs.slot := position
        }
    }
}
