# Stale wrap claims fuse scrollback logical lines

Scratch notes, 2026-08-07. Not a plan file. Records a confirmed and ablated bug,
the tooling built to find it, and -- as of the second session the same day --
the fix that is now **implemented in the working tree**, which is *not* the fix
the first session's review recommended. The probe that resolved the open
question below produced a counterexample that killed the reviewed design; see
"The fix that was actually written" for what shipped and why.

Start here if you are picking this up cold: read "The bug in one paragraph",
then "The fix that was actually written", then "Working tree state".

## The bug in one paragraph

DanTerm stores scrollback as width-free logical line records and re-derives
display rows at read time by folding a record against the current width. A row
carries `isSoftWrapped`, a bit the printer sets when it autowraps. `CSI 2 K`
(EL 2) blanks a row's cells but deliberately leaves that bit set. When a TUI
repaints after a resize, it blanks rows with EL 2 and rewrites them shorter, so
rows end up blank-tailed while still claiming to continue. Admission trusts the
claim absolutely: a row flagged soft-wrapped is measured to the full width, and
the open record is only closed when a row is *not* flagged. Several genuinely
separate lines therefore fuse into one record, padded out to the width they
fused at. That record renders correctly at that width -- the padding lands
exactly on the fold seams -- and garbled at every other one. The corruption is
latent until the next resize and permanent once it is in scrollback.

## How it presented

The user ran Claude Code (an Ink/React TUI) in a pane that was half of a
horizontal split, then zoomed the tab to full width. The transcript stopped
wrapping where it should: text landed at wrong columns and lines broke in wrong
places. Unzoomed it looked fine.

In the live pane, `danterm pane read` showed scrollback line 0 as 219 characters
= banner row 0 (31 characters of content, padded to 89) + banner row 1 (62,
padded to 89) + banner row 2 (41). Three separately printed lines, one record.
Lines 2, 3, and 4 were 267, 356, and 445 -- exactly 3, 4, and 5 rows of 89.
Deeper in scrollback the same sentence appeared twice: once stored correctly as
a 179-cell genuine wrap, and once as 280 cells with blank gaps at columns 86,
175, and 251, joined at 89-column seams.

## The chain, each step verified

1. Pane at 58 columns, half a horizontal split. Content prints and genuinely
   autowraps, setting `isSoftWrapped` correctly.
2. Tab zooms; pane goes to 117 columns.
3. Tab unzooms; pane returns to 58. **The engine's resize and reflow are clean
   here** -- no violations immediately after the resize.
4. The PTY gets SIGWINCH and Ink repaints the whole screen. Its repaint opens
   `ESC[H ESC[2K ESC[1B ESC[2K ESC[1B ...`: cursor home, then EL 2 plus cursor
   down, per row.
5. `Terminal.swift#eraseLine` does not clear the wrap flag for EL 2. Only EL 0
   does. Rows are left blank but still flagged.
6. Ink writes shorter content into those rows, never reaching the last column.
7. The rows scroll off. `LogicalLineStore.swift#admissionExtent` measures a
   flagged row to the full width, and `#admit` closes the open record only when
   `row.isSoftWrapped == false`, so the lines fuse.

## The ablation

Captured a flight recording of the whole session with `danterm pane tape
--follow` and replayed it headlessly into `TerminalCore`. It reproduces
deterministically.

| Replay | Violations |
|---|---|
| Baseline | 20 |
| Every `ESC[2K` rewritten to `ESC[K` | 1 |

EL 0 erases the same cells from a home-column cursor but also drops the wrap
claim, so this isolates the flag and not the erase. The first violation appears
at tape record 137; record 136 is the resize. The resize is clean and the
repaint is what does it.

The tape is at `.build/evidence/2026-08-07-zoom-wrap-fusion.tape.jsonl`
(gitignored, and unscrubbed -- run `scripts/terminal-tape-to-fixture.py` before
committing any of it). It is also regenerable: the whole stimulus is now
scripted, see "Reproducing from scratch".

## EL 2 parity is correct and must stay

Not clearing the flag on EL 2 matches xterm (`util.c#ClearRight` is the only
clear that drops it), Ghostty
(`references/ghostty/src/terminal/Terminal.zig#eraseLine` declines it explicitly
for EL complete, with a comment saying xterm does not reset it), kitty, and
foot. tmux severs and is the lone outlier. DanTerm's behavior is pinned by
`CSIEraseTests#eraseLineWrapAsymmetry`.

The first session believed the parity harmless in those emulators "because none
of them re-measures scrollback against a width". The second session found that
is **not true of ghostty**: `PageList.zig#reflowRow` trims trailing blanks only
on rows whose wrap bit is clear, so a wrap-flagged blank-tailed row contributes
its full width to the reflowed line and ghostty fuses on resize exactly as
DanTerm did. The defect class is ecosystem-wide among reflow-capable emulators;
DanTerm's width-free store only made it permanent and visible sooner. The
actual defect statement stands with that amendment: the flag's meaning as
consumed -- "this row is exactly `width` cells of its line" -- is stronger than
the writers guarantee, and the fix belongs on the reader side.

## Tooling built (in the working tree, uncommitted)

### `danterm pane rows`

Per-display-row structural dump for the whole stream, retained rows first:

    {"rows":[{"index":0,"retained":true,"softWrapped":false,"contentEnd":30,"width":117}, ...]}

It exists because text projections cannot see this bug: `pane read` joins
soft-wrapped rows, so a record holding more cells than its content reads exactly
like legitimately wrapped prose. The pair `(softWrapped, contentEnd)` separates
them.

Stack: `TerminalRowStructure` and `Terminal.rowStructure` in `TerminalCore`;
`pane.rows` through `DanTermProtocol` -> core `update()` -> `AppRuntime`; a
session accessor. `app/TerminalSession.swift` keeps engine types out (its header
says grids stay out of that protocol), so it restates the struct as
`TerminalSessionRowStructure` and `SwiftTerminalSessionView` maps across.

### `danterm pane zoom [--pane <id>] on|off|toggle`

Zoom was previously reachable only by keyboard shortcut, menu, or toolbar
button, which is why the bug resisted reproduction for so long. Every other
resize path (split, close) is a different stimulus and stays clean.

Routes through the same `.toggleZoomPane` the human paths use, so scripted and
human behavior cannot drift -- in particular the "only a split tab may zoom"
guard lives there, and is why a request can be honoured and still report
`isZoomed: false`. `on` and `off` are idempotent so a script reaches a known
state without observing the current one; `toggle` is opt-in. The reply carries
`tab.isZoomed` after the request.

Zoom is deliberately transient and is not checkpointed (pinned by
`CheckpointTests#toggleZoomPaneDoesNotEmitScheduleCheckpoint`), so it is
absent from the persisted snapshot `ls` returns. `pane info` now reports
`isZoomed` instead, which closes the set-but-cannot-observe gap. Adding it to
the snapshot would have made zoom survive restart, which is a behavior change
nobody asked for.

## The oracle, and its one known bug

Invariant used to detect the defect:

    softWrapped && contentEnd < width

`contentEnd` counts only `.narrow` and `.wideHead`, so background-erase paint is
not content.

**This is wrong as stated and needs refining.** A wide glyph meeting the last
column leaves a `.spacerHead` there and sets the flag
(`Terminal.swift#printWide`, `#upgradeClusterToWide`), so a CJK or emoji wrap
produces `softWrapped && contentEnd == width - 1` legitimately, by printing.
Verified in the tree: feeding `abcd` plus U+754C at width 5 gives
`wrap=true, contentEnd=4, width=5` with `.spacerHead` in the last column. The
check must become:

    softWrapped && contentEnd < width && lastCell.kind != .spacerHead

`admissionExtent` itself already drops the spacer correctly after measuring, so
this is an oracle bug, not a store bug.

**Resolved 2026-08-07, second session.** The refinement is implemented --
`TerminalRowStructure.marginCellKind`, surfaced as `marginKind` in `pane rows`
-- but the spacer hypothesis for the residual violation was **refuted** by
probing: the tape contains zero wide-glyph wraps at the fold, zero `ESC[1K`
(the fallback hypothesis, also refuted), and the residual violation's margin
kind is `padding`. What it actually is: a **legitimate refold**. The source is
a hard-ended 117-wide row with content to column 113 and an interior blank at
column 57 (Ink positions with `ESC[nG` and leaves gaps); folding it at 58 puts
that blank exactly on the new margin, so `pack` emits a soft-wrapped row whose
margin is padding -- genuinely one line, flagged by the oracle. The oracle is
therefore **heuristic, not exact**: `softWrapped && contentEnd < width &&
marginKind != "spacerHead"` flags suspects that include this legal shape, and
no row-local check can exclude it, because the cells are identical to the
erased-transient case. This is also the counterexample that killed the
reviewed fix; see below.

## The recommended fix (reviewed, then refuted -- kept for the reasoning)

A subagent reviewed the evidence and the three options below, rejected all
three, and named a fourth: evidence-gated continuation, a derived predicate
`isSoftWrapped && marginHoldsContent(row)`. The second session **refuted the
fourth option too** before writing it: the residual ablation violation above is
a soft-wrapped row whose margin is padding and whose continuation is genuine
(a refold put an interior blank on the fold seam). Evidence-gating would sever
that line -- the dual corruption of the fusion it fixes, reachable by any
`ESC[nG`-positioning TUI that resizes. Cell inspection cannot separate the two
states because they are byte-identical; the distinguishing fact is *which
writer last touched the margin*, and no derived predicate can recover
provenance. The section is kept because its rejections (below) remain correct
and its "readers are the narrow waist" framing survives into the shipped fix.

### Why the wrap bit cannot simply be derived

Print exactly `width` characters, then LF. Cell for cell, that row is identical
to one that autowrapped. The bit carries one irreducible fact -- the printer
continued this line, versus ended it here -- that no cell inspection recovers.
Real prose hits this constantly. So deleting the bit is out.

### Evidence-gated continuation

Keep the stored bit as what it actually is, a claim the printer made, and make
"this row logically continues" a **derived predicate** at every site that asks
the line-structure question:

    logicalContinuation(row) = row.isSoftWrapped && marginHoldsContent(row)

where `marginHoldsContent` means the last column's kind is `.narrow`,
`.wideTail`, or `.spacerHead` (equivalently `retainedContentEnd == width` or the
last cell is a `.spacerHead`).

The argument for it: the defect class is a mutable bit with roughly fifty
writers, one of which left it stale. The class cannot be fixed at the writers,
because xterm parity *requires* EL 1 and EL 2 to leave it stale -- blank then
rewrite in place is a deliberate transient, as `#eraseLine`'s own comment says.
But the readers are a narrow waist: about five sites ask the question. Define
the answer there and the incoherent pair still exists in storage but has no
observable meaning anywhere. A writer can bypass a choke point; nothing can
bypass a definition.

It also beats severing on behavior. If the app rewrites the blanked row back to
full width before it scrolls off -- exactly the case EL 2 semantics exist for --
the evidence returns and the continuation is preserved. Severing destroys it
permanently.

Adoption sites:

- `LogicalLineStore.swift#admissionExtent` and the close-record condition in
  `#admit` (the fusion site).
- The live-grid resize reflow: `Terminal.swift#reconstructLogicalLines`,
  `#liveReflowLine`, `#logicalCellCount`.
- The text projections and selection line-joining walks
  (`#projectedHistoryText` and the `isSoftWrapped` expansion loops).
- The oracle `#rowStructure`.

`#eraseLine` stays exactly as it is. Parity stands and
`CSIEraseTests#eraseLineWrapAsymmetry` stands.

### Rejected, and why

- **Validate at admission only.** Correct instinct but one consumer short.
  `Terminal.swift#logicalCellCount` (`row.isSoftWrapped ? columnCount :
  retainedContentEnd(in: row)`) and `#reconstructLogicalLines` trust the raw flag
  just as absolutely. A SIGWINCH landing *during* the blank-and-claimed transient
  fuses lines in the live-grid reflow, where admission never sees it. The captured
  tape happens to resize at a clean moment; that is luck, not safety.
- **Sever the claim on EL 2.** Note the reason this is rejected is *not*
  external compatibility: the flag is never observable by the application, no
  sequence reports it, and cursor position after EL is identical, so AGENTS.md's
  control-sequence exception is not implicated. It is rejected because it
  permanently splits the rewrite-in-place case that ghostty, kitty, and foot all
  keep joined, and being alone with tmux is a smell.
- **Delete the stored bit entirely.** Impossible, per the exact-width-line
  argument above.

## The fix that was actually written

Implemented and tested in the working tree, 2026-08-07 second session.

**`GridRow.marginErased`: one transient provenance bit per live row.** Set when
an erase blanks the row's last column (`eraseCells` sets it whenever the erased
range reaches the margin -- EL 2 always, EL 1 only with the cursor at the last
column, ED per-row via the same funnel). Cleared when a print writes the last
column (`writeNarrowCells`' margin case, a wide tail landing on the margin, a
`.spacerHead` placed by a declined wide). Rows built by reflow (`pack`) and rows
folded out of the store never carry it. The readers consume
`GridRow.logicallyContinues = isSoftWrapped && !marginErased`.

Why a stored bit when the review's whole case was for a derived predicate: the
distinguishing fact -- erased leftover versus positional interior padding at the
margin -- is not present in the cells, only in the write history. The bit
records exactly that one fact at the moment it is created, and nothing else.
The claim itself (`isSoftWrapped`) is untouched at all ~50 writers, so xterm
parity stands and `CSIEraseTests#eraseLineWrapAsymmetry` passes verbatim.

Reader adoption, matching the "narrow waist" framing:

- `LogicalLineStore#admissionExtent` measures a gated row as a hard end, and
  `#admit` closes the record on the gated value (the fusion site).
- `Terminal#reconstructLogicalLines`, `#liveReflowLine`, `#liveReflowOffset`,
  `#logicalCellCount` gate directly (the live-reflow fusion site).
- The projection stream constructors collapse the claim to its gated value as
  live rows enter a stream (`ProjectionRows` subscript, `activeProjectionRows`,
  `presentedRows`, `primaryProjectionRows`, `fullHistoryText`,
  `primaryHistoryText`), so every text/selection walk downstream reads line
  structure with no knowledge of the transient.
- `#rowStructure` reports the gated value as `softWrapped` plus the raw
  transient as `staleWrapClaim`.
- `geometry` and `viewportStreamRow` stay **raw**: grid facts, the parity pin's
  window, and the render walks that read only cells.

Semantics this buys, each pinned by a test in
`TerminalCoreTests/TerminalStaleWrapClaimTests.swift`:

- EL 2 + shorter rewrite + scroll-off admits separate records (the user's bug).
- The same transient survives a mid-transient resize without fusing.
- The interior-padding refold row keeps its continuation across a resize round
  trip and admits as one record (the counterexample that killed evidence-gating).
- Rewrite-in-place back to full width reprints the margin, clears the bit, and
  keeps the line joined -- the case severing on EL 2 (tmux) destroys, preserved
  here exactly as ghostty/kitty/foot preserve it.

**Verification against the original tape**: baseline violations went from 20 to
1, identical to the EL 2 ablation's 1, and that 1 is the legitimate refold in
both runs. The fused banner (one 219-cell record) now admits as its three
printed lines (31, 62, 41 cells). Line-length comparison against the ablated
replay shows one remaining difference, which is the **known, deliberate
residue**: a row rewritten in place to *full* width inherits the old claim with
real evidence, so if the row below it is then rewritten with unrelated content,
the two still fuse (147 = 58+58+31 in the tape). That fusion is forced by the
claim-keeping parity contract itself -- the terminal cannot know the app
repurposed the row -- and ghostty, kitty, and foot fuse identically there
(ghostty's `PageList.zig#reflowRow` trims trailing blanks only on non-wrapped
rows, so it fuses the *erased* class too; DanTerm is now strictly better on
that class and at parity on this one).

Ecosystem note: the whole defect class exists in every reflow-capable emulator,
not just in DanTerm's width-free store -- the store only made it permanent and
width-visible earlier. Severing on EL 2 remains rejected for the same reason as
before.

### Separate bug, fixed in the same tree

`Terminal.swift#advanceToNextRow`: when the cursor is on the last screen row but
the scroll region's bottom is *above* it, the first branch is false
(`cursor.row != region.upperBound - 1`), the second is false
(`cursor.row < rowCount - 1` fails), the cursor does not move, and
`#restoreWrapClaimBeforeCursor` then stamps `rows[cursor.row - 1]` -- a
region-interior row the wrap never touched. Reachable by inline-viewport TUIs
that pin a footer with `CSI 1;N r`; codex/ratatui do this. Claude Code emits
`ESC[r` and never sets a region, so it is not the cause of the bug above.

The gate *contains* this (a stamped short row becomes inert) but does not
subsume it: if the stamped row happens to be full to the margin, the spurious
claim has evidence and fuses two real lines. **Fixed**: `advanceToNextRow` now
tracks whether it actually scrolled or moved and skips
`restoreWrapClaimBeforeCursor` when the advance was declined. Pinned by the
pinned-footer test below.

### Tests (written, all passing)

`TerminalCoreTests/TerminalStaleWrapClaimTests.swift` (five tests: admission
sever, live-reflow sever, refold-seam keep, full-width-rewrite keep, pinned
footer) plus the wide-glyph margin case in
`TerminalCoreTests/TerminalRowStructureTests.swift`. Three were red before the
fix (admission, live reflow, pinned footer); the two keep-cases are guard pins
that were green before and must stay green -- they are what the abandoned
evidence-gating design would have broken.

## Working tree state

Branch `experiment/swift-terminal-engine`. Everything below is **uncommitted**.
`just test` green (all 75 steps) after the fix, 2026-08-07 second session.

The tree now holds two logical changes on top of each other:

1. **The tooling** (first session): `pane rows`, `pane zoom`, `isZoomed` in
   `pane info` -- the files listed in the first session's table below.
2. **The fix** (second session):
   - `lib/TerminalCore/.../Terminal.swift` -- `GridRow.marginErased` /
     `logicallyContinues` / `withGatedContinuation`; set/clear sites in
     `eraseCells`, `writeNarrowCells`, `printWide`, `upgradeClusterToWide`;
     reader gates in reflow; projection-boundary normalization; the
     `advanceToNextRow` declined-advance fix; `rowStructure` reports the gated
     flag, `marginCellKind`, `staleWrapClaim`, and applies the seam-spacer rule.
   - `lib/TerminalCore/.../LogicalLineStore.swift` -- admission gates on
     `logicallyContinues`.
   - `lib/TerminalCore/.../TerminalGeometry.swift` -- `marginCellKind` and
     `staleWrapClaim` on `TerminalRowStructure`.
   - `app/TerminalSession.swift`, `app/SwiftTerminalSessionView.swift`,
     `app/AppRuntime.swift` -- `marginKind` + `staleWrapClaim` through the
     session boundary into the `pane rows` JSON.
   - `integrations/danterm/SKILL.md` -- the check documented as heuristic, new
     fields.
   - New: `lib/TerminalCore/Tests/TerminalCoreTests/TerminalStaleWrapClaimTests.swift`.
   - `TerminalRowStructureTests.swift` gained the wide-glyph margin case.

First-session file table (tooling):

    app/AppRuntime.swift                    pane.rows + pane.zoom perform cases
    app/SwiftTerminalSessionView.swift      readRowStructure, maps engine -> session type
    app/TerminalSession.swift               TerminalSessionRowStructure + protocol method
    cli/main.swift                          help text for pane rows and pane zoom
    integrations/danterm/SKILL.md           both commands, usage, the invariant check
    lib/DanTermCore/.../Command.swift       readPaneRowStructure
    lib/DanTermCore/.../Update.swift        pane.rows + pane.zoom handlers, isZoomed in paneInfoResult
    lib/DanTermCore/Tests/.../UpdateIpcTests.swift    UpdateIpcZoomTests suite
    lib/DanTermProtocol/.../CLIParser.swift parsePaneRowsCommand, parsePaneZoomCommand
    lib/DanTermProtocol/.../Methods.swift   paneRows, paneZoom
    lib/DanTermProtocol/Tests/.../CLIParserTests.swift  parser tests for both
    lib/TerminalPTY/.../TerminalPaneSession.swift      readRowStructure
    tests-ui/SidebarViewTestShim.swift      conformance stub
    tests-ui/SwiftTerminalSessionViewTestShim.swift    conformance stub

## Reproducing from scratch

The dev CLI is `.build/debug/DanTermCLI` -- the installed `danterm` is from the
last production release and lacks both new commands.

    ./scripts/dev-slot-launcher.py                  # prints the socket path
    export DANTERM_SOCK=<socketPath from that JSON>
    CLI=.build/debug/DanTermCLI

    # a pane running Claude Code in half a horizontal split
    $CLI tab new --group <gid> --cwd <repo> --title probe --foreground
    $CLI pane split --pane $P -h --cwd /tmp
    $CLI pane input --pane $P -- "claude --permission-mode plan" Enter
    $CLI pane tape --pane $P --follow --from-now > tape.jsonl &

    # produce prose long enough to wrap, then cycle the zoom
    $CLI pane input --pane $P --literal -- "<prompt asking for long unbroken paragraphs>"
    $CLI pane input --pane $P -- Enter
    $CLI pane zoom --pane $P on;  $CLI pane zoom --pane $P off   # repeat ~4x

    # check (heuristic -- see the oracle section; spacer margins and refold
    # seams are legal, so eyeball what this flags)
    $CLI pane rows --pane $P | python3 -c '
    import json, sys
    for r in json.load(sys.stdin)["rows"]:
        if r["softWrapped"] and r["contentEnd"] < r["width"] \
           and r["marginKind"] != "spacerHead":
            print(r)'

Pre-fix, violations appeared on **unzoom** (the narrowing direction), first in
the live grid, then migrating to `retained: true` as those rows scrolled off,
at which point they were permanent. Observed progression across four cycles:
0, 2, 1, 8, 1, 18, 4, 20. Post-fix the tape replays to a single flagged row
(the legitimate refold), and `staleWrapClaim: true` rows may appear transiently
in the live grid during a repaint -- that is the parity transient, inert by
construction.

To replay a tape headlessly, walk the JSONL and drive `Terminal`: records with
`columns`/`rows` are resizes (the first builds the terminal), records with
`base64` are feeds. Ablate by rewriting bytes in the feed payloads before
feeding.

## What was ruled out along the way

Recorded so nobody re-runs these:

- Ink never prints into the last column on its own. It positions with `ESC[nG`
  and ends lines with `\r\r\n`. A fresh replay of a captured stream produces zero
  wrap flags.
- Replay with live `TIOCSWINSZ` resizes at 89 -> 178 -> 89 -> 178 -> 89, real
  SIGWINCH and real Ink repaints, engine resized at the recorded byte offsets:
  zero fusions. The zoom path differs because the pane, not the window, changes
  size, and the repaint arrives against a live grid in a different state.
- A 13-point resize round-trip sweep, 89 -> {20,30,...,200} -> 89: zero fusions.
- Split and close to cycle pane width, during streaming and settled: zero
  violations. Only zoom reproduces it.
- The user's corrupted pane came from a binary built 2026-08-06 19:36, i.e.
  before commits `90731fdc` (T8, `printBulkASCII`) and `3c88a2e9` (T7). Those
  are not implicated -- the bug reproduces on current HEAD.

## Open question -- answered

The 1 residual violation under EL 2 ablation. Both hypotheses were refuted
(zero spacer margins anywhere in the replay, zero `ESC[1K` in the tape). The
answer is the legitimate interior-padding refold documented in the oracle
section: it appears transiently in the live grid at every unzoom (born at the
resize event itself, absorbed by the next repaint) and lands in scrollback once
at the last cycle. It is present, and legal, under baseline and ablation alike
-- post-fix, baseline and ablated replays both report exactly this 1.
