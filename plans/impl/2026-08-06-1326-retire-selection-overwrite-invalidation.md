# Retire overwrite-invalidation of the selection

## Problem

Holding a click-drag selection while a TUI (Claude Code, Codex) repaints makes
the selection flicker at the TUI's frame rate.

Cause, verified in source: `Terminal.swift#invalidateInspection(inAbsoluteRows:)`
nulls the entire selection whenever a cell write touches a row the selection
intersects. A TUI repaints selected rows every frame, so the selection dies every
frame; the drag latch in `TerminalInteractionPolicy.swift#TerminalInteractionState`
holds a `PinnedTextRange` anchor and re-issues the whole range on the next
pointer-move, restoring it. Clear/restore alternation is the flicker.

The same rule also eats a *settled* selection under a repainting TUI, with no
restore -- the selection simply vanishes. That is the same defect without a drag.

Load-bearing premises:

- The selection already has a complete lifecycle without this rule: eviction
  clamps or drops (`handleEviction`), row-numbering epochs retire it on screen
  switch and reset (`clearInspection` + `renumberRows`), resize clamps
  (`clampSelectionToRetainedStream`), and width reflow restates or drops anchors
  by content address (`restateAnchors`).
- The tradeoff is already shipped in the busiest path: `advanceToNextRow` scrolls
  the region with `invalidatesInspection: false`, so plain linefeed scrolling has
  never invalidated the selection.
- There is no compatibility ground truth here. Ghostty does not clear selections
  on overwrite; kitty does. This is a design choice, and DanTerm's pinned-range
  idiom is already the ghostty model, applied to the drag anchor but not to the
  selection.

## Decision

Delete the selection branch of `invalidateInspection(inAbsoluteRows:)`. Keep the
search-occurrence, hovered-link, and armed-link branches: those are the engine's
claims *about content* and die with the content, whereas a selection is the
user's claim on a region and is retired only by the user or by the region
ceasing to exist. That asymmetry is surprising enough that the rationale belongs
in a comment at the site.

Because the selection is then no longer acted on by that function, narrow the
per-printed-character fast-path guard to the three fields it still gates. This is
a strict reduction in hot-path work: a settled selection stops flipping the guard
true and costs nothing per character.

The change is confined to the engine plus tests and one contract amendment. No
interaction-policy, render, PTY, or app change: nothing outside the engine clears
a selection in response to output.

The normative contract in
[plan-terminal-engine/08-input-interaction.md](../../plan-terminal-engine/08-input-interaction.md)
currently states that content overwritten by terminal output invalidates the
affected selection endpoint or search match. Amend it in this change so the two
channels are stated separately: a selection is geometrically anchored and
survives overwrites of the rows it covers, while search matches and link state
remain content-derived and are invalidated by an overwrite. Leaving the old text
standing would make this behavior read as a regression to a later reader.

**Accepted behavioral change, confirmed with the user:** a selection held over
text a program overwrites now stays highlighted and copies the *new* text under
the highlight, rather than disappearing. On the alternate screen this extends to
region scrolls (vim `Ctrl-E`, a TUI log pane): the highlight stays geometrically
fixed while text moves under it.

## Invariants

- **I1.** A selection survives any program write to the rows it covers, and
  `selectedText` reports what is now under the highlight.
- **I2.** No frame exists in which a held drag's selection is absent: with the
  button down, the selection is non-nil at every observation across interleaved
  pointer-moves and repaints, not merely at the end.
- **I3.** A search occurrence, a hovered link, and an armed link are still each
  dropped by an overwrite of the rows they cover.
- **I4.** Every remaining retirement mechanism still retires the selection --
  eviction past its end, alternate-screen entry and exit, hard reset, and a width
  reflow that drops an endpoint.
- **I5.** A selection that was non-empty when made never survives a width reflow
  as a collapsed, zero-length selection: it is either absent or non-empty. Two
  paths reach that collapse once the rule is deleted, and both are in scope --
  prompt vacating before reflow, and an erase of the selection's content (which
  I1 now keeps alive) followed by a width change. Both end at the same reflow
  restatement fallback, which sends every anchor with no surviving boundary to the
  line's content end; a zero-length selection keeps Copy enabled and copies an
  empty string. I5 is specific to that collapse. Present-but-empty selections the
  engine produces deliberately stay: Select All on an empty or blank buffer, which
  keeps Copy enabled by design, and a selection whose covered content a program
  erased with no reflow, which I1 requires to remain present.
- **I6.** Damage stays sufficient with a live selection: a plan built from
  drained damage equals a from-scratch plan when a write lands inside a
  selection, including when only some of a multi-row selection's rows are
  written and when the viewport is scrolled back.
- **I7.** Narrowing the fast-path guard gates nothing but inspection
  invalidation: content mutation that arrives while only a selection is live is
  still visible to a search opened afterwards.

## Proof obligations

- **PO1 (I1).** Overwrite every row a selection covers; assert the selection is
  present and `selectedText` equals the new content. State the tradeoff at the
  assertion so restoring the old branch fails loudly.
- **PO2 (I2).** At the `decideTerminalPointer` seam with the button still down,
  interleave pointer-move, repaint, pointer-move, and assert selection presence
  at each step. An end-state check is insufficient -- the old code passed one and
  still flickered.
- **PO3 (I1, no drag).** Same overwrite after the pointer is released, proving
  the fix does not depend on the drag latch.
- **PO4 (I3).** One overwrite drops all three other channels while the selection
  survives.
- **PO5 (I4).** The existing eviction, alt-screen, hard-reset, and reflow tests
  stay green *by their own mechanism*. Confirm rather than assume: at least one
  of them passes today because of the deleted branch.
- **PO6 (I5).** Both collapse paths, each asserting the selection is absent or
  non-empty and never collapsed to zero length: select a non-empty prompt, vacate
  it, and change width; and select non-empty text, erase the content under it, and
  then change width. A third case pins the other side: erase under a settled
  selection with no reflow, and assert the selection is still present with empty
  `selectedText`, so a fix for the collapse cannot be generalized into a rule that
  drops every empty selection.
- **PO7 (I6).** Reuse-vs-from-scratch planning equality for a write inside a live
  selection, in both the following and scrolled-back viewport states. Extend the
  existing pane frame-planning tests, which already own this shape.
- **PO8 (I7).** A search opened after output arrived while only a selection was
  live still sees that output.

Existing tests that pin the deleted rule invert rather than being deleted -- their
subject survives, only the expected outcome flips, and their search-channel arms
stay as part of what discharges PO4. Any such test that becomes vacuous once the
selection stops clearing is re-aimed so it still states a claim, not left passing
trivially.

## Non-goals

- Making the selection track content as it moves (reanchoring to text rather than
  to stream rows). Out of scope; the accepted tradeoff is the fixed-anchor
  behavior.
- Changing when the alternate screen force-clears the selection on entry and
  exit. That is deliberate and stays.
- Any change to how search occurrences, hovered links, or armed links invalidate.

## Accepted risks

- **AR1.** A selection held across a repaint copies text the user did not
  originally select. Accepted explicitly: it is strictly better than the
  selection vanishing, and it is what the engine already does for linefeed scroll.
- **AR2.** The render corpus damage gate is structurally blind here -- none of its
  fixtures contains a mouse event, so no fixture has ever held a selection while
  output arrived. It will pass this change without evidence, and must not be
  cited as confirmation. PO7 is the real gate; closing the corpus blind spot with
  a mouse-bearing fixture is deferred.
- **AR3.** The performance ladder has no selection-holding workload, so the
  hot-path effect is unmeasurable in either direction with the current
  instruments. No benchmark is claimed. The guard narrowing is defensible without
  one only because it strictly removes work in every reachable state -- do not
  report a benchmark result for this change.

## Rejected ideas

- **RI1.** A drag-active flag in `Terminal` that suppresses invalidation while
  the button is down. Fixes only the drag case, leaves the settled-selection case
  broken, puts gesture state in the wrong owner, and leaks into permanent
  suppression if pointer-up is never delivered.
- **RI2.** Content-sensitive invalidation (drop only when a write changes cell
  contents). Does not work: TUIs repaint erase-then-reprint, so the erase step
  changes contents even when the frame is identical, and dynamic rows genuinely
  differ each tick. Adds per-write comparison to the parser's hottest path for a
  partial fix.
- **RI3.** Re-applying the selection at the render layer while the engine reports
  none. Splits the source of truth: copy would read nil while the screen shows a
  highlight.
- **RI4.** Softening the deletion into a middle ground that shrinks the selection
  to its untouched part. This silently breaks I6 -- the shrunk-away rows change
  appearance and need not fall inside the write's row range.

## Implementation discretion

- How I5 is discharged: any mechanism scoped to the reflow collapse, including a
  single one at the restatement site covering both paths. A terminal-wide "drop
  every collapsed selection" rule is not available -- it would break Select All on
  an empty buffer and the erased-selection case I1 requires.
- Whether the rationale for the selection/search asymmetry lives only at the
  deletion site or is graduated to a design doc.
- Helper naming, comment placement, and which test files hold the new and
  inverted cases.

## Verification

- `just test` green, with the inverted and new tests above.
- Manual, from this worktree: `just provision-worktree` once, then `just launch`
  (never `just build-run`, which would replace the user's canonical dev app), and
  drive the launched slot with an explicit `danterm --socket` argument. Start
  Claude Code or `btop` in a pane, drag a
  selection across live output and hold it -- no flicker; release and let the TUI
  keep repainting -- the highlight stays. Then confirm the retirement paths by
  hand: scroll the selection out of scrollback, enter and leave the alternate
  screen, and resize the window across a prompt selection, checking Copy is not
  enabled with nothing to copy.

## Implementation notes

- Width-reflow collapse uses selection-creation content provenance rather than anchor distance: a deliberate selection over blank cells can have distinct anchors while still being intentionally empty, so coordinates alone cannot distinguish it from selected content erased before reflow.

## Follow Up

- Run the manual live-TUI selection and retirement-path verification above from an interactive session with screen-capture and input permissions; this agent environment could launch the isolated slot but `CGPreflightPostEventAccess()` returned false and screen capture was unavailable.
