// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";

// Remember to add the loupe functions from DiamondLoupeFacet to the diamond.
// The loupe functions are required by the EIP2535 Diamonds standard

contract DiamondCutFacet is IDiamondCut {
    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall
    /// @dev Owner-only, and permitted only during the bootstrap phase. Once
    ///      OwnershipFacet.finalizeBootstrap() closes the latch, this reverts and upgrades
    ///      must go through governance (VoxGovernanceFacet.ratifyUpgrade).
    /// @param _diamondCut Contains the facet addresses and function selectors
    /// @param _init The address of the contract or facet to execute _calldata
    /// @param _calldata A function call, including function selector and arguments
    ///                  _calldata is executed with delegatecall on _init
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        // Direct owner cut is a bootstrap-only backdoor. Once finalizeBootstrap() trips the
        // latch (called at the end of deployment), upgrades must go through governance
        // (ratifyUpgrade calls LibDiamond.diamondCut directly, bypassing this).
        require(!LibVoxTokenStorage.tokenStorage().directCutFinalized, "Bootstrap finalized: use governance");
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }

    /**
     * @notice Receive function - not used in DiamondCutFacet
     * @dev DiamondCutFacet is deployed before Diamond, so cannot forward to it
     *      Payment to this facet address directly is rejected
     */
    receive() external payable {
        revert("DiamondCutFacet: Direct payments not accepted");
    }
}
