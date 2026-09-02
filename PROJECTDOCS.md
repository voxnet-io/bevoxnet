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

| Facet                 | Responsibility                                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `DiamondCutFacet`     | Add/replace/remove function selectors on the Diamond (owner, bootstrap-gated)                                                        |
| `DiamondLoupeFacet`   | Introspection: enumerate facets and selectors (EIP-2535 required)                                                                    |
| `OwnershipFacet`      | ERC-173 ownership — `owner()`, `transferOwnership()`, `isOwner()`; bootstrap latch — `finalizeBootstrap()`, `isBootstrapFinalized()` |
| `VoxFacet`            | Chapter registry, chapter creation, admin management, platform ban management                                                        |
| `VoxGovernanceFacet`  | Proposal-based governance, admin elections (apply/vote/ratify), signing/storage config, VoxAssistant role                            |
| `VoxTokenFacet`       | ERC-20 VOX token, POL/USDC reward distribution, flash loan protection                                                                |
| `ChapterLensFacet`    | Read-only view aggregators for chapter data                                                                                          |
| `GovernanceLensFacet` | Read-only view aggregators for governance, proposal, and admin-election state                                                        |
| `TokenLensFacet`      | Read-only view aggregators for token balances and reward data                                                                        |
| `VoxAssistantFacet`   | Delegated moderation role (invite / accept / remove VoxAssistants)                                                                   |

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

| Library                   | Storage Key                                     | Contents                                                                                                                                                                                                             |
| ------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LibDiamond`              | `keccak256("diamond.standard.diamond.storage")` | Selector→facet mapping, facet address array, supported interfaces, `contractOwner`                                                                                                                                   |
| `LibVoxStorage`           | `keccak256("vox.main.storage")`                 | Chapter registry, admin↔chapter bidirectional mappings, platform ban state                                                                                                                                           |
| `LibVoxTokenStorage`      | `keccak256("vox.token.storage")`                | VOX token balances, reward aggregates, USDC/oracle addresses, vote/transfer cooldown blocks, storage provider balances, turbo topup audit trail, pull-model unclaimed balances, `directCutFinalized` bootstrap latch |
| `LibVoxGovernanceStorage` | `keccak256("vox.governance.storage")`           | Quota config, active proposal state, admin election state, signing address, VoxAssistant registry                                                                                                                    |
| `LibVoxChapterStorage`    | `keccak256("vox.chapter.storage")`              | Stub (currently only `chapterName`), reserved for future use                                                                                                                                                         |

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
- `storageProviderPOLBalance` / `storageProviderUSDCBalance` — storage provider's accumulated cut (held in the Diamond; paid out to `storageProviderAddress` via `withdrawStorageProviderFunds()`)
- `unclaimedPOL[user]` / `unclaimedUSDC[user]` — pull-model reward balances accrued but not yet withdrawn
- `turboTopupTransactionIds` / `turboTopupRecords` — audit trail for off-chain Turbo topup executions reported by the owner via `confirmTurboTopup()`
- `directCutFinalized` — one-way bootstrap latch; once tripped by `OwnershipFacet.finalizeBootstrap()`, the direct owner `diamondCut` path is permanently disabled

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
voxAssistants[] / isVoxAssistant — active delegated-moderation roster and lookup
voxAssistantInvitations[] / ...  — pending VoxAssistant invitations (opt-in, mirrors SubMod invites)
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
6. The owner write is routed through `LibDiamond.setContractOwner()`, which emits the standard ERC-173 `OwnershipTransferred(previousOwner, newOwner)` event (for off-chain watchers) in addition to the app-specific `NewAdminRatified`. `LibVoxStorage` admin flags are updated: the outgoing owner loses `isAdmin` **only if** they are not also a chapter admin (`checkChapterAdminAddress == 0`), preserving chapter-scoped rights.
7. `adminVoteId` incremented, candidate list cleared

> **No-quorum auto-reset (no deadlock):** if the deadline passes with **no** candidate meeting `voxAdminChangeQuorum`, `ratifyNewAdmin()` does **not** revert — it retires the round via the internal `_resetElectionRound()`: clears `proposedAdminAddresses`, resets `adminVoteDeadline` to 0, and **increments** `adminVoteId` (mandatory — every per-round mapping is keyed by it, so reusing the id would carry stale vote totals into the next round), emitting `GovernanceRoundCancelled(round)`. This mirrors `ratifyUpgrade()`'s never-revert resolution for proposals and is fully permissionless, so a round can never stall and the incumbent cannot freeze the seat by inaction. When a candidate _does_ meet quorum the same call elects them instead (see step 6).

### 4.7 Ban Flows

**Platform user ban:** `VoxGovernanceFacet.banUserFromPlatform()` (owner-only) sets `mainStorage.isUserBanned[user]`. Reverted via `unbanUserFromPlatform()`. Checked at chapter creation and subMod invitation. Chapter contracts call back to `isUserBannedFromPlatform()` on the Diamond for all ban checks — they do **not** read Diamond storage directly (the old approach was silently broken because `LibVoxStorage.mainStorage()` inside a chapter clone resolves to the _chapter's own_ keccak slot, not the Diamond's).

**Chapter user ban:** `VoxChapter.banUserFromChapter()` (chapter owner or platform owner). Stored in `chapterBannedUsers[user]` (mapping) with a parallel `bannedUsersArray` (address[]) + `bannedUsersArrayIndex` (1-based mapping) kept in sync. The array enables full enumeration during chapter migration. Swap-and-pop is used on unban to keep the array compact.

**Platform chapter ban:** `VoxFacet.banChapter()` (owner-only). Sets `mainStorage.isChapterBanned[chapter]`, adds to `inactiveChapterArray`, calls `IVoxChapter.setBanned(true)`.

**Chapter removal:** `VoxFacet.removeChapter()` (owner-only). Calls `IVoxChapter.prepareForRemoval()` which distributes all funds, frees subMods, and sets the `isRemoved` flag permanently.

---

## 5. Access Control Matrix

| Action                                                                                    | Who Can Call                                                                      |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `diamondCut` (upgrade)                                                                    | Diamond owner only (via `DiamondCutFacet`), **bootstrap phase only** (see §8)     |
| `finalizeBootstrap` / `isBootstrapFinalized`                                              | Owner only (finalize) / anyone (view) — via `OwnershipFacet`                      |
| `transferOwnership(address)`                                                              | Disabled — always reverts (`Use transferOwnership(address,address)`)              |
| `transferOwnership(address,address)`                                                      | Diamond owner (rejects `address(0)`; atomically rotates the requestKey — see §8a) |
| `setRequestKey` / `returnRequestKey`                                                      | Owner only (rotate) / anyone (view, via `GovernanceLensFacet`) — see §8a          |
| `createChapter`                                                                           | Any non-banned address with valid platform signature                              |
| `setChapterAdmin`                                                                         | Platform owner only                                                               |
| `revokeChapterAdmin`                                                                      | Platform owner only                                                               |
| `updateChapterAdmin`                                                                      | Registered chapter contracts only (callback)                                      |
| `banChapter` / `unbanChapter`                                                             | Platform owner **or VoxAssistant**                                                |
| `removeChapter`                                                                           | Platform owner only (banned users cannot self-remove even if owner)               |
| `banUserFromPlatform` / `unbanUserFromPlatform`                                           | Platform owner **or VoxAssistant** (via GovernanceFacet)                          |
| `inviteVoxAssistant` / `revokeVoxAssistantInvitation` / `removeVoxAssistant`              | Platform owner only (via GovernanceFacet)                                         |
| `acceptVoxAssistantInvitation` / `declineVoxAssistantInvitation` / `resignAsVoxAssistant` | Invited address / active VoxAssistant (self-service)                              |
| `banUserFromChapter`                                                                      | Chapter owner or platform owner                                                   |
| `addSubMod` / `inviteSubMod`                                                              | Chapter owner or platform owner                                                   |
| `createProposal`                                                                          | Platform owner only                                                               |
| `revokeProposal`                                                                          | Platform owner only, **before the voting deadline only**                          |
| `ratifyUpgrade`                                                                           | Anyone (after the voting deadline — permissionless resolver)                      |
| `voteOnProposal`                                                                          | Any VOX token holder (flash loan protected)                                       |
| `applyAsNewAdmin`                                                                         | Any non-incumbent non-banned address (fee required)                               |
| `voteForNewAdmin`                                                                         | Any VOX token holder (flash loan protected)                                       |
| `ratifyNewAdmin`                                                                          | Anyone (after deadline — elects a winner or auto-retires a no-quorum round)       |
| `initialize` (token/governance)                                                           | Platform owner, one-time only                                                     |
| `setChapterImplementation`                                                                | Platform owner                                                                    |
| `getChapterImplementation`                                                                | Anyone (public view)                                                              |
| `migrateChapter` / `batchMigrateChapters`                                                 | Platform owner (migrateChapter is nonReentrant)                                   |
| `withdrawAdminPOL`                                                                        | Platform owner only (via VoxTokenFacet)                                           |
| `getAdminAvailablePOL`                                                                    | Anyone (public view)                                                              |
| `approve` / `allowance` / `transferFrom`                                                  | ERC-20 standard — any token holder                                                |
| `withdrawAdminUSDC` / `getAdminAvailableUSDC`                                             | Platform owner / anyone (view — pure read, no state mutation)                     |
| `withdrawStorageProviderFunds`                                                            | Platform owner only (via VoxTokenFacet)                                           |
| `confirmTurboTopup`                                                                       | Platform owner only (voluntary audit trail)                                       |
| `getTurboTopupHistory` / `getTurboTopupDetails`                                           | Anyone (public view)                                                              |
| `claimChapterRewards` (chapter)                                                           | Chapter owner, subMods, or platform owner                                         |
| `rescueChapterFunds` (chapter)                                                            | Platform owner (chapter must be banned or removed)                                |

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
6. Deploy all facets: `DiamondLoupeFacet`, `OwnershipFacet`, `VoxFacet`, `VoxGovernanceFacet`, `VoxTokenFacet`, `ChapterLensFacet`, `VoxAssistantFacet`, `GovernanceLensFacet`, `TokenLensFacet` — each with `diamondAddress` as constructor arg
7. `diamondCut` to add all facets, calling `DiamondInit.init()` as initializer
8. Deploy `VoxChapter` master implementation
9. `voxFacet.setChapterImplementation(implAddress)`
10. `voxTokenFacet.initialize(diamond, usdc, priceFeed, openAdverts)`
11. `voxGovernanceFacet.initialize(quotas, signingAddress, storageProviderAddress)`
12. `ownershipFacet.finalizeBootstrap()` — closes the bootstrap latch so post-deploy upgrades must go through governance (production/CLI deploy only; `deployDiamond(true)`)

All facets receive `(diamondAddress)` in their constructor. This address is stored as `immutable` and used only to forward accidental direct payments back to the Diamond.

---

## 8. Upgradeability Model

There are two upgrade mechanisms:

**Owner-direct upgrade (bootstrap phase only):** While the diamond is in bootstrap, the platform owner can submit a `diamondCut` transaction directly to add, replace, or remove function selectors with no governance vote. It is the mechanism used at deployment and for early fixes. A **one-way bootstrap latch** (`LibVoxTokenStorage.directCutFinalized`) permanently closes this path: it is tripped by an explicit owner-only call to `OwnershipFacet.finalizeBootstrap()`, which `scripts/deploy.js` invokes at the end of a successful deployment (`deployDiamond(true)`). Token transfers do **not** trip it (kept off the transfer hot path). After it trips, `DiamondCutFacet.diamondCut` reverts `"Bootstrap finalized: use governance"`. Query state via `isBootstrapFinalized()`; the trip emits `BootstrapFinalized`.

**Governance-gated upgrade (`FacetProposal`):** A `FacetProposal` is created by the owner, voted on by token holders, and if support-quorum and majority are met, resolved by the permissionless `ratifyUpgrade()` (callable by anyone after the deadline). Ratification runs the cut through `executeGovernanceCut()` (an external self-call guarded by a transient `governanceCutInProgress` flag) wrapped in `try/catch`, so a passed-but-invalid or hostile cut (bad selectors, protected-selector removal, or a reverting `_init`) resolves the proposal as **failed** and clears the queue instead of reverting `ratifyUpgrade()` forever and bricking governance. The cut still bypasses the bootstrap latch. This is the only upgrade path once bootstrap is finalized.

**Protected selectors:** `LibDiamond.diamondCut` reverts (`"LibDiamond: Cannot remove protected selector"`) if any cut — owner-direct **or** governance — tries to _remove_ the diamond's innate selectors: `diamondCut` and the four EIP-2535 loupe functions. Replacing (upgrading) them is still allowed; only removal is blocked, so no cut can brick upgradeability or introspection. App-level selectors (governance, etc.) are intentionally not protected — a passed proposal may add/replace/remove them; a reverting cut is still caught by `ratifyUpgrade`'s `try/catch`, so it fails cleanly rather than bricking the queue.

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

7. **Platform owner has broad unilateral power** — can upgrade the diamond, ban users/chapters, revoke admins, set signing address, rotate the requestKey (`setRequestKey`), set implementation. The governance system provides community input but does not constrain the owner.

8. **Signing address controls chapter creation** — the platform signs `keccak256(chapterName || callerAddress || chainId)`. This binds each signature to a specific caller and chain, preventing a signature for one wallet from being used by another and preventing cross-chain replay. If the signing key is compromised, unauthorized chapters can still only be created by the address the key was asked to sign for. Key rotation is via `setChapterSignerAddress()` (owner-only).

8a. **RequestKey rotates atomically with ownership** — a second protocol address (`requestKey`) is published on-chain by `VoxRequestKeyFacet` and read via `GovernanceLensFacet.returnRequestKey()`. It is the identity the off-chain signing service authenticates request callers against. It is **publish-only**: the contract stores and emits it (`RequestKeyUpdated`) but never `ecrecover`s it and never adds it to any signature payload — the `VoxFacet` chapter-creation gate still uses `chapterSignerAddress` only. Ownership can never move without a fresh requestKey: the 1-arg `transferOwnership(address)` reverts (`Use transferOwnership(address,address)`), the 2-arg `transferOwnership(address,address)` sets both atomically, every admin candidate supplies the requestKey they will use via `applyAsNewAdmin(string,address)`, and `ratifyNewAdmin()` activates the non-incumbent winner's key on handover (an incumbent re-election keeps the current key). The owner may also rotate out-of-band via `setRequestKey()`. Invariants enforced on every candidate key: nonzero, `!= prospective owner`, `!= current requestKey`, and `!= chapterSignerAddress` (separation of duties); symmetrically, `setChapterSignerAddress()` rejects `newChapterSignerAddress == requestKey`, so the two identities can never converge from either side. The requestKey private key is server-side only and must rotate in lockstep with any ownership handover / `setRequestKey`.

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
    OwnershipFacet.sol                 — ERC-173 ownership + bootstrap latch
    VoxFacet.sol                   — Chapter registry + admin + ban management
    VoxGovernanceFacet.sol         — Proposals + admin elections + quotas
    VoxTokenFacet.sol              — VOX ERC-20 + reward distribution
    ChapterLensFacet.sol               — Read-only chapter view aggregators
    GovernanceLensFacet.sol            — Read-only governance view aggregators
    TokenLensFacet.sol                 — Read-only token/reward view aggregators
    VoxAssistantFacet.sol              — Delegated moderation role
    Test1Facet.sol / Test2Facet.sol    — Test fixtures only
  libraries/
    LibDiamond.sol                     — Diamond storage + cut/loupe logic
    LibVoxStorage.sol              — Main platform storage
    LibVoxTokenStorage.sol         — Token + reward storage
    LibVoxGovernanceStorage.sol    — Governance + quota storage
    LibVoxChapterStorage.sol       — Stub (unused)
    LibVoxViewStructs.sol              — Shared structs for lens/view facets
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
