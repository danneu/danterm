# Headless terminal core foundation (Milestone 2, slice 1)

First implementation slice of
[plan-terminal-engine/14-roadmap.md](../../plan-terminal-engine/14-roadmap.md)
Milestone 2. Governing contracts:
[04-terminal-core.md](../../plan-terminal-engine/04-terminal-core.md) and
[05-unicode-grid-scrollback.md](../../plan-terminal-engine/05-unicode-grid-scrollback.md).

## Problem

Milestone 1 established the DanTerm-facing terminal backend boundary; nothing
of the Swift engine itself exists yet. Every later slice -- VT parser,
scrollback/reflow, PTY, renderer -- depends on the text and grid
representation. If grapheme-based cells, width handling, or streaming
ingestion are wrong, everything built on them reworks. This slice builds and
proves that representation headlessly, before any parser, PTY, or renderer
exists to obscure it.

Load-bearing evidence (verified): the repo's nested-package pattern
(`lib/DanTermProtocol` is the dependency-free template), the purity lint
(`scripts/core-purity-lint.sh` takes a positional target dir, pure profile by
default, wired per-target in the justfile `test:` recipe), and the Ghostty
reference implementation in `.ghostty-src/src/terminal/` (`UTF8Decoder.zig`,
`Parser.zig`, `stream.zig`, `Terminal.zig` print path) whose default-mode
behavior this slice ports or matches.

## Decision

Create a new pure SwiftPM package `lib/TerminalCore` (module `TerminalCore`)
on the nested-package template. The library target has zero dependencies --
not even Foundation; the test target may use the repo's existing test tooling
(swift-custom-dump, per DanTermCore precedent). The package uses Swift 6
language mode with strict concurrency, resolving that open question from
`15-open-questions.md` for new engine packages -- the slice's change
deletes the resolved question from that document so the planning corpus
stays consistent; existing v5 packages are unchanged. No `app/` symlink -- nothing in the app consumes the engine this
slice, and the engine will eventually be a real `import`, not same-module
compilation. The package joins the `just test` gate: its test suite, the purity
denylist on the library sources, and an import gate that fails on any
library-target import, Foundation included -- the existing lint bans
Cocoa/AppKit imports and IO tokens but never checks Foundation, so this
check is new and gets self-test coverage in both directions per repo
convention.

The slice delivers a headless terminal state machine, a value type whose
public surface is byte ingestion, cell/cursor inspection, and test-facing
views of plain screen text and of grid geometry -- the latter distinguishing
never-written blanks from written spaces and exposing cell classes, wrap
flags, and cursor. Grid internals stay non-public so the scrollback slice
can swap the storage representation invisibly.

- **Streaming ingestion, Ghostty's stream architecture.** A per-byte loop:
  in the parser ground state, bytes flow through an incremental UTF-8
  decoder to scalar dispatch (C0 execute / print); in any other parser
  state, the absorber consumes raw bytes. This is how the reference resolves
  bytes-vs-scalars, and the next slice's VT parser drops into the absorber
  without touching the decoder or the loop. The incremental decoder
  reproduces the reference decoder's (`UTF8Decoder.zig`) malformed-input
  behavior byte-for-byte -- maximal-subpart U+FFFD replacement -- so the
  reference's decoder tests port directly as fixtures. Decoder and
  absorber state live inside the terminal value and participate in
  equality. There is no end-of-input flush API: a terminal stream never
  ends in-band, and its absence is what makes chunk invariance structural.
- **Escape absorption, zero interpretation.** Recognition of the full
  VT500 sequence grammar the reference parser (`Parser.zig`) accepts, with
  discard-only actions: ESC/CSI/OSC/DCS/SOS/PM/APC sequences are swallowed
  cleanly -- including the anywhere transitions (CAN/SUB abort, ESC
  restart), OSC termination by BEL or ST, and C0 execution inside
  sequences -- but no sequence is interpreted. "A ESC [ 3 1 m B" renders
  "AB"; OSC title writes vanish. C1 controls are recognized in their
  7-bit ESC-prefixed encodings only: ground-state bytes all pass through
  the UTF-8 decoder (the reference stream's parser never sees a raw
  ground-state byte either), so a raw C1 introducer such as 0x9B is
  malformed UTF-8 per I5, not a sequence start; inside a sequence the
  absorber consumes raw bytes and the table's 8-bit anywhere transitions
  apply. The parser slice adds param collection and dispatch to this
  recognizer in place.
- **Widths from pinned, generated tables.** A checked-in generated Swift
  table plus a manually-run regeneration script pinned to a specific
  Unicode version (current stable at implementation time), never run at
  build time. Zero-width classification (general categories Mn/Me/Cf)
  takes precedence over East Asian Width; otherwise Wide/Fullwidth are
  width 2 and Ambiguous is width 1 -- U+3099 is both Mn and EAW Wide and
  is width 0, extending its base. An Extended_Pictographic bit gates
  variation selectors. Product code never consults
  `Unicode.Scalar.Properties` (OS/toolchain-versioned Unicode data) -- that
  is what "pinned" means here.
- **Grapheme cells via width-based appending, scoped to this slice.**
  This is the reference's default (mode-2027-off) path and covers this
  slice's Spanish/Chinese/basic-emoji scope, but it is not the engine's
  final default: 05's contract makes extended grapheme clusters the
  indivisible unit unconditionally, so the later segmentation slice must
  deliver that behavior by default, without application opt-in. A cell
  stores one cluster, scalar-exact: ingestion never normalizes, and cell
  equality compares scalars, so state remains a pure function of input
  bytes while canonical equivalence is asserted at the geometry level.
  Zero-width scalars append to the attach target: the cell just printed
  (honoring deferred wrap, so a combining mark after a last-column print
  lands on that cell) with wide-tail resolving to its head; with no prior
  cell the scalar is discarded. VS15/VS16 append only when the target's
  base is Extended_Pictographic and never change width this slice.
- **Wide-cell integrity.** Four cell roles: narrow, wide head, wide tail
  (spacer), and the right-edge spacer head. Overwriting either half of a
  wide pair clears the whole pair; clearing at a row's left edge also
  clears a stale spacer head on the previous row; the erase primitive
  widens a range to whole pairs when an edge would split one. Autowrap
  with VT100 deferred wrap (pending-wrap state) is included: printing past
  the right edge needs defined behavior, and a wide cluster with only one
  column remaining writes a spacer head and wraps the pair to the next
  row. The supported grid domain is `columns >= 2` (any `rows >= 1`),
  rejected at construction: a wide cluster is unrepresentable in one
  column, and the reference itself treats a 1-wide terminal as a broken
  case to prevent upstream.
- **Minimal controls.** CR (column 0), LF/VT/FF as line feed (at the bottom
  row the grid scrolls and the top row is discarded -- no scrollback this
  slice), BS (cursor left, clamped, no erase), TAB (fixed 8-column stops,
  clamped to the last column, writes nothing). Rows record soft-wrap
  identity now: hard/soft line identity is a Milestone 2 exit criterion,
  and not recording it would make this slice's output unreconstructible for
  the reflow slice. All other C0 bytes and DEL are consumed without
  effect.
- **Recorded deviations from Ghostty** (differential traces must carve
  these out): decoded C0 in 0x10-0x1A/0x1C-0x1F are ignored rather than
  printed, and zero-width attach honors pending wrap (the reference's
  legacy path attaches to the wrong cell at the right edge; 05's
  canonical-equivalence invariant requires the correct behavior, and
  Ghostty output is evidence, not authority).

## Invariants

- I1. Identical input bytes produce identical terminal state -- including
  pending decoder/absorber state -- regardless of how the bytes are split
  into chunks.
- I2. The core performs no IO and reads no ambient state; transitions are
  synchronous and invoke no callbacks. Enforced structurally (zero
  library dependencies, Foundation included) and by the gate's import
  and purity checks.
- I3. Canonically equivalent Spanish text (precomposed vs decomposed)
  occupies equivalent terminal geometry, one cell per user-visible
  character, while cell storage stays scalar-exact.
- I4. A Chinese wide character or basic emoji occupies exactly two cells,
  and no mutation -- overwrite of either half, erase, wrap at the right
  edge, scroll -- leaves an orphaned half-cell or dangling spacer head.
- I5. Malformed UTF-8 (truncated sequences, lone continuation bytes,
  overlong forms, surrogates, out-of-range) produces maximal-subpart
  U+FFFD replacement and never desynchronizes ingestion: later valid
  input is processed correctly.
- I6. Arbitrary byte input cannot crash, hang, or prevent later valid text
  from being processed.
- I7. No transition leaves invalid cursor, pending-wrap, or wide-cell
  state.
- I8. Escape sequences are absorbed without interpretation: no sequence
  byte is ever printed, and text resumes correctly after any sequence,
  aborted sequence, or ESC arriving mid-UTF-8-sequence.
- I9. A written space is observably distinct from a never-written cell,
  and cursor-only motion (TAB, CR, BS) never converts padding to
  content or content to padding -- the distinction 06's logical-text
  projection depends on.

## Proof obligations

- PO1 (I1). Chunk-boundary invariance: a fixture corpus (Spanish both
  forms, Chinese, U+1F618, controls, malformed bytes, escape sequences,
  wide-at-last-column) fed at every 2-way and 3-way split point and
  byte-at-a-time reaches state equal to single-chunk ingestion.
- PO2 (I2). The library builds with no dependencies; the purity denylist
  passes on the library sources; the import gate rejects any
  library-target import (Foundation included), with both directions
  pinned in the gate's self-test.
- PO3 (I3). Precomposed and decomposed Spanish fixtures produce equal
  geometry and screen text; their cell storage differs scalar-exactly.
- PO4 (I4). A wide-cell mutation matrix: narrow over head, narrow over
  tail, wide over adjacent halves, erase range splitting a pair, wide at
  last column (spacer head + wrapped pair), overwrite clearing a stale
  spacer head, and bottom-row scroll discarding rows that hold wide pairs
  and right-edge spacer heads; plus a whole-grid validity sweep after
  each mutation. The matrix runs on the minimal 2-column grid as well as
  a wide one, and construction below the supported domain is rejected.
- PO5 (I5). Decoder fixtures ported from the reference plus
  malformed-UTF-8 sequences truncated exactly at chunk boundaries,
  followed by valid text that must land intact.
- PO6 (I6). Seeded deterministic fuzz: arbitrary byte blobs terminate
  without crash, and after CAN (forcing ground) a trailing sentinel
  prints -- recovery, not just absence of crashes.
- PO7 (I7). A ground-control behavior matrix: CR; LF, VT, and FF each
  acting as line feed at and below the bottom row (wrap flags move with
  rows); BS at column 0 and onto a wide tail; TAB stops and clamping;
  the pending-wrap set/clear matrix across prints and controls; and the
  ignored C0 bytes and DEL leaving cursor, grid, and pending-wrap state
  unchanged -- pinning the recorded deviation from the reference's
  print-through behavior.
- PO8 (I8). Escape-absorption tests covering every absorbed family --
  ESC-final, CSI, OSC (BEL- and ST-terminated), DCS, SOS, PM, APC, each
  in its 7-bit ESC-prefixed form -- and every transition class: CAN/SUB
  abort, ESC restarting a sequence, string termination by ST, C0
  handling inside sequences, the 8-bit anywhere transitions on raw bytes
  inside a sequence, a raw ground-state C1 byte producing U+FFFD rather
  than starting a sequence, and ESC arriving mid-UTF-8 (U+FFFD, then the
  sequence honored). Printable text resumes intact after each.
- PO9 (I1, I2). Determinism replay: the same bytes into two fresh
  terminals produce equal states; a copied value is unaffected by further
  feeds to the original.
- PO10 (I3, I4). The generated width/property table matches the pinned
  official Unicode data files across their full code-point ranges --
  East Asian Width, the zero-width general categories, and
  Extended_Pictographic -- not only sampled fixtures, including derived
  width at property overlaps (a scalar both zero-width and EAW Wide
  resolves to width 0).
- PO11 (I3, I7). A zero-width attach matrix: no prior print (discard),
  narrow target, wide target resolved tail-to-head, attach across
  pending wrap after a last-column print (the recorded deviation), and
  VS15/VS16 accepted on Extended_Pictographic bases and rejected
  otherwise.
- PO12 (I9). Grids built from a literal space versus cursor-only motion
  to the same column read identically as screen text but differ through
  the public geometry view: the written space is content, the skipped
  cell padding.

Slice exit gate: `just test` green with the package's tests and gate
checks wired in. Left open for later slices: scrollback/reflow, sequence
interpretation, selection/search, alternate screen, styles, official
UAX #29 segmentation fixtures (with the segmentation slice), and
differential traces against live Ghostty.

## Non-goals

- Scrollback retention and resize/reflow (LF at bottom discards the top
  row).
- Interpreting any escape sequence: no CSI/SGR/OSC/DCS semantics,
  alternate screen, margins, scrolling regions, saved cursor, modes, or
  query replies.
- ZWJ emoji sequences, emoji modifier sequences, regional-indicator
  flags, UAX #29 segmentation, and the VS16 narrow-to-wide width
  upgrade -- all owned by the later segmentation slice, which must
  satisfy 05's extended-grapheme-cluster contract by default.
- Output bytes, semantic events, and damage tracking -- ingestion returns
  nothing this slice.
- PTY, rendering, selection, search, and app integration (no `app/`
  symlink, no `TerminalSession` conformance).
- Configurable behavior of any kind.

## Accepted risks

- AR1. The ingestion entry point will change signature when query replies,
  semantic events, and damage arrive; an empty effects value now would be
  speculative. In-repo mechanical change, no external consumers.
- AR2. The scrollback slice will likely replace row/cell storage with a
  compact paged representation. Contained by keeping grid internals
  non-public.

## Implementation discretion

- Generated table format, generator script language, and the exact pinned
  Unicode version.
- Cell/row storage layout, geometry-view formatting, decoder algorithm
  (behavior pinned by ported reference fixtures), parser-state and
  mutation-primitive decomposition, import-gate mechanics, and internal
  type/file decomposition.
- TDD sequencing of the build-out (repo rule: each step lands green).

## Commit progress

- [x] 1. Establish the pure Swift 6 package and pinned Unicode property foundation
- [x] 2. Add chunk-invariant UTF-8 decoding and escape absorption
- [x] 3. Add terminal grid, controls, wrapping, and wide-cell invariants

## Implementation notes

- Pinned Unicode 17.0.0, the current stable standard for this implementation,
  and record official-file SHA-256 hashes in the generator. The generated test
  reference independently combines the source properties into exhaustive runs
  so `just test` validates every scalar without network access.
- The stream-to-grid handoff uses internal scalar/control actions rather than a
  callback. Commit 3 consumes them inside the public terminal's void ingestion
  method, preserving the no-callback and no-public-effects contracts while
  keeping decoder and absorber behavior independently testable.
- The public geometry projection carries cell roles, wrap flags, and cursor
  state but not scalar payloads, so canonically equivalent text compares as the
  same geometry. Scalar-exact content remains available through cell inspection.
