# UNI-1: store the packed scalar record as a palette index, not a 16-bit bitfield

Source finding: UNI-1 in docs/scratch/2026-08-18-construction-audit.md (verified 2026-08-19; all numbers reproduced from the committed tables).

## Problem

`GeneratedPackedUnicodeTables` in
`lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift`
holds two `UInt16` stages totaling 71,680 bytes, yet the whole codespace
decodes to exactly 29 distinct records and the largest stage-one value is
122 -- every entry fits a byte. `terminalUnicodeClassification(for:)`, the
hottest lookup in the engine, re-derives four fields from bits on every
call and runs two failable `rawValue` inits guarded by
`preconditionFailure`, because the bitfield can represent values (width 3,
grapheme class 31) no generated entry ever holds. The bit layout is also a
contract stated twice: the Python packer in
`scripts/generate-terminal-unicode-tables.py#packed_two_stage_tables` and
the Swift decoder's masks must be kept in sync by hand.

## Decision

Decode at generation time, not at lookup time. The generator emits the
record vocabulary as a palette of fully-formed
`TerminalUnicodeClassification` values; both stages become byte-wide index
arrays; the lookup returns the palette entry directly. The generator
derives the block shift by minimizing total emitted size instead of
hardcoding 8 (the audit's computation puts the minimum at shift 7,
~32 KB vs 71,680 bytes today).

Files: `scripts/generate-terminal-unicode-tables.py` (packing, emission,
and the call site in `main`), and
`lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift`
(regenerated wholesale -- never hand-edited). No caller changes: the only
consumers are `Terminal.swift` and `GraphemeBreak.swift`, all through the
three public functions, whose signatures do not change.

## Invariants

- I1: Every one of the 1,112,064 scalars classifies identically to today
  (Unicode 17.0.0, same pinned inputs, same sha256 header).
- I2: The table can only produce classifications the generator emitted.
  Invalid widths and grapheme classes are unrepresentable, and the decoder
  has no failure path -- the two `preconditionFailure` arms cease to
  exist rather than being merely unreached.
- I3: The packed layout (block shift, index widths) is stated once, in the
  generator, and the emitted Swift derives from it. No constant is
  hand-synced between the packer and the emitted decoder.
- I4: The generator fails loudly if the palette or the block-index range
  outgrows the emitted element type (this replaces today's 0x10000
  stage-one guard), so a future Unicode revision cannot silently truncate.
- I5: Of the seven artifacts one generator run writes, only the production
  table changes; the other six come back byte-identical, proving the
  input data did not drift.
- I6: Emitted arrays stay flat, explicitly typed literals -- the
  type-check budget gate exists because nested/tuple literals at this
  scale blow up swift-frontend memory (generator's own comments).

## Proof obligations

- PO1 (I1): the existing exhaustive suites --
  `UnicodeWidthTests` "generated policy matches every Unicode 17.0 scalar",
  `GraphemeBreakTests` exhaustive sweep plus the GraphemeBreakTest corpus,
  and `TerminalASCIIRunTests` -- compare the production table against an
  independently generated reference for all five fields across the whole
  codespace and already run in the gate. No new test: this is a pure
  repacking, and asserting palette size or index width would be the
  structure assertion AGENTS.md forbids.
- PO2 (I5): after regeneration, `git diff --stat` shows exactly one
  changed file among the seven artifacts.
- PO3 (size claim): `nm -S` on the table symbols (or `size -m` on the
  built TerminalCore object) before and after; report the numbers once in
  the commit message, not in a test.
- PO4 (no feed regression): `just benchmark-quick baseline=HEAD
  workload=terminal-feed` under the conditions in
  agent-docs/terminal-performance.md. Expected honest outcome is
  `equivalent` (the audit's own read); `faster`/`slower` are believed and
  recorded; `inconclusive` escalates to `confirm`, never a re-rolled
  `quick`. The change lands only on `equivalent` or `faster`. A `slower`
  verdict, or a `confirm` that is still `inconclusive`, stops the change:
  report the numbers and replan. There is no verdict under which a
  bitfield decode ships, so the acceptance path always terminates.

## Non-goals

- UNI-2 / UNI-4 (bulk-print run predicate from the record) -- they depend
  on this change and land separately after it.
- A gate step that detects a stale generated file -- out of scope; the
  gate detects a wrong one via PO1.
- Any change to the CanonicalCaseless tables or the test-side reference
  artifacts.

## Accepted risks

- AR1: The palette adds a third dependent load to a two-load chain. The
  29-entry palette stays cache-resident under sustained feed, but a sparse
  workload could pay a miss the bitfield form does not. PO4 decides, under
  the acceptance rule stated there. Keeping the `UInt16` bitfield decode is
  not a fallback: it is the representation I2 exists to remove, so a
  regression ends the change rather than degrading it.
- AR2: I4 is a generator assertion with no test behind it. A future Unicode
  revision that outgrows the emitted element type is caught by the
  assertion firing during regeneration, and by PO1 if it somehow did not;
  a synthetic-overflow test would assert generator internals, which is
  below the bar for the risk it removes.
- AR3: Regeneration needs the nine pinned Unicode 17.0 inputs, which are
  not in the repo -- `verified_data` downloads them from unicode.org
  (sha256-checked) unless `--data-dir` points at staged copies. Plan for
  network access; a hash mismatch is a hard failure, not drift.

## Implementation discretion

- Palette ordering, emission formatting (`integer_array` reuse), and the
  shift-search range.
- Which conformances the emitted `TerminalUnicodeClassification` gains
  beyond the `Sendable` that Swift 6 language mode requires for a
  `static let` array of it.

## Verification

1. Regenerate: `python3 scripts/generate-terminal-unicode-tables.py`
   (network, or `--data-dir` with staged files). Confirm PO2 first -- it
   is the cheapest correctness check available.
2. `swift test --package-path lib/TerminalCore` (PO1), then `just test`.
3. PO3 size measurement; PO4 benchmark run. Record both in the commit
   message per agent-docs/measurement-discipline.md.

## Implementation notes

- The shift search runs over 4 through 12 and the minimum landed at 7, matching
  the audit's prediction: stage one 8,704 bytes plus stage two 23,424 bytes, so
  32,128 table bytes against 71,680 before. Both stages fit `UInt8`, so the
  emitted element type widened nowhere.
- The palette is emitted as 29 explicit `TerminalUnicodeClassification` struct
  literals rather than flat integer arrays rebuilt at runtime. I6's flat-literal
  rule exists for arrays at codespace scale; 29 entries are nowhere near it, and
  spelling them out is exactly what lets the lookup drop both `rawValue` inits
  and satisfy I2.
- `TerminalUnicodeClassification` gained `Sendable`, which Swift 6 requires for
  the `static let` palette array. No other conformance was added.
- Building the per-scalar records now writes ranges with `bytearray` slice
  assignment instead of a per-index loop. Slice assignment past the end grows
  the array rather than raising, so the record builder checks each table's
  length afterwards; the previous loop got that failure from indexing for free.
- PO3 was measured with `size -m` rather than `nm -S`, which reports zero sizes
  on Mach-O. Whole-module numbers were needed because the table's initializer
  symbols do not always land in the generated file's own object.

## Follow Up

- UNI-2 and UNI-4 (the bulk-print run predicate read off the record) were held
  out as non-goals because they depend on this change. They are now unblocked.
- `app-tests/IpcServerRemoteTests.swift` test "a bind that fails on a missing
  interface retries and then serves an admitted peer" failed once under a loaded
  gate with `NSPOSIXErrorDomain Code=54 "Connection reset by peer"` at
  `IpcServerRemoteTests.swift:243`, then passed in isolation and on a clean full
  gate. It is unrelated to this change and looks load-sensitive.
