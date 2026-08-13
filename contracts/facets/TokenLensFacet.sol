// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";

/**
 * @title TokenLensFacet
 * @notice View-only Diamond facet that consolidates token-facet reads into
 *         single-call snapshots for the Vox frontend.
 * @dev Runs in the Diamond's delegatecall context — shares storage 1:1 with
 *      `VoxTokenFacet`. All reward math is inlined (rather than calling
 *      back through `address(this).staticcall(...)`) for gas efficiency. The
 *      formulas mirror `pendingRewards`, `calculateRewardPOL/USDC`,
 *      `getAdminAvailablePOL/USDC`, and `getTotalValueAndRewardDue` in
 *      `VoxTokenFacet` exactly.
 */
contract TokenLensFacet {
    /// @dev Stored solely for parity with the deploy loop's
    ///      `Facet.deploy(diamondAddress)` invariant.
    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }

    // ============================================
    // STRUCTS
    // ============================================

    /// @dev Mirrors the existing `getClaimPercentages()` 4-tuple shape.
    struct ClaimPercentages {
        uint256 affiliateClaimPercentage;
        uint256 viewerClaimPercentage;
        uint256 thirdPartyCount;
        uint256[] thirdPartyClaimPercentages;
    }

    /// @dev Per-transaction Turbo top-up record (id + record fields flattened).
    struct TurboTopupEntry {
        string transactionId;
        uint256 polAmount;
        uint256 usdcAmount;
        uint256 timestamp;
        address executedBy;
    }

    struct TokenFacetSnapshot {
        // ── immutable / global token info ──────────────
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        ClaimPercentages claimPercentages;
        // ── treasury / wiring ──────────────────────────
        uint256 adminAvailablePOL;
        uint256 adminAvailableUSDC;
        address openAdvertsContractAddress;
        address usdcAddress;
        address priceFeedAddress;
        // ── per-user (zero if user == address(0)) ──────
        uint256 userPendingPOL;
        uint256 userPendingUSDC;
        uint256 userAccrualPOL;
        uint256 userAccrualUSDC;
        bool userCanVoteThisBlock;
        // ── totals snapshot ────────────────────────────
        uint256 totalPOLReward;
        uint256 totalUSDCReward;
        uint256 userPOLRewardDue;
        uint256 userUSDCRewardDue;
    }

    struct StorageProviderSnapshot {
        bool isStorageProvider;
        address registeredProvider;
        uint256 tranchePOL;
        uint256 trancheUSDC;
        TurboTopupEntry[] turboHistory;
    }

    // ============================================
    // PROMPT 6 — getTokenFacetSnapshot(user)
    // ============================================

    /**
     * @notice Single-call aggregator for token-facet reads used by the PGovernance UI.
     * @param user Address to populate per-user fields for. Pass address(0) to
     *             zero-out the user-scoped fields while still populating
     *             everything else.
     */
    function getTokenFacetSnapshot(address user) external view returns (TokenFacetSnapshot memory snapshot) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage gs = LibVoxGovernanceStorage.governanceStorage();

        // ── immutable / global token info ──
        snapshot.name = ts.name;
        snapshot.symbol = ts.symbol;
        snapshot.decimals = 18;
        snapshot.totalSupply = ts.totalSupply;
        snapshot.claimPercentages = _buildClaimPercentages(gs);

        // ── treasury / wiring ──
        snapshot.adminAvailablePOL = ts.totalAggregateAdminPOL - ts.adminWithdrawnPOL;
        snapshot.adminAvailableUSDC = _adminAvailableUSDC(ts, gs);
        snapshot.openAdvertsContractAddress = ts.openAdvertsContractAddress;
        snapshot.usdcAddress = ts.usdcTokenAddress;
        snapshot.priceFeedAddress = ts.priceFeedAddress;

        // ── totals (msg.sender-independent portion) ──
        snapshot.totalPOLReward = address(this).balance;
        if (ts.usdcTokenAddress != address(0)) {
            snapshot.totalUSDCReward = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
        }

        // ── per-user ──
        if (user != address(0)) {
            uint256 polAccrual = _calculateRewardPOL(ts, user);
            uint256 usdcAccrual = _calculateRewardUSDC(ts, user);

            snapshot.userAccrualPOL = polAccrual;
            snapshot.userAccrualUSDC = usdcAccrual;

            // pendingRewards: unclaimed + accrual cursor gap (USDC simulates undetected deposits).
            snapshot.userPendingPOL = ts.unclaimedPOL[user] + polAccrual;
            snapshot.userPendingUSDC = _pendingUSDCWithSimulation(ts, gs, user);

            // getTotalValueAndRewardDue tuple[2]/[3]: unclaimed + plain calculateRewardX.
            snapshot.userPOLRewardDue = ts.unclaimedPOL[user] + polAccrual;
            snapshot.userUSDCRewardDue = ts.unclaimedUSDC[user] + usdcAccrual;

            snapshot.userCanVoteThisBlock = LibVoxTokenStorage.canVote(ts, user);
        }
    }

    // ============================================
    // PROMPT 7 — getStorageProviderSnapshot(user)
    // ============================================

    /**
     * @notice Snapshot of storage-provider tranche + turbo history.
     * @dev `registeredProvider` is always populated. Tranches and history are
     *      only meaningful when `user == registeredProvider`; otherwise
     *      returned as zero/empty so the UI can render static info safely.
     */
    function getStorageProviderSnapshot(address user) external view returns (StorageProviderSnapshot memory snapshot) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxGovernanceStorage.GovernanceStorage storage gs = LibVoxGovernanceStorage.governanceStorage();

        snapshot.registeredProvider = gs.storageProviderAddress;

        if (user == address(0) || user != gs.storageProviderAddress) {
            // Leave tranche/history zero/empty; isStorageProvider stays false.
            return snapshot;
        }

        snapshot.isStorageProvider = true;
        snapshot.tranchePOL = ts.storageProviderPOLBalance;
        snapshot.trancheUSDC = ts.storageProviderUSDCBalance;

        uint256 n = ts.turboTopupTransactionIds.length;
        snapshot.turboHistory = new TurboTopupEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory txid = ts.turboTopupTransactionIds[i];
            LibVoxTokenStorage.TurboTopupRecord storage rec = ts.turboTopupRecords[txid];
            snapshot.turboHistory[i] = TurboTopupEntry({
                transactionId: txid,
                polAmount: rec.polAmount,
                usdcAmount: rec.usdcAmount,
                timestamp: rec.timestamp,
                executedBy: rec.executedBy
            });
        }
    }

    // ============================================
    // INTERNAL HELPERS — exact mirrors of token-facet logic
    // ============================================

    function _buildClaimPercentages(LibVoxGovernanceStorage.GovernanceStorage storage gs) internal view returns (ClaimPercentages memory cp) {
        cp.affiliateClaimPercentage = gs.currentQuotas.voxClaimPercentage;
        cp.viewerClaimPercentage = gs.currentQuotas.viewerClaimPercentage;

        uint256[6] memory all = [
            gs.currentQuotas.thirdParty1ClaimPercentage,
            gs.currentQuotas.thirdParty2ClaimPercentage,
            gs.currentQuotas.thirdParty3ClaimPercentage,
            gs.currentQuotas.thirdParty4ClaimPercentage,
            gs.currentQuotas.thirdParty5ClaimPercentage,
            gs.currentQuotas.thirdParty6ClaimPercentage
        ];

        uint256 count;
        for (uint256 i = 0; i < 6; i++) {
            if (all[i] > 0) count++;
        }
        cp.thirdPartyCount = count;
        cp.thirdPartyClaimPercentages = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < 6; i++) {
            if (all[i] > 0) {
                cp.thirdPartyClaimPercentages[j++] = all[i];
            }
        }
    }

    function _adminAvailableUSDC(
        LibVoxTokenStorage.TokenStorage storage ts,
        LibVoxGovernanceStorage.GovernanceStorage storage gs
    ) internal view returns (uint256) {
        uint256 pendingAdminUSDC = ts.totalAggregateAdminUSDC;
        if (ts.usdcTokenAddress != address(0)) {
            uint256 currentBalance = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
            if (currentBalance > ts.lastKnownUSDCBalance) {
                uint256 newDeposits = currentBalance - ts.lastKnownUSDCBalance;
                uint256 storageAmount = (newDeposits * gs.currentQuotas.storageProviderPercentage) / 100;
                if (storageAmount > newDeposits) storageAmount = newDeposits;
                uint256 afterStorage = newDeposits - storageAmount;
                uint256 adminAmount = (afterStorage * gs.currentQuotas.voxAdminClaimPercentage) / 100;
                if (adminAmount > afterStorage) adminAmount = afterStorage;
                pendingAdminUSDC += adminAmount;
            }
        }
        return pendingAdminUSDC - ts.adminWithdrawnUSDC;
    }

    function _calculateRewardPOL(LibVoxTokenStorage.TokenStorage storage ts, address account) internal view returns (uint256) {
        uint256 bal = ts.balances[account];
        if (bal == 0 || ts.totalAggregateRewardInPOLWei == 0 || ts.totalSupply == 0) return 0;
        uint256 last = ts.lastRewardClaimInPOL[account];
        if (ts.totalAggregateRewardInPOLWei <= last) return 0;
        return (bal * (ts.totalAggregateRewardInPOLWei - last)) / ts.totalSupply;
    }

    function _calculateRewardUSDC(LibVoxTokenStorage.TokenStorage storage ts, address account) internal view returns (uint256) {
        uint256 bal = ts.balances[account];
        if (bal == 0 || ts.totalAggregateRewardInUSDC == 0 || ts.totalSupply == 0) return 0;
        uint256 last = ts.lastRewardClaimInUSDC[account];
        if (ts.totalAggregateRewardInUSDC <= last) return 0;
        return (bal * (ts.totalAggregateRewardInUSDC - last)) / ts.totalSupply;
    }

    function _pendingUSDCWithSimulation(
        LibVoxTokenStorage.TokenStorage storage ts,
        LibVoxGovernanceStorage.GovernanceStorage storage gs,
        address account
    ) internal view returns (uint256 usdcReward) {
        usdcReward = ts.unclaimedUSDC[account];

        uint256 effectiveTotalUSDC = ts.totalAggregateRewardInUSDC;
        if (ts.usdcTokenAddress != address(0)) {
            uint256 currentBalance = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
            if (currentBalance > ts.lastKnownUSDCBalance) {
                uint256 newDeposits = currentBalance - ts.lastKnownUSDCBalance;
                uint256 storageAmount = (newDeposits * gs.currentQuotas.storageProviderPercentage) / 100;
                if (storageAmount > newDeposits) storageAmount = newDeposits;
                uint256 afterStorage = newDeposits - storageAmount;
                uint256 adminAmount = (afterStorage * gs.currentQuotas.voxAdminClaimPercentage) / 100;
                if (adminAmount > afterStorage) adminAmount = afterStorage;
                effectiveTotalUSDC += (afterStorage - adminAmount);
            }
        }

        uint256 bal = ts.balances[account];
        if (bal > 0 && effectiveTotalUSDC > 0 && ts.totalSupply > 0) {
            uint256 lastClaimed = ts.lastRewardClaimInUSDC[account];
            if (effectiveTotalUSDC > lastClaimed) {
                usdcReward += (bal * (effectiveTotalUSDC - lastClaimed)) / ts.totalSupply;
            }
        }
    }
}
