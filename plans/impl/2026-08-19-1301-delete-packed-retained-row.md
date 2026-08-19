# STORE-2: Delete PackedRetainedRow's dead body and re-home the cell-word constants

## Context

Doc 31's logical-line arena replaced the per-display-row `PackedRetainedRow`
as retained storage, but the type was never removed. Audit finding STORE-2
(docs/scratch/2026-08-18-construction-audit.md), verified against the tree on
2026-08-19: outside its own 643-line file, every non-comment reference is
either `PackedRetainedRow.Header.<cell-word constant>` in
`LogicalLineStore.swift` or the four byte-count aliases on
`LogicalLineRecord` (LogicalLineRecord.swift:128-131). Nothing in production
constructs or reads one. A reader working on row storage faces two full
layout contracts, one of which is a fiction, and the constants the live store
depends on are declared inside the fiction and tested only against dead code.

The verification pass found two things the audit under-scoped:

- `TerminalPackedRetainedRowTests.swift` is not all dead. Six of its eleven
  tests exercise the dead encoder directly; the other five drive a live
  `Terminal` through the public API (canonical trim extents, metadata
  survival across admission/reflow/height transfer, soft-wrap rejoin, OSC 133
  stamp survival, fragmented-identity structure surviving into history). Those
  five are real arena-path coverage and must survive.
- `Terminal.GridRow.compacted()` (Terminal.swift:296) has no caller outside
  the dead encoder's comment and its tests, so it dies in the same change.

STORE-1 landed as commit 3354fd46, so this is unblocked. STORE-3 (one
`CellWord` encode/decode type) lands after this, on the single declaration
this change leaves behind.

## Decision

- Delete `lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift`
  outright -- no shim, no renamed remnant (the audit's cheaper fallback is
  rejected: a namespace named for a representation that no longer exists).
- Declare the 8-byte cell-word layout constants (`cellScalarMask`,
  `cellKindShift`, `cellKindMask`, `cellSpillBit`, `cellStyleShift`) once, in
  `LogicalLineRecord.swift`, beside -- not inside --
  `LogicalLineRecord.Header`: that enum documents a different 8-byte word
  (the record header) and must not absorb this one. The cell-word bit diagram
  doc comment moves with them. STORE-3 upgrades this declaration in place;
  the constants must not need a second move.
- Make the four byte-count constants on `LogicalLineRecord` (`cellBytes`,
  `hyperlinkEntryBytes`, `identityRunEntryBytes`, `identityCellBytes`)
  literal, dropping the alias indirection.
- Delete `GridRow.compacted()`.
- Split the test file: the six direct-encoder tests die with the encoder; the
  five live tests survive as their own suite under a name that states their
  real subject, with the one dead-type assertion
  (`PackedRetainedRow.pack(decoded).unpacked() == decoded`,
  TerminalPackedRetainedRowTests.swift:416) removed. The `Terminal` hooks
  they use (`retainedRowForTesting`, `scrollbackRecordContentIdentityShape`)
  already exist and stay.
- Rename and rewrite the fifth live test
  (`fragmentedIdentityRowStillAdjudicatesActivation`) to state what it
  actually asserts once the dead-type line is gone: a fragmented-identity row
  reaches history with a strict-run shape of more than one run and with
  decoded cells that still carry identities. It must not claim to adjudicate
  link activation -- it never activates a link. Exact per-cell identity
  preservation stays covered by
  `TerminalLogicalLineStoreTests.fragmentedIdentityFallsBackPerCellWithoutLoss`.
- Rewrite every comment that cites `PackedRetainedRow` (sites exist in
  `Terminal.swift`, `LogicalLineRecord.swift`, `LogicalLineStore.swift`,
  `TerminalRetainedRowReadPathTests.swift`,
  `TerminalLogicalLineStoreTests.swift`) to state the rule directly --
  canonical trim, the one-cell floor, strict-step-of-one identity runs, the
  two identity encodings -- instead of pointing at the deleted type.
- `docs/research/31-logical-line-scrollback/findings.md` cites the full
  repo-relative path of the deleted file; declare it there with a
  `<!-- docs-lint: allow-missing ... -->` marker (research is historical and
  is otherwise untouched).

## Invariants

- I1: After the change, `PackedRetainedRow` appears nowhere under `lib/` or
  `app/` -- not in code, not in comments, not in test names.
- I2: The cell-word layout has exactly one declaration in the tree, in
  `LogicalLineRecord.swift`.
- I3: Observable behavior is unchanged -- byte-identical retained storage,
  identical reads. The change is deliberately invisible to every instrument.
- I4: The five live behavioral tests keep their assertions (minus the one
  dead-type line) and keep passing with no production-code accommodation.
  Each surviving test's name and description state only what it asserts.

## Proof obligations

- PO1 (I3, I4): `just test` green. The retained read-path suites
  (`TerminalRetainedRowReadPathTests`, `TerminalLogicalLineStoreTests`) pass
  with no assertion edits -- their staying green with the type gone is the
  proof nothing observable depended on it.
- PO2 (audit risk): before deleting the six encoder tests, confirm each rule
  the store still relies on -- canonical trim extents including the
  trailing-blank asymmetry and one-cell floor, and both identity encodings
  including the strict-step-of-one run shape -- is asserted by an arena-level
  test (the relocated live suite or `TerminalLogicalLineStoreTests`); add any
  missing assertion there first.
- PO3 (I1): `grep -rn PackedRetainedRow lib app --include='*.swift'` returns
  nothing.
- PO4: docs-lint passes with the file deleted, via the allow-missing marker.

## Non-goals

- STORE-3's `CellWord` encode/decode type. This change only leaves the single
  declaration it builds on; the eight hand-inlined shift sites in
  `LogicalLineStore.swift` are retargeted to the new constant home, not
  restructured.
- Any change to storage bytes, budgets, or read behavior.
- Rewriting research docs beyond the one docs-lint marker.

## Implementation discretion

- The namespace name for the relocated cell-word constants, and the surviving
  test suite's file and type name.
- Which arena suite hosts an assertion PO2 finds missing.

## Verification

1. Targeted first: `swift test --package-path lib/TerminalCore`.
2. `just test` -- the gate, which includes docs-lint (PO1, PO4).
3. The PO3 grep.

## Implementation notes

- The deleted file also held two live encodings the audit did not name:
  `TerminalCellKind.packedCode` / `init(packedCode:)` (the cell word's kind
  field) and the same pair on `Terminal.SemanticPromptRow` (the record header's
  semantic mark). Both are read and written by `LogicalLineStore` today, so they
  moved to `LogicalLineRecord.swift` with the layout they encode rather than
  dying with the type.
- The relocated cell-word constants dropped their `cell` prefix inside the new
  `Terminal.CellWord` namespace (`CellWord.scalarMask`, `.kindShift`,
  `.kindMask`, `.spillBit`, `.styleShift`). Values are unchanged, so storage
  bytes are identical; the prefix only restated the namespace.
- PO2 found one rule with no arena-level test: a wide cell's two columns share
  one identity, which is the repeat the strict-step-of-one run encoding cannot
  express and must break on. `TerminalLogicalLineStoreTests`'
  `wideCellIdentityRepeatSurvivesTheRunEncoding` now asserts it, and was checked
  by ablation -- relaxing the run-extend condition to accept a repeat makes it
  fail with the tail reading a neighbour's identity.

## Follow Up

- `IpcServerRemoteTests` timed out under `just test`'s oversubscribed pool on
  two runs out of three, on a different test each time ("an unavailable audit
  sink prevents tailnet service but not local IPC", then "closing a peer retires
  the runtime state its pending request owns"), and passes standalone in 15
  seconds. The 30-second in-test guards in that suite look too tight for the
  gate's load. Unrelated to this change, which touches only `TerminalCore`.
