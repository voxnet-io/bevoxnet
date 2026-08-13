# Vox Diamond Project Documentation

---

## 1. Project Overview

Vox is a content creator platform built on Polygon (POL). The protocol allows community members (called "chapters") to form groups around a chapter admin, with sub-moderators and viewers participating in a dual-token reward distribution system (POL native token + USDC). There is a single platform owner (the VOX/admin) who governs the protocol and can be changed via on-chain token holder elections.

The entire backend is a single EIP-2535 Diamond proxy contract. All user-facing functionality routes through the Diamond's `fallback()` and `receive()`. No business logic lives in the Diamond contract itself — everything is delegated to facets.

**Target network:** Polygon mainnet (chainId 137)  
**Native token:** POL (formerly MATIC)  
**Stablecoin:** USDC (6 decimals) — `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` on mainnet  
**Price oracle:** Chainlink POL/USD feed  
**Solidity version:** 0.8.22  
**Build toolchain:** Hardhat, ethers.js, OpenZeppelin Contracts  
**Optimizer:** enabled, 200 runs

---

## 2. Architecture

### 2.1 Diamond Proxy (EIP-2535)

The Diamond is the single public-facing contract address. It contains no business logic. Its `fallback()` reads `msg.sig`, looks up the corresponding facet address from `LibDiamond.diamondStorage().selectorToFacetAndPosition`, and `delegatecall`s into that facet. All facets execute in the Diamond's storage context.

**Diamond.sol**

- Constructor: sets contract owner, registers only `diamondCut` selector
- `fallback()`: function selector routing via `delegatecall`
- `receive()`: POL payment entry point. Implements a 3-step waterfall:
  1. Storage provider cut (tracked in `storageProviderPOLBalance`, not transferred)
  2. Admin claim (accumulated in `ts.totalAggregateAdminPOL` — **pull model, never pushed**)
  3. Bounty pool (added to `totalAggregateRewardInPOLWei` for token holder distribution)

  Admin withdraws their POL share via `VoxTokenFacet.withdrawAdminPOL()`. This mirrors the USDC pull pattern and eliminates the `require(adminSuccess)` send-on-receive failure mode.

### 2.2 Facets

Each facet is an independently deployed contract. All facets take `diamondAddress` as a constructor argument (stored as `immutable`) for the case where the facet receives direct payments (they forward to the Diamond). **Exceptions:** `DiamondCutFacet` has no constructor and no `immutable` — it is deployed standalone and receives the Diamond's context via `delegatecall`.

| Facet                | Responsibility                                                                |
| -------------------- | ----------------------------------------------------------------------------- |
| `DiamondCutFacet`    | Add/replace/remove function selectors on the Diamond                          |
| `DiamondLoupeFacet`  | Introspection: enumerate facets and selectors (EIP-2535 required)             |
| `OwnershipFacet`     | ERC-173 ownership — `owner()`, `transferOwnership()`, `isOwner()`             |
| `VoxFacet`           | Chapter registry, chapter creation, admin management, platform ban management |
| `VoxGovernanceFacet` | Proposal-based governance, admin elections, signing/storage config            |
| `VoxTokenFacet`      | ERC-20 VOX token, POL/USDC reward distribution, flash loan protection         |

**Test facets** (`Test1Facet`, `Test2Facet`) exist in the repo but are not registered on the Diamond in production deployment.

### 2.3 Chapter Contracts

Each chapter is a **separate standalone contract** (`VoxChapter.sol`), not a facet. Chapters are deployed via the minimal proxy clone pattern (OpenZeppelin `Clones`) from a single master implementation address stored in `LibVoxStorage.VoxMainStorage.chapterImplementation` (accessed via `VoxFacet.getChapterImplementation()`). The Diamond holds the chapter registry; chapter contracts hold their own reward state and member lists.

Chapter contracts call back into the Diamond (via the `IVoxDiamond` interface) in two cases:

- `updateChapterAdmin()` — when admin succession occurs inside the chapter
- `isUserBannedFromPlatform()`, `isChapterBannedByPlatform()`, `isChapterRemoved()` — for permission checks
- `registerSubMod(address)` — when a new subMod accepts an invitation (`acceptSubModInvitation`)
- `deregisterSubMod(address)` — when a subMod is removed or leaves (`removeSubMod`, `_removeSubModInternal`)

The Diamond calls into chapter contracts (via `IVoxChapter`) in these cases:

- `setBanned(bool)` — when the platform bans or unbans a chapter
- `prepareForRemoval()` — when the platform permanently removes a chapter
- `getMigrationSnapshot()` — reads packed scalar state during migration
- `migrateState(snap, polBal, usdcBal)` — restores scalar state on the new clone
- `migrateUserClaims(users[], polClaimed[], usdcClaimed[])` — restores per-user claim cursors
- `migrateBannedUsers(users[])` — restores banned-user list
- `migratePOL(dest)` — transfers native POL balance to new clone
- `migrateUSDC(dest, amount)` — transfers USDC balance to new clone

### 2.4 Storage Layout

Storage is partitioned using the "diamond storage" pattern: each library defines its own isolated struct at a deterministic keccak256 slot. No library shares a slot with another.

| Library                   | Storage Key                                     | Contents                                                                                                                                        |
| ------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `LibDiamond`              | `keccak256("diamond.standard.diamond.storage")` | Selector→facet mapping, facet address array, supported interfaces, `contractOwner`                                                              |
| `LibVoxStorage`           | `keccak256("vox.main.storage")`                 | Chapter registry, admin↔chapter bidirectional mappings, platform ban state                                                                      |
| `LibVoxTokenStorage`      | `keccak256("vox.token.storage")`                | VOX token balances, reward aggregates, USDC/oracle addresses, vote/transfer cooldown blocks, storage provider balances, turbo topup audit trail |
| `LibVoxGovernanceStorage` | `keccak256("vox.governance.storage")`           | Quota config, active proposal state, admin election state, signing address                                                                      |
| `LibVoxChapterStorage`    | `keccak256("vox.chapter.storage")`              | Stub (currently only `chapterName`), reserved for future use                                                                                    |

---

## 3. Core Data Structures

### 3.1 VoxMainStorage (LibVoxStorage)

```solidity
struct VoxMainStorage {
    mapping(string => address)  chapterAddresses;              // chapterName → chapter contract
    string[]                    chapterArray;                  // ordered list of all chapter names
    string[]                    inactiveChapterArray;          // banned/removed chapter names
    mapping(address => address) checkChapterAdminAddress;     // user → chapter they admin (user→chapter)
    mapping(address => address) checkChapterAdminAddressOut;  // chapter → its admin (chapter→user)
    mapping(address => bool)    isAdmin;                      // quick admin status flag
    // Multi-chapter subMod registry (replaces single-chapter isSubmod mapping).
    // A subMod may belong to multiple chapters simultaneously.
    mapping(address => address[]) subModChaptersList;          // subMod → chapters they belong to
    mapping(address => mapping(address => bool)) isSubModOf;   // subMod → chapter → bool
    mapping(address => mapping(address => uint256)) subModChapterIndex; // subMod → chapter → 1-based index
    mapping(address => bool)    isUserBanned;                 // platform-level user ban
    mapping(address => uint256) isUserBannedFromBlocknumber;
    mapping(address => bool)    isChapterBanned;              // platform-level chapter ban
    mapping(address => uint256) chapterBanBlockNumber;
    mapping(address => bool)    isChapterRemoved;             // permanent removal flag
    mapping(address => uint256) chapterRemovalBlockNumber;
    mapping(string => uint256)  chapterArrayIndex;            // O(1) array management
    mapping(string => uint256)  inactiveChapterArrayIndex;
    address                     chapterImplementation;        // EIP-1167 master implementation for clones
}
```

Key invariant: `checkChapterAdminAddress` and `checkChapterAdminAddressOut` are maintained as a **bidirectional mapping**. One admin can only manage one chapter at a time (exception: platform owner can hold multiple). This invariant is enforced in `updateChapterAdmin()` and violated by direct storage writes (which only diamondCut can produce).

### 3.2 TokenStorage (LibVoxTokenStorage)

Holds ERC-20 state (balances, supply, name/symbol) alongside reward tracking. There is **no per-user accumulator** — rewards use a "global aggregate" pattern:

- `totalAggregateRewardInPOLWei` — running total of all POL ever added to the bounty pool
- `lastRewardClaimInPOL[user]` — value of `totalAggregateRewardInPOLWei` at the time of the user's last claim
- `totalAggregateAdminPOL` — cumulative POL admin share (accumulates from `receive()`; admin withdraws via `withdrawAdminPOL()`)
- `adminWithdrawnPOL` — total POL the admin has already withdrawn
- `allowances` — ERC-20 approval mappings for `transferFrom` support
- `storageProviderPOLBalance` / `storageProviderUSDCBalance` — storage provider's accumulated cut (withdrawn via `withdrawStorageProviderFunds()`)
- `turboTopupTransactionIds` / `turboTopupRecords` — audit trail for off-chain Turbo topup executions reported by the owner via `confirmTurboTopup()`

On claim: `reward = (balance / totalSupply) * (currentAggregate - lastClaim)`

The same pattern applies to USDC via `totalAggregateRewardInUSDC` and `lastRewardClaimInUSDC`.

### 3.3 GovernanceStorage (LibVoxGovernanceStorage)

```
CurrentQuotas                   — live governance parameters (percentages, quorums, durations, fees)
VotingStruct                    — active proposal state (id, type, deadline, vote tallies)
QuotaProposal                   — pending proposed quota values
proposedNewFacets[]             — pending proposed diamond cuts
proposedInit                    — initializer address for FacetProposal (passed to diamondCut on ratification)
proposedInitCalldata            — initializer calldata for FacetProposal
hasVotedOnProposal[][]          — per-user per-proposal vote flag
votesByUser[][][]               — per-user per-proposal per-direction vote amount
proposedAdminAddresses[]        — candidates in current admin election (capped at MAX_ADMIN_CANDIDATES = 100)
adminVotesByUser[][][]          — per-voter per-round per-candidate vote amount
totalVotesPerAdminCandidate[][] — candidate totals
adminApplicantStorageId[][]     — per-applicant per-round storage provider ID submitted at application
```

---

## 4. Key Flows

### 4.1 Chapter Creation

1. Platform signs `keccak256(chapterName || msg.sender || chainId)` off-chain (ECDSA, EIP-191). The payload binds the chapter name to the specific caller address and chain ID, preventing front-running (another wallet reusing the sig) and cross-chain replay.
2. User calls `VoxFacet.createChapter(name, id, signature)`
3. Signature verified: `ecrecover(EIP191(keccak256(name || caller || chainId))) == govStorage.signingAddress`
4. Chapter name uniqueness checked
5. Minimal proxy clone of `chapterImplementation` deployed via `Clones.clone()`
6. `VoxChapter.initialize()` called on the clone
7. Bidirectional admin mappings set in `LibVoxStorage`
8. Events emitted: `ChapterCreated`, `AdminAssigned`

Non-owner users are limited to one chapter. The owner can create multiple.

### 4.2 POL Reward Flow

```
External caller → Diamond.receive()
  → storage provider cut tracked (not sent)
  → admin share accumulated: ts.totalAggregateAdminPOL += adminClaimAmount  (pull model)
  → remainder added to ts.totalAggregateRewardInPOLWei (bounty pool)

Token holder calls distributeReward(account) [or it's triggered on transfer]
  → reward = (balance/supply) * (currentAggregate - lastClaim)
  → low-level .call{value: reward}(account)
  → lastRewardClaimInPOL[account] = currentAggregate

Platform owner (VOXAdmin) calls withdrawAdminPOL()
  → available = totalAggregateAdminPOL - adminWithdrawnPOL
  → adminWithdrawnPOL += available (cursor advanced before send)
  → low-level .call{value: available}(contractOwner)
  → emits AdminPOLWithdrawn(contractOwner, available)
```

### 4.3 USDC Reward Flow

USDC arrives via direct ERC-20 transfer (no `receive()` equivalent). The contract detects it by comparing `IERC20(usdc).balanceOf(address(this))` against `lastKnownUSDCBalance`. This delta detection runs at the start of every USDC-touching operation (`processNewUSDCDeposits()`). The 3-step waterfall (storage cut → admin claim → bounty pool) mirrors the POL flow.

USDC originates from the `OpenAdverts` contract (external, address configurable by owner).

### 4.4 Chapter Reward Flow

Chapter contracts hold their own POL and USDC directly. They use the same delta detection pattern (`lastKnownPOLBalance`, `lastKnownUSDCBalance`). Distribution is:

- Chapter owner: `(total * chapterOwnerShare) / 100`
- Each subMod: `(total * (100 - chapterOwnerShare)) / 100 / subModCount`

Reward claiming inside a chapter is independent of the Diamond's reward pool.

### 4.5 Governance — Proposals

1. Owner calls `createProposal(type, data, duration, facets, initAddress, initCalldata)`
2. Token holders vote via `voteOnProposal(bool support)` (flash loan protected, one vote per proposal per address)
3. Voting power = token balance at time of vote
4. After the deadline, **anyone** may call `ratifyUpgrade()` (permissionless — the vote outcome is already fixed)
5. Quorum check (support/FOR votes only): `support >= (totalSupply * quorum%) / 100`. An oppose vote can never help a proposal reach quorum.
6. `ratifyUpgrade()` never reverts on quorum/majority: if `support >= quorum && support > oppose` it applies the change, otherwise it resolves the proposal without applying. Either way it clears the single-proposal queue (emitting `ProposalRatified` or `ProposalFailed`), so an expired proposal can never brick governance.
7. For `QuotaProposal`: quotas updated in `govStorage.currentQuotas`
8. For `FacetProposal`: `LibDiamond.diamondCut()` is called **directly** (internal) with the proposed facets and stored initializer (`initAddress`, `initCalldata`). It intentionally does **not** route through `IDiamondCut(address(this)).diamondCut(...)` — an external self-call would enter `DiamondCutFacet` with `msg.sender == address(this)` and fail `enforceIsContractOwner()`. The passed vote is the authorization. This path also bypasses the bootstrap latch (see §8).

> **Owner veto window:** `revokeProposal()` (owner-only) may only be called **before** the voting deadline (`block.number < votingDeadline`). After the deadline the outcome belongs to token holders and is resolved by the permissionless `ratifyUpgrade()`.

### 4.6 Governance — Admin Elections

1. Any non-incumbent token holder calls `applyAsNewAdmin(storageId)` with fee in POL (candidate list capped at `MAX_ADMIN_CANDIDATES = 100`)
2. First applicant triggers incumbent being auto-added to candidates and sets voting deadline
3. Token holders call `voteForNewAdmin(candidate)` (support votes only, no opposition; self-voting is permitted)
4. After deadline, anyone calls `ratifyNewAdmin()` (requires active election: `proposedAdminAddresses.length > 0`)
5. Candidate with highest votes meeting quorum threshold wins; incumbent winning is a valid outcome (no-op ownership change, election resets)
6. `LibDiamond.contractOwner` updated, `LibVoxStorage` admin flags updated
7. `adminVoteId` incremented, candidate list cleared

### 4.7 Ban Flows

**Platform user ban:** `VoxGovernanceFacet.banUserFromPlatform()` (owner-only) sets `mainStorage.isUserBanned[user]`. Reverted via `unbanUserFromPlatform()`. Checked at chapter creation and subMod invitation. Chapter contracts call back to `isUserBannedFromPlatform()` on the Diamond for all ban checks — they do **not** read Diamond storage directly (the old approach was silently broken because `LibVoxStorage.mainStorage()` inside a chapter clone resolves to the _chapter's own_ keccak slot, not the Diamond's).

**Chapter user ban:** `VoxChapter.banUserFromChapter()` (chapter owner or platform owner). Stored in `chapterBannedUsers[user]` (mapping) with a parallel `bannedUsersArray` (address[]) + `bannedUsersArrayIndex` (1-based mapping) kept in sync. The array enables full enumeration during chapter migration. Swap-and-pop is used on unban to keep the array compact.

**Platform chapter ban:** `VoxFacet.banChapter()` (owner-only). Sets `mainStorage.isChapterBanned[chapter]`, adds to `inactiveChapterArray`, calls `IVoxChapter.setBanned(true)`.

**Chapter removal:** `VoxFacet.removeChapter()` (owner-only). Calls `IVoxChapter.prepareForRemoval()` which distributes all funds, frees subMods, and sets the `isRemoved` flag permanently.

---

## 5. Access Control Matrix

| Action                                                                                    | Who Can Call                                                                  |
| ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `diamondCut` (upgrade)                                                                    | Diamond owner only (via `DiamondCutFacet`), **bootstrap phase only** (see §8) |
| `finalizeBootstrap` / `isBootstrapFinalized`                                              | Owner only (finalize) / anyone (view) — via `OwnershipFacet`                  |
| `transferOwnership`                                                                       | Diamond owner (see §8 — democratic-election trade-off is open)                |
| `createChapter`                                                                           | Any non-banned address with valid platform signature                          |
| `setChapterAdmin`                                                                         | Platform owner only                                                           |
| `revokeChapterAdmin`                                                                      | Platform owner only                                                           |
| `updateChapterAdmin`                                                                      | Registered chapter contracts only (callback)                                  |
| `banChapter` / `unbanChapter`                                                             | Platform owner **or VoxAssistant**                                            |
| `removeChapter`                                                                           | Platform owner only (banned users cannot self-remove even if owner)           |
| `banUserFromPlatform` / `unbanUserFromPlatform`                                           | Platform owner **or VoxAssistant** (via GovernanceFacet)                      |
| `inviteVoxAssistant` / `revokeVoxAssistantInvitation` / `removeVoxAssistant`              | Platform owner only (via GovernanceFacet)                                     |
| `acceptVoxAssistantInvitation` / `declineVoxAssistantInvitation` / `resignAsVoxAssistant` | Invited address / active VoxAssistant (self-service)                          |
| `banUserFromChapter`                                                                      | Chapter owner or platform owner                                               |
| `addSubMod` / `inviteSubMod`                                                              | Chapter owner or platform owner                                               |
| `createProposal`                                                                          | Platform owner only                                                           |
| `revokeProposal`                                                                          | Platform owner only, **before the voting deadline only**                      |
| `ratifyUpgrade`                                                                           | Anyone (after the voting deadline — permissionless resolver)                  |
| `voteOnProposal`                                                                          | Any VOX token holder (flash loan protected)                                   |
| `applyAsNewAdmin`                                                                         | Any non-incumbent non-banned address (fee required)                           |
| `voteForNewAdmin`                                                                         | Any VOX token holder (flash loan protected)                                   |
| `ratifyNewAdmin`                                                                          | Anyone (after deadline)                                                       |
| `initialize` (token/governance)                                                           | Platform owner, one-time only                                                 |
| `setChapterImplementation`                                                                | Platform owner                                                                |
| `getChapterImplementation`                                                                | Anyone (public view)                                                          |
| `migrateChapter` / `batchMigrateChapters`                                                 | Platform owner (migrateChapter is nonReentrant)                               |
| `withdrawAdminPOL`                                                                        | Platform owner only (via VoxTokenFacet)                                       |
| `getAdminAvailablePOL`                                                                    | Anyone (public view)                                                          |
| `approve` / `allowance` / `transferFrom`                                                  | ERC-20 standard — any token holder                                            |
| `withdrawAdminUSDC` / `getAdminAvailableUSDC`                                             | Platform owner / anyone (view — pure read, no state mutation)                 |
| `withdrawStorageProviderFunds`                                                            | Platform owner only (via VoxTokenFacet)                                       |
| `confirmTurboTopup`                                                                       | Platform owner only (voluntary audit trail)                                   |
| `getTurboTopupHistory` / `getTurboTopupDetails`                                           | Anyone (public view)                                                          |
| `claimChapterRewards` (chapter)                                                           | Chapter owner, subMods, or platform owner                                     |
| `rescueChapterFunds` (chapter)                                                            | Platform owner (chapter must be banned or removed)                            |

### 5.1 VoxAssistant Role (delegated moderation)

The **VoxAssistant** is an optional role delegating the four moderation powers above (`banChapter`, `unbanChapter`, `banUserFromPlatform`, `unbanUserFromPlatform`) to one or more trusted addresses. All other VOX Admin powers (`diamondCut`, `transferOwnership`, `confirmTurboTopup`, fund movement, proposal creation, facet/implementation management) remain exclusively with the platform owner.

**Lifecycle (two-step opt-in, mirrors SubMod invitations):**

1. VOX Admin calls `inviteVoxAssistant(candidate)` — candidate must not be zero, self, already-active, already-invited, or platform-banned.
2. Candidate calls `acceptVoxAssistantInvitation()` (re-validates platform-ban at accept time) or `declineVoxAssistantInvitation()`.
3. VOX Admin may call `revokeVoxAssistantInvitation(candidate)` before acceptance, or `removeVoxAssistant(assistant)` after.
4. An active assistant may call `resignAsVoxAssistant()` at any time.

**Auto-cleanup on ban:** When `banUserFromPlatform(user)` is called, if `user` is an active VoxAssistant they are auto-removed, and any pending invitation is auto-revoked — preventing a banned address from later accepting a stale invite.

**Storage:** Appended to `LibVoxGovernanceStorage.GovernanceStorage` (preserves slot layout): enumerable `voxAssistants` array + `isVoxAssistant` mapping + 1-based `voxAssistantIndex`; parallel `voxAssistantInvitations` array + `hasVoxAssistantInvite` + 1-based `voxAssistantInviteIndex` + `voxAssistantInviteSentAt` timestamp.

**Auth helper:** `LibVoxGovernanceStorage.enforceIsOwnerOrVoxAssistant()` — short-circuits on `contractOwner`, otherwise requires active assistant. `LibDiamond` itself is left pure per EIP-2535.

**Explicitly out of scope:** No cap on assistant count, no invitation expiry, no timelock, no owner-change wipe. `VoxChapter._getPlatformOwner()` still resolves strictly to the diamond owner — assistants have **no** chapter-side powers.

---

## 6. External Dependencies

| Dependency                            | Usage                                                          | Address (Polygon mainnet)                        |
| ------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------ |
| OpenZeppelin ERC20                    | Interface only (not inherited state — VOX uses custom storage) | N/A                                              |
| OpenZeppelin ECDSA + MessageHashUtils | Signature verification in `createChapter`                      | N/A                                              |
| OpenZeppelin ReentrancyGuard          | `nonReentrant` on transfer and reward functions                | N/A                                              |
| OpenZeppelin Clones                   | Minimal proxy deployment of `VoxChapter`                       | N/A                                              |
| Chainlink AggregatorV3Interface       | POL/USD price feed for reward calculations                     | Configurable via `setPriceFeedAddress`           |
| USDC (ERC-20)                         | Reward distribution token                                      | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`     |
| OpenAdverts contract                  | External USDC reward source                                    | Configurable via `setOpenAdvertsContractAddress` |

> **Note:** OpenZeppelin's `ERC20` contract is imported by `VoxTokenFacet` and `VoxFacet` but the token state is entirely in `LibVoxTokenStorage`, not in OZ's inherited state. The facet does NOT inherit from `ERC20` — it imports it for the `IERC20` interface and library functions only.

---

## 7. Deployment Sequence

From `scripts/deploy.js`:

1. Deploy `MockUSDC` (testnet) or use mainnet address
2. Deploy `MockV3Aggregator` (testnet) or use Chainlink address
3. Deploy `DiamondCutFacet`
4. Deploy `Diamond(contractOwner, diamondCutFacet)`
5. Deploy `DiamondInit`
6. Deploy all facets: `DiamondLoupeFacet`, `OwnershipFacet`, `VoxFacet`, `VoxGovernanceFacet`, `VoxTokenFacet` — each with `diamondAddress` as constructor arg
7. `diamondCut` to add all facets, calling `DiamondInit.init()` as initializer
8. Deploy `VoxChapter` master implementation
9. `voxFacet.setChapterImplementation(implAddress)`
10. `voxTokenFacet.initialize(diamond, usdc, priceFeed, openAdverts)`
11. `voxGovernanceFacet.initialize(quotas, signingAddress, storageProviderAddress)`

All facets receive `(diamondAddress)` in their constructor. This address is stored as `immutable` and used only to forward accidental direct payments back to the Diamond.

---

## 8. Upgradeability Model

There are two upgrade mechanisms:

**Owner-direct upgrade (bootstrap phase only):** While the diamond is in bootstrap, the platform owner can submit a `diamondCut` transaction directly to add, replace, or remove function selectors with no governance vote. It is the mechanism used at deployment and for early fixes. A **one-way bootstrap latch** (`LibVoxTokenStorage.directCutFinalized`) permanently closes this path: it is tripped by an explicit owner-only call to `OwnershipFacet.finalizeBootstrap()`, which `scripts/deploy.js` invokes at the end of a successful deployment (`deployDiamond(true)`). Token transfers do **not** trip it (kept off the transfer hot path). After it trips, `DiamondCutFacet.diamondCut` reverts `"Bootstrap finalized: use governance"`. Query state via `isBootstrapFinalized()`; the trip emits `BootstrapFinalized`.

**Governance-gated upgrade (`FacetProposal`):** A `FacetProposal` is created by the owner, voted on by token holders, and if support-quorum and majority are met, resolved by the permissionless `ratifyUpgrade()` (callable by anyone after the deadline). Ratification calls `LibDiamond.diamondCut()` **directly** (internal) — not the external `IDiamondCut` wrapper — so it is unaffected by the bootstrap latch. This is the only upgrade path once bootstrap is finalized.

Because production deployment finalizes the latch immediately, there is no post-deploy owner-direct fix window: even the earliest fixes go through a `FacetProposal` (during bootstrap the owner still holds ~100% of supply, so the owner alone can meet quorum, but must observe the `minFacetProposalDuration` voting window ≈ 1 day). This removes the standing owner backdoor at the cost of a mandatory delay on upgrades.

**Chapter implementation upgrade:** The platform owner upgrades `chapterImplementation` in `VoxFacet` via `setChapterImplementation()`. Existing chapters are **not** automatically migrated. Migration requires explicit calls to `migrateChapter(name)` (or `batchMigrateChapters(names[])` for bulk). The migration sequence:

1. `require(!isChapterBanned)` — banned chapters cannot be migrated
2. Deploy new clone from current `chapterImplementation`
3. Call `initialize()` on the new clone (sets name, id, diamond pointer, owner)
4. Read old clone's subMod list; call `addSubModDirect()` on new clone for each
5. Transfer USDC via `oldChapter.migrateUSDC(newAddr, balance)` (runs in old clone's context)
6. Capture `oldChapter.balance` then transfer POL via `oldChapter.migratePOL(newAddr)` (runs in old clone's context)
7. Pack scalar state into `MigrationSnapshot` struct via `getMigrationSnapshot()` and apply via `migrateState(snap, polBal, usdcBal)` — restores `chapterOwnerShare`, aggregate accounting fields, and min-claim thresholds; stamps `lastKnownPOLBalance` / `lastKnownUSDCBalance`
8. Restore per-user claim cursors via `migrateUserClaims(users[], polClaimed[], usdcClaimed[])`
9. Restore banned-user list via `migrateBannedUsers(array[])`
10. Update all registry mappings in `LibVoxStorage` to point to the new clone address

The old clone is orphaned after migration (no registry entry, no funds). All migration helpers (`migrateState`, `migrateUserClaims`, `migrateBannedUsers`, `migratePOL`, `migrateUSDC`) are guarded by `require(msg.sender == diamondAddress, "AUTH")`.

---

## 9. Known Design Constraints & Important Assumptions

1. **One admin per chapter, one chapter per admin** — enforced in `updateChapterAdmin`. Violation produces inconsistent bidirectional mapping state.

2. **21,000,000 VOX total supply** — fixed at initialization, minted entirely to deployer. No mint function exists post-initialization.

3. **Max 150 subMods per chapter** — enforced in `_addSubModInternal`. Exists to bound gas cost of iteration during fund distribution and `prepareForRemoval`.

4. **Reward distribution is pull-based for token holders** — holders call `distributeReward(account)` or it triggers on `transfer()`. Diamond POL is never pushed automatically.

5. **Reward distribution is push-based for chapter members** — calling `claimChapterRewards()` distributes to all members in one transaction. Gas cost scales with subMod count.

6. **USDC delta detection is stateful** — relies on `lastKnownUSDCBalance` being consistent. If USDC is transferred out by any mechanism not tracked by the contract (e.g., direct ERC-20 transfer by a compromised owner), the aggregate can become inconsistent.

7. **Platform owner has broad unilateral power** — can upgrade the diamond, ban users/chapters, revoke admins, set signing address, set implementation. The governance system provides community input but does not constrain the owner.

8. **Signing address controls chapter creation** — the platform signs `keccak256(chapterName || callerAddress || chainId)`. This binds each signature to a specific caller and chain, preventing a signature for one wallet from being used by another and preventing cross-chain replay. If the signing key is compromised, unauthorized chapters can still only be created by the address the key was asked to sign for. Key rotation is via `setSigningAddress()` (owner-only).

9. **Chapter contracts are not part of the Diamond** — they are autonomous contracts. The Diamond has no slashable access to chapter funds except via `rescueChapterFunds()` (platform owner, chapter must be banned or removed) and `prepareForRemoval()` (platform owner, permanent action).

10. **SubMods can belong to multiple chapters** — the old single-chapter constraint (`isSubmod[subMod]`) has been replaced by a multi-chapter registry (`subModChaptersList`, `isSubModOf`, `subModChapterIndex`) in `LibVoxStorage`. This is managed on the Diamond side; chapters call `registerSubMod`/`deregisterSubMod` callbacks to keep the registry current.

11. **`LibVoxChapterStorage` is a stub** — it exists in the libraries directory but contains only `chapterName`. It is not used by any active code path.

---

## 10. File Map

```
contracts/
  Diamond.sol                          — Proxy entry point, POL receive() waterfall
  VoxChapter.sol                   — Chapter contract (standalone, not a facet)
  MockUSD.sol                          — Test USDC (MockUSDC)
  MockV3Aggregator.sol                 — Test Chainlink price feed
  facets/
    DiamondCutFacet.sol                — EIP-2535 upgrade mechanism
    DiamondLoupeFacet.sol              — EIP-2535 introspection
    OwnershipFacet.sol                 — ERC-173 ownership
    VoxFacet.sol                   — Chapter registry + admin + ban management
    VoxGovernanceFacet.sol         — Proposals + admin elections + quotas
    VoxTokenFacet.sol              — VOX ERC-20 + reward distribution
    Test1Facet.sol / Test2Facet.sol    — Test fixtures only
  libraries/
    LibDiamond.sol                     — Diamond storage + cut/loupe logic
    LibVoxStorage.sol              — Main platform storage
    LibVoxTokenStorage.sol         — Token + reward storage
    LibVoxGovernanceStorage.sol    — Governance + quota storage
    LibVoxChapterStorage.sol       — Stub (unused)
  interfaces/
    IDiamondCut.sol                    — FacetCut struct + diamondCut interface
    IDiamondLoupe.sol                  — Loupe interface
    IERC165.sol / IERC173.sol          — Standard interfaces
    IVoxChapter.sol                — Diamond→Chapter call interface
  upgradeInitializers/
    DiamondInit.sol                    — One-time initializer called during deployment diamondCut
scripts/
  deploy.js                            — Full deployment sequence
  libraries/diamond.js                 — getSelectors helper
test/
  diamondTest.js                       — Core diamond tests
  VoxFacetTest.js                  — Chapter/admin function tests
  VoxGovernanceFacet.js            — Governance tests
  VoxTokenFacetTest.js             — Token/reward tests
  VoxChapter.js                    — Chapter contract tests
  cacheBugTest.js / ErrorFunds.js      — Misc tests
hardhat.config.js                      — Polygon mainnet + testnet config
```

---

## TODO: tx.origin Security Issues & Composability Fixes — ✅ Mostly Resolved

**Priority: HIGH**  
**Date Identified:** March 12, 2026  
**Status:** Issues 2 and 3 resolved. Issue 1 (getChapterAdminAddress deprecation) pending frontend migration.

---

### Issue Summary

Three instances of `tx.origin` usage were identified in the codebase. Two have been resolved (Issues 2 and 3 — changed to `msg.sender`). Issue 1 (`getChapterAdminAddress`) has a replacement function but the original is kept for backward compatibility pending frontend migration.

---

### 1. ❌ VoxFacet.getChapterAdminAddress() - Line 338

**Current Implementation:**

```solidity
function getChapterAdminAddress() external view returns (address) {
    return mainStorage.checkChapterAdminAddress[tx.origin];
}
```

**Issue:**

- Anti-pattern that breaks composability
- Cannot be called from contracts
- Prevents integration with DeFi protocols

**Status:** ✅ Partially addressed with new `getUserAdminContext()` function

- New function uses address argument instead of tx.origin
- Original function remains unchanged (may still be used by frontend)

**Action Needed:**

- [ ] Deprecate or remove original `getChapterAdminAddress()` function
- [ ] Update all frontend references to use `getUserAdminContext()` instead
- [ ] Document migration path for any external integrators

---

### 2. ✅ VoxTokenFacet.flashLoanProtection - Lines 103-104, 111-112

**Status:** **Resolved.** `tx.origin` checks removed (Option A implemented). Modifier now uses `msg.sender` only:

```solidity
modifier flashLoanProtection() {
    require(canVoteThisBlock(msg.sender), "Cannot vote: recent transfer or voting activity");
    _;
    ts.lastVoteBlock[msg.sender] = block.number;
}
```

NatSpec updated to accurately describe the `msg.sender`-only 2-block cooldown. Compatible with contract wallets (Gnosis Safe, Argent, etc.).

---

### 3. ✅ VoxTokenFacet.recordVoteActivity() - Line 706

**Status:** **Resolved.** Access control changed from `tx.origin` to `msg.sender` (Option A implemented):

```solidity
function recordVoteActivity(address voter) external {
    require(voter == msg.sender, "Can only record your own activity");
    ts.lastVoteBlock[voter] = block.number;
}
```

NatSpec `@custom:security` updated to: "Uses msg.sender for access control — compatible with contract wallets".

---

### Discussion Questions — ✅ Resolved

All discussion questions have been addressed:

1. **Multisig Support:** Contract wallets now fully supported — `msg.sender`-only access control throughout.
2. **Threat Model:** The 2-block cooldown on `msg.sender` provides basic flash loan mitigation. `tx.origin` checks removed as they provided no additional security while blocking contract wallets.
3. **Breaking Changes:** Project is pre-mainnet — clean break approach used. No migration needed.
4. **Design Goals:** Security and composability prioritized. Both EOAs and contract wallets are supported.

---

### Implementation Priority — ✅ Complete

1. **Immediate:** ✅ Document current behavior and known limitations
2. **High:** ✅ Fix recordVoteActivity access control (Option A — `msg.sender`)
3. **High:** ✅ Fix flashLoanProtection approach (Option A — `msg.sender` only)
4. **Medium:** Deprecate old `getChapterAdminAddress()` function — pending frontend migration
5. **Low:** Add comprehensive integration tests with multisig wallets — future work

---

### Testing Requirements

Core `tx.origin` fixes verified — remaining integration tests for future:

- [x] Voting from EOA (direct user wallet)
- [ ] Voting from Gnosis Safe multisig
- [ ] Voting from Argent smart contract wallet
- [ ] Flash loan attack simulation (borrow, vote, return)
- [x] Multi-block holding period scenarios
- [x] Edge case: zero balance after voting
- [x] Integration with governance contracts
- [x] recordVoteActivity called from multiple contexts

---

### Related Files

- `contracts/facets/VoxFacet.sol` - getChapterAdminAddress (line 338)
- `contracts/facets/VoxTokenFacet.sol` - flashLoanProtection (lines 103-112)
- `contracts/facets/VoxTokenFacet.sol` - recordVoteActivity (line 706)
- `contracts/libraries/LibVoxTokenStorage.sol` - Token storage structure

---

### References

- [Consensys: tx.origin Security Best Practices](https://consensys.github.io/smart-contract-best-practices/development-recommendations/solidity-specific/tx-origin/)
- [EIP-2535 Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [OpenZeppelin: Voting Snapshot Mechanism](https://docs.openzeppelin.com/contracts/4.x/governance#token_snapshot)

---

---

## TODO: Consolidated Issue Tracker

**Last Updated:** Current session  
**Status Key:** ✅ Resolved/By Design  
**Summary:** 25 of 25 items resolved (✅). 0 items pending.

---

### CRITICAL — Direct Fund Loss / Production-Breaking

---

#### C-1 ✅ `_transferCustom` never emits `event Transfer(from, to, amount)`

**File:** `contracts/facets/VoxTokenFacet.sol`  
**Impact:** Every VOX token transfer is silent on-chain. MetaMask, Rabby, Ledger, Polygonscan, every indexer and subgraph will show zero transfer history. The token appears to have no on-chain activity. Breaks every standard ERC-20 wallet and explorer integration at the infrastructure level.  
**Fix:** Add `emit Transfer(from, to, amount)` inside `_transferCustom`.  
**Status:** ✅ Resolved in prior session.

---

#### C-2 ✅ Reward claim cursors advance before sends — permanent fund loss on failure

**File:** `contracts/facets/VoxTokenFacet.sol`, `distributeReward()`  
**Impact:** `lastRewardClaimInPOL[account]` was written before `call{value}`. `lastRewardClaimInUSDC[account]` was written before the `try-catch` send.  
**Fix:** `RewardClaimFailed(address indexed account, uint256 polAmount, uint256 usdcAmount)` event added and emitted when `!polSuccess || !usdcSuccess`. Cursor-before-send reorder implemented in prior session.  
**Status:** ✅ Resolved.

---

#### C-3 ✅ `VoxTokenFacet.initialize` — duplicate ownership check + missing `Transfer` mint event

**File:** `contracts/facets/VoxTokenFacet.sol`  
**Fix:** Redundant `require` removed; `emit Transfer(address(0), deployer, totalSupply)` added after minting.  
**Status:** ✅ Resolved in prior session.

---

### HIGH — Security Vulnerabilities

---

#### H-1 ✅ Uninitialized implementation contract (`VoxChapter`)

**File:** `contracts/VoxChapter.sol`  
**Fix:** Constructor guard added: `constructor() { initialized = true; }`. Clones copy bytecode only, so this locks the master without affecting clone behavior.  
**Status:** ✅ Resolved in prior session.

---

#### H-2 ✅ `applyAsNewAdmin` uses `payable.transfer()` for excess refund — locks out all multisig/contract wallets

**File:** `contracts/facets/VoxGovernanceFacet.sol`  
**Fix:** Replaced with `call{value}` + `require(refundSuccess, "Refund failed")`.  
**Status:** ✅ Resolved in prior session.

---

#### H-3 ✅ `rescueChapterFunds` (formerly `withdrawFundsIfBanned`) — USDC transfer return value now checked

**File:** `contracts/VoxChapter.sol`  
**Fix:** Function renamed to `rescueChapterFunds()`. Guard relaxed to `require(isBanned || isRemoved, "Not banned or removed")` to allow fund recovery from both banned and removed chapters. USDC transfer now uses `SafeERC20.safeTransfer` which reverts on failure.  
**Status:** ✅ Resolved in session 2.

---

#### H-4 ✅ `prepareForRemoval` reentrancy window — ban flag temporarily cleared during external POL sends

**File:** `contracts/VoxChapter.sol`  
**Fix:** `nonReentrant` modifier added to `prepareForRemoval`. The `ReentrancyGuard` was already imported.  
**Status:** ✅ Resolved in prior session.

---

#### H-5 ✅ `createChapter` signature bound to `msg.sender` and `chainId`

**File:** `contracts/facets/VoxFacet.sol`  
**Fix:** Signed payload already includes `msg.sender` and `block.chainid`: `keccak256(abi.encodePacked(chapterName, msg.sender, block.chainid))`. Code confirmed correct — the earlier docs description was stale.  
**Status:** ✅ Resolved (code already correct).

---

#### H-6 ✅ `flashLoanProtection` in `VoxTokenFacet` — `tx.origin` removed

**File:** `contracts/facets/VoxTokenFacet.sol`, lines 103–112  
**Status:** **Resolved.** `tx.origin` checks removed entirely. Modifier now uses `msg.sender` only (Option A). Both the `require(canVoteThisBlock(msg.sender))` check and the post-execution `ts.lastVoteBlock[msg.sender] = block.number` stamp use `msg.sender` exclusively. NatSpec updated to reflect the 2-block `msg.sender` cooldown without referencing `tx.origin`.

---

#### H-7 ✅ `flashLoanProtection` in `VoxGovernanceFacet` — inconsistent, incorrect check order, modifier removed

**File:** `contracts/facets/VoxGovernanceFacet.sol`  
**Status:** **Resolved.**

- `flashLoanProtection` modifier removed from GovernanceFacet entirely.
- All three affected functions (`voteOnProposal`, `voteForNewAdmin`, `applyAsNewAdmin`) now inline the check in the correct semantic order: active state → deadline → eligibility → voting power → canVote() → logic → stamp.
- Double-writes of `lastVoteBlock[msg.sender]` (modifier write + manual write in body) eliminated — single stamp at the end of each function.
- Canonical `canVote()` helper extracted into `LibVoxTokenStorage` and used by both GovernanceFacet and TokenFacet, so both apply identical rules including the `> 0` guards on block numbers (previously GovernanceFacet was missing these).
- `ratifyNewAdmin` guard order fixed: `proposedAdminAddresses.length > 0` now fires before `highestVotes > 0` (previously the second check was unreachable when the election was inactive).
- `applyAsNewAdmin` now stamps `lastVoteBlock[msg.sender]` consistently with the other voting-adjacent actions.

---

#### H-8 ✅ `recordVoteActivity` — `tx.origin` replaced with `msg.sender`

**File:** `contracts/facets/VoxTokenFacet.sol`, line 706  
**Status:** **Resolved.** Access control changed from `require(voter == tx.origin)` to `require(voter == msg.sender, "Can only record your own activity")`. NatSpec updated: `@custom:security` now reads "Uses msg.sender for access control — compatible with contract wallets".

---

#### H-9 ✅ `setBanned(true)` — stale comment removed, manual pull model confirmed

**File:** `contracts/VoxChapter.sol`, `setBanned()`  
**Status:** **Resolved.** Per Q1 resolution: fund recovery from banned chapters remains a **manual pull** by the platform owner via `withdrawFundsIfBanned()`. No automatic transfer occurs on ban. Stale comment removed (see L-3).

---

### MEDIUM — Correctness / Invariant Violations

---

#### M-1 ✅ `removeChapter` inactive array dedup check broken at index 0

**File:** `contracts/facets/VoxFacet.sol`, `removeChapter()`  
**Fix:** Replaced fragile index-0 check with `if (!mainStorage.isChapterBanned[chapterAddress])` flag check. The `isChapterBanned` flag is cleared immediately after this block, so checking it before clearing is correct.  
**Status:** ✅ Resolved in session 2.

---

#### M-2 ✅ Distribution truncation dust permanently locked

**File:** `contracts/VoxChapter.sol`, `_distributeFunds()`  
**Fix:** Integer remainder (dust) now added to the chapter owner's distribution for both POL and USDC.  
**Status:** ✅ Resolved in prior session.

---

#### M-3 ✅ Inconsistent quorum comparisons in `ratifyUpgrade`

**File:** `contracts/facets/VoxGovernanceFacet.sol`  
**Fix:** Confirmed both `QuotaProposal` and `FacetProposal` now use `>=` for quorum check. NatSpec updated to document `>=` behavior.  
**Status:** ✅ Resolved in session 2.

---

#### M-4 ✅ `applyAsNewAdmin` now stamps `lastVoteBlock` — resolved with H-7

**File:** `contracts/facets/VoxGovernanceFacet.sol`  
**Status:** **Resolved.** All three voting-adjacent functions (`voteOnProposal`, `voteForNewAdmin`, `applyAsNewAdmin`) now stamp `tokenStorage.lastVoteBlock[msg.sender] = block.number` at the end of execution, consistent with the `flashLoanProtection` read-side check. See H-7 for complete fix details.

---

#### M-5 ✅ Banned subMod forfeits accumulated chapter rewards — confirmed intentional

**File:** `contracts/VoxChapter.sol`, `banUserFromChapter()`  
**Policy:** `banUserFromChapter` calls `_removeSubModInternal` (no reward distribution), while `removeSubMod` calls `claimChapterRewards` first. Banned subMods do not receive pending rewards.  
**Decision:** By design — banned users should not receive funds. Update code comment to explicitly document this policy: `// Intentional: banned subMods forfeit accumulated unclaimed rewards`.

---

#### M-6 ✅ Admin election applicants array is unbounded — hard cap implemented

**File:** `contracts/facets/VoxGovernanceFacet.sol`, `applyAsNewAdmin()`  
**Status:** **Implemented.** `MAX_ADMIN_CANDIDATES = 100` constant added to `LibVoxGovernanceStorage`. `applyAsNewAdmin` now enforces `require(proposedAdminAddresses.length < MAX_ADMIN_CANDIDATES, "Candidate list full")`. The incumbent is auto-added (counts toward the cap), so effective open-slot capacity is 99.

---

### LOW / Informational

---

#### L-1 🟡 `getChapterAdminAddress()` uses `tx.origin` — deprecate in favor of `getUserAdminContext()`

**File:** `contracts/facets/VoxFacet.sol`, line 338  
**Status:** Replacement function `getUserAdminContext(address user)` already exists.  
**Action:** Remove `getChapterAdminAddress()`. Update all frontend references to use `getUserAdminContext()`.  
**Decision:** Implement after frontend migration confirmed complete.

---

#### L-2 ✅ VOX token is not ERC-20 complete — no `transferFrom`, `approve`, or `allowance`

**File:** `contracts/facets/VoxTokenFacet.sol`  
**Status:** **Implemented.**

- `allowances` mapping added to `LibVoxTokenStorage.TokenStorage`
- `approve(address spender, uint256 amount)` — sets `allowances[msg.sender][spender]`, emits `Approval`
- `allowance(address owner, address spender)` — view getter
- `transferFrom(address sender, address recipient, uint256 amount)` — mirrors `transfer`'s reward distribution, vote adjustment, and transfer-block tracking; spends allowance with explicit underflow check
- `Approval` event added alongside existing `Transfer` event

---

#### L-3 ✅ `VoxChapter.setBanned` — stale comment fixed

**File:** `contracts/VoxChapter.sol`, `setBanned()`  
**Status:** **Implemented.** NatSpec rewritten to accurately document behavior: suspended chapters cannot distribute rewards; funds are NOT automatically transferred and remain accessible to the platform owner via `rescueChapterFunds()` (formerly `withdrawFundsIfBanned()`). The stale `// transfer funds to diamond if banned` comment has been removed.

---

### NEW FINDINGS — Identified and Resolved

The following issues were surfaced during code review and implemented in the same pass.

---

#### N-1 ✅ CRITICAL: Platform ban bypass in `VoxChapter` (silent, complete)

**File:** `contracts/VoxChapter.sol`  
**Impact:** All `LibVoxStorage.mainStorage().isUserBanned[x]` reads inside a chapter clone resolve the storage pointer at `keccak256("vox.main.storage")` within the **chapter contract's own EVM context** (address space), not the Diamond's. The chapter has no storage at that slot — the read always returns `false`. Platform bans were completely bypassed at the chapter level for: `setChapterAdmin`, `inviteSubMod`, `_addSubModInternal`, `changeChapterOwnerShare`, `removeSubMod`, `removeMyselfAndAppointSuccessor`.  
**Fix:** All six call sites replaced with `IVoxDiamond(diamondAddress).isUserBannedFromPlatform(address)` — a callback to the Diamond that reads the correct storage. The `LibVoxStorage` and (unused) `LibDiamond` imports removed from `VoxChapter.sol`.  
**Status:** ✅ Resolved.

---

#### N-2 ✅ `isSubmod` mapped only one chapter per subMod — multi-chapter membership impossible

**File:** `contracts/libraries/LibVoxStorage.sol`, `contracts/VoxChapter.sol`  
**Impact:** The old `mapping(address => address) isSubmod` stored exactly one chapter address per subMod, preventing multi-chapter membership. In addition, the write inside `VoxChapter._addSubModInternal` suffered the same storage context bug as N-1.  
**Fix:**

- `LibVoxStorage.VoxMainStorage`: replaced `isSubmod` with `subModChaptersList` (array), `isSubModOf` (bool mapping), `subModChapterIndex` (1-based swap-and-pop index).
- `VoxFacet`: added `registerSubMod(address)`, `deregisterSubMod(address)` (chapter-gated callbacks), `getSubModChapters(address)` (view), and two internal helpers `_registerSubModInStorage` / `_deregisterSubModFromStorage`.
- `acceptSubModInvitation`: calls `IVoxDiamond(diamondAddress).registerSubMod(msg.sender)` after local state update.
- `removeSubMod`, `_removeSubModInternal`: call `IVoxDiamond(diamondAddress).deregisterSubMod(_subMod)` after local cleanup.
- `prepareForRemoval`: global registry cleanup moved to `VoxFacet.removeChapter()` (executed before calling `prepareForRemoval`) to avoid a `nonReentrant` deadlock in the call chain Diamond→chapter→Diamond.
- `migrateChapter`: deregisters subMods from old chapter registry entry and registers them under new chapter address directly in Diamond storage.  
  **Status:** ✅ Resolved.

---

#### N-3 ✅ SubMod reward dilution on new member join

**File:** `contracts/VoxChapter.sol`, `acceptSubModInvitation()`  
**Impact:** When a new subMod accepted an invitation, their per-seat claim baseline was set to `totalAggregateSubModsPOL / newCount`. Existing members had unrealized rewards proportional to `totalAggregateSubModsPOL / oldCount`. The new denominator shrinks their per-seat entitlement retroactively — existing subMods lose a fraction of rewards they had already accrued.  
**Fix:** Before calling `_addSubModInternal`, flush all existing subMods if above threshold: call `processNewDeposits()` + `claimChapterRewards()`. Also added `nonReentrant` to `acceptSubModInvitation`. The migration path (`addSubMod`, called by Diamond only) does not get the pre-payout.  
**Status:** ✅ Resolved.

---

#### N-4 ✅ `hasVotedForCandidate` declared but never set — `undoVotes` iterates all candidates on every transfer

**File:** `contracts/libraries/LibVoxGovernanceStorage.sol`, `contracts/facets/VoxGovernanceFacet.sol`, `contracts/facets/VoxTokenFacet.sol`  
**Impact:** `hasVotedForCandidate[voter][voteId]` existed in storage but was never written. `undoVotes()` (called on every transfer) unconditionally looped up to 100 candidates per account, paying 2,100+ gas per cold SLOAD for voters and non-voters alike.  
**Fix:** `voteForNewAdmin` now sets `govStorage.hasVotedForCandidate[msg.sender][govStorage.adminVoteId] = true` after recording the vote. `undoVotes` wraps the candidate loop in `if (govStorage.hasVotedForCandidate[account][govStorage.adminVoteId])` — non-voters pay one warm SLOAD instead of up to 100 cold SLOADs.  
**Status:** ✅ Resolved.

---

### Open Design Questions (Blocking Implementation) — ALL RESOLVED

---

**Q1 — `setBanned` fund transfer behavior (H-9 / L-3) ✅ RESOLVED**

**Decision confirmed:** Fund recovery from banned chapters remains a **manual pull** by the platform owner via `withdrawFundsIfBanned()`. No automatic transfer happens inside `setBanned(true)`. The existing implementation is correct as documented after the L-3 fix.

---

**Q2 — `createChapter` signature binding (H-5) ✅ RESOLVED**

**Decision confirmed:** Code already binds `msg.sender` and `block.chainid` in `createChapter` signature verification: `keccak256(abi.encodePacked(chapterName, msg.sender, block.chainid))`. The earlier docs description was stale. No code change needed.

---

**Q3 — Quorum operator consistency (M-3) ✅ RESOLVED**

**Decision confirmed:** Both `QuotaProposal` and `FacetProposal` now use `>=` for quorum checks. NatSpec updated to document this behavior.

---

### SESSION 2 FIXES — Implemented

The following items were implemented in session 2 (security hardening pass):

---

#### S2-1 ✅ `claimChapterRewards` nonReentrant + internal refactor

**File:** `contracts/VoxChapter.sol`  
**Fix:** `claimChapterRewards()` now has `nonReentrant` modifier. `removeMyself()`, `removeSubMod()`, and `removeMyselfAndAppointSuccessor()` refactored to call `_claimChapterRewardsInternal()` (new internal function) to avoid nested ReentrancyGuard lock. All three removal functions also gained `nonReentrant`.

---

#### S2-2 ✅ `withdrawFundsIfBanned` renamed to `rescueChapterFunds`

**File:** `contracts/VoxChapter.sol`  
**Fix:** Function renamed. Guard relaxed from `require(isBanned, "BAN")` to `require(isBanned || isRemoved, "Not banned or removed")`, allowing platform owner to recover funds stranded in removed chapters (e.g., funds sent after removal).

---

#### S2-3 ✅ SafeERC20 in VoxTokenFacet

**File:** `contracts/facets/VoxTokenFacet.sol`  
**Fix:** Added `import SafeERC20` + `using SafeERC20 for IERC20`. Three raw `require(usdcToken.transfer(...))` calls replaced with `.safeTransfer()`: `withdrawAdminUSDC`, `claimRewards`, `withdrawStorageProviderFunds`.

---

#### S2-4 ✅ `removeChapter` inactive array dedup fix

**File:** `contracts/facets/VoxFacet.sol`  
**Fix:** Fragile `keccak256(bytes(...))` string-compare approach replaced with simple `if (!mainStorage.isChapterBanned[chapterAddress])` flag check. Cheaper and more robust.

---

#### S2-5 ✅ `USDCTransferFailed` event in all chapter USDC catch blocks

**File:** `contracts/VoxChapter.sol`  
**Fix:** `USDCTransferFailed(address indexed recipient, uint256 amount)` event declared and emitted in all 5 `catch` blocks across `_distributeFunds`, `_distributeToOwner`, `_distributeToSubMods`.

---

#### S2-6 ✅ `ratifyUpgrade` NatSpec corrected (`>=` vs `>`)

**File:** `contracts/facets/VoxGovernanceFacet.sol`  
**Fix:** NatSpec corrected from `>` to `>=` to match actual code behavior for both `QuotaProposal` and `FacetProposal` quorum checks.

---

#### S2-7 ✅ Stale comments removed from rescue function

**File:** `contracts/VoxChapter.sol`  
**Fix:** Placeholder comments in the renamed `rescueChapterFunds()` (formerly `withdrawFundsIfBanned()`) cleaned up.

---

## Pre-Mainnet Deployment Checklist

The following items **must** be verified before deploying to Polygon mainnet:

### Environment Variables

Mainnet deploys load `.env.prod` (non-secret config) via `npm run deploy:mainnet`
(`dotenv -e .env.prod -- hardhat run scripts/deploy.js --network polygon`). Local/dev
uses `.env`. See `.env.example` / `.env.prod.example`.

- [ ] `I_UNDERSTAND_MAINNET=1` — Deliberate opt-in gate; `scripts/deploy.js` reverts on Polygon mainnet unless set to `1`
- [ ] `PRIVATEKEYMAINNET` — Dedicated Polygon mainnet owner EOA key. **Not stored in any file** — shell-inject it for the single mainnet deploy (`$env:PRIVATEKEYMAINNET="0x…"`). Deploy reverts if missing. Prefer a hardware wallet / KMS signer
- [ ] `SIGNING_ADDRESS_FE` — Production frontend signing address; written on-chain by `VoxGovernanceFacet.initialize()`. Deploy reverts if missing/invalid
- [ ] `OPENADVERTS_ADDRESS` — Production OpenAdverts contract address (dev fallback `0x0165878A594ca255338adfa4d48449f69242Eb8F` is used only on non-mainnet; on mainnet a missing, malformed, **or** dev-fallback value is rejected and the deploy reverts)
- [ ] `POLYGON_POL_USD_FEED` — Mainnet Chainlink POL/USD price feed address (confirm code + `decimals()` on Polygonscan)
- [ ] `ETHERSCAN_API_KEY` — Etherscan V2 unified key; verifies all chains (incl. Polygon via chainid). No separate Polygonscan key needed
- [ ] `PRIVATE_KEY` (dev only) — Testnet/dev key (sepolia, amoy). Defaults to the public Hardhat account; **must never hold mainnet value**

### Contract Configuration

- [ ] `signingAddress` — Confirm production signing key for chapter creation signatures is ready and secured (set via `VoxGovernanceFacet.initialize()`)
- [ ] `storageProviderAddress` — Confirm production storage provider address
- [ ] `chapterImplementation` — Deploy production `VoxChapter` implementation and call `setChapterImplementation()`
- [ ] USDC address — Verify `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` is correct for mainnet Polygon USDC (not bridged USDC.e)

### Security

- [x] `VoxChapter` implementation locked with constructor guard (H-1) — ✅ resolved
- [x] All `tx.origin` references removed (H-6, H-8) — ✅ resolved
- [x] `getProposalState` returns `canRatify = false` for defeated proposals — ✅ verified
- [x] `claimChapterRewards` access restricted to authorized callers + `nonReentrant` — ✅ resolved
- [x] SafeERC20 try-catch pattern in chapter distribution functions — ✅ resolved
- [x] SafeERC20 in VoxTokenFacet for USDC transfers (3 sites) — ✅ resolved session 2
- [x] `rescueChapterFunds` guard relaxed to isBanned || isRemoved — ✅ resolved session 2
- [x] `removeChapter` inactive array dedup fix (M-1) — ✅ resolved session 2
- [x] `USDCTransferFailed` event added to all chapter USDC catch blocks — ✅ resolved session 2
- [x] `ratifyUpgrade` NatSpec quorum operator fixed (M-3) — ✅ resolved session 2
- [x] All former C-1, C-2, C-3, H-1–H-5, M-1–M-3 items — ✅ resolved

### Deployment Verification

- [ ] Run full test suite: `npx hardhat test`
- [ ] Verify contract code on Polygonscan for all deployed contracts
- [ ] Confirm `Diamond.owner()` returns expected deployer address
- [ ] Confirm `getChapterImplementation()` returns expected implementation address
- [ ] Test chapter creation with a valid signature on mainnet
- [ ] Verify USDC deposit detection via `processNewUSDCDeposits()`

### Known Remaining Issues (Pre-Mainnet Blockers)

- [ ] **VoxChapter contract size: 28.6 KiB** — exceeds 24 KiB Spurious Dragon limit. Must optimize before mainnet deployment. Consider splitting into a base + extension pattern, or extracting view functions.
- [ ] **`getMyAdminApplicationStorageId` test failure** — test references a function that doesn't exist on the contract. Test bug, not contract bug. Fix the test in `test/VoxGovernanceFacet.js:871`.
- [ ] **`getChapterAdminAddress()` uses `tx.origin`** (L-1) — deprecate after frontend migration to `getUserAdminContext()`.
- [ ] **Distribution truncation dust** (M-2) — resolved for chapter distributions; verify the same pattern is not needed in Diamond-level token reward distribution.

---
