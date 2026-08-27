# Wave 7 -- make reflow carry the whole row

Audit: `docs/scratch/2026-08-26-improvement-audit.md`, `## Plan of work`,
Wave 7: REFLOW-1, -2, -3, -5, -6, -7. All six rewrite `reconstructLogicalLines`,
`reflowDestination` and `pack` in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, so the wave lands as
one commit. Wave 14's REFLOW-4 rewrites the same pack walk and assumes this
wave is finished. Starting point: Wave 6 is landed (through 7cd2bf02).

## 1. Problem

The primary screen's width reflow rebuilds every row from too little: the
text cells of each source row, a scalar for the cursor, and nothing else.

**Cursor.** A cursor in a row's trailing blanks is carried as `distance` past
the content end and placed at `min(contentEnd + distance, columns - 1)`.

- When the refolded line fills its last row, the clamp parks the cursor on the
  last committed character with no wrap armed; the next print overwrites it.
  Reproduced: 6x3 `"abcd" CSI 6G`, narrow to 4, print `X` -> `abcX`. The
  `distance == 0` case was patched by arming the pending wrap; every other
  distance is still live.
- A cursor on an all-padding continuation row resolves to the line's *first*
  row, landing on committed text. Reproduced: 4x4 `"abcdefg"`, blank row 1,
  cursor (1,2), widen to 6 -> cursor on the `c`.
- `ReflowCursorAnchor` stores the line index twice and overloads
  `.trailingPadding` for two unrelated shapes; the clamp and the
  `distance == 0 &&` special case are symptoms of that shape.

Both cursors -- live and DECSC-saved -- go through the same resolution.

**Paint.** A width change erases every background-colored blank (reproduced:
4x3 `ESC[41m ESC[2J ESC[H`, widen to 5, every cell goes `.indexed(1)` ->
`.default`; 6x3 `ESC[H ESC[41mAB ESC[K`, widen to 8, red survives only under
`AB`). The alternate screen keeps its paint, and so does retained history:
`LogicalLineStore.admissionExtent` (`LogicalLineStore.swift:825-858`) records
"content end, then one trailing fill style to the margin" per hard-ended row
and `materializedRow(includeFill:)` repaints it at any width. The live refold
is the one width-change path that re-derives blanks at the default style
(`retainedContentEnd`'s text-only scan, `pack`'s default-styled row seed, the
trailing `makeBlankRow` loop in `resizeWidth`, and a text-only
`lastLiveContentRow` cutoff that keeps painted blank rows out of the fold).
That drop is pinned as intended by
`TerminalCellStyleTests.bcePaddingDoesNotBecomeResizeContent` (80475a69);
doc 31's DD25 amendment reversed the decision for history without revisiting
the live refold, so the tree holds both answers.

**Marks.** "Which display rows of a marked line carry `.continuation`" is
stated three times -- `pack`, the store's materializer
(`LogicalLineStore.swift:2498`), its head trim (`:1072`) -- and the printer
stamps by a fourth rule (from `screen.semanticContent`), so a soft-wrapped
`.output`-headed line is `.none` live and `.continuation` after it
rematerializes. No in-engine reader distinguishes them; the drift leaks
through the sync dump's `mark=` field.

**Line structure.** The height-shrink trailing-blank trim
(`Terminal.swift:5400-5406`) is the last resize reader of the raw wrap claim.
A blank last row with a stale claim blocks the trim, and a shrink displaces a
content row into scrollback instead of dropping a blank one (reproduced via a
scroll region that excludes the last row, and via
`OSC 133;S;mark=none;wrap=stale`).

## 2. Decision

Reflow carries every fact of a row that has an observable effect -- its text,
its fill style, the cell the cursor is on, its mark -- and resolves cursors
through the same cell map as text.

- **D1 -- one lossless row-extent rule.** History admission, the live
  refold's source-row cutoff, and the fold itself call one owner of the
  rule "content end, then one trailing fill style to the margin". The rule
  is lossless: the content end is the last cell with a visible effect --
  text or a styled blank -- except that the maximal uniform run of styled
  blanks that reaches the right margin collapses into the fill style. This
  is what `admissionExtent`'s own doc comment already promises and its scan
  does not deliver (it stops at the last text cell, so `A` + two red blanks
  + a default margin loses the red). `retainedContentEnd` /
  `rowContainsContent` keep their text-only meaning for Copy, the text
  projections, prompt reclaim and the height trim. Two rules, each named
  once.
- **D2 -- fill is line metadata, not cells.** The fold carries content units
  up to D1's content end and keeps the fill as one style on the line. Every blank the fold
  synthesizes for that line -- row seeds and any extension needed to reach a
  tracked cursor -- is painted in the fill. A wide-wrap spacer is not a blank:
  it keeps inheriting the attributes of the head it defers, as
  `LogicalLineStore.spacerDeferring` and `pack` already do. No row with a
  visible effect is rebuilt from a default blank; rows past the last row with
  any visible effect are default blanks and may be rebuilt freely.
- **D3 -- the cursor is a cell.** A hard-ended row's fold bound is
  `max(content end per D2, live cursor column + 1)` (ghostty's
  `cols_len = max(cols_len, p.x + 1)`; wezterm folds the same offset). Only
  the live cursor past the content end adds blank units, painted in the fill
  style, and the cursor then resolves as a `.cell` anchor through the same
  cell map as text. So a six-column `AB` row filled to the margin, with no
  live cursor past `AB`, narrows to one row of `AB` plus fill, never to six
  units. The DECSC slot keeps D7's two-stage rule: it is a passenger of the
  layout the live cursor decides. It resolves as `.cell` when its cell is in
  the fold, as `.boundary` at its line's end when it sat past the fold bound,
  and by its row offset below the content otherwise. `.trailingPadding`,
  `allPaddingColumn`, the clamp and the `retainedEnd == 0` branch cease to
  exist; the anchor enum is `cell | boundary`, `.inLine` carries the line
  index once, and the per-row "retained end" is D1's content end. Whether a
  cursor is in-line or below content is decided by D1's cutoff: a painted
  blank row is in-line.

  Accepted behavior change: a narrow can create a blank row for a cursor
  parked to the right of a short line (`"ab"` at 6 columns, cursor column 4,
  narrow to 3 -> two rows, cursor (1,1)). The row exists because the cursor
  is on it. The saved slot never creates a row.
- **D4 -- one continuation rule.** The store's meaning wins: `.continuation`
  is a display row of a marked logical line that is not its head. That rule
  is named once and called by the packer, both store sites, and the printer's
  soft-wrap stamp. The printer's hard-newline stamp inside a prompt/input
  region marks a new logical line's head; it is a different fact and stays.
- **D5 -- one line-structure reader.** The height-shrink trim reads
  `logicallyContinues` and the text-only blankness rule, and keeps stopping
  at the cursor row, so a row that exists only to hold the cursor is never
  trimmed.
- **D6 -- reversed decisions are deleted, and the register is amended in
  the same commit.** The width leg of `bcePaddingDoesNotBecomeResizeContent`
  goes (its height leg stays). D7 of
  `docs/design/2026-08-06-swift-terminal-engine.md` binds "the existing
  per-width column clamp" and the "trailing-padding distance" attachment;
  it is amended in place to state I2's two anchors, the cursor-row creation
  for the live cursor, the saved slot's line-end fallback, and fill
  preservation, so REFLOW-4 inherits one
  contract. Doc 31's DD25 gets the D1 lossless wording.

Behavioral scope: primary-screen width resize, height shrink, and the
`.continuation` mark on soft-wrapped rows. The alternate screen's resize is
untouched.

## 3. Invariants

- **I1.** A cursor that sat past a row's committed text before a width
  change (trailing padding, all-padding row, or pending-wrap boundary) still
  sits past that text afterwards: printing one scalar never overwrites a cell
  that held committed text before the resize. A cursor that sat on committed
  text keeps sitting on that same cell. Live and saved cursor alike.
- **I2.** Two anchors, no third: a non-pending cursor follows the source cell
  it sat on -- text or the padding cell D3 carries for the live cursor -- to
  that cell's new position, with no pending wrap; a pending cursor, or a
  saved slot that sat past the fold bound, follows a boundary (the row end
  after that cell, or the line's end), spelled as the last column plus a
  pending wrap only when that boundary falls on the new margin. Exact cell
  preservation is the live cursor's guarantee; the saved slot keeps it only
  while its cell is in the fold.
- **I3.** An attachment whose outer and inner line index disagree, and an
  anchor carrying both a distance and an all-padding column, are not
  representable.
- **I4.** A width change preserves a row's paint: every cell a background
  erase painted still shows that background, and a widened column past a
  filled row's content shows the row's fill. Primary and alternate screen
  agree on the painted cells they both have.
- **I5.** Copy, the text projections and prompt reclaim do not change: a
  colored-but-empty row, and a padding cell carried for the cursor, are
  still text-blank to them.
- **I6.** A row with a visible effect (text or fill) is never dropped or
  rebuilt by a width change; only rows with no visible effect are
  synthesized.
- **I7.** `.continuation` on a soft-wrapped row is the same before a resize,
  after a resize, and after the line scrolls into history and is pulled back
  -- whatever the line's head mark.
- **I8.** A height shrink drops trailing text-blank rows before it displaces
  any content row, regardless of a stale wrap claim on those blanks.
- **I9.** History admission changes in exactly one way: a styled blank
  that does not belong to the margin-reaching fill run is now retained as a
  cell instead of dropped. Every row the old rule admitted losslessly is
  admitted identically.

## 4. Proof obligations

`lib/TerminalCore/Tests/TerminalCoreTests/`, public surface only:
`geometry.cursor`, `cell(row:column:)` (kind and `style.background`),
`screenText`, `fullHistoryText`, `scrollbackRowCount`,
`semanticPromptRowsForTesting`.

- **PO1 (I1, I2).** `TerminalResizeTests`: 6x3 `"abcd" CSI 6G`, narrow to 4,
  print `X` -> row 0 `abcd`, row 1 ` X`; 8-column `CSI 7G` variant -> row 1
  `  X`; the REFLOW-3 probe (4x4 `"abcdefg"`, blank row 1, cursor (1,2),
  widen to 6) -> cursor (1,0), and printing leaves row 0 `abcd  `. The
  existing `"some long long text"` case stays green unchanged.
- **PO2 (I1, D3, saved cursor).** `TerminalSavedCursorResizeTests`: DECSC
  in trailing blanks, narrow so the line fills, DECRC, print -> no committed
  text lost. And the full-viewport case: 6x3, `A`, `B`, `C` on rows 0-2,
  DECSC at (2,5), live cursor on `A`, narrow to 3 -> no row is created, `A`
  stays on screen with the live cursor on it, and DECRC then print does not
  overwrite committed text.
- **PO3 (D3 accepted change).** Rewrite `trailingPaddingAnchorPreservesDistance`,
  the `padded` tail of `trailingBlankAnchorDefersWrapWhenContentFillsRow`,
  and `multiStepWidthWalkRestoresLayoutAndHistory` (retitled without the
  clamp claim; the padding cursor at column 9 returns to column 9 after the
  walk) to the folded positions; saved-cursor expectations move the same way.
- **PO4 (I5).** `fullHistoryText` after a resize with a parked cursor is
  unchanged, the carried cursor cells report kind `.padding`, and Copy /
  `screenText` of a filled row emits no trailing content beyond the text.
  (`screenText` cannot prove the padding kind: it renders padding as a
  space.)
- **PO5 (I4).** The two paint probes on widen and on narrow, the
  alternate-screen control pinned alongside them, and a row with a
  differently styled gap between its text and its fill (`A`, default blanks,
  red fill): after a widen and a narrow the gap keeps its own style and the
  fill reaches the new margin. A cursor parked in a filled row's fill region
  lands on a fill-styled cell after narrowing. The isolated case: `A`, two
  red `ECH` blanks at columns 3-4, default margin -> after a widen, a
  narrow, and a scroll into history and pull-back, both red cells keep their
  background.
- **PO6 (I6).** A fully painted screen whose top line wraps on narrowing
  keeps every painted row (displacing content into scrollback rather than
  dropping paint), and default-blank rows below the last visible effect are
  still trimmed first.
- **PO7 (I7, D4).** A soft-wrapped `.output`-headed line: the wrapped rows'
  marks are identical on the live grid, after a width change, and after a
  scroll into history and pull-back. A hard newline inside a prompt/input
  region still produces a `.continuation` head before and after a width
  change.
- **PO8 (I8, D5).** The vetted REFLOW-7 probe: `XY` on row 0, a scroll
  region that strands a wrap claim on the last row, EL 2 there, shrink by
  one row -> `XY` stays on row 0 and `scrollbackRowCount == 0`. Same through
  `OSC 133;S;mark=none;wrap=stale`.
- **PO9 (I9, I3).** The retained-history suites, `Resize`,
  `TerminalLogicalLineFoldTests`, `TerminalSavedCursorResizeTests` and
  `TerminalPromptAnchorResizeSweepTests` stay green apart from the PO3
  rewrites, the D6 deletion, and any admission test that pinned an isolated
  styled blank being dropped (rewritten to pin it retained).

Suites likely to move and to be read, not silenced:
`TerminalPromptAnchorResizeSweepTests`, `TerminalStaleWrapClaimTests`,
`TerminalCellStyleTests`, `TerminalSemanticPromptInvariantTests`.

## 5. Non-goals / Accepted risks / Rejected ideas

Non-goals:
- REFLOW-4: resolving cursors during the pack walk and deleting the per-cell
  destination maps. Wave 14; the maps stay.
- Deleting `.continuation` from the vocabulary or the sync wire.
- Changing the alternate screen's positional truncate-and-pad.

Accepted risks:
- **AR1.** D3 creates rows for a far-right parked cursor. Matches ghostty;
  the alternative keeps a clamp.
- **AR2.** A painted screen now displaces content on a narrowing where it
  used to drop painted blanks. ghostty's behavior; follows from I6.
- **AR3.** A DECSC slot that sat past the fold bound loses its distance from
  the content and lands at its line's end. Non-destructive by I1; the
  alternative (the saved slot creates rows) can push the live cursor's row
  into history in a full viewport, which breaks I1 for the live cursor.

Rejected ideas:
- **RI1.** Fold `contentEnd + distance` with `/` and `%` but keep the
  padding anchor. The folded row can exceed the packed line's rows, and it
  keeps the scalar special case REFLOW-3 and -5 are symptoms of.
- **RI8.** Both tracked cursors extend the fold. A saved slot can then
  create a row the viewport cannot hold, displacing the live cursor's row
  into history (the AR3 scenario); see PO2.
- **RI2.** Carry `tracked.row - firstRowOfLine` in the anchor and add it to
  `baseRow`. Right only while the line's row count is unchanged, which a
  width reflow changes.
- **RI3.** Fold trailing fill as cells ("last cell with a visible effect").
  A filled `AB` row would fold to six units and create rows on a narrow; the
  store already keeps fill as one style per line.
- **RI4.** A reflow-private content-end rule (the audit's REFLOW-2 part 1).
  The store already owns the rule; a second copy is the defect class this
  wave removes.
- **RI5.** Routing unfolded rows through the alternate screen's
  `resizedRectangle` (the audit's part 2). It is positional, so a widened
  column would not take the fill; and once the cutoff counts fill, no row
  with a visible effect is unfolded.
- **RI6.** One blankness predicate for trim, `rowContainsContent` and the
  fold. They mean different things (text vs visible effect); one name would
  re-split the moment Copy and reflow disagree.
- **RI7.** Bending `pack` to the printer's context rule. The store
  rematerializes by the structural rule, so the refold would then disagree
  with history.

## 6. Implementation discretion

- Where the shared extent rule lives (`GridRow` method vs
  `DisplayRowProjector.RowFacts`), and whether fill is carried on the reflow
  line or the packed row.
- The shape of the fold-bound expression in D3.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` --
  `ReflowCursorAnchor`, `ReflowCursorAttachment`, `ReflowRowMetadata`,
  `reconstructLogicalLines`, `reflowDestination`, `pack`, `resizeWidth`
  (cutoff, trailing-row rebuild, `placed(...)`), `resizeHeight` trim,
  `stampSemanticContinuationAfterLineAdvance`.
- `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift` --
  `admissionExtent` (rule moves out), the two `.continuation` sites.
- `docs/design/2026-08-06-swift-terminal-engine.md` -- D7 amendment (D6).
- `docs/research/31-logical-line-scrollback/decisions.md` -- DD25 lossless
  wording (D6).
- Tests named in section 4.

## Verification

1. Red first for PO1, PO5, PO6, PO7, PO8.
2. `swift test --package-path lib/TerminalCore` into a file in the working
   tree; grep for failures. `just lint`. `just test` before the single commit.
3. Live check on a slot (`just launch-slot`): `printf 'abcd\e[6G'`, narrow
   the pane, type a character -- `abcd` intact, the character on the next
   row. `printf '\e[44m'; clear`, resize wider and narrower -- paint stays.

Then tick all six Wave 7 boxes in the audit's `## Plan of work` with the
commit hash.

## Commit progress

- [x] 1. fix(reflow): carry complete row state through width changes

## Implementation notes

- **The cursor is the boundary after the blanks before it, not a carried
  cell.** D3/I2 say the live cursor's row folds to `cursor column + 1` and the
  cursor resolves as a `.cell`. Done literally, the cursor's own blank folds to
  column 0 of a fresh row whenever the blanks before it fill the row, which
  breaks the two cases PO1/PO3 keep: `"some long long text"` at 19 columns
  must give `(0, 18, pending)`, and `abcdef` narrowed then widened must
  restore `(0, 5, pending)`. The implementation folds the blanks *before* the
  cursor (`max(visible extent, cursor column)`) and anchors the cursor as the
  boundary after them -- the same anchor a pending wrap uses, and DanTerm's one
  spelling of "after the last cell of a full row". Every PO1/PO3/D3 number
  falls out of that rule except the REFLOW-3 probe, which lands at
  `(0, 5, pending)` rather than `(1, 0)`: the same position, with no row
  opened for it. I2's two-anchor claim holds (`cell | boundary`, no third).
- **Cursor-only rows are conserved with the trailing blanks.** A row the fold
  opens for the cursor's distance alone (`abcd` + cursor at 6, narrowed to 4:
  row 1 holds one folded blank) is taken out of the trailing-blank budget, and
  a blank non-head row of the cursor's line is counted back into it on the
  next fold. Without this, D7's blank preservation displaced `abcd` into
  history on the narrow (PO1 wants it on row 0), and the widen pulled an extra
  history row back (`multiStepWidthWalkRestoresLayoutAndHistory`).
- **The text projection trims a logical line's trailing padding.** I5 says the
  carried blanks are text-blank to the projections, but `projectedCellEnd`
  measured every soft-wrapped row to full width, so `"ab"` + cursor at 4
  narrowed to 3 read as `"ab "`. `projectedCellEnd(in:columns:textFollowsInLine:)`
  now measures a wrapped row to its text end when no later row of its line
  holds text; the row-local overload stays for search, click expansion and
  end-of-stream anchors. This also drops trailing spaces from an erased tail
  inside a wrapped line, which no test pinned.
- **`blankedPromptRowDoesNotWidenTheLineBelow` moved.** Its expectation had the
  `UVWXY` tail on row 1 because the old fold snapped the cursor onto row 0's
  `H` (the REFLOW-3 defect). The emptied row is the cursor's row and stays a
  row; the tail is on row 2 with its own left margin, which is the bug the
  test guards.
- **Shared extent rule lives on `GridRow`** (`visibleExtent(columns:)`), with
  the two cell predicates on `GridCell`; fill is carried on `ReflowLine`.

## Follow Up

- Tick the six Wave 7 boxes in `docs/scratch/2026-08-26-improvement-audit.md`
  `## Plan of work` with this commit's hash (the plan's last step; it needs
  the hash, so it is a separate `docs(audit)` commit like `6311287b`).
- `pane rows` / `TerminalRowStructure.contentEnd` report the text extent; the
  visible extent (fill style, styled blanks) is not observable through the
  CLI, so the paint half of this change was verified live through `pane
  snapshot` sync bytes. Add the fill style to `pane rows`
  (`integrations/danterm/SKILL.md`, `TerminalRowStructure`).
