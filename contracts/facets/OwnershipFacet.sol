// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";

/// @dev Intra-diamond self-call surface exposed by VoxRequestKeyFacet. Both helpers enforce
///      `msg.sender == address(this)`, so they are only reachable via a self-call from this facet.
interface IVoxRequestKeyOps {
    function validateRequestKeyOnlyDiamond(address newKey, address prospectiveOwner) external view;
    function rotateRequestKeyOnlyDiamond(address newKey, address changedBy) external;
}

contract OwnershipFacet is IERC173 {
    address internal immutable diamondAddressForDirectCalls;

    /// @notice Emitted once when the bootstrap latch is closed (owner loses direct cut backdoor).
    /// @dev Also declared in LibVoxTokenStorage (the trip-on-transfer emitter); same topic hash.
    event BootstrapFinalized(address indexed by, uint256 blockNumber);

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    /// @notice Disabled: ownership can never move without atomically rotating the requestKey.
    /// @dev Retains the ERC-173 selector (so tooling/ABIs still resolve it) but always reverts. Use
    ///      `transferOwnership(address,address)` instead.
    function transferOwnership(address) external pure override {
        revert("Use transferOwnership(address,address)");
    }

    /// @notice Atomically hand over ownership and rotate the protocol requestKey.
    /// @dev Validation and rotation live in VoxRequestKeyFacet, reached here via intra-diamond
    ///      self-call, so a departed owner immediately loses signing-service request access. The new
    ///      requestKey must be nonzero, differ from `_newOwner`, actually change, and differ from the
    ///      governance chapterSignerAddress (enforced by validateRequestKeyOnlyDiamond).
    /// @param _newOwner The address to become the new contract owner.
    /// @param _newRequestKey The requestKey the new owner controls, published on-chain on handover.
    function transferOwnership(address _newOwner, address _newRequestKey) external {
        LibDiamond.enforceIsContractOwner();
        require(_newOwner != address(0), "New owner cannot be zero address");
        IVoxRequestKeyOps(address(this)).validateRequestKeyOnlyDiamond(_newRequestKey, _newOwner);
        LibDiamond.setContractOwner(_newOwner);
        IVoxRequestKeyOps(address(this)).rotateRequestKeyOnlyDiamond(_newRequestKey, msg.sender);
    }

    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    // add function called isOwner
    function isOwner() external view returns (bool) {
        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();
        return msg.sender == diamondStorage.contractOwner;
    }

    /// @notice Irreversibly closes the direct owner cut backdoor (item 2 bootstrap latch).
    /// @dev Owner-only. Reverts if already finalized (idempotency guard). Called at the end of
    ///      deployment; after this the only upgrade path is a passed governance FacetProposal.
    function finalizeBootstrap() external {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        require(!ts.directCutFinalized, "Bootstrap already finalized");
        ts.directCutFinalized = true;
        emit BootstrapFinalized(msg.sender, block.number);
    }

    /// @notice True once the direct owner cut backdoor has been permanently closed.
    function isBootstrapFinalized() external view returns (bool) {
        return LibVoxTokenStorage.tokenStorage().directCutFinalized;
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
