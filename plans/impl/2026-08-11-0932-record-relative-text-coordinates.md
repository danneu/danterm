# Search matches are keyed to content, not to display geometry

## Problem

Retained history is width-invariant by construction: one logical line is one
record, and no stored byte depends on the pane's width (`research/31/I1`). The
search index over that history is not. It stores every match as a pair of
absolute display rows, so a width change renames all of them even though no
text changed, and `resizeWidth` ends by rebuilding the index from a fresh walk
of retained history. That rebuild is the only full rebuild left in the search
path -- output, eviction, and tail truncation are all incremental already.

The rebuild has a visible cost: dragging a window edge with the find bar open
pays a history-depth walk per width step. The structural cost is larger. Every
mechanism that keeps the index honest exists because its coordinates describe
where text is drawn rather than what text it is:

- The immutable prefix is denominated in display rows, so its boundary can
  regress three different ways, and a regression rebuilds a carried window of
  units by walking backwards over rows already scanned.
- Head eviction, tail truncation, and the width rebuild are three separate
  responses to the two things the store actually does: drop content at the
  head, drop content at the tail.
- The width-change path captures the durable search position against the old
  fold and restates it against the new one, as one of eight held anchors.

Underneath all of it sits a live correctness defect, recorded as an accepted
risk when the streaming scan shipped and never fixed. A record's projected text
is not yet a function of its content alone: a record cut by the forced-split
cap and carrying a background-erase fill projects a run of trailing spaces
whose length follows the width. The same history therefore yields different
copied text and a different match set at different widths, which contradicts
`docs/design/2026-08-06-swift-terminal-engine.md E1` on the copy path as much
as on the search path.

Two further premises this plan rests on, both read out of the current tree
rather than assumed:

- A record's identity today is derived from its position in the retained
  sequence. Dropping the tail record does not retire that number, so the next
  record admitted reuses it. Nothing stores a match against it yet, so nothing
  is broken today; a stored coordinate would make the reuse reachable.
- Head eviction trims the oldest record one display row at a time, moving every
  surviving cell in that record closer to its front, while the record's own
  identity side table already keeps its original keys and rebases on read.

## Decision

Search matches move into **record-relative coordinates**: a match names the
record its text lives in and the offsets inside that record, so a width change
cannot invalidate one. Display rows are computed from those coordinates when a
frame is planned, for visible matches only. Nothing else about search changes.

Three constraints make this decisive rather than a representation swap:

- **Record identity costs no per-record storage.** `research/31/D2` Decision 1
  prices a blank logical line at eight arena bytes plus eight index bytes, and
  the retained depth a pane gets at the 16 MiB budget
  (`docs/design/2026-08-06-swift-terminal-engine.md D5`) rests on that
  arithmetic. Identity may not widen a record.
- **The index covers closed records only.** The open record and the live grid
  stay display-row keyed and rescanned on each read, bounded by the
  forced-split cap exactly as today. This is what answers the objection
  `research/31/D3` Decision 2 raised against record-addressed anchors, and the
  reason this plan does not reverse that decision: a user-held anchor keyed to
  a record would have to be converted as each live row is admitted, on the
  write path where the store's own admission falsifier lives. A match index
  converts nothing there, because it only ever covers records that have already
  closed -- and the scan that produces its coordinates already runs at exactly
  that moment.
- **The record's projection lands first.** A record whose projected text still
  depends on the width has no fixed match set to store, so defining that
  projection from the record's content alone precedes the index change, and the
  identity contract lands with it or before it. The same definition serves copy
  and search, which is what makes the fix an E1 restoration rather than a
  search-local patch.

What this deletes: the reflow rebuild of the whole index; the display-row
prefix boundary together with its three regression cases and the backward walk
that rebuilds a window after one; and the second definition of a record's
projected text that copy and search maintain separately today.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
`LogicalLineStore.swift`, `LogicalLineRecord.swift`,
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSearchTests.swift`.

### The ideal beyond this plan

The end state this is a slice of is one content coordinate for the whole
stream, with no width-dependent position stored anywhere: the selection, the
hover and arm ranges, the browsing top, and the drag pin all move with the
matches, the width-change restatement disappears outright, and retiring pinned
ranges narrows from "any reflow" to a hard reset or a screen replacement.

It stays out of this plan because it owes a coordinate the engine does not
have. History has records; the live grid has none, and reflow genuinely rebuilds
it. Every one of those anchors can sit in the live region, so the follow-up has
to answer what identifies a still-forming logical line before it can move a
single anchor -- and that answer is worth designing against measured need, not
inherited from the search index. Naming it here keeps it a decision rather than
an omission.

## Invariants

- **I1.** A record's projected text is a function of its stored content alone.
  Full-history text and the ordered match set for the same content are
  identical at every width, copy and search alike, including a record cut by
  the forced-split cap and carrying a background-erase fill.
- **I2.** A stored match coordinate names the same text for as long as that
  text is retained, and can never come to name different text. Content leaves
  only at the head and at the tail; a coordinate whose text left is
  invalidated, never retargeted onto other text
  (`docs/design/2026-08-06-swift-terminal-engine.md G9`).
- **I3.** A width change rescans no record that survives it. The work a width
  change spends on search does not grow with retained depth. Records the width
  change drops or reopens at the seam lose their matches and are rescanned when
  their content is next admitted and closed.
- **I4.** Head eviction rewrites no surviving match coordinate, so index
  maintenance per evicted display row stays independent of how many matches
  history holds.
- **I5.** A match that spans a forced-split seam, or a hard boundary requested
  by the needle, is one match: at every width it is reported once, as a single
  contiguous cell range. The range's geometry follows the width; the occurrence
  and its record-relative endpoints do not.
- **I6.** Which occurrence the durable search position resolves to does not
  depend on the pane's width. Nearest occurrence, ties resolved toward the
  later one, as today.
- **I7.** Per-frame highlight cost stays independent of retained depth, and a
  planned frame still performs at most one display-row locate
  (`research/31/D3` Decision 1).
- **I8.** Search semantics are unchanged: literal matching over whole graphemes
  under canonical caseless folding, spanning soft wraps but not an unrequested
  hard newline, newest match first, wrapping at both ends
  (`docs/design/2026-08-06-swift-terminal-engine.md E5`, `E6`).

## Proof obligations

- **PO1.** I1 -- the same fed content at two widths produces byte-identical
  full-history text and an identical ordered match set. The corpus includes a
  forced-split record carrying a background-erase fill, which is the case that
  fails today. For that record the assertion is the exact expected copied text
  and the exact expected match set, with the erase-fill trailing spaces absent,
  so a projection that agrees across widths but is wrong at both cannot pass.
- **PO2.** I2 -- the index agrees with an independent full rescan after every
  store mutation the engine can produce, including a tail drop followed by
  fresh admissions that would reuse a positionally derived identity, and a head
  trim that cuts through a match's start. The existing cross-mutation oracle is
  the starting point; it does not cover identity reuse.
- **PO3.** I3 -- at two retained depths, both the display rows a width change
  projects and the search-index maintenance work it performs are measured, and
  neither grows with depth, with no whole-stream projection at either. The
  maintenance measure counts every stored match the width change visits, so a
  walk or rewrite of the whole index registers even when no row is projected;
  a width change that disturbs no seam record is expected to measure zero. A
  separate seam-moving width change measures non-zero, which is what shows the
  instrument is live rather than always reporting nothing.
- **PO4.** I4 -- per-evicted-row index maintenance is unchanged between a needle
  that matches nothing and one that matches most retained lines.
- **PO5.** I5 -- a needle spanning a forced-split seam, and a needle containing
  a hard newline, each report exactly one match. Across a width change the same
  logical occurrence is still the one reported, with the same record-relative
  endpoints, and its reported cell range equals the correct contiguous geometry
  for that text at each width.
- **PO6.** I6 -- the same position over the same content resolves to the same
  occurrence at two widths, including a position lying between two occurrences.
- **PO7.** I7 -- the existing per-frame locate and projection-row assertions
  keep passing, exercised at more than one retained depth.
- **PO8.** I8 -- the existing independently segmented projection oracle keeps
  passing, and is exercised at more than one width.
- **PO9.** The inspection and recovery characterization corpus still replays,
  and the persistence projection's own contract
  (`docs/design/2026-08-06-swift-terminal-engine.md E8`) is unchanged by the
  projection fix.
- **PO10.** Record identity costs no per-record storage -- at a fixed memory
  budget, the settled blank-history depth a pane retains, and the storage
  charged per record, are unchanged from the record-cost contract identity must
  respect (`research/31/D2` Decision 1: eight arena bytes plus eight index
  bytes). A widened record index or a per-record side table fails this.

## Non-goals

- The selection, hover and arm ranges, the browsing top, and the drag pin stay
  on absolute display rows, and the width change keeps restating them.
  Narrowing which mutations retire a pinned range goes with them.
- The durable search position stays where those anchors are; see RI1.
- No change to needle syntax or search semantics: no regex, whole-word, or
  locale-sensitive matching (`docs/design/2026-08-06-swift-terminal-engine.md
  E12`).
- No change to the overlay, its brightness ladder, the counter, or any
  rendering.
- The open record and the live grid stay display-row keyed and rescanned per
  read.
- No new workload in the `just benchmark-*` ladder.

## Accepted risks

- **AR1.** The index's correctness now rests on a contract the store publishes
  rather than on a coordinate the reader can re-derive from the stream, and a
  wrong index means wrong highlights rather than a stale count. Mitigated by
  PO2's oracle covering every mutation, and by a needle change rebuilding from
  scratch so no error outlives the current needle.
- **AR2.** Fixing the projection leak changes copied text and reported matches
  for a record cut by the forced-split cap and carrying a background-erase
  fill. That is deliberate -- it is the E1 violation -- and PO9 is the gate on
  it reaching saved history.
- **AR3.** Translating a record coordinate to display rows is new per-visible-
  match work on the frame path. It is bounded by the viewport rather than by
  depth, and I7's counters are what hold it there.
- **AR4.** The mutable suffix is still rescanned on each read, so one logical
  line near the forced-split cap still costs a bounded rescan per read. This
  plan neither improves nor worsens it.

## Rejected ideas

- **RI1. Move the durable search position into a record coordinate too**, which
  would delete its slot in the width-change restatement. The position is a
  user-held anchor of the same kind as the selection, and `research/31/D3`
  Decision 2 keeps those on absolute display rows so nothing has to convert on
  the admission path. Splitting search's position away from the selection's
  would put one kind of thing in two coordinate systems to save one of eight
  slots. It returns with the follow-up above, where every anchor moves or none
  does.
- **RI2. Restate display-row match coordinates arithmetically at the width
  change** instead of changing what is stored. That is the compensating
  machinery this plan exists to remove: it keeps geometry as the key and adds a
  fourth rule for keeping it honest.
- **RI3. Give every record an explicit stored id.** The record header word is
  full, and `research/31/D2` Decision 1 prices a blank record at eight arena
  bytes plus eight index bytes; widening a record trades retained depth for a
  number the store can already derive.
- **RI4. Key the live region by content as well.** Reflow rebuilds the live
  grid by construction, and its rescan is already bounded by the forced-split
  cap, so a content coordinate there buys nothing for the problem this plan
  states.

## Implementation discretion

- How record identity is represented, and how the store publishes the head
  record's trim so that a surviving coordinate does not have to move.
- How a visible match is translated into display rows on the frame path, given
  I7.

## Commit progress

- [x] 1. Establish width-invariant record projection and stable record
  coordinates -- `caeb7d3a`
- [x] 2. Index closed-history search matches by record coordinates --
  `2bf55fe6`
- [x] 3. Post-implementation hardening from the perf review -- `8425340e`

## Implementation notes

- The current tree already separates content rows from painted rows, so trailing
  background-erase fill was absent from copy and search before this slice. The
  forced-split regression corpus now pins the exact text and match behavior at
  two widths instead of adding a second projection path.
- Record identity shares the existing 8-byte offset entry: the arena capacity
  determines the offset bits and the remaining bits hold a monotonic ordinal.
  If that ordinal space is ever exhausted, the store retires all history and
  advances an epoch before admitting another record, so an old coordinate can
  never resolve to new text.
- The closed-history index keeps record endpoints unresolved, and nearest-match
  ties count projected content units instead of width-dependent hard-line
  padding. As of `2bf55fe6` the ordered reads still resolved coordinates inside
  their binary searches; the discipline of resolving only returned matches
  landed in `8425340e` below.

### Post-implementation hardening (`8425340e`)

A perf review of `2bf55fe6` found the read and build paths spending the cost
the plan's invariants bound, unobserved because no counter fired on coordinate
resolution:

- Ordered reads compared stored matches by resolving them into display
  geometry -- a record fold per binary search probe, so I7's depth independence
  failed while PO7's locate assertion stayed green. Reads now convert the query
  point once, compare record coordinates directly, and resolve only the matches
  they return. A new `RecordPositionResolutionCounter` fires on every
  resolution, and a frame-cost test pins resolutions and locates as equal at
  two retained depths.
- The index build materialized every record's cells and asked the store to
  derive each cell's coordinate twice, though identity and trim base are
  per-record constants. The build now streams kinds and scalars from the packed
  arena words (`ClosedRecordScan` / `forEachClosedRecordCell`, the width-free
  counterpart of `withPaintedCells`) and states coordinates arithmetically. A
  new `RecordCellMaterializationCounter` and a two-depth test pin the build at
  zero materializations.
- The match snapshot held a second live reference to the store on every read --
  the arena copy hazard `research/31/F13` measured. It now holds only the two
  match halves.
- `RecordIdentity` packed its retirement generation beside the ordinal into one
  word, returning a coordinate to 16 bytes and a stored match to 32, with the
  store's own no-reissue property intact and no staleness check at call sites.
  A layout test pins the strides.

Residual, carried rather than hidden: when the durable position does not sit on
an occurrence, the nearest-occurrence distance walk is bounded by the gap
between the two bracketing occurrences -- not by the viewport. Closing it needs
the cumulative content coordinate named in "The ideal beyond this plan"; the
ideal is also recorded on `searchDistance`'s doc comment.
