# Unify the search matchers and lift search out of Terminal (S16)

## Context

Audit finding S16 (docs/scratch/2026-08-11-simplification-audit.md, line 432).
Search is implemented twice inside `Terminal.swift` (7,894 lines): a retained
index over closed history records (`scanClosedRecordSearchUnits`,
Terminal.swift:4292) and a rescan over the display projection
(`scanSearchUnits`, Terminal.swift:4445). The two scanners carry byte-identical
sliding-window match logic in their nested `consume` closures; a matcher fix
must be made twice, and the two copies can silently disagree -- the
`scannedSearchMatchRanges` test oracle exists to catch that disagreement after
the fact. Around them, ~1,000 lines of search state, producers, and resolution
helpers read Terminal's fields ambiently, and seven nested types
(Terminal.swift:543-628) sit in scope for 7,000 lines that must never touch
them.

S16 also gates the other Terminal.swift restructurings (S14 screens, S15
modes, S34 anchors, S53 file split): the audit's ordering ("Settle these
first", line 118) puts the search lift first so the later file split does not
draw boundaries around a shape about to be deleted.

Desired outcome: one matcher implementation that both scan paths use by
construction, and a search subsystem with an explicit input surface in its own
file -- leaving `Terminal.swift` smaller and the remaining Terminal-to-search
edges visible and deliberate.

## Decision

Two stages, ordered; the first is independently landable and is the audit's
"cheaper fallback" -- the ideal contains it as its first commit.

**1. One generic matcher.** Extract the duplicated sliding-window logic into a
generic `NeedleWindow<Position>` in its own file (`NeedleWindow.swift`), with a
generic unit type replacing `RecordSearchProjectionUnit` /
`SearchProjectionUnit` (same three fields, only the position type differed).
Both scanners become producers feeding one matcher instance.

The two axes the audit feared a generic matcher would need collapse:

- *Seed admission* is not a matcher parameter. The matcher exposes two feed
  operations -- one that only fills the window (join context) and one that also
  records matches -- and each caller decides per unit which to use. The record
  path's all-non-matching seeding and the projection path's
  `matchingSeedSuffixCount` (Terminal.swift:4475-4481) are then caller-side
  loops over the same two operations. This equivalence rests on the boundary
  window never exceeding needle-length-minus-one units (true today at every
  assignment site); assert it where the window is stored so the equivalence
  is enforced rather than tacit.
- *The intersects filter* (Terminal.swift:4472) moves out of the matcher:
  callers post-filter the returned matches. Equivalent because matches are only
  ever returned, never fed back into the scan.

**2. Lift the subsystem, same module.** Move search state and logic into
`Terminal.Search`, declared in a new `TerminalSearch.swift` via
`extension Terminal` -- the same shape `LogicalLineStore.swift` already uses
for a lifted subsystem. `SearchState` dies; `Search` is the state (query,
position, match index) plus the producers, index maintenance, and resolution
helpers as methods. Grid data reaches those methods as an explicit per-call
context (history, projection stream, evicted-row count, column count) built by
Terminal -- never stored, so search holds no second live reference to the
history arena (the copy `research/31/F13` measured; see the invariant on
`SearchMatchSnapshot`, Terminal.swift:583-587).

**What deliberately stays on Terminal** (the edges that make a module boundary
wrong, kept explicit rather than severed):

- `private var search: Search?` with its `didSet` cache -- the field stays
  private because every forwarder stays in `Terminal.swift`.
- The public entry points and test hooks as thin forwarders owning the
  alternate-screen guards, `publicRange` conversion, damage recording, and the
  viewport writes (`revealSearchMatchIfNeeded`) -- search never writes
  `viewportState` or damage.
- The damage path's dependency on search: `widenedSearchDamageRows`
  (Terminal.swift:1156) reads a needle-radius the lifted type exposes, and
  `recordScrollDamage` (Terminal.swift:7634) keeps its search-active check.
- The six index-synchronization call sites on mutation paths, `clearInspection`,
  and the width-change capture/restate of the search position
  (Terminal.swift:5565, 5649).

**Rejected: a separate SPM target.** The damage path depends on search state
and search depends on grid data; a target boundary would need the dependency
both ways or force grid internals public. It would also un-specialize the
matcher across the module boundary (the tax
docs/design/2026-07-29-cross-module-value-dispatch.md exists to manage), and
packaging is a deliberately open question in the engine register
(docs/design/2026-08-06-swift-terminal-engine.md, Open questions) that this
work has no independent reason to answer.

## Invariants

- I1. Search behavior is unchanged: the contract is engine register rows E5,
  E6, and G9, and every existing `TerminalSearchTests` case passes with its
  body unedited -- including the indexed-vs-scanned oracle equivalences and the
  `SearchIndexMaintenanceCounter` / `ProjectionRowCounter` /
  `SearchDistanceWorkCounter` cost assertions. Adding new cases to that file is
  allowed and expected (PO3, PO5); editing or deleting an existing one is not.
  Public API shapes on `Terminal` do not change.
- I2. One matcher: after stage 1 there is exactly one implementation of the
  sliding-window match logic, used by both the closed-record and projection
  scans. The oracle's job shrinks from "catch matcher divergence" to "catch
  producer/index divergence".
- I3. The matcher stays in the same module as its two instantiations, so
  specialization needs no cross-module annotation.
- I4. The lifted search type stores no reference to the history store or
  projection; grid data is a per-call parameter.
- I5. Search reads grid state and writes only its own state; viewport writes,
  damage recording, and alternate-screen gating remain Terminal's.
- I6. Per agent-docs/measurement-discipline.md, no step asserts the refactor
  is performance-free: the counter assertions are the check, and a counter
  regression is a stop-and-investigate, not a threshold to re-freeze.
- I7. The per-feed index-maintenance path stays as cheap as today when search
  is inactive: the nil guard runs before any context construction, and the
  maintenance entry point takes only the history it reads -- it never
  constructs a projection facade. (It runs on the feed path via scrollback
  budget enforcement, Terminal.swift:4816-4820, with `search` almost always
  nil, and no pinned counter measures facade construction -- a regression here
  would ship silently.)
- I8. The three cost-counter recording sites (`ProjectionRowCounter` at
  Terminal.swift:4455 sized by the scan range,
  `SearchIndexMaintenanceCounter` at 4179 and 4201) keep their exact
  placement and granularity through both stages; they do not fold into the
  matcher.
- I9. No search state crosses an alternate-screen transition. Entering the
  alternate screen clears an existing primary-screen search outright --
  `switchAlternateScreen(enabled:)` calls `clearInspection()`
  (Terminal.swift:6764, 6777), which nils `search` (Terminal.swift:4676) -- so
  navigation afterwards returns false, and leaving the alternate screen does not
  restore it. The lift must keep that clear total: `clearInspection` drops the
  whole lifted `Search`, never just the query or position while an index
  survives.

## Proof obligations

- PO1 (I1, I6): `swift test --package-path lib/TerminalCore --filter
  TerminalSearchTests` green after each stage, with no existing case edited or
  deleted.
- PO2 (I2): new `NeedleWindow` unit tests, written TDD-first, covering the
  matcher contract directly: window wrap, trailing-unit extraction,
  single-unit needle, overlapping matches, and mixed join-context/recording
  feed sequences -- the join-context feed must advance the window identically
  to the recording feed (only match recording differs), and the tests pin
  that.
- PO3 (I1): a scenario with a match ending exactly at the closed-history /
  live-suffix seam stays reported after the intersects filter moves to the
  caller -- the caller must reproduce the widened match-rows branch
  (Terminal.swift:4087-4089), and a match ending at row start counts its last
  included row as the previous row (Terminal.swift:4728-4730). Verify the
  existing oracle fixtures cover this seam; add one if none does.
- PO5 (I9): a `TerminalSearchTests` case, written before stage 2, that opens a
  multi-match search on the primary screen, enters the alternate screen, and
  asserts the search is gone -- `searchStatus` nil, `searchNext` and
  `searchPrevious` false -- then leaves the alternate screen and asserts it is
  still gone. Today's only alternate-screen coverage
  (`alternateScreenReportsNoSearch`) starts its search *on* the alternate screen
  and so never exercises the clear; a lift that left an index behind while
  nilling the query would pass every named test.
- PO4 (I1): the full gate `just test` at the end of each stage.

## Non-goals

- No change to search semantics, key folding, navigation order, or any public
  API signature.
- No separate SPM target for search (rejected above).
- S14/S15/S34/S53 are out of scope; this plan only unblocks them.

## Accepted risks

- AR1. Lifting forces visibility promotions inside the module: `TextAnchor`,
  `TextAnchorRange` (fileprivate, Terminal.swift:480/490), `ProjectionRows`
  (private, Terminal.swift:381), and the shared row-geometry helpers
  (`projectedCellEnd`, `rowContainsContent`, `retainedContentEnd`) become
  internal so the new file can use them. Genuine encapsulation loss, judged
  worth it: the `search` field and all forwarders stay private to
  `Terminal.swift`, and `internal` still ends at the TerminalCore module
  boundary. `ProjectionRows` is promoted in place, not moved -- its bodies
  call the fileprivate `seamSpacer` (Terminal.swift:3538).
- AR2. `Terminal` is `Equatable, Sendable` with synthesized equality; the
  lifted `Search` type and the matcher's stored unit and match types all
  carry both conformances (verified feasible: `Deque` is conditionally both,
  and the position types already conform).
- AR3. In-place mutation of the lifted state fires the `search` `didSet` on
  the no-change maintenance path where today's copy-out/write-back skips it.
  The observer is an idempotent three-load cache refresh; accepted. In-place
  mutation does *not* buy back today's `guard var search` CoW copy of the match
  Deque: `search` is a stored property with an observer (Terminal.swift:776), so
  it is accessed through a synthesized get-modify-set, the temporary holds a
  second reference to the buffer, and `prefixMatches` copies on append exactly
  as it does today. Expect parity, not an improvement. Shedding the copy would
  mean dropping the `didSet` and calling `refreshHasContentInspectionState()`
  explicitly at the mutation sites, which is out of scope here.

## Implementation discretion

- The exact context-parameter shape (one small view struct vs. explicit
  parameters) and the exact home of the promoted row-geometry helpers.
- Whether the unit/match types nest inside `NeedleWindow` and how the
  counters relocate beside the code they count.

## Files

- `lib/TerminalCore/Sources/TerminalCore/NeedleWindow.swift` (new, stage 1)
- `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift` (new, stage 2)
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (both stages; its
  file header's ownership claim, lines 1-27, is amended in stage 2 to move
  search to the "deliberately lives elsewhere" list, per the code-style rule
  the audit's T8 invokes)
- `lib/TerminalCore/Tests/TerminalCoreTests/NeedleWindowTests.swift` (new)
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`
  (additions only -- new cases for PO3 and PO5; no existing case is edited)

## Verification

Stage order is load-bearing: land the matcher unification green before any
move. For each stage: new tests first (PO2 and PO3 in stage 1, PO5 in stage 2),
then `swift test --package-path lib/TerminalCore --filter TerminalSearchTests`
(PO1), then `just test` (PO4).
No app-level behavior changes, so no UI harness run is required beyond the
gate.

## Commit progress

- [x] 1. Unify search scans on one generic needle window
- [ ] 2. Lift search state and logic into Terminal.Search
