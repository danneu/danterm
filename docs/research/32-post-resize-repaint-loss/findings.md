# Findings -- post-resize repaint loss

Continues doc 19; qualified citations like `19/F15` refer to
[../19-owner-queue-occupancy.md](../19-owner-queue-occupancy.md).

Provenance for `F1`-`F3`: one interactive session on 2026-08-05, run by the user
in a `just build` dev app at branch `experiment/swift-terminal-engine`
(`69f6cbc8`), agent-directed step by step. These are human observations of a
live pane, reported as seen and reproduced more than once each. They are
trustworthy as reproductions and are **not** instrumented; no artifact was saved
beyond screenshots in the session transcript. Phase 1 exists to replace them
with measurement.

## `F1` -- rows stop being painted after a settled resize, and three things bring them back

**Reproduction.** DanTerm dev app, one pane, zsh with a two-line starship prompt
carrying a width-truncating right segment:

1. Ctrl-L, then Enter three times. The pane holds a few prompts and **no
   scrollback** -- everything is on the live screen.
2. Widen the window by roughly one column. Release the mouse. Pause about a
   second. Repeat.
3. Between the 8th and 10th widen, every prompt above the live one disappears.

Also reproduced by narrowing, and reproduced a second time in the same session
after one narrowing step followed by column-by-column widening.

**Observed.**

- The live prompt and cursor render correctly at the new width. Only the rows
  above stop being painted.
- The rows are **not lost**. Three independent actions bring them back
  unchanged: click-dragging a selection across them, scrolling once scrollback
  exists, and pressing Enter enough times to push content into scrollback by a
  row or two.
- Once recovered, they stay correct -- scrolling afterwards does not make them
  vanish again.
- A subsequent resize step sometimes repaints them on its own.
- It happens on a step where the mouse was released and the resize had settled,
  not only during a continuous drag.

**Inferred.** The terminal state is intact and the *paint* is missing: rows
inside the viewport, present in the grid, that no frame filled. Anything that
marks those rows damaged repaints them correctly, which is the signature of a
frame drawn against damage narrower than what was actually invalidated.

**Competing interpretations.** A viewport-anchoring defect would also produce
"rows I expect to see are not there" (`H3`), but not the selection-repairs-it
property, and not the live prompt holding its position at the bottom while the
rows above it disappear.

**Uncertainty.** Human observation, uninstrumented. "Roughly one column" is a
mouse drag, not a controlled step; the trigger count (8-10) is therefore soft.
Whether the step must be settled is established (it reproduced on settled
steps) but the converse -- that an unsettled step cannot do it -- is not.

**Next action.** `H2`'s rebuild (Phase 1, task 1), then the frame instrumentation
that decides `H1`.

## `F2` -- the resize-storm debris is not ours

**Reproduction.** The same pane, and then the same shell and prompt in two
other terminals. Grab the window edge and shake it -- fast drags wide to narrow
and back, two or three passes, no pause.

**Observed.**

| terminal | zsh | fish | bash |
| --- | --- | --- | --- |
| DanTerm | debris | debris (fast shake) | clean |
| Terminal.app | debris on narrowing | debris on fast resize | clean |
| iTerm2 | debris | debris | clean |

The debris is partial prompt fragments (`repo:dan`, `rep`, `r`) and truncated
right-prompt segments (`k8s:orbstac`, `k8s:orbs`, `k8s:orb`) landing mid-row and
concatenated onto rows that already hold a previous fragment.

**Inferred.** This is the shell's own prompt-redraw race under a burst of
SIGWINCH, not a terminal defect: three independent terminals render it the same
way, and it tracks the shell rather than the emulator. bash is clean in all
three, which is consistent with it not repainting the prompt the way zsh's zle
redisplay and fish's repaint do.

**This closes `19/F15`'s open question.** `19/D4` framed two branches; this is
the first one. The stacked prompts in the 2026-07-30 screenshot were a storm
artifact, and DanTerm renders faithfully what the shell emits under a storm.

**Competing interpretations.** All three terminals sharing a defect is
conceivable but not credible for a symptom this visible, and the bash column
argues the same way -- a terminal-side defect would not care which shell was
running.

**Uncertainty.** The fragment *pattern* differs from `19/F15`'s screenshot,
which showed whole stacked prompts rather than mid-row fragments. Same class,
possibly not the identical failure. Not pursued: it is the shell's, either way.

**Next action.** None. This is out of scope by the doc's own boundary.

## `F3` -- the DanTerm shell integration is not the cause

**Reproduction.** In a DanTerm pane, `DANTERM= zsh`, then the `F1` recipe.

**Verification that the marks were actually off** -- necessary because
`integrations/shell-integration/danterm.zsh#_danterm_enabled` resolves
`${DANTERM:-${LC_DANTERM:-}}`, so an empty `DANTERM` falls through to
`LC_DANTERM`:

```
print -r -- $PS1 | cat -v | head -c 200; echo; echo "LC_DANTERM=[$LC_DANTERM]"
```

PS1 came back as plain starship with no `^[]133;A` sequence, and `LC_DANTERM`
was empty.

**Observed.** The vanish still reproduces.

**Inferred.** Not the integration. The hypothesis was worth testing --
`danterm.zsh` embeds `OSC 133;A;redraw=1` in PS1, and per doc 24 that `redraw`
declaration is exactly a promise about how much of the prompt block DanTerm may
blank before reflowing on a resize, which would have been a precise fit for
"prompt rows disappear on resize". The evidence excludes it.

**Uncertainty.** Only the emission side was disabled. A pane whose *earlier*
prompts were stamped before the unmarked shell started could in principle carry
stale row classification; the session's `DANTERM= zsh` inherited a pane that had
been running marked shells. Cheap to re-check with a fresh pane if the question
ever matters again.

**Next action.** None; recorded as a rejection in `README.md#Rejected`.

## `F4` -- the core marks full damage on every resize

**Observed.** `Terminal.swift#resize` runs
`damage.reset(rowCount: rows, isFull: true)` before any reflow work, on the same
path that bumps `primaryHistoryObservation`.

**Inferred.** The core is not under-reporting damage on resize. Any explanation
of `F1` has to account for a full-damage snapshot existing and then not reaching
the frame that mattered -- which is what `H1` proposes and what Phase 1's
instrumentation task is for.

**Uncertainty.** Source reading only. It establishes what the core records, not
what the view consumed or when.

**Next action.** Phase 1's frame instrumentation.

## `F5` -- the vanish reproduces at `f3c774db~1`, and the vanished pixels are a different painter

**Provenance.** 2026-08-05, second session. Detached worktree at `d3780961`
(`f3c774db~1`), launched as isolated dev slot 1, Swift backend
(`resolveTerminalBackend(nil) == .swift`, no backend env var passed). Pane
staged by CLI: `exec zsh`, Ctrl-L, three Enters -- four two-line starship
prompts, no scrollback. User drove the widening by hand.

**Observed -- reproduction.** The vanish reproduces at `d3780961`. Every prompt
above the live one stopped being painted on one of the widens, with the live
prompt and cursor correct at the new width. Same symptom as `F1`.

**Observed -- pixel measurement.** The window was captured window-scoped
(`screencapture -l`) while the defect was on screen, and sampled on a 7px grid.
This is the doc's first instrumented evidence:

| region | sampled colour |
| --- | --- |
| vanished-rows band | `#0d0d0d`, 100% uniform, zero variation |
| empty background below the live prompt | `#0c0c0c` dominant, dithered (`#0b0c0c`, `#0c0d0c`, `#0c0c0b`) |
| background beside the live prompt | `#0c0c0c`, same dither |
| sidebar (control) | `#1e1e1e`, flat |

The second and third rows are empty terminal background **in the same frame** --
rows the renderer did paint. They carry +/-1 dither. The vanished band is flat
and one step away.

**Inferred.** The vanished pixels were not painted by the renderer at all. Both
values are the same nominal colour reached by two painters:
`SwiftTerminalSessionView#init` and `#applyResolvedTheme` set
`layer?.backgroundColor` from the theme, which CoreAnimation composites flat;
`#draw` fills with `context.setFillColor` + `context.fill` through the same
`#cgColor` helper, which lands in the layer's backing store with conversion
dither. Flat `#0d0d0d` is therefore the bare layer background showing through
where the layer's *contents* are empty.

**This excludes `H3`.** A viewport-anchoring defect puts the wrong rows on
screen, but the renderer still fills background for the cells it does draw --
which would sample as `#0c0c0c` dithered, like every other empty row in the
frame. It samples as the layer colour instead, so no frame drew those pixels.
`H3` is now rejected on evidence rather than kept for want of exclusion.

**Competing interpretations.** A flat band could also come from a fill that
bypassed the dithering path rather than from no fill at all. Against it: the
only other fill site in `#draw` is the same helper and the same context, and it
would have to coincidentally cover exactly the rows that recover on new damage.

**Uncertainty.** One reproduction, one capture. The colour identification is
measured; the attribution of `#0d0d0d` specifically to `layer.backgroundColor`
rather than to some other unpainted-surface colour is source-read inference, not
a probe -- nothing yet reads the layer's contents directly. The negative control
(`a94abc26`, `d3780961~1`) has not been built.

**Next action.** Build `a94abc26` and confirm the vanish does *not* reproduce,
which closes the attribution in `F6`.

## `F6` -- `d3780961` moved the background fill inside the sparse-row clip

**Observed.** `git show d3780961 -- app/SwiftTerminalSessionView.swift` moves one
line. Before, `#draw` ran `context.fill(dirtyRect)` unconditionally, before the
`if let frame` block. After, the fill is inside `saveGState()` and below the
sparse-row `context.clip()`, so a draw whose damage is sparse fills only the
damaged rows.

Three further source facts on the same path:

- `#synchronizeGeometry` calls `invalidateFullDisplay()` **only when
  `metricsChanged`**. A width-only resize changes `dimensions`, not cell
  metrics, so a widen produces no view-side full invalidation. The full repaint
  depends entirely on the core's full-damage frame (`F4`) arriving and being
  consumed after the layer has its new size.
- `#drawingDamage` consumes `pendingDisplayDamage` and resets it to `.none`, so
  whichever draw runs first spends the full-damage snapshot.
- `#publish` sets `.full` on a full-damage frame but `formUnion`s a sparse one,
  so a sparse publish after the snapshot was spent stays sparse.

**Inferred.** This is `H2`'s mechanism, and it is present at `d3780961` --
**one commit earlier than the doc assumed**. `f3c774db` (maximal spans) and
`c4fc65f7` (folded clip) only reshape a clip this commit introduced. The
README's `H2` and its Phase 1 task named `f3c774db` as the boundary; the real
boundary is `d3780961`, dated 2026-08-01.

`H1` and `H2` are the two halves the README predicted were compatible, and both
now have support. `H2` makes a sparse frame destructive rather than merely
incomplete; `H1` is the ordering that lets a sparse frame land on a layer whose
contents were just discarded. `F5`'s flat `#0d0d0d` is direct evidence the
contents were in fact empty.

**Not a fix direction on its own.** Reverting the fill to unconditional would
reintroduce the defect that motivated `d3780961`: with the plan clipped to
sparse damage, filling the whole `dirtyRect` blanks undamaged rows the draw will
not redraw. The clip is correct in steady state; what is missing is that a draw
following a layer resize has no valid contents to preserve and must be treated
as full.

**Uncertainty.** Source reading plus one diff. The *ordering* claim -- that the
full-damage snapshot is spent before the layer is sized -- is still unmeasured;
that is Phase 1's instrumentation task and it is what would confirm `H1`
outright.

**Next action.** The `a94abc26` control build, then the frame instrumentation.

## `F7` -- a programmatic settled resize does not reproduce it; the stimulus needs a live drag

**Reproduction attempt.** An automated probe drove slot 1 (`d3780961`, the build
`F5` had just reproduced on by hand) through 16 settled single-column widens:
Accessibility `set size of window 1`, 1.1 s settle per step, window-scoped
capture and pixel measurement after each. Step size calibrated to one column
(10 pt; `cols` advanced 71 -> 89 across the run). Pane staged identically to
`F5` -- `exec zsh`, Ctrl-L, three Enters.

**Observed.** No reproduction. The glyph-bearing scanline count held at exactly
106 for all 16 steps, with no partial-repaint anomaly at any step, and the
flat-fill detector never fired.

**Inferred.** The probe is **not a valid instrument for this defect** and its
negative says nothing about any build. It failed the calibration gate: an
instrument that cannot reproduce a defect on a build known to carry it cannot
be used to declare the defect absent elsewhere.

More usefully, the failure localises the stimulus. A programmatic
`set size` is a single jump: one `setFrameSize`, one settle. A mouse drag is
live resize -- `inLiveResize`, a continuous stream of intermediate frames, and
a mouse-up settle -- and that is what `F1` and `F5` reproduced under. The
difference between those two paths is where the defect's ordering lives, which
is consistent with `H1` and with `F6`'s reading that a width-only resize has no
view-side full invalidation.

**What this does and does not constrain.** It rules out driving the *live app*
through programmatic settled resizes as a reproduction route. It did **not**
end up constraining Phase 2's harness test, which reproduces on a plain
`setFrameSize`: the harness controls which frame follows the resize, so it
constructs the damaging ordering directly instead of waiting for a live drag to
produce it. The distinction is between a test that reproduces by *timing* --
which would need `viewWillStartLiveResize` / intermediate frames /
`viewDidEndLiveResize` -- and one that reproduces by *construction*, which is
what Phase 2 shipped.

**Uncertainty.** One stimulus shape, one window height, one starting width, one
shell. A programmatic resize might reproduce it under some parameter
combination not tried; the claim here is only that the obvious one does not, at
the step size and step count the manual recipe uses.

**Next action.** Manual A/B remains the only trusted comparison until the
harness models live resize. The probe script is kept out of the repo; it is
recorded here as a dead end so it is not rebuilt.

## `F8` -- the control is clean, and fast-resize flicker is the deterministic form of the defect

**Reproduction.** Manual A/B, 2026-08-05, same session as `F5`. Two isolated
slots at matched window size (827x491) and identically staged panes: slot 1 at
`d3780961`, slot 2 at `a94abc26` (`d3780961~1`). User drove both by hand.

**Observed.**

| | slot 1 -- `d3780961` | slot 2 -- `a94abc26` |
| --- | --- | --- |
| settled single-column widens | vanish reproduced, 10th-20th widen | no vanish in 30 widens |
| fast continuous drag | **black flickering** | **no flickering at all** |

**Inferred -- attribution.** `d3780961` introduced the defect. The negative on
slot 2 alone would be soft evidence, since the settled-widen recipe is
stochastic. The flicker column is what carries the conclusion: it is present on
every fast drag in slot 1 and absent on every fast drag in slot 2, so it
discriminates the two builds deterministically rather than by waiting on a rare
event.

**Inferred -- mechanism, and why a *settled* step is required.** Flicker and
vanish are one defect at two timescales. During a fast drag, sparse-damage
frames land repeatedly on a just-resized layer whose contents are blank; the
rows outside the clip show the bare layer background (`F5`'s flat `#0d0d0d`),
which is the flicker. More frames keep arriving, so each blank region is
overwritten almost immediately and the damage is transient. On a settled step
the sparse frame from zsh's post-SIGWINCH redraw is the *last* write, so nothing
arrives to repair the unpainted rows and the gap persists.

This dissolves `F1`'s open puzzle. `F1` recorded "it happens on a step where the
mouse was released and the resize had settled" as a property needing
explanation; it is now the predicted one. The settle is not a trigger, it is the
absence of a subsequent repaint.

**Not a fix.** Slot 2 is the pre-regression baseline, not a repair. The defect
remains present on `experiment/swift-terminal-engine`.

**Competing interpretations.** The flicker could in principle be an unrelated
second defect that happens to share the `d3780961` boundary. Against it: it is
the same colour and the same spatial signature as `F5`'s measured band, and
`F6`'s mechanism predicts exactly this transient form under continuous resize.

**Uncertainty.** The flicker is a human observation, not yet captured or
measured -- no probe has sampled a mid-drag frame to confirm it is the same flat
`#0d0d0d`. The slot 2 negative is 30 widens by one person in one sitting.

**Next action.** The flicker is a far better instrument than the settled-widen
recipe: it is deterministic and high-frequency, so it can pass the calibration
gate `F7` failed. Build a fast-drag flicker detector, gate it on showing flicker
at `d3780961` and none at `a94abc26`, and use it as Phase 2's regression signal.

## `F9` -- the fix clears the flicker, and the remaining debris is grid-resident

**Reproduction.** `D1` applied, dev slot at `experiment/swift-terminal-engine`,
pane staged with the `F1` recipe. User drove fast drags by hand, then narrowed
the pane.

**Observed.**

- The fast-drag flicker is **gone**. Per `F8` this is the deterministic form of
  the defect, so its absence is the strongest available hand confirmation.
- Narrowing still produces prompt debris on screen.
- `danterm pane read` on that pane returns the debris **in the grid**:
  `k8s:orbstac`, `k8s:orbst`, `k8s:o`, `k8s`, `k8s:orbs` concatenated onto rows
  already holding a `╭ ~` fragment.

**Inferred.** The debris is `F2`, unchanged and still not ours. `pane read`
returns terminal state rather than painted pixels, so fragments appearing there
prove the bytes were written into the grid by the shell -- DanTerm is rendering
faithfully. This is a stronger form of `F2`'s evidence: `F2` argued from three
terminals agreeing, which is circumstantial; this reads the grid directly.

The exact fragment set also matches `F2`'s recorded signature verbatim
(`k8s:orbstac`, `k8s:orbs`, `k8s:orb` mid-row, concatenated onto rows carrying a
previous fragment), so it is the same phenomenon rather than a lookalike.

**A likely consequence of the fix, not a regression.** Before `D1`, a resize
left rows unpainted showing the bare layer background; some of those blanked
rows would have been carrying debris. Forcing a full repaint means the grid's
actual contents are now painted faithfully, so debris that was previously masked
by the defect can become more visible. More visible debris after `D1` is
expected and is not evidence against it.

**Uncertainty.** The masking claim above is inference from the mechanism, not a
measurement -- no before/after debris count was taken. It matters only if
someone later reads increased debris as a regression.

**Next action.** None for this doc; `F2`'s boundary already excludes the debris.
It belongs to the shell.
