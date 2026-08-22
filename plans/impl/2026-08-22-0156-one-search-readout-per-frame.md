# One search readout per frame

Source: audit FIND-2 in `docs/scratch/2026-08-18-construction-audit.md`
(verified against the tree at `9b958843`).

## 1. Problem

While a search is open, every delivered frame scans the whole mutable
suffix (open tail plus every live grid row) three times on the main actor,
all over the same `Terminal` value:

1. `TerminalPaneSession.consume` -> `emitSearchStatusIfNeeded` ->
   `Terminal.searchStatus`.
2. `planFrame` -> `Terminal.activeSearchMatchRange`.
3. `planFrame` -> `Terminal.searchMatchRanges(in: viewportRows)`.

Each of `Search.status`, `Search.activeMatch`, and `Search.matchRanges`
opens with `currentMatches(in:)`, which runs `lastProjectedContentRow` plus
`scanSearchUnits` over the suffix. Two of the three scans are pure waste,
and the coherence `TerminalSearchStatus` documents ("a total and an index
never taken from different scans") holds only inside the counter, not
between the counter and the highlights the same frame draws.

Evidence: `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`
(`activeMatch`/`status`/`matchRanges`, `currentMatches`),
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (the three public
reads), `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`
(the two planner reads), `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
(`consume`, `emitSearchStatusIfNeeded`, `planIfNeeded`). No commit since the
audit reduces the read count; `plans/impl/2026-08-19-2254-refine-search-index-on-needle-append.md`
explicitly defers this item.

Load-bearing premises:

- P1. `planFrame` borrows the terminal (`281022fc`), so a per-frame value
  the planner consumes is an *input* to planning, not something the planner
  asks the terminal for.
- P2. Status must be emitted for a pane that is not visible (`consume`
  emits status unconditionally; `planIfNeeded` is gated on visibility), so
  the readout cannot be a by-product of planning.
- P3. The only reader of `Search.activeMatch` outside the three reads is
  the no-argument path of `revealSearchMatchIfNeeded`, which has no callers
  (every call passes the match it just navigated to).

## 2. Decision

Introduce one public value, a search readout, that carries everything a
frame needs from an active search -- the counter, the active occurrence,
and the occurrences intersecting the current viewport -- produced by one
scan of the mutable suffix. The terminal exposes it as its single search
read; the pane session computes it once per delivered frame, emits status
from it, and passes it into the damage-aware planner as an explicit input.
The three independent public reads (`searchStatus`,
`activeSearchMatchRange`, `searchMatchRanges(in:)`) and the three
independent `Search` reads they wrap are deleted, so a frame has no way to
scan twice.

Decisive constraints:

- D1. The readout is a plain value built and consumed within one turn.
  Nothing is stored across frames and nothing is invalidated: memoizing on
  `Terminal` keyed by a mutation generation is the rejected alternative
  (RI1).
- D2. The readout's viewport half is defined by the terminal's own scroll
  projection, the same rows the planner draws, so there is no viewport
  parameter for a caller to get wrong. A hidden pane pays the bounded
  viewport-intersect walk it did not pay before (AR1).
- D3. The damage-aware pane planning entry point takes the readout as a
  parameter. The stateless `planFrame(for:presentation:)` convenience
  keeps its signature and derives the readout from the terminal itself, so
  benchmarks, tools, and tests that plan a single frame from a terminal
  value keep one scan and no new plumbing.
- D4. The pane session has exactly one place that turns a terminal value
  into a readout for a frame; every `planIfNeeded` call site (frame
  delivery, initial plan, visibility/theme/rendering-available replans)
  hands the planner a readout computed from the same terminal value it
  plans.
- D5. Alternate-screen and "no search" rules are unchanged: the readout is
  nil exactly where `searchStatus` is nil today, and its viewport and
  active halves are empty exactly where the deleted reads were.

Behavioral scope: no user-visible change. The counter the find overlay
shows, the active and passive highlight runs, reveal-on-navigate, and
status delivery timing are identical.

## 3. Invariants

- I1. One delivered frame with an open search scans the mutable suffix
  once: status emission plus planning together cost the projection rows
  of a single scan.
- I2. A frame's counter, active highlight, and viewport highlights are
  derived from one match snapshot: the readout's total equals the number
  of occurrences the same readout family reports over the whole stream,
  and its active occurrence is an element of its viewport occurrences
  whenever it lies inside the viewport.
- I3. Status reaches `onSearchStatus` subscribers for a pane that is not
  visible, and with the same dedup-by-equality semantics as today.
- I4. No public search read on `Terminal` remains that can scan
  independently of the readout; every consumer (session, planner,
  `TerminalPTYHost.applySearch`, the occupancy probe) reads through it.

## 4. Proof obligations

- PO1 (I1). An `Instrument.projectionRow` measurement shows one readout
  costs the rows of one scan, and a delivered frame on a session with an
  open search (status emission and planning together) costs no more than
  that. Existing shape: `navigationUsesTheOrderedIndex` in
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`.
- PO2 (I2). A readout's total equals the occurrence count implied by the
  readout family over the whole stream, and the active occurrence lies in
  the viewport occurrences when in view -- under arriving output and after
  navigation, quiet and streaming.
- PO3 (I3). New session test in
  `lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift`:
  a session made not visible (`setVisible(false)`) with an open search
  publishes a changed status when matching output arrives, and a following
  update that leaves the status equal publishes nothing. The existing
  `controllerSearchReportsStatus` and
  `matchingOutputPublishesLiveSearchStatus` cover only the visible case and
  never a repeated equal status, so they do not prove I3 on their own; they
  must also pass unchanged.
- PO4 (D5, behavior unchanged). `SearchMatchRenderPlanningTests` and the
  search behavior tests in `TerminalSearchTests` (counter, active
  highlight, viewport highlights, alternate screen, reveal) pass with only
  the read-site rename.
- PO5 (wall clock, reported not gated). `just terminal-occupancy-probe
  --json`, cases `search: held Enter, quiet pane` and `search: held Enter,
  output arriving between presses`, before and after, reported as side
  numbers per `agent-docs/measurement-discipline.md`; the probe brackets
  `searchNext` plus one status read, so it sees at most one of the removed
  scans.

## 5. Non-goals / Accepted risks / Rejected ideas

Non-goals:

- N1. Removing the host-side status push in `TerminalPTYHost.applySearch`
  (a fourth scan per search *mutation*, not per frame). It is a delivery-
  ordering decision of the owner-queue protocol, pinned by the session
  status tests; it can be re-examined separately once every mutation
  provably publishes a frame.
- N2. FIND-4 (`lastProjectedContentRow` without materializing rows) and
  FIND-5 (carrying content ordinals out of the scan). Both are "do after"
  this item and become cheaper once the scan runs once per frame.
- N3. Any change to scan cost per unit, the retained index, or needle
  refinement.

Accepted risks:

- AR1. A hidden pane's status read now also resolves the viewport
  occurrences it did not need. The walk is bounded by the visible rows
  and resolves at most the matches intersecting them; the scan it
  accompanies is the cost that matters.
- AR2. Tests that read `activeSearchMatchRange` / `searchMatchRanges` /
  `searchStatus` move to the readout; this is mechanical churn across
  `TerminalSearchTests` and siblings, accepted instead of keeping the old
  reads alive as a compatibility surface.

Rejected ideas:

- RI1. Memoize the snapshot on `Terminal` keyed by a mutation generation.
  A hand-invalidated mirror whose key must cover history mutation,
  viewport movement, alternate-screen toggles, and needle changes; a
  missed input shows stale highlights.
- RI2. Have the planner compute the readout and return status inside the
  plan. Hidden panes do not plan but must still emit status (P2).
- RI3. Thread the readout through `RenderPresentation`. Presentation
  equality gates row reuse; a per-frame value there would defeat reuse on
  every frame with a search open.

## 6. Implementation discretion

- Whether `Terminal.searchStatus` survives as a one-line derivation of the
  readout for the host's mutation-time push and the probe, or those two
  callers read `searchReadout?.status` directly; either way there is one
  scan path (I4).
- Where the per-frame instrument assertion for PO1 sits (core-level
  readout measure plus a session-level frame measure, or one session-level
  measure that covers both).

## Verification

1. `swift test --package-path lib/TerminalCore --filter 'TerminalSearchTests|SearchMatchRenderPlanningTests|InstrumentTests' > <scratch>/core.log` and grep for failures.
2. `swift test --package-path lib/TerminalPTY --filter TerminalPaneSessionControllerTests > <scratch>/pty.log`.
3. `just terminal-occupancy-probe --json` before and after on the same
   machine in one session; record both in the commit message as side
   numbers.
4. `just test` before commit.
5. Manual: `just launch-slot`, open a pane with a few thousand lines of
   output containing a needle, Cmd-F, type, press Enter repeatedly while
   output streams; counter and highlights match, hide the pane (switch
   tab) and confirm the counter updates on return; `just stop-slot <n>`.
