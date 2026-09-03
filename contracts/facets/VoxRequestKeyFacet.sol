// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVoxRequestKeyStorage} from "../libraries/LibVoxRequestKeyStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";

/// @title VoxRequestKeyFacet
/// @author Vox Team
/// @notice Owns the protocol requestKey: the address the off-chain signing service authenticates
///         request callers against. Published on-chain (never `ecrecover`'d), rotates atomically with
///         ownership.
/// @dev TEE-only: the requestKey is consumed only by the future TEE/enclave (aegis) signing path,
///      which authenticates each sign-request via a requestKey-signed envelope. The current
///      production backend is KMS, which does NOT use it (KMS signs with a bearer IAM credential; no
///      envelope check), so today the on-chain key is published/rotated but inert - kept now so the
///      eventual TEE cutover needs no contract upgrade.
/// @dev Storage lives in LibVoxRequestKeyStorage (accessor only). The two `...OnlyDiamond` helpers are
///      reached by intra-diamond self-call from OwnershipFacet.transferOwnership and the
///      VoxGovernanceFacet admin-election flow, so their validate/rotate bytecode does not inflate
///      those (size-constrained) facets. Deployed with `Facet.deploy(diamondAddress)` like every other
///      facet; selectors registered by the deploy diamondCut.
contract VoxRequestKeyFacet {
    /// @dev Stored solely for parity with the deploy loop's `Facet.deploy(diamondAddress)` invariant
    ///      and to forward any POL accidentally sent to the facet address back to the Diamond.
    address internal immutable diamondAddressForDirectCalls;

    /// @notice Emitted whenever the requestKey changes (owner rotation, out-of-band owner reset, or a
    ///         governance handover). `changedBy` is the human caller of the entry function, threaded
    ///         through the self-call so the event never attributes the Diamond itself.
    event RequestKeyUpdated(address indexed previousKey, address indexed newKey, address indexed changedBy);

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    /// @notice Owner-only, immediate (no timelock): rotate the requestKey out-of-band, e.g. on
    ///         suspected compromise, without waiting for an ownership change.
    /// @dev Reverts unless the new key is nonzero, not the current owner, actually changes, and differs
    ///      from the governance chapterSignerAddress (separation of duties).
    /// @param newRequestKey The new requestKey to publish.
    function setRequestKey(address newRequestKey) external {
        LibDiamond.enforceIsContractOwner();
        _validateRequestKey(newRequestKey, LibDiamond.contractOwner());
        _writeRequestKey(newRequestKey, msg.sender);
    }

    /// @notice onlyDiamond: validate a candidate requestKey against `prospectiveOwner` without mutating
    ///         state. Called by OwnershipFacet (before handover) and VoxGovernanceFacet (at application).
    /// @param newKey The candidate requestKey.
    /// @param prospectiveOwner The address that will own the Diamond if this key is adopted.
    function validateRequestKeyOnlyDiamond(address newKey, address prospectiveOwner) external view {
        require(msg.sender == address(this), "RequestKey: only diamond");
        _validateRequestKey(newKey, prospectiveOwner);
    }

    /// @notice onlyDiamond: write the requestKey (assumed already validated by the caller).
    /// @dev Intentionally does NOT re-validate. It is called at ownership handover (OwnershipFacet 2-arg
    ///      transfer and VoxGovernanceFacet.ratifyNewAdmin) where reverting would deadlock a completed
    ///      transfer/election. The key was validated when it was supplied; ratifyNewAdmin is designed to
    ///      never revert on outcome, so re-validation here would be a liveness hazard.
    /// @param newKey The requestKey to store.
    /// @param changedBy The human caller of the entry function, for event attribution.
    function rotateRequestKeyOnlyDiamond(address newKey, address changedBy) external {
        require(msg.sender == address(this), "RequestKey: only diamond");
        _writeRequestKey(newKey, changedBy);
    }

    /// @dev The four invariants every candidate requestKey must satisfy.
    function _validateRequestKey(address newKey, address prospectiveOwner) internal view {
        require(newKey != address(0), "RequestKey: zero");
        require(newKey != prospectiveOwner, "RequestKey: equals owner");
        require(newKey != LibVoxRequestKeyStorage.requestKeyStorage().requestKey, "RequestKey: unchanged");
        require(newKey != LibVoxGovernanceStorage.governanceStorage().chapterSignerAddress, "RequestKey: equals signer");
    }

    function _writeRequestKey(address newKey, address changedBy) internal {
        LibVoxRequestKeyStorage.RequestKeyStorage storage rks = LibVoxRequestKeyStorage.requestKeyStorage();
        address previous = rks.requestKey;
        rks.requestKey = newKey;
        emit RequestKeyUpdated(previous, newKey, changedBy);
    }

    /**
     * @notice Receive function to handle edge case of direct payments to facet address.
     * @dev Mirrors the other facets: forwards any POL sent directly to this facet's own address on to
     *      the Diamond. POL sent to the Diamond address is handled by Diamond.sol's receive().
     */
    receive() external payable {
        if (msg.value > 0) {
            require(diamondAddressForDirectCalls != address(0), "Diamond address not set");

            (bool success, ) = payable(diamondAddressForDirectCalls).call{value: msg.value}("");
            require(success, "Transfer to Diamond failed");
        }
    }
}
