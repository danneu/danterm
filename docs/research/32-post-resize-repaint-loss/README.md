# Post-resize repaint loss

Research started: 2026-08-05.
Continues: [19-owner-queue-occupancy.md](../19-owner-queue-occupancy.md) (`19/F15`, `19/D4`).

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.

## Purpose

This doc owns one defect: **after a resize, rows that are still present in the
grid are not painted.** They are recoverable -- selecting them, or scrolling
them, brings them back unchanged -- so nothing is lost from the terminal state.
What is lost is the paint.

It exists because `19/F15` sent an agent to run one live test and that test
found something other than what it predicted. `19/D4` framed the outcome as a
binary: either the stacked prompts on resize were a storm artifact, or there was
a reflow cursor bug underneath. The answer is the first (`F2`), and the storm
half now belongs to the shell rather than to DanTerm. But the same session
surfaced a second, unrelated symptom that is DanTerm-only and reproduces on a
*settled* single-column resize (`F1`). That is this doc's subject.

The boundary inherited from doc 19: the resize-storm debris is **not ours** and
is not investigated here (`F2`). Reflow *cost* is settled and not reopened --
`28/D11`'s amendment records the same recipe at 1.58 ms after `9ad7cc5`, so
nothing in this doc is a performance question.

## Investigation rules

- **This is a paint defect, not a parse defect.** A PTY byte recording
  (`DANTERM_PTY_RECORDING_DIR`) captures what the child wrote; it cannot
  capture a frame that was drawn against the wrong damage. Replaying bytes
  into `TerminalCore.Terminal` will show the rows present, which is already
  known (`F1`). Evidence has to come from the view layer.
- **The grid is not the suspect until it is measured.** `F4` reads
  `Terminal.swift#resize` marking full damage on every resize. Any hypothesis
  that blames the core has to explain that line first.
- **Shell dependence is a timing signal, not an attribution.** zsh reproduces
  and fish/bash do not (`F1`), but the shell integration is innocent (`F3`) and
  the debris control (`F2`) shows zsh's redraw is normal terminal traffic. Treat
  zsh as a reliable *stimulus*, not as a cause.
- No fix lands without a test that fails first in the automated AppKit harness
  (`just test-ui`), which already has a `clipRectsForTesting` seam on the draw
  path.

## Trigger and current evidence

An interactive session on 2026-08-05, driven by the user in a `just build` dev
app at branch `experiment/swift-terminal-engine` (`69f6cbc8`), running the
`19/F15` test that doc 19 had been waiting on since 2026-07-30.

The recipe, in a DanTerm pane running zsh with a two-line starship prompt:

1. Ctrl-L, then Enter three times, so the pane holds a few prompts and **no
   scrollback**.
2. Widen the window by roughly one column, release, pause. Repeat.
3. Between the 8th and 10th widen, every prompt above the live one disappears.

The pane is not blank: the live prompt and its cursor render normally at the
new width. Only the rows above stop being painted. See `F1` for the full
property list, including the three independent ways the rows come back.

## Current hypotheses

### `H1` -- the full-damage frame is consumed before the layer takes its new size

`Terminal.swift#resize` sets `damage.reset(rowCount:isFull:)` with
`isFull: true` (`F4`), so the core does mark everything damaged. If a draw
consumes that snapshot *before* the backing layer is resized, the layer resize
then discards its contents, and the next frame carries only the small damage
zsh's post-SIGWINCH redraw produced -- two rows painted onto a blank layer.

Supports it: the rows are provably still in the grid (`F1`); any new damage over
them repaints them correctly; it explains shell dependence without blaming the
shell, since zsh reliably writes immediately after SIGWINCH and so reliably
lands a sparse-damage frame inside that window.

Competing: `H2`, `H3`.

Distinguishing experiment: instrument the frame sequence across a resize --
which draw consumed the full-damage snapshot, and what the layer's size was at
that moment. The `clipRectsForTesting` seam already records per-draw clip rects.

### `H2` -- a regression from the sparse damage clip -- **mechanism confirmed** (`F6`)

Before this work, a draw whose damage was sparse still filled `dirtyRect`;
after it, the fill happens inside the sparse-row clip, so rows outside the
clip keep whatever the layer already held. On a freshly resized layer, that is
nothing.

Supports it: the symptom's shape is exactly "unclipped rows keep stale layer
contents"; `F6` reads the one-line move that created the mechanism; and `F5`
measures the exposed rows as the bare layer background rather than as
renderer-painted background.

**The boundary is one commit earlier than this doc first assumed.** The fill
moved inside the clip in `d3780961` ("preserve sparse AppKit damage",
2026-08-01), not in doc 29's `f3c774d`. `f3c774d` (maximal spans) and doc 30's
`c4fc65f7` (folded clip) only reshape the clip `d3780961` introduced. `F5`
reproduced the vanish at `f3c774db~1` for exactly this reason.

Competing: `H1` -- and note the two are compatible. `H1` is the ordering that
lets a sparse frame land at all; `H2` is what makes a sparse frame destructive
instead of merely incomplete. `F5` and `F6` support both halves.

Remaining experiment: build `a94abc26` (`d3780961~1`) and confirm the vanish
does not reproduce, which closes the attribution.

### `H3` -- the viewport anchor, not the damage -- **rejected** (`F5`)

Excluded on evidence. An anchoring defect still has the renderer fill
background for the cells it draws, which samples as the dithered `#0c0c0c` every
other empty row in the frame carries. The vanished band samples as flat
`#0d0d0d`, the layer's own background, so no frame drew those pixels at all.
Retained below as the original statement; see `README.md#Rejected`.

An alternative reading of `F1`: the rows are painted, but the viewport is
anchored such that they fall outside it, and the pane renders blank space where
they should be.

Against it, already: the live prompt stays put at the *bottom* of the pane while
the rows above vanish, and pressing Enter enough times to push content into
scrollback makes the earlier rows reappear in place rather than scrolling them
into view (`F1`). Both fit damage better than anchoring. Kept because it has not
been directly excluded, and because it predicts a different fix.

## Task ledger

### Phase 1 -- attribute the frame

- [x] Build at the commit before `f3c774d` and re-run the `F1` recipe. **It
      reproduces** (`F5`), so the boundary is older than `f3c774d`.
- [x] Locate the real boundary. `F6`: `d3780961` moved the background fill
      inside the sparse-row clip; `f3c774d` and `c4fc65f7` only reshape it. The
      bisect between those two is moot and is dropped.
- [x] Build `a94abc26` (`d3780961~1`) and confirm the vanish does **not**
      reproduce. `F8`: clean across 30 widens, and -- the stronger signal --
      fast-drag flicker is present at `d3780961` and absent at `a94abc26`.
      **Attribution to `d3780961` is settled.**
- [ ] Instrument the draw sequence across a single resize: which frame consumed
      the full-damage snapshot, the layer size at that moment, and the clip
      rects of the frame that followed. `clipRectsForTesting` is the existing
      seam. Record in `F7`; this decides `H1`, whose ordering claim is so far
      inferred from source rather than measured.
- [x] Exclude `H3`: rejected by `F5`'s pixel measurement.

### Phase 2 -- make it deterministic

- [x] Reproduce in the `just test-ui` harness without a shell. **Done**:
      `tests-ui/SwiftTerminalSessionViewTests.swift`, "the first draw after a
      resize fills every row". It widens a mounted pane, emits a single-row
      damage frame standing in for zsh's redraw, and asserts the clip covers
      every row. Currently fails with rows `[0...6]` unfilled; 207/208 pass.
      This is the gate for any fix.

      `F7`'s constraint turned out not to bind here. A live drag is what makes
      the bad ordering *arise* in the real app, but the harness does not have to
      wait for it -- the test injects the ordering directly by controlling which
      frame follows the resize. Live-resize modelling would only be needed for a
      test that reproduces via timing rather than construction.
- [ ] Record how tight the timing window is -- whether the injected write has
      to land within a specific frame, which tells the fix how much slack it
      has.
- [ ] Prefer the **fast-drag flicker** as the regression signal over the
      settled-widen recipe (`F8`). It is deterministic and high-frequency rather
      than stochastic, so an automated detector built on it can pass the
      calibration gate `F7` failed: it must show flicker at `d3780961` and none
      at `a94abc26` before it is trusted anywhere else.

### Phase 3 -- fix and verify

- [x] Direction gate. Recorded as `D1`: force a full repaint when the view's
      size changes, chosen because it is the only candidate that does not
      presuppose `H1`'s still-unmeasured ordering. The `dirtyRect`-fill option
      was struck before the gate ran (`F6`).
- [x] Land the fix behind the Phase 2 test.
      `SwiftTerminalSessionView#setFrameSize` invalidates fully on a size
      change. UI suite 208/208, `just test` 77/77, and the three sparse-clip
      tests still pass.
- [x] Confirm by hand. `F9`: the fast-drag flicker is gone. Debris on narrowing
      remains and is `F2` -- `danterm pane read` shows it in the grid, so the
      shell wrote it and DanTerm is painting faithfully.
- [x] Confirm the sparse-clip benefit doc 29 measured is still present.
      Structurally untouched: doc 29's win is steady-state sparse damage, and
      `#setFrameSize` is not on that path -- typing and TUI redraws never reach
      it. The three regression tests cover the clip's behaviour, and
      `terminal-benchmark-draw-path-lint.sh` passes.
- [ ] **Open, uninstrumented**: the cost `D1` itself adds, one full repaint per
      resize frame. No resize benchmark exists -- `terminal-benchmark.sh` and
      its companions measure feed workloads, not geometry changes -- so the only
      evidence is that hand-dragging in `F9` showed no smoothness complaint.
      Build an instrument before treating that as verified.

## Rejected

### `H3`, the viewport anchor

`F5`. The vanished band samples as flat `#0d0d0d` -- the layer's own background
colour, composited by CoreAnimation -- while every other empty row in the same
frame samples as `#0c0c0c` with conversion dither, the renderer's own
`context.fill`. An anchoring defect would still route those pixels through the
renderer. Nothing painted them, so the defect is damage, not anchoring.

### The DanTerm shell integration

`F3`. Ruled out directly: the vanish reproduces with the integration's marks
disabled and the prompt otherwise identical. The hypothesis was reasonable --
`integrations/shell-integration/danterm.zsh` puts `OSC 133;A;redraw=1` inside
PS1, and that `redraw` promise is precisely a licence for DanTerm to blank part
of the prompt block before reflowing -- but the evidence excludes it. Reopen
only if a case appears where the vanish *depends* on the marks.

### zsh's redraw, as the cause of the vanish

`F2` establishes zsh's post-resize redraw is ordinary: three terminals render
the storm debris the same way, so zsh is not emitting anything exotic. zsh
remains the reliable stimulus, and Phase 2 exists to remove even that dependence.

## Open questions and caveats

- ~~Whether this is a regression or has always been present.~~ **Answered**: a
  regression, and a recent one. `F6` puts the mechanism at `d3780961`
  (2026-08-01), four days before the first sighting. The `a94abc26` control
  build is what turns this from "located" into "confirmed".
- Whether fish and bash are genuinely immune or merely unlucky stimuli. `F1`
  failed to reproduce with either across ~12 widens, which is not the same as
  proof.
- The session produced screenshots but no saved artifacts, and none of the
  evidence here is instrumented. Every `F1` property is a human observation of
  a live pane; Phase 1 exists partly to replace that with a measurement.
- `19/F15`'s original 2026-07-30 incident is described as zsh. The prompt in its
  screenshot is the same width-truncating segment this session ran under fish,
  so the shell attribution in that finding may be wrong. It does not affect
  anything here.

## Outcome

**Fixed**, pending one open verification.

The defect was attributed to `d3780961` (`F6`, `F8`), `H3` was rejected on
measured pixels (`F5`), and `H1` and `H2` were confirmed as the two halves of
the mechanism. `D1` forces a full repaint when the view's size changes, which is
correct independently of `H1`'s ordering -- the one claim still inferred from
source rather than measured. The Phase 2 test fails without the change and
passes with it; `F9` confirms the fast-drag flicker is gone in the real app.

Still open: re-measuring doc 29's sparse-clip performance win (its behaviour is
covered by three passing regression tests, but the number has not been re-run),
and the `H1` frame instrumentation, which is now optional since no shipped
behaviour depends on the answer.

Out of scope and unchanged: the resize-storm prompt debris (`F2`, `F9`). It is
in the grid, the shell wrote it, and three terminals render it alike.
