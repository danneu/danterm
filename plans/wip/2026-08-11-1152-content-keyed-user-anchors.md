# Every user-held anchor is keyed to content, not to display geometry

## Problem

Every durable user-held position in the engine is still an absolute display
row: the selection, the durable search position, the hover and arm link
ranges, the browsing top, and the drag pin. Display rows describe where text
is drawn, not what it is, so three defects follow:

- **The width-change restatement pipeline.** Because a width change renames
  every display row, `resizeWidth` runs a capture/rebase/restate machine over
  eight anchor slots, under an ordering invariant that lives only in a comment
  (capture must read the old fold, which exists only until the index is
  recomputed). The seam pull-back needs its own address-rebasing special case,
  and the pipeline's fallback for an unresolvable address clamps to a row head
  instead of the exact cell. Eviction can also run after restatement inside
  the same resize, leaving the eviction clamp as the only guard. This is
  compensating machinery for a representation defect -- the same machinery the
  search index already escaped when its matches moved to record coordinates,
  and that plan names this refactor as its ideal beyond.
- **Pin retirement over-breadth.** The drag pin cannot be captured by the
  restatement loop, so `resizeWidth` renumbers rows and retires every
  outstanding pin on any width change. Retirement should mean the text is
  gone, not that it re-wrapped.
- **The `searchDistance` residual.** Nearest-occurrence resolution walks
  projected content units between the two bracketing occurrences -- bounded
  by that gap, not by the viewport. Its own doc comment names a cumulative
  content coordinate as the fix.

Premises read out of the current tree, not assumed:

- Closed history already has stable, never-reissued, head-trim-rebasing
  record identities, and search matches already live in them. What is missing
  is that identity before the content closes into history.
- Retained content leaves the store only at the head (eviction) and at
  clear; tail truncation and the width-change seam pull-back always hand
  cells back to the live grid, so the line they belong to survives.
- Lines born above existing lines are ordinary input, not a corner case:
  reverse index at the top, `CSI T`, insert-lines, a partial scroll region
  with rows below it, and a mid-grid wrap sever all do it. Any identity
  scheme that only survives the common bottom-birth case is wrong on `less`
  scrolling backward.
- Both store reopen paths currently retire the tail record's identity, and
  that retirement is what implicitly retracts stale search matches on reopen.
- The head-trim path preserves the head record's identity today only through
  an unasserted no-carry property of the packed index word.

## Decision

Every durable anchor becomes a content coordinate -- **content-segment
identity plus cell offset within the segment**, the segment being the unit
one record identity already names -- and the width-change restatement
pipeline is deleted. This supersedes `research/31/D3` Decision 2 ("the stored
anchor coordinate stays the absolute display row"; its "ten held anchors" are
today's eight slots). Its three objections are answered rather than waved
off:

- *Head-trim instability*: already solved by shipped mechanics -- the head
  trim keeps original cell-offset keys and rebases on read.
- *Per-admission conversion on the measured feed path*: dissolved by identity
  at birth. A segment carries one identity from the live grid into history,
  so admission, record close, and reopen convert nothing.
- *Comparable on the pointer path needs a refold*: dissolved by the order
  invariant below -- anchor comparison is a raw two-word compare.

`research/31/D3` Decision 1 (the frame-path contract) is **not** superseded;
its "no anchor cache" clause is restated as "a derived display position is
recomputed per anchor change or per refold event, never per read", which its
own rule 3 permits.

Five constraints make this decisive:

1. **Identity at birth, order by invariant.** Every primary-screen row is
   stamped with its content segment's identity when the segment starts
   forming, and the identity rides into history unchanged. At every mutation
   boundary, walking retained records head-to-tail and then live lines
   top-to-bottom yields strictly increasing identities (equal only among the
   rows of one still-open segment). A birth above existing live lines renumbers the lines
   below it -- an order-preserving restamp that rides the row-touching pass
   those events already perform -- and rewrites any anchor keyed to a
   renumbered segment in the same mutation. The store asserts monotonicity at
   admission and never repairs it: a violation is a Terminal bug that fails
   loudly. The store remains the single mint authority (ordinal space and
   epoch).
2. **Role-tiered coordinate contract.** Two orthogonal rules govern a
   coordinate. Storage decides whether the text under it can change: closed
   history is immutable; the live grid mutates in place. Anchor role
   decides the response when it does. A content assertion (a search match,
   a link range) is a claim about the text and invalidates when any cell
   under it is overwritten, wherever it points
   (`docs/design/2026-08-06-swift-terminal-engine.md G9`). A tracked
   position (a selection endpoint, the durable search position, the
   browsing top, a pin) holds a place: it keeps its cell boundary through
   in-place mutation -- exactly today's behavior, where a selection over
   live output copies the overwritten text -- and dies only when its text
   leaves: head eviction, clear, hard reset, screen replacement. Either
   kind may also be rewritten text-preservingly by a renumber, split, or
   merge in the same mutation that caused it. G9's current wording
   over-claims relative to shipped behavior -- overwrite already preserves
   a selection and drops only link state -- so the design doc is amended in
   the same change to state this role split.
3. **Identity continuity across the seam, both directions.** Reopening the
   tail record (resumed printing, or truncation bookkeeping) and handing
   cells back to the live grid preserve the segment's identity; both reopen
   paths stop retiring it. The duty that retirement performed -- retracting
   the reopened record's stale search matches -- moves to explicit
   retraction in the index-maintenance path, landing in the same commit.
   This is also what makes the seam pull-back exact: an anchor in the open
   tail segment resolves into its live continuation with no special case.
4. **Frame and pointer arithmetic preserved.** `scrollProjection` stays
   two-integer arithmetic (the browsing top keeps a display-row shadow,
   adjusted by integer deltas at mutation time and equal to its resolved
   position at every frame boundary). A planned frame still performs at most
   one display-row locate, and per-frame coordinate resolutions are bounded
   by the anchors actually visible. Anchor ordering is a raw compare on
   (identity, offset), sound by constraint 1.
5. **Cost lands where anchors are.** With no anchors held, the feed path
   gains one stamp comparison per admitted row and one counter increment per
   segment birth, and nothing else; renumber, split, and merge anchor work is
   gated behind "any anchors outstanding". The existing feed benchmarks and
   the admission probe are the falsifiers.

The identity unit is the **content segment**: the stretch of one logical
line that one record identity represents. A segment starts in the live
grid and survives admission, close, reopen on either path, head trim, and
the seam hand-back. A forced split ends the segment and mints a strictly
larger successor, restamping the line's live remainder and rewriting
anchors past the split boundary in the same mutation -- the same
text-preserving rewrite channel renumbering uses. Anchors and search
matches therefore share one coordinate representation and one
binary-search contract; only their tier semantics differ, and evicting one
segment never strands a coordinate in a later segment of the same line.

What this deletes: the eight-slot capture/rebase/restate pipeline and its
three helper walks; `renumberRows()` from the width change (pins survive
reflow); the seam-rebasing special case; and `searchDistance`'s gap walk
over closed history. What survives untouched: the live refold and cursor
anchoring (`reconstructLogicalLines`/`pack`), whose cursor contract
(`docs/design/2026-08-06-swift-terminal-engine.md D7`) already anchors the
cursor to its logical cell boundary. Two behaviors the deleted pipeline
carries move, not vanish: the collapsed-selection rule (an erased selection
must not survive reflow as a zero-length range) is restated at resolution
time, and the seam fallback becomes exact by constraint 3.

This plan completes the "ideal beyond" named by the record-coordinate search
plan: after it, no width-dependent position is stored anywhere in the engine.

## Invariants

- **I1 (role-tiered contract).** A content assertion (match, link range)
  names the exact text it was minted over: it never retargets, and an
  overwrite of any cell under it invalidates it, in live and closed text
  alike. A tracked position (selection endpoint, search position, browsing
  top, pin) keeps its cell boundary through in-place mutation -- content
  overwritten under a selection is copied as overwritten -- and is
  invalidated only by its text leaving. A renumber, a split (sever or
  forced), or a merge rewrites affected coordinates text-preservingly
  within the same mutation, never observably.
- **I2 (order).** After every mutation, retained records head-to-tail
  followed by primary live lines top-to-bottom carry strictly increasing
  identities (equal only among the rows of one still-open segment), so the
  store's binary searches and raw anchor comparison are valid by
  construction. The store asserts this at admission.
- **I3 (coordinate non-events).** Admission of a row, record close, record
  reopen on either path, tail-truncation hand-back, and the width-change
  seam pull-back change no held coordinate's meaning and drop no anchor.
- **I4 (width change moves no anchor).** `resizeWidth` captures nothing,
  restates nothing, and renumbers nothing. Every anchor -- including one in
  the open tail line cut by the seam, and every outstanding pin -- denotes
  the same text before and after any width change. Width-change anchor work
  is recomputing at most one derived display position per held anchor.
- **I5 (eviction semantics unchanged, per anchor).** Selection fully evicted
  is dropped; partially evicted clamps its start to the retained head and
  never its end. Hover and arm drop when their start evicts. The browsing
  top clamps and converts to following at the maximum top. The durable
  search position is absorbed read-side. Pins clamp at read time. Clear-all
  flows through this same path, so pins survive it.
- **I6 (pin retirement narrowed).** The row-numbering epoch bumps only on
  screen replacement and hard reset.
- **I7 (frame path).** `scrollProjection` performs no index lookup and no
  fold; a planned frame performs at most one display-row locate, invariant
  to retained depth; coordinate resolutions per frame are bounded by visible
  anchors; a resolution is paid per anchor change or refold event, never per
  read. The browsing top's shadow equals its resolved position at every
  frame boundary.
- **I8 (identity hygiene).** No identity is ever minted twice with different
  meaning. Terminal-held identities carry their mint-time epoch; ordinal
  exhaustion wipes history, renumbers live lines, and retires every anchor
  in one mutation. The head trim already preserves the head record's identity
  structurally, through the packed-word accessor rather than an unasserted
  no-carry property, as of commit `123a0ce4`; this plan only inherits it.
- **I9 (storage and publish cost).** Per-record charge stays 8 arena bytes
  plus 8 index bytes. The per-row stamp lives inside the already-copied rows
  array; no new state holds a second store reference; nothing new is touched
  per pointer event; whole-value equality stays cheap. New anchor-derived
  state (the resolve caches and the browsing shadow) adds no
  reference-counted storage to `Terminal`: it is plain value data, so a
  per-frame publish copy pays no retain/release for it.
- **I10 (feed cost).** Per admitted row, the write path gains O(1) work when
  no anchors are outstanding; renumber, split, and merge anchor repair is
  gated behind an O(1) anchors-outstanding check.
- **I11 (distance).** Nearest-occurrence distance over closed history is
  independent of retained depth and of the gap between occurrences, via
  content-unit prefix sums at the store's existing block granularity; unit
  counts are width-invariant, so a width change maintains nothing. Which
  occurrence the durable position resolves to stays width-invariant.

## Proof obligations

- **PO1 (I1).** The existing overwrite-preserves-selection, hover-overwrite,
  and stripped-blank-endpoint tests stay green. New: a selection into closed
  history is byte-stable under any live mutation; the same selection over
  live text copies the mutated text; a renumber, split, and merge each leave
  every affected anchor resolving to identical text.
- **PO2 (I2).** A property test drives randomized operation sequences --
  scroll regions, insert/delete lines, reverse index, `CSI T`, wrap sever
  and restore, resize -- and checks the order invariant by walking store and
  grid after every step, and checks raw anchor comparison against resolved
  display order.
- **PO3 (I3).** Store tests pin identity across both reopen paths, a full
  admit-close-reopen-admit cycle, the empty-open-record discard at the arena
  seam, and the truncation hand-back. A Terminal test pins an anchor set in
  a live line across that line's admission and close. The cross-mutation
  search oracle is extended with same-identity reopen, which is what guards
  the explicit-retraction duty. A forced split rewrites anchors past the
  boundary text-preservingly, and an anchor and a search match in a
  successor segment survive eviction of the preceding segment.
- **PO4 (I4).** The existing resize-attachment, browsing-anchor,
  collapsed-selection, and width-invariant-match tests stay green. New: an
  anchor in the open tail line survives a width change exactly (the case
  today's fallback clamps); a pin survives a width change and resolves to
  the same text. The seeded inspection sweep is extended with sever,
  restore-wrap, and forced-split events.
- **PO5 (I5).** The existing eviction tests for selection, browsing, hover,
  and the drag pin carry this wholesale, amended only where they construct
  epoch assumptions.
- **PO6 (I7).** The frame-locate suite and the
  resolutions-equal-locates search test stay green. New: a width change with
  all slots held performs at most one resolution per anchor, counted; frames
  while anchors are held and nothing changes perform zero resolutions; the
  browsing shadow equals its resolved position across a mutation storm.
- **PO7 (I8).** Identity-reuse and exhaustion tests are extended: exhaustion
  retires live segment identities and anchors. The head trim's own regression
  test, resolving a stored coordinate in a trimmed head record, shipped with
  `123a0ce4` and stays green.
- **PO8 (I9, I10).** The record-coordinate stride and blank-depth pricing
  tests stay green; a layout assertion covers any new per-anchor state,
  including that it holds no references (`_isPOD` on the anchor-state
  type). The feed benchmarks and the admission probe are re-run and not
  slower under the frozen decision rules.
- **PO9 (I11).** A distance work counter is measured at two depths and two
  occurrence gaps and is independent of both; the block sums agree with an
  independent full recount after every store mutation; the
  nearest-occurrence width-invariance test stays green.
- **PO10.** The inspection and recovery characterization corpus still
  replays; persistence stores text only, so this is confirmation, not
  migration.

## Non-goals

- The public coordinate type and every IPC/persistence surface are
  unchanged; nothing outside the engine stores positions durably.
- Content coordinates describe the primary stream only. Alternate-screen
  selection stays display-keyed and keeps dying on transitions and
  alt-screen resize; alt rows carry no identity.
- The search suffix over the live region stays display-keyed and rescanned
  per read; the durable search position migrates with the other anchors.
- No change to search semantics, rendering, the overlay, or the benchmark
  ladder.

## Accepted risks

- **AR1.** A missed anchor-rewrite site at a renumber, split, or merge event
  is a dangling anchor rather than a compile error. Mitigated by routing
  every rewrite through one channel and by PO1/PO2's property coverage.
- **AR2.** Preserving identity across reopen removes the implicit search
  retraction; the explicit retraction and the reopen change must land in the
  same commit or stored matches misresolve into a line being rewritten. PO3
  is the gate.
- **AR3.** Drag-pin resolution becomes a bounded point read per pointer
  event instead of pure arithmetic. Small against the drag budget; cacheable
  if measured otherwise.
- **AR4.** A pathological writer mutating an anchored live line every frame
  pays a bounded, viewport-limited re-resolve per frame.
- **AR5.** Ordinal exhaustion (test-hook territory at the 40-bit production
  budget) now also retires anchors, alongside the history wipe it already
  performs.

## Rejected ideas

- **RI1. Cumulative stream-offset anchors** (one global content offset per
  anchor): a live edit that shrinks one line shifts every later offset --
  cross-line retargeting onto unrelated text, exactly what G9 forbids.
- **RI2. Convert-at-close** (display-keyed while live, converted at
  admission): recreates the admission-path objection this plan dissolves,
  and makes close a coordinate event again.
- **RI3. Lazy identities with cached-row comparison** (identity only for
  anchored lines; ordering via per-anchor cached display rows): out-of-order
  births make raw comparison unsound, so ordering must route through caches
  whose invalidation is a new bug surface of exactly the kind this plan
  deletes; order-by-repair (renew-and-report at admission) replaces an
  invariant with a protocol. The eager stamp costs 8 bytes per live row
  inside an array the publish path already copies.
- **RI4. Gapped order-maintenance ordinals** (bisect on mid-grid birth):
  avoids renumbering but imports rebalancing and a second exhaustion regime
  measured in millions, not trillions, of lines.
- **RI5. Partial migration** (browsing top or any slot stays display-keyed):
  one kind of thing in two coordinate systems; G7 already words the browsing
  top as a stable logical position. All anchors move or none does.
- **RI6. Dense per-record distance side table**: ~40 bytes per record
  against a per-record contract of 16; block-granularity sums cost a
  fraction of a byte per record inside the existing metadata reserve.

## Implementation discretion

- Renumber mechanics: transient old-to-new map versus per-anchor compare
  during the restamp walk; batch-mint API shape.
- Resolve-cache and browsing-shadow representation, and the generation
  granularity that invalidates them, within I7 and I9.
- Prefix-sum maintenance points for I11, within PO8's budget gates.

## Commit progress

- [ ] 1. Store identity lifecycle, store-internal only: split the shared
  reopen body so neither path retires identity, paired in the same commit
  with explicit search-index retraction; rewrite the head-trim index write
  through the packed accessor with a pinning test; lift the open-record
  gate on minting a text coordinate. (PO3 store half, PO7 store half.)
- [ ] 2. Row stamps, mint authority, and the order invariant: per-row
  segment stamps on the primary grid, store-minted; renumber-below at
  above-existing births; forced-split successor reporting and restamp;
  identity continuity through the truncation hand-back and the
  empty-open-record discard; admission asserts monotonicity and uses the
  row's stamp; property tests and feed benchmarks. (PO2, PO3 seam half,
  PO8.)
- [ ] 3. Resolution and comparison layer: content-anchor type, raw ordering,
  resolve composing the store's record position with live-row folding
  across the seam, per-anchor caches and the browsing shadow, eviction
  gate. No anchor migrated yet. (PO6 machinery, PO7 Terminal half.)
- [ ] 4. Anchor migration and pipeline deletion: all slots move; the
  restatement pipeline, its types, and the width-change renumber are
  deleted; collapsed-selection and eviction rules restated in content terms;
  the G9 tier amendment lands in the engine design doc with the behavior;
  seeded sweep extended; recovery corpus replayed. (PO1, PO4, PO5, PO10.)
- [x] 5. Distance prefix sums: block-granularity content-unit sums; the
  closed-history gap walk deleted. (PO9.)
