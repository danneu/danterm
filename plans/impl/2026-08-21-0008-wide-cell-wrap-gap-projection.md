# Wide-cell printing: BCE vacates, a derived wrap gap, and the DECAWM-off cursor

BUG-18, BUG-19, and BUG-20 from the construction audit
(docs/scratch/2026-08-18-construction-audit.md), re-verified on the tree at
`c6336f47` (after ROW-4 `c36da989` moved the print path onto
`prepareDestination`).

## 1. Problem and evidence

Three defects share `Terminal.swift`'s printing and pair-cleanup surface.

- **BUG-18.** A print that vacates a cell -- the other half of a wide pair it
  overwrites, the tail a VS15 downgrade frees, the neighbour a VS16 upgrade
  clears -- blanks it with the default style. Erase, ICH/DCH, and scroll reveal
  already paint a vacated cell with the background-erase pen. Probe:
  `ESC[44m 界 ESC[1G X` at 4x1 leaves (0,1) with background `.default`; ECH or
  ICH over the same pair leaves `.indexed(4)`.
  `TerminalCellStyleTests#structuralWideClearRemainsDefaultStyled` pins the
  defect as intended behavior.
- **BUG-20.** `printWide` at the last column writes a `.spacerHead` into the
  margin, wraps, then runs the insert-mode shift on the new row, which retires
  the spacer it just wrote. Probe: `ESC[4h ESC[4G 界` at 4x2 gives row 0
  `isSoftWrapped` with a `.padding` margin and projects `"    界"`; without
  IRM the margin is `.spacerHead` and the text is `"   界"`. The stored spacer
  is kept consistent with the wide head below it by five retire sites, two
  preserve flags, and the history/live seam repair; this is one of those sites
  firing at the wrong moment. A plainer instance of the same class: a TUI that
  redraws the wrapped head in place (`ESC[4G 界 ESC[2;1H 界` at 4x2) retires
  its own spacer, because the second print did not wrap itself -- the line
  gains a space the program never printed, exactly the defect
  `restoreSeamSpacer`'s own comment warns about.
- **BUG-19.** With DECAWM off, a wide glyph that ends at the margin parks the
  cursor on its head; kitty and ghostty leave it on the last column. The next
  narrow character lands one column early and destroys the glyph. Probe:
  `ESC[?7l ESC[3G 界 A` at 4x1 puts `A` at column 2, references at column 3.
  `TerminalModeTests#autoWrapModeControlsRightEdge` pins column 2.

A further defect surfaced while probing the seam. History never stores a
spacer (`31/I1`) and re-derives it from the wide head that follows; the live
grid stores one and repairs the seam by hand. At 4x1, `ESC[4G 界 ESC[1G X`
(the wide wraps, its row scrolls into history short by one column, `X` then
overwrites the head on the live row): `primaryHistoryText` is `"   X"` while
the same sequence on a 2-row grid projects `"    X"`, and a 4 -> 5 -> 4 column
resize collapses the two rows into one `"   X"`. The omitted margin column was
lost because the seam repair only materializes a non-default-styled blank and
the overwriting print hands it the default style. That breaks design doc D7
(an unchanged-width round trip restores the layout).

## 2. Decision

One task, four parts, ordered so each commit is green.

1. **Every vacate is a background-erase blank.** No print path carries a
   default replacement style. Pen background over "keep the old cell's
   attributes": it is what DanTerm's erase, shift, and reveal paths already do,
   it is ghostty's rule, and keeping the old style would leave reverse or
   underline on a blank.
2. **The live grid derives the wrap spacer instead of storing it.** A wide glyph
   that does not fit leaves an ordinary blank in the margin carrying the style
   the glyph carries (no hyperlink, no identity), marks the row as continuing,
   and records on the row that a wide wrap left that margin -- the sibling of
   `marginErased`, which records that an erase last wrote it. `.spacerHead`
   becomes a projection: a row that logically continues, whose margin a wide
   wrap left, followed by a row whose first cell is a wide head, projects a
   spacer carrying that head's style, hyperlink, and identity. One rule serves
   live rows and the history/live seam, and it is the store's fold rule
   restated. Nothing a write to the row below can do desynchronizes a spacer
   from its head, because there is no stored spacer and the row's margin
   provenance is written only by writes into its own margin. The
   stored-spacer maintenance (retire sites, preserve flags,
   `repairHorizontalMove`'s spacer arm, the spacer half of `severWrapClaim`,
   `protectedMask`'s exemption, `restoreSeamSpacer`,
   `seamRowIsShortOfItsSpacer`, `repairClearedSpacer` and its live-write
   triggers) goes away.
3. **The store resolves a continuing row's margin when its follower is known.**
   A continuing row whose margin a wide wrap left is admitted short, and the
   open tail remembers that margin's paint; the follower decides its fate at
   every point that needs the line materialized -- the next admission, the
   close that severs the claim, and the hand-backs to the live grid on a height
   or width change: a wide head below discards the margin (the fold re-derives
   the gap), anything else appends one blank with the remembered paint. This
   is what fixes the D7 break above, and it is the only moment left where live
   and history have to agree.
4. **DECAWM off: a wide glyph whose second cell is the last column leaves the
   cursor on the last column with no pending wrap**, exactly as a narrow
   character printed there does; the following character overwrites that cell.

Backwards compatibility is not a constraint: the stored-kind change, the
store's open-tail rule, and the test flips are all internal.

## 3. Invariants

- **I1 -- BCE vacate.** Every cell a print vacates (the partner half of an
  overwritten wide pair, the tail a VS15 downgrade frees, the neighbour a VS16
  upgrade clears) is a blank carrying the pen's foreground and background and
  no other attribute -- the same blank `eraseCells`, `moveAndFillCells`, and a
  scroll reveal paint. Under a default pen this is bit-identical to today's
  default blank. The wrap gap is not a vacate (I3).
- **I2 -- the spacer is a projection.** No live row stores a `.spacerHead`.
  A row records its margin's last writer -- content, an erase (today's
  `marginErased`), or a wide wrap that skipped it -- and the wrap-gap case
  implies the margin cell is a blank with no hyperlink and no identity.
  Readers see a spacer exactly when the row logically continues, a wide wrap
  skipped its margin, and the following row's first cell is a `.wideHead`; the
  projected spacer carries that head's style, hyperlink, and content identity.
  One definition serves live rows and the last retained row against live row 0
  (primary screen only), and it agrees cell for cell with the store's fold of a
  fully retained line: a blank that is content -- an erased cell, a VS15
  downgrade at width-2, a reflow-folded interior pad landing on the margin
  before a wide head -- stays `.padding`. Every reader of line structure
  consumes projected rows: the text projections (`primaryHistoryText`
  included, which today skips the seam rule), search, selection and links,
  `rowStructure`, `geometry`, `cell(row:column:)`, `scrollbackRow`, live
  reflow, alt-screen clipping, state sync, and the render frame plan; a cached
  projection never outlives a change to the follower's first cell. The renderer
  is not exempt: while a wide head follows, the projected spacer's style is that
  head's current style, which stops being the stored blank's wrap-time paint as
  soon as the head is redrawn under a different pen, so a frame built from
  stored rows would paint a cell that inspection and history report
  differently. Because the projection reads one row ahead, a write that changes
  a row's first cell damages the gap row above it as well -- the live row, and
  the seam row while browsing -- so the incremental frame planner never reuses a
  stale margin cell. The public kind `TerminalCellKind.spacerHead`,
  `TerminalRowStructure.marginCellKind`, and the `pane rows` `marginKind` value
  keep their meaning.
- **I3 -- the gap is a function of state, never maintained.** The gap blank is
  painted once, when the wrap happens, with the style the glyph carries, and no
  later write to the follower, sever, or erase repaints it; that stored paint is
  what shows once the gap retires, and while a wide head still follows every
  reader shows the projected spacer's paint instead (I2) -- so the margin paints
  the same live, at the seam, and in history, frame included. A wide glyph printed at
  the margin projects the same stream with and without insert mode; redrawing
  the wrapped head in place keeps the spacer; an ICH/DCH, erase, or print on
  the row below never writes the row above; erasing, shifting, or overwriting
  the head retires the spacer; printing a wide head back under a continuing
  gap margin shows it again.
- **I4 -- width-free line structure end to end.** For every row the content
  admission stores equals what the live projection reports: a wrap gap with a
  wide head below is no cell; a wrap gap whose follower is anything else is
  one blank cell. A same-width resize round trip therefore restores the layout
  at the history/live seam too (today's 4x1 `ESC[4G 界 ESC[1G X` case
  included), and history text equals live text for the same content at every
  moment.
- **I5 -- the open tail resolves its margin once, by its follower.** A
  continuing row whose margin a wide wrap skipped is admitted one column short
  and the open tail remembers the margin's paint; at most one such pending
  margin exists, only on the open tail, and it survives everything the open
  record survives (front eviction, budget rebase). It belongs to that record:
  when the record is evicted whole, the pending margin goes with it, even though
  `startsMidLine` survives the drop -- otherwise the next admission would append
  the remembered blank at column 0 of a new line. The follower resolves it at
  every point that needs the line materialized: (a) the next admission into
  the record -- a leading wide head discards it, anything else first appends
  one blank with the remembered paint, whatever its style; (b) the close that
  severs the claim -- one blank iff the paint is non-default (research/31
  Decision 3, with the wrap-time paint as its input); (c) before a width
  change, against live row 0's first cell as in (a); (d) a height grow hands
  the row back to the live grid as a gap row -- blank margin with the
  remembered paint, marked as skipped by a wide wrap -- and the projection
  decides. A forced split or a reopen never sees a pending margin. Until
  resolved, the seam projects the short row to full width by I2, showing the
  remembered blank when no wide head follows.
- **I6 -- links cross the seam.** An OSC 8 run that wraps at a wide-glyph seam
  is one run: the projected spacer carries the head's hyperlink, and link
  activation identity behaves as today.
- **I7 -- DECAWM off at the margin.** A wide glyph whose second cell is the
  last column leaves the cursor on the last column with no pending wrap, as a
  narrow character printed there does; the next character overwrites that
  cell. A wide glyph that does not fit with autowrap off still backs up to the
  last two columns (kitty's rule), then obeys the same cursor rule.
- **I8 -- a declined advance claims nothing.** When the cursor sits on the
  last screen row below the scroll region and a wide glyph does not fit, no
  wrap claim and no gap are recorded; the glyph prints where the existing rule
  puts it.
- **I9 -- every mutation leaves wide pairs whole (D13 unchanged), gap
  included.** Protection (DECSCA) rides the gap blank with the glyph's style: a
  protected glyph's gap survives DECSEL 1/2 and the row still continues; an
  unprotected gap is erased and gates the claim.

## 4. Proof obligations

Behavioral, structure-insensitive Swift Testing suites in
`lib/TerminalCore/Tests/TerminalCoreTests`. Each entry names the claim; the
implementer picks the scenarios.

- **PO1 (I1).** Overwriting either half of a coloured wide pair with a narrow
  or a wide glyph under a different pen, a VS16 upgrade beside a coloured cell,
  and a VS15 downgrade each leave the vacated cell `.padding` with the pen's
  foreground and background and no attributes; one pen-reset case pins the
  ghostty choice (the partner takes the pen, not the old cell's colour). Flip
  `TerminalCellStyleTests#structuralWideClearRemainsDefaultStyled` and the
  downgrade arm of `#clusterStyleSurvivesContinuationAndWidthChanges`;
  `#defaultEraseRemainsBitIdentical` stays.
- **PO2 (I2, I3).** `ESC[4h ESC[4G 界` and its control without IRM give equal
  `rowStructure`, `screenText`, and history text, live and after scrolling
  off, at 4x1 and 4x2, and the successor row's prior content shifts right by
  two; redrawing the wrapped head in place keeps the spacer; ICH at column 0
  or 1 of the follower retires it; printing a wide head back under a continuing
  gap margin shows it again; the gap's paint is unchanged by overwriting,
  erasing, or shifting the head, live and at the seam. `expectValidStream`
  keeps asserting spacer => wide head below with the same style and hyperlink;
  no converse is added (a content blank before a wide head is legitimate), so
  BUG-20's shape is pinned by scenario and `rowStructure`.
- **PO3 (I2 content blanks).** A VS15 downgrade at width-2 that leaves a blank
  margin before a wrapped wide head, and a reflow that folds an interior pad
  onto the margin before a wide head, keep the blank as content in text,
  `rowStructure`, admission, and a width round trip.
  `TerminalStaleWrapClaimTests#interiorPaddingAtFoldSeamKeepsContinuation` is
  the narrow-follower member of this family.
- **PO4 (I2, I9).** EL 1 / EL 2 over a gap row with the head still below
  projects no spacer; DECSEL 1/2 at the margin of a protected glyph's gap
  leaves the gap, the claim, and the spacer; DECSEL over an unprotected gap
  erases it and the spacer disappears. Restate
  `CSIEraseTests#selectiveEraseBlanksAWrapSpacer` accordingly;
  `#selectiveEraseKeepsTheSpacerAboveAProtectedHead` stays.
- **PO5 (I4, I5).** On a 1-row grid: wide wraps, row admitted short; (a) head
  stays -> seam projects the spacer, history text `"   界"`, `scrollbackRow`
  margin `.spacerHead` with the head's style; (b) `X` overwrites the head ->
  history text `"    X"` equals the 2-row live projection, and a width round
  trip (N -> N+1 -> N) restores two rows, default and coloured pen alike;
  (c) the record is closed by ED -> the margin keeps the wrap-time paint
  (coloured iff the wrap's pen was), not the erase's; (d) a width change with
  the head still live reflows to `"   界"` on one row and back; (e) a height
  grow hands the row back with the spacer still projected, and with `X` below
  hands back a content blank; (f) a coloured pending margin driven through the
  existing budget-rebase path, and through a front eviction, survives both --
  the follower then stops being a wide head and the blank, its paint, the
  history text, and a width round trip all come back; (g) the open gap record is
  evicted whole under a small budget and the next admitted row starts with a
  narrow glyph -- no leading blank appears in history text, `rowStructure`, or a
  width round trip. `TerminalLogicalLineFoldTests#assertOpenTailSeam`
  and `#comparableRowCount` describe the divergence this removes -- delete or
  invert them; `#clearedSpacerMaterializesTheBackgroundEraseBlank` and
  `#clearedSpacerRepairSkipsAFullLastDisplayRow` restate as pending-margin
  resolution (discard on a head, append otherwise, Decision 3 on close);
  `TerminalScrollbackTests#backgroundErasePaintsTheSeveredSpacerColumn` flips
  to the wrap-time paint; the fold tests' live-row oracle must read projected
  live rows.
- **PO6 (I2 readers and caches).** Overwriting the head below a gap row changes
  the projection of the row above as seen by `cell(row:column:)`,
  `rowStructure`, selection text, search, and the render frame plan, live and at
  the seam. One scenario drives `PaneFramePlanner`'s incremental path with the
  terminal's own recorded damage: redraw the follower's wide head in place under
  a different pen, then overwrite it with a narrow glyph, and check the reused
  frame's margin cell against the projected spacer both times, live and while
  browsing the seam. Restate
  `RenderFramePlanningTests#wideCellAndSpacerGeometry` on projected rows.
- **PO7 (I6).** An OSC 8 run spanning a wide-glyph wrap resolves as one link
  from either row; `linkArmTracksRunIdentity` still holds.
- **PO8 (I7, I8).** `ESC[?7l ESC[3G 界 A` at 4x1 puts `A` in column 3 over
  the glyph's tail and the head is gone; the VS16 upgrade at the margin with
  autowrap off ends with the same cursor; flip the two cursor expectations in
  `TerminalModeTests#autoWrapModeControlsRightEdge`. A wide glyph at the last
  column of the row below a scroll region leaves no wrap claim and a valid
  stream.
- **PO10 (I2 state sync).** An ordinary derived gap -- a wide glyph wrapped at
  the margin, head still below -- round-trips through state synchronization with
  its visible projection intact: the replayed stream gives the same
  `rowStructure`, text, margin style, and OSC 8 run identity across the seam,
  and the wide head is emitted once, not twice. The retired gap stays out of
  this scenario, and the round trip is not asserted to carry the gap's stored
  wrap-time paint (AR5).
- **PO9 (existing behavior kept).** `TerminalResizeTests#spacerRoundTripAcrossWidths`,
  `TerminalRowStructureTests#wideGlyphWrapReportsSpacerMargin`,
  `TerminalScrollRegionTests#marginWrapPreservesLogicalLine`,
  `TerminalEditingTests#characterEditingSeversWrapClaim` and
  `#characterEditingRepairsWidePairs`,
  `TerminalAlternateScreenTests#alternateRectangleResize`,
  `TerminalScrollbackTests#crossBoundarySpacerRepair`,
  `TerminalASCIIRunTests#runClearsPrecedingWrapSpacer`,
  `CSIEraseTests#eraseAtColumnOneClearsPrecedingSpacer`,
  `#eraseCharactersWrapAndSpacerCleanup`, `#eraseAtTopRowClearsScrollbackSpacer`,
  `TerminalCellStyleTests#widePrintAtMarginKeepsStyleCoherent` and
  `#reflowSynthesizedWideCellsKeepStyle`, and the
  `Fixtures/libvterm/reflow-narrow-wide.json` replay keep passing unchanged.

## 5. Non-goals, accepted risks, rejected ideas

- **Non-goal.** Changing the renderer's drawing rules: `.padding` and
  `.spacerHead` still draw identically (background only). The frame path does
  read projected rows (I2) -- the two kinds' shared geometry does not make their
  styles equal.
- **Non-goal.** The `pane rows` diagnostic heuristic in
  `integrations/danterm/SKILL.md` (`softWrapped && contentEnd < width &&
  marginKind != spacerHead`) already misreports a retired gap today and keeps
  doing so; `TerminalGeometry.swift#TerminalRowStructure`'s "unreachable by
  printing" comment is corrected in passing.
- **Non-goal.** State-sync replay of a retired gap (blank margin, soft wrap) is
  lossy today and stays so; the writer never advances past the margin.
- **AR1.** Printing a wide head back under a continuing gap margin re-derives
  the spacer, where today (and ghostty) the retired gap stays content.
  Display-identical at the current width; width-free by construction, so live
  and history can no longer disagree about it.
- **AR2.** A gap keeps its wrap-time paint after the head is gone and after a
  sever (IL, ED, EL at row 0) under a different pen, as ghostty's and xterm's
  margin cell does; today the retiring write repaints it. research/31
  Decision 3's measured table changes in that one row.
- **AR3.** Alt-screen widening leaves the old gap as an interior blank and may
  project a spacer at the new margin if the head is still below; pixel-
  identical, alt-screen text differs by one space either way.
- **AR6.** I8 departs from ghostty at the bottom row outside the scroll region:
  `references/ghostty/src/terminal/Terminal.zig#print` has already written the
  spacer and set the wrap flag before `#index` declines to scroll, so ghostty
  leaves a claim whose follower is the row itself. DanTerm records neither,
  which is what the projection needs -- a claim there would read the wrong head.
- **AR5.** State synchronization carries a live gap's visible projection, not
  the wrap-time paint stored beneath it: replay reconstructs the gap by wrapping
  under the pen the projected spacer shows, so a source that wrapped blue and
  then redrew the head red hands the replica a red gap. The two agree until the
  head is retired in the replica, and then differ by one cell's background.
  Preserving it would make the writer emit the wide head twice -- once to paint
  the gap, once to restyle it -- to keep state a viewer cannot see, in a stream
  the plan already accepts as lossy for the retired gap.
- **AR4.** Point queries must not copy rows to project: the spacer is derived
  at the one margin cell, and whole rows are materialized only on whole-stream
  walks. Each live-row projection peeks one row ahead.
- **RI1 -- keep the stored spacer, make the retire head-aware and run it
  after every print/edit.** Smaller, fixes the probes, but leaves the seam
  machinery and one reconcile to forget per site, and keeps the live-write
  trigger into history that the D7 defect lives in. Named as the trade-off;
  not taken.
- **RI2 -- keep the old cell's colour on a vacated half (xterm, kitty).** Would
  leave reverse/underline on a blank and contradict DanTerm's erase paths.
- **RI3 -- hand admission a projected row and special-case the 1-row grid.**
  Keeps `repairClearedSpacer`'s live-write triggers alive for the seam, which
  is the BUG-20 class again.
- **RI4 -- derive the gap from the margin cell alone, without row
  provenance.** Cannot tell a wrap gap from a content blank before a wide head
  (PO3's cases); the store's fold can, so live and history would disagree and
  admission would drop a painted cell.
- **RI5 -- keep `.spacerHead` stored as a gap marker with derived attributes.**
  Every reader would have to demote a stale marker, and the marker's repair
  arms survive; more rules, not fewer.

## 6. Implementation discretion

- Where the open tail keeps the remembered margin paint and whether the short
  admission is "append short, materialize later" or "append full, cut on a wide
  follower" (`cutTail` exists), as long as I5 holds at all four resolution
  points and the seam row paints full width.
- Whether the margin provenance is one enum (content / erased / skipped) that
  absorbs `marginErased`, or a second bit beside it; and whether "no live row
  stores a spacer" is enforced by a debug assertion on the row-write path or
  by review alone.
- How live reflow's `pack` interns the gap blank's style, and how the fold
  tests' oracle reads projected live rows.

## 7. Sequence

Green, independently reviewable commits; order is load-bearing where noted.

1. BCE vacate (I1) with PO1 -- independent of everything below.
2. DECAWM-off cursor and the declined advance (I7, I8) with PO8 -- independent.
3. Margin provenance replaces `marginErased`; no behavior change.
4. One projection function replaces `seamSpacer` and its hand-rolled twins,
   still on the stored model; every reader in I2 routed through it,
   `primaryHistoryText` and the frame path included, with the follower's damage
   rule. Consumers must be on projected rows before 6, or live reflow counts
   gap blanks as content.
5. Store: short admission plus remembered paint and the four-point resolution
   (I5), seam readers painting the short row to full width; replaces
   `repairClearedSpacer` and its triggers and `restoreSeamSpacer`. Carries the
   research/31 Decision 3 amendment. Lands before 6 because 6 removes the stored
   kind the store's drop-on-admit relied on. PO5.
6. Stop storing the spacer: the gap blank and provenance at the wrap writers,
   deletion of every writer, maintainer, and flag; reflow, alt-screen resize,
   and state sync on the projected stream (I2, I3, I4, I6, I9) with PO2-PO4,
   PO6, PO7, PO9, PO10. Carries the `TerminalRowStructure` comment correction
   and the pointers that name `repairClearedSpacer`/`seamSpacer`. `SKILL.md`
   changes only if `pane rows` output does, which it should not.

## Commit progress

- [x] 1. fix(terminal): paint every print vacate with the background-erase pen
- [x] 2. fix(terminal): keep the cursor on the last column when autowrap is off
- [x] 3. refactor(terminal): record the margin's last writer as row provenance
- [x] 4. refactor(terminal): route every line-structure reader through one spacer projection
- [x] 5. feat(terminal): let the open tail's follower resolve its pending margin
- [x] 6. refactor(terminal): derive the wrap spacer instead of storing it
