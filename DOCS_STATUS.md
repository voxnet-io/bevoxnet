# Documentation Status Tracker

Tracks every Markdown document in the repository and whether its content has been
verified against the current codebase. This is the entry point for the doc-review
process: when you review a doc, or when you change code that a doc describes, update
that row's **Last checked** date and **Status**.

## How to use

1. When code changes, scan this table for docs whose scope overlaps the change and mark them **Needs review**.
2. When you review a doc against the code, set **Status** to **Current** (or **Needs update** with a note) and set **Last checked** to today's date.
3. Add a row here whenever a new doc is created.

## Status legend

- **Current** — reviewed against the code on the date shown; no known discrepancies.
- **Needs update** — reviewed; specific discrepancies found (see Notes).
- **Needs review** — code changed since the last check; not yet re-verified.
- **Not checked** — never verified against the current code.
- **Internal** — working note kept locally in the gitignored `internal/` folder; not part of the published docs. Verify only if the content is reused.

## Public docs (tracked in git)

| Document                         | Purpose                                                            | Last checked | Status  | Notes                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------- | ------------------------------------------------------------------ | ------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [README.md](README.md)           | Public entry point: overview, setup, test, deploy                  | 2026-08-13   | Current | Rewritten this session from the mudgen boilerplate to describe VoxNet.                                                                                                                                                                                                                                                                  |
| [PROJECTDOCS.md](PROJECTDOCS.md) | Architecture, storage layout, flows, access control, upgrade model | 2026-08-18   | Current | §4.5 and §8 updated for governance changes: permissionless `ratifyUpgrade`, `revokeProposal` deadline gate, `executeGovernanceCut` try/catch self-call, `governanceCutInProgress` in-flight sentinel, `ProposalFailed` event, protected-selector enforcement on Remove, and `withdrawStorageProviderFunds` destination fix. Access control matrix (§5) updated. |
| [ERROR_CODES.md](ERROR_CODES.md) | Revert/error code reference                                        | 2026-08-13   | Current | Verified all 13 short codes (INIT, AUTH, RMV, BAN, ADDR, OWN, SUB, INV, MAX, BAL, POL, USDC, SHR) are still present and used in `VoxChapter.sol`.                                                                                                                                                                                       |
| DOCS_STATUS.md (this file)       | Doc-review process + status index                                  | 2026-08-18   | Current | —                                                                                                                                                                                                                                                                                                                                       |

## Internal docs (gitignored `internal/`, not published)

These are historical working notes moved out of the public tree. They are not maintained
as current documentation; verify only before reusing their content.

| Document                                                   | Purpose                                                          | Last checked | Status   | Notes                                                    |
| ---------------------------------------------------------- | ---------------------------------------------------------------- | ------------ | -------- | -------------------------------------------------------- |
| internal/BAN_IMPLEMENTATION_GUIDE.md                       | Ban feature implementation notes                                 | —            | Internal | Historical.                                              |
| internal/CHAPTER_BAN_IMPLEMENTATION.md                     | Chapter-ban implementation notes                                 | —            | Internal | Historical.                                              |
| internal/IMPLEMENTATION_SUMMARY.md                         | Prior implementation summary                                     | —            | Internal | Historical.                                              |
| internal/MIGRATION_DRIFT_RECAP.md                          | Migration drift recap                                            | —            | Internal | Historical.                                              |
| internal/PLATFORM_BAN_AND_SUBMOD_ROSTER_FRONTEND_PROMPT.md | Front-end handoff prompt                                         | —            | Internal | Historical.                                              |
| internal/TEST_UPDATES.md                                   | Test change log                                                  | —            | Internal | Historical.                                              |
| internal/VOX_REBRAND_FRONTEND_HANDOFF.md                   | Rebrand handoff notes                                            | —            | Internal | Historical.                                              |
| internal/PROJECTDOCS_ISSUE_HISTORY.md                      | Archived pre-mainnet issue tracker (moved out of PROJECTDOCS.md) | 2026-08-13   | Internal | Resolved issues C-1…N-4, Q1…Q3; retained for the record. |
