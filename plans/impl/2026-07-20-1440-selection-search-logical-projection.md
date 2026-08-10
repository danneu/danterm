# Milestone 6 slice 4: selection and search over the logical projection

## Context

`plan-terminal-engine/06-inspection-recovery.md` makes linear selection and
literal full-history search core policy over the one logical-text projection:
selection joins soft-wrapped rows, places `\n` at included hard boundaries,
preserves selected spaces and empty logical lines, and never splits a grapheme
cluster or wide cell; search is literal, ASCII case-insensitive and otherwise
Unicode-exact, spans soft wraps but not an unrequested hard newline, selects
the newest match first, navigates older with Next and newer with Previous, and
stops at either end. `plan-terminal-engine/05-unicode-grid-scrollback.md`
requires selection and search positions to remain attached to logical content
across reflow and to survive eviction only as clamped, valid content.

Neither exists in the engine yet. The Milestone 6 slice map
(`plans/impl/2026-07-20-1014-alternate-screen-resize-semantics.md`) sequences
this as slice 4: pure core policy, needing the inspection projection (exists)
and slice 2's eviction seam (exists). Slice 5 needs this slice's local
selection for mouse-precedence proofs; slice 7 needs it for selection
rendering.

Verified premises (against `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`):

- The projection engine is `projectedHistoryText`/`appendProjectedText`
  (:392, :2195): soft-wrapped rows project all columns (interior and trailing
  padding as spaces), non-wrapped rows trim at last content, `spacerHead` and
  `wideTail` project nothing, `\n` only at hard boundaries.
- Width reflow (`resizeWidth` -> `reconstructLogicalLines`/`pack`, :607-:903)
  already computes per-cell source-key -> destination maps
  (`cellDestinations`, with trailing-padding and boundary fallbacks) to carry
  the cursor across reflow. This is exactly the attachment machinery anchors
  need; no parallel mechanism is required.
- Row identity by stream index (scrollback then viewport) is preserved by the
  scroll-off push, height-shrink displacement, and height-growth pull-back
  (rows migrate between arrays wholesale). It is destroyed by width reflow
  (whole stream rebuilt) and permuted by region scroll/IL/DL/RI
  (`moveAndFillRows` with `pushesToScrollback: false`).
- The scrollback tail row is content-mutated in place by exactly three
  helpers: `severScrollbackWrapClaim` (:2171), `restoreWrapClaimBeforeCursor`
  (:2181), and the scrollback arm of `clearPreviousSpacer` (:2245). All other
  scrollback rows are immutable until eviction, ED 3, pull-back, or reflow.
- Slice 2 left one eviction seam, `enforceScrollbackBudget()` (:421), and
  explicitly reserved a monotonic evicted-row counter for this slice (its
  RI7). `resizeWidth` ends by calling it (:702), so reflow can itself evict.
- ED 3 (:1421) clears scrollback outside that seam and resets the truncation
  flag.
- ESC intermediate sequences are currently absorbed without reaching terminal
  dispatch, so the DECALN invalidation proof also requires preserving the
  intermediate/final pair through `EscapeAbsorber` and `TerminalInputStream`.
- libvterm has no linear-selection or search cases: `t/40state_selection.test`
  is OSC 52 clipboard (slice 7 territory) and is not in the manifest's
  selected files; `references/alacritty` selection/search coverage is Rust
  unit tests with no adaptable recordings.

## Decision

- **D1. Engine-owned selection and search state.** Selection and the active
  search live in `Terminal`, like the cursor: mutating set/clear entry points,
  read-only projections, invalidation performed by the engine's own mutation
  paths. Caller-owned anchors cannot observe a mid-`feed` eviction, and
  slices 5 and 7 must be able to ask the terminal value what is selected.
  Public surface (names indicative, shapes contractual):
  - `setSelection(from:to:)` / `clearSelection()` taking positions in the
    current full-stream coordinate space (scrollback rows then viewport rows,
    by row and cell column) -- the same space `scrollbackRow(at:)` and
    `geometry` already expose; positions clamp into the stream and normalize
    off wide-cell tails at set time.
  - `selectionRange` (current-coordinate endpoints, for slices 5/7) and
    `selectedText` (`nil` when no selection; `""` is legal).
  - `beginSearch(_:)` (newest match), `searchNext()` (toward older),
    `searchPrevious()` (toward newer), `clearSearch()`,
    `activeSearchMatchRange`. The engine stores only the query and the
    current match -- no match list; Next/Previous scan on demand so
    navigation is correct against content that changed since `beginSearch`,
    and both return whether they moved (no wrap; failing navigation leaves
    the current match unchanged).
- **D2. Anchors are projection-unit boundaries in absolute-row space,
  remapped through reflow.** A selection or match is a half-open range of
  *boundaries between projection units*, not of cells: a boundary sits before
  or after a given cell in a given absolute row, and a hard line boundary is
  itself an addressable position, so a range covering only a hard newline (the
  `"\n"`-only match) is representable. The absolute row coordinate is
  monotonic evicted-row count + stream index -- the counter slice 2 reserved.
  Public set/clear entry points take cell positions and convert them to
  before/after-cell boundaries. Operations that move rows wholesale
  (scroll-off push, height shrink/growth migration) preserve anchors by
  construction; width reflow remaps the stored boundaries through the same
  cell-attachment machinery that carries the cursor, with the existing
  clamp-to-content fallbacks for cells reflow does not retain; endpoints on
  trailing blank rows stripped by height shrink clamp to the last retained
  row. Logical-line anchor coordinates were rejected (see RI1).
- **D3. Overwrite invalidation: row-level intersection.** Any mutation that
  changes the content or projection of retained rows clears the selection and
  the active search iff the mutated absolute-row range intersects theirs.
  Prints, REP, ICH/DCH/ECH, EL, ED 0/1/2, IL/DL, region scroll and RI
  rotations, DECALN, and the three scrollback-tail wrap-claim/spacer edits
  (attributed to that scrollback row) all count. Appending new rows,
  migrating rows between viewport and scrollback, cursor motion, SGR,
  projection-neutral mode changes, and tab-stop changes never count.
  Screen-switching modes are outside D3 entirely; D5 governs them. The check
  is an integer range compare
  performed only while selection or search state exists.
- **D4. Eviction clamps selection, clears search, at the single seam.**
  Inside `enforceScrollbackBudget()` (and ED 3, treated as evict-all with the
  counter advanced by the cleared row count): a selection whose start was
  evicted clamps to the first retained position; a wholly evicted selection
  clears; a search whose current match lost any row clears (a truncated match
  no longer matches). Reflow-triggered eviction composes remap-then-clamp
  because enforcement already runs after the rebuild. `selectedText` after a
  clamp is the retained suffix; `isHistoryHeadTruncated` stays the separate
  truncation signal and projections are never decorated.
- **D5. Selection and search clear exactly when the active projection is
  replaced.** The rule, not a list of sequences: a control that swaps or
  blanks the active screen invalidates anchors made against the projection it
  destroys. Concretely -- mode 47 is an unimplemented no-op in this engine and
  therefore always preserves; 1047/1049 clear whenever they actually enter,
  re-blank, or leave the alternate screen, and preserve when the request is
  redundant and the grid is untouched; DECSTR clears when it exits the
  alternate screen and preserves on the primary screen; RIS clears; resize
  while the alternate screen is active clears. While the alternate screen is
  active, selection and search operate normally over the active projection
  (scrollback plus alternate rows with the seam soft-wrap severed, matching
  `fullHistoryText`).
- **D6. Search walks cells, not the projected String.** Matching runs over
  the projection's unit stream derived directly from cells -- narrow/wideHead
  cells contribute their scalar run, projected padding contributes one space,
  spacerHead/wideTail contribute nothing, hard boundaries contribute `\n` --
  so match endpoints are unit-aligned by construction and map to anchors
  without reverse-offset bookkeeping. ASCII case folding applies to A-Z/a-z
  scalars only; every other scalar is exact (no normalization: precomposed
  and decomposed accents do not cross-match, and a bare `e` cannot match
  inside a decomposed accent cell). Soft wraps contribute no unit, so matches
  span them; a match crosses a hard boundary only where the query itself
  contains `\n`. Empty queries match nothing. Every occurrence is eligible,
  including overlapping ones: searching `aa` in `aaa` exposes two navigable
  matches, so match order is by start position, not by non-overlapping
  greedy scan.
- **D7. Selected text is a substring of the projection.** `selectedText`
  equals the contiguous substring of the active full-history projection lying
  between the endpoint images. Serialization rules are not restated anywhere:
  one projection walker serves both `fullHistoryText` and any sub-range.
- **D8. No new fixtures or manifest changes.** Behavioral Swift Testing
  suites only, using the slice 2 small-budget knob for eviction cases. The
  upstream inventory was checked: nothing adoptable exists (see Context);
  `40state_selection.test` remains for slice 7/8 disposition.

## Invariants

- **I1 (substring law).** `selectedText` is exactly the projection substring
  between the endpoints: soft wraps join with no separator, `\n` appears at
  precisely the included hard boundaries, selected written spaces and empty
  logical lines are preserved, and no selection or match boundary falls inside
  a grapheme cluster or wide cell. Padding is defined solely by the
  projection, never by a separate selection rule: padding units the projection
  emits (a soft-wrapped row's interior and trailing padding) are emitted when
  inside the range, and padding the projection omits (a non-wrapped row's
  trailing padding, padding-only trailing rows) is never emitted. No newline
  is emitted merely because a range ended.
- **I2 (attachment).** Operations that do not change the projection of the
  selected rows -- appended output, scroll-off push, height-resize migration,
  width reflow, cursor/mode/SGR/tab-stop changes -- keep anchors attached to
  the same logical occurrence, not merely to equal text: `selectionRange` and
  `activeSearchMatchRange` still designate the same projection-unit boundaries
  in the same logical content, so with duplicate occurrences of the query the
  active match cannot silently migrate to a different one. Where such an
  operation is width-invertible, the unclamped ranges return to their original
  endpoints.
- **I3 (overwrite invalidation).** Any mutation changing the content or
  projection of retained rows clears selection and search iff its mutated
  absolute-row range intersects theirs; scrollback-tail wrap-claim and spacer
  edits count as mutations of that scrollback row; non-intersecting mutations
  never clear. Screen replacement is outside this invariant's scope: I5, not
  the intersection rule, decides those.
- **I4 (eviction).** All eviction-driven selection/search maintenance happens
  at the slice 2 seam plus ED 3: selection clamps its start to the first
  retained position or clears when wholly evicted; a partially or wholly
  evicted current match clears the search; the absolute coordinate base is
  monotonic between resets so retained anchors never renumber.
- **I5 (screen switches).** Selection and search clear exactly when a control
  replaces or blanks the active projection: 1047/1049 transitions that
  actually switch or re-blank, DECSTR exiting the alternate screen, RIS, and
  resize while alternate is active. A redundant 1047/1049 *set* while already
  alternate still re-blanks the grid and therefore clears; a redundant *reset*
  while already primary leaves the grid untouched and therefore preserves.
  Controls that leave the grid untouched -- mode 47 in either direction,
  DECSTR on the primary screen -- preserve them. While alternate is active
  both operate over the active projection.
- **I6 (search semantics).** Search is literal, unit-aligned, ASCII-folding
  and otherwise scalar-exact over the active projection; matches span soft
  wraps, cross hard boundaries only where the query contains `\n`;
  `beginSearch` selects the newest match; Next moves strictly older, Previous
  strictly newer; both stop at the ends without wrapping and report failure
  without moving.
- **I7 (transparency).** Selection/search state is default-empty and
  unreachable via `feed`; every existing fixture replay and chunk-invariance
  result is byte-identical; equal `Terminal` values answer every new query
  equally; all new state is semantic (no caches influencing `Equatable`).

## Proof obligations

- **PO1 (I1).** Serialization: selection across a soft wrap (no separator),
  across a hard boundary (`\n`), selected written spaces, an empty logical
  line inside a selection, reversed endpoint order, single-cell selection, and
  agreement with the corresponding `fullHistoryText` substring. Padding both
  ways against the same projection rule: a selection spanning a soft-wrapped
  row's trailing padding into its continuation emits those spaces, while a
  selection ending past a non-wrapped row's last content emits none.
- **PO2 (I1).** Cluster atomicity: precomposed and decomposed Spanish, CJK
  wide cells (endpoint on a tail snaps to its head; never half a character),
  and an emoji ZWJ sequence each select and serialize as one unit.
- **PO3 (I6).** Search: case-insensitive ASCII both directions; non-ASCII
  exactness (no precomposed/decomposed cross-match; no match inside a
  cluster); newest-first initial match; Next/Previous ordering over multiple
  matches; stop-at-ends both directions without moving; a match spanning a
  soft wrap (including one continuing through projected padding of a wrapped
  row); no match across an unrequested hard boundary; a query containing
  `\n` matching across one; a query that is only `\n`; overlapping
  occurrences all navigable; empty query; failed `beginSearch` leaves no
  state.
- **PO4 (I2).** Reflow attachment: a width shrink -> grow -> original
  round-trip restores unclamped `selectionRange` and `activeSearchMatchRange`
  to their original endpoints, not merely to equal text -- including a history
  containing several identical occurrences of the query, where the active match
  must still be the same occurrence; repeated width changes; endpoints on
  interior padding of a wrapped line survive; an endpoint on cells reflow does
  not retain clamps to content.
- **PO5 (I2).** Height changes: shrink displacing selected rows into
  scrollback and growth pulling them back preserve `selectedText`; an
  endpoint on a stripped trailing blank row clamps.
- **PO6 (I3).** Overwrite: every distinct mutation path D3 names as counting
  -- prints, REP, ICH/DCH/ECH, EL, ED 0/1/2, IL/DL, region scroll and RI,
  DECALN, and the scrollback-tail wrap-claim/spacer edits -- is exercised
  both intersecting (clears) and non-intersecting (preserves), so a missing
  hook fails a test rather than passing silently. Also: the paths D3 names as
  never counting (scroll-off push of new output, viewport/scrollback
  migration, cursor motion, SGR, projection-neutral mode changes such as
  DECAWM/DECTCEM, and tab-stop changes) preserve -- screen-switching modes
  belong to PO8, not here; and
  with a selection and a search match on different rows, a mutation
  intersecting one clears only that one.
- **PO7 (I4).** Eviction with the small-budget knob: partial eviction clamps
  and `selectedText` equals the retained suffix; whole eviction clears; an
  evicted current match clears search; eviction triggered by width reflow
  clamps after remap; ED 3 behaves as evict-all.
- **PO8 (I5).** Screen transitions, each arm of the D5 rule: 1047/1049 enter
  and exit clear; a redundant set while already alternate clears (it re-blanks)
  and a redundant reset while already primary preserves (guarded no-op);
  mode 47 in both directions preserves; DECSTR clears on the
  alternate screen and preserves on the primary; RIS clears; resize during
  alternate clears. Plus: selection and search operate over alternate rows
  while active.
- **PO9 (I7).** Transparency: the existing fixture corpus and manifest pass
  with zero edits; a terminal driven to an equal value by different chunkings
  answers selection/search queries identically.
- **PO10 (I1-I6).** A seeded deterministic sweep interleaving output,
  resizes, selection, and search asserts per step: any surviving
  `selectedText` is a substring of the current projection, endpoints are
  never inside a cluster or wide pair, and any surviving match still equals
  the query under D6 folding.

Slice exit gate: `just test` green (all packages plus lint scripts), plus a
checked Milestone 6 slice 4 sub-bullet in `plan-terminal-engine/14-roadmap.md`
linking the promoted plan.

## Non-goals

- Mouse/keyboard selection gestures, mouse-report encoding, Shift overrides,
  capture-vs-local precedence (slice 5 consumes this API).
- Viewport offset, scrolling, wheel behavior, and the viewport anchor
  (slice 6).
- Selection rendering, per-row render-range queries, damage, links, OSC 52
  clipboard (slice 7); `40state_selection.test` disposition stays with
  slice 7/8.
- Regex, whole-word, locale-aware, or normalization-insensitive search;
  match counts or highlight-all.
- Block/rectangular selection; word/line (double-click) expansion.
- Persisting selection or search state (06 non-goal).

## Accepted risks

- **AR1.** Row-level invalidation clears selections a cell-level rule would
  keep (e.g. a status redraw touching a selected row). Accepted: the check is
  O(1), and refining later only loosens observable behavior.
- **AR2.** Search scans are O(history x query) per operation over a 10 MiB
  history. Accepted initially; navigation stops at the first hit and
  incremental strategies remain open.
- **AR3.** While selection or search exists, mutation paths pay one integer
  range compare per printed cluster commit; a nil check otherwise. Accepted.
- **AR4.** The absolute coordinate base resets with RIS; it is internal and
  only monotonic between resets. Documented at the counter.

## Rejected ideas

- **RI1.** Logical-line anchor coordinates ("stable across reflow by
  construction"): viewport soft-wrap flags churn under prints, erases, and
  `moveAndFillRows`, splitting and merging logical lines, so line indices are
  volatile exactly where selections start; making them safe requires a
  volatility tier boundary plus fractional-eviction unit counters, and
  mapping viewport cells to line coordinates is O(history). Absolute-row
  anchors get reflow attachment from machinery that already proves the
  cursor's contract.
- **RI2.** Searching the projected `String` and reverse-mapping offsets:
  multi-scalar clusters make scalar offsets ambiguous against cells; the
  duplicate offset bookkeeping is the class of bug the single-projection
  contract exists to prevent.
- **RI3.** Caller-owned anchors with validity queries: pushes named core
  policy into the session layer and cannot observe mid-`feed` eviction.
- **RI4.** A cached match list: stale under every `feed`; on-demand
  Next/Previous scans are naturally correct.
- **RI5.** Clearing selection on eviction instead of clamping: hostile to
  large scrollback selections during streaming output, and 05's
  truncated-line rule is clamp-shaped.
- **RI6.** Persisting selection across alternate-screen switches: the
  projection the selection was made against (severed seam, alternate rows)
  ceases to exist at the switch.

## Implementation discretion

- Internal anchor, counter, and search-state representation, provided all
  state entering `Equatable` is semantic.
- Search scan strategy and any incremental optimization under AR2.
- Endpoint normalization details beyond the contractual clamps (wide-tail
  snap, stream clamp).

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- selection, search,
  attachment, and invalidation policy.
- `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift` and
  `TerminalInputStream.swift` -- preserve ESC intermediates for the promised
  DECALN mutation path.
- `lib/TerminalCore/Tests/TerminalCoreTests/` -- new selection and search
  suites; the slice 2 budget-knob pattern for eviction cases.
- `plan-terminal-engine/14-roadmap.md` -- checked slice 4 sub-bullet at exit.

## Implementation notes

- DECALN needed the parser's already-bounded ESC intermediate collection to
  survive into terminal dispatch; unsupported intermediate sequences remain
  inert.

## Follow Up

- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:244`:
  investigate the pre-existing `TerminalPaneSessionControllerTests`
  `EXC_BAD_ACCESS` while `planIfNeeded` copies a `Terminal`; the crash recurs in
  the full gate and controller-only run, predates this change in local crash
  reports, while `TerminalPTYHostTests` passes in isolation.
