// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

library LibVoxTokenStorage {
    bytes32 constant STORAGE_POSITION = keccak256("vox.token.storage");

    struct TokenStorage {
        bool initialized;
        uint256 totalSupply;
        string name;
        string symbol;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        // uint256 totalAggregateDividend;
        // mapping(address => uint256) lastTotalAggregateDividendAmount;
        uint256 totalAggregateRewardInPOLWei;
        uint256 totalAggregateRewardInUSDC;
        //
        uint256 totalAggregateAdminUSDC; // Admin's cumulative USDC share
        uint256 adminWithdrawnUSDC; // Total USDC admin has withdrawn
        //
        uint256 totalAggregateAdminPOL; // Admin's cumulative POL share (pull model)
        uint256 adminWithdrawnPOL; // Total POL admin has withdrawn
        //
        uint256 lastKnownUSDCBalance; // Last recorded USDC balance (for delta detection)
        address diamondAddress;
        address usdcTokenAddress;
        address priceFeedAddress;
        address openAdvertsContractAddress;
        mapping(address => uint256) lastRewardClaimInPOL;
        mapping(address => uint256) lastRewardClaimInUSDC;
        mapping(address => bool) rewardClaimInProgress;
        mapping(address => uint256) lastTransferBlock;
        mapping(address => uint256) lastVoteBlock;
        // Storage provider tranche tracking
        uint256 storageProviderPOLBalance;
        uint256 storageProviderUSDCBalance;
        // Turbo topup transaction tracking
        string[] turboTopupTransactionIds;
        mapping(string => TurboTopupRecord) turboTopupRecords;
        // Pull-model unclaimed reward balances (accrued but not yet withdrawn)
        mapping(address => uint256) unclaimedPOL;
        mapping(address => uint256) unclaimedUSDC;
        // One-way bootstrap latch. While false, the owner may run direct diamondCut
        // (bootstrap). Tripped irreversibly by an explicit owner-only finalizeBootstrap()
        // (called at the end of deployment); once true the direct owner cut path is closed
        // and upgrades must go through governance (which calls LibDiamond.diamondCut directly).
        bool directCutFinalized;
    }

    struct TurboTopupRecord {
        uint256 polAmount;
        uint256 usdcAmount;
        uint256 timestamp;
        address executedBy;
    }

    function tokenStorage() internal pure returns (TokenStorage storage ts) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ts.slot := position
        }
    }

    /**
     * @notice Canonical flash-loan / vote-cooldown eligibility check.
     * @dev Shared by VoxTokenFacet and VoxGovernanceFacet so both facets
     *      enforce identical rules. An account must not have transferred tokens or
     *      voted in the current block or the immediately preceding block.
     * @param ts The token storage pointer.
     * @param account The address to check.
     * @return bool True if the account may vote in this block.
     */
    function canVote(TokenStorage storage ts, address account) internal view returns (bool) {
        uint256 transferBlock = ts.lastTransferBlock[account];
        uint256 voteBlock = ts.lastVoteBlock[account];

        if (transferBlock == block.number) return false;
        if (voteBlock == block.number) return false;

        if (transferBlock > 0 && block.number <= transferBlock + 1) return false;
        if (voteBlock > 0 && block.number <= voteBlock + 1) return false;

        return true;
    }
}
