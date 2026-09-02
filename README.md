# VoxNet Protocol — Smart Contracts

VoxNet (VOX) is an on-chain content platform protocol built on the
[EIP-2535 Diamond standard](https://eips.ethereum.org/EIPS/eip-2535). A single `Diamond` proxy
delegates to modular facets covering the VOX token, chapter/content management, reward distribution,
and token-holder governance.

- **Token:** VOX — fixed supply of 21,000,000, custom storage (not OZ-inherited), with POL/USDC reward accrual.
- **Governance:** token-weighted proposals (quota + facet upgrades) and a permissionless admin-election flow.
- **Upgrades:** owner-direct `diamondCut` during a one-time bootstrap window, then governance-only via `FacetProposal`.

> Full architecture, storage layout, access-control matrix, reward math, and upgrade model are documented in
> [`PROJECTDOCS.md`](./PROJECTDOCS.md). Error/revert codes are in [`ERROR_CODES.md`](./ERROR_CODES.md).

## Architecture at a glance

| Component                                    | Role                                                                       |
| -------------------------------------------- | -------------------------------------------------------------------------- |
| `Diamond`                                    | Proxy: `fallback` delegatecalls facets; constructor registers `diamondCut` |
| `DiamondCutFacet`                            | Add/replace/remove selectors (owner, bootstrap-gated)                      |
| `DiamondLoupeFacet`                          | EIP-2535 introspection                                                     |
| `OwnershipFacet`                             | ERC-173 ownership + `finalizeBootstrap`                                    |
| `VoxTokenFacet` / `TokenLensFacet`           | VOX token + reward accounting; read aggregators                            |
| `VoxFacet` / `ChapterLensFacet`              | Chapter lifecycle, migration, bans; read aggregators                       |
| `VoxGovernanceFacet` / `GovernanceLensFacet` | Proposals, voting, admin elections; read aggregators                       |
| `VoxAssistantFacet`                          | Delegated moderation role                                                  |
| `VoxChapter`                                 | Per-chapter clone (EIP-1167 minimal proxy)                                 |

## Upgrade & bootstrap model

Two upgrade paths exist:

1. **Owner-direct `diamondCut`** — available only during the _bootstrap window_. A one-way latch
   (`OwnershipFacet.finalizeBootstrap()`) permanently closes it; `scripts/deploy.js` calls this at the
   end of a mainnet deploy. After finalization, `DiamondCutFacet.diamondCut` reverts.
2. **Governance `FacetProposal`** — created by the owner, voted on by token holders (support-quorum,
   FOR-only), then resolved by the **permissionless** `ratifyUpgrade()` after the voting deadline.
   Ratification calls `LibDiamond.diamondCut` directly, so it is unaffected by the latch.

## Requirements

- Node.js 18+
- npm

## Setup

```bash
git clone https://github.com/voxnet-io/bevoxnet.git
cd bevoxnet
npm install
cp .env.example .env   # fill in dev values (see comments in the template)
```

## Test

```bash
npm test                 # full suite
npx hardhat test path/to/file.js
npx hardhat size-contracts
```

## Deploy

Local:

```bash
npx hardhat node         # in one terminal
npm run deploy:local
```

Polygon mainnet (guarded — see `.env.prod.example`):

```bash
# Never store the mainnet key in a file; inject it for the single command:
$env:PRIVATEKEYMAINNET = "0x<dedicated mainnet owner EOA key>"
# Enable the mainnet gate, either in .env.prod (I_UNDERSTAND_MAINNET=1) or in the
# shell as below — a shell-set value is NOT overridden by .env.prod:
$env:I_UNDERSTAND_MAINNET = "1"
npm run deploy:mainnet
npm run verify:mainnet
```

The deployer receives the full VOX supply at genesis and is the initial Diamond owner. Deployment
finalizes the bootstrap latch, so post-deploy upgrades go through governance.

## Security

- Secrets live only in gitignored `.env*` files; the mainnet key is shell-injected, never committed.
- Reentrancy guards on transfer/reward paths; flash-loan (same/adjacent-block) protection on voting.
- Report vulnerabilities via the repository's security contact rather than public issues.

## License

MIT — see [`LICENSE`](./LICENSE).
