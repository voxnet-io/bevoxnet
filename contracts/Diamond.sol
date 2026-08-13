// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";
import {LibVoxTokenStorage} from "./libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "./libraries/LibVoxGovernanceStorage.sol";

contract Diamond {
    constructor(address _contractOwner, address _diamondCutFacet) payable {
        LibDiamond.setContractOwner(_contractOwner);

        // Add the diamondCut external function from the diamondCutFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({facetAddress: _diamondCutFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: functionSelectors});
        LibDiamond.diamondCut(cut, address(0), "");
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @notice Receive function to handle POL (native token) payments
     * @dev Implements 3-step waterfall allocation:
     *      1. Storage provider cut (tracked for offchain Turbo topup)
     *      2. Admin claim (accumulated in adminAccumulatedPOL — pull model)
     *      3. Bounty pool (remaining funds for reward distribution)
     *
     *      Using a pull model for the admin slice means this function can never
     *      revert due to an admin address that is a non-payable contract.
     *      The admin withdraws their share via withdrawAdminPOL() in VoxTokenFacet.
     */
    receive() external payable {
        if (msg.value > 0) {
            LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
            LibVoxGovernanceStorage.GovernanceStorage storage govStorage = LibVoxGovernanceStorage.governanceStorage();

            address voxAdmin = LibDiamond.diamondStorage().contractOwner;
            require(voxAdmin != address(0), "Owner not set");

            uint256 valueReceived = msg.value;

            // Step 1: Storage provider cut (tracked, not transferred)
            uint256 storagePct = govStorage.currentQuotas.storageProviderPercentage;
            uint256 storageAmount = (valueReceived * storagePct) / 100;
            // Defense-in-depth: VoxGovernanceFacet caps storagePct and adminClaimPct
            // at <= 100 on both initialize() and _validateQuotaProposal(), so the
            // subtractions below cannot underflow today. A future facet upgrade or
            // storage migration bug that sneaks a value >100 into either quota slot
            // would otherwise brick every inbound payment. Cap at the carried balance.
            if (storageAmount > valueReceived) {
                storageAmount = valueReceived;
            }
            ts.storageProviderPOLBalance += storageAmount;

            uint256 afterStorage = valueReceived - storageAmount;

            // Step 2: Admin claim (accumulated for pull-withdrawal — never pushed)
            uint256 adminClaimPct = govStorage.currentQuotas.voxAdminClaimPercentage;
            uint256 adminClaimAmount = (afterStorage * adminClaimPct) / 100;
            if (adminClaimAmount > afterStorage) {
                adminClaimAmount = afterStorage;
            }
            ts.totalAggregateAdminPOL += adminClaimAmount;

            // Step 3: Bounty pool (remaining funds)
            uint256 bountyPoolAmount = afterStorage - adminClaimAmount;
            ts.totalAggregateRewardInPOLWei += bountyPoolAmount;
        }
    }
}
