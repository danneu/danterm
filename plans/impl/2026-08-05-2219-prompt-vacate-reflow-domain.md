# Vacate the prompt block before reflow, not before resize

## Context

`Terminal#resize` vacates the prompt block -- blanks every row from the prompt
head to the bottom of the screen and stamps them `.vacated` -- on every resize,
including one that changes only the row count. The vacate is a debt owed to
*reflow*: a width change refolds logical lines across a different number of
display rows, so a row keeps its index and loses its text, and the shell's
"my prompt starts N rows up" arithmetic stops matching the grid. The shell's
OSC 133 `redraw=` promise is what makes erasing it safe.

A height-only resize refolds nothing. `Terminal#resizeWidth` says so itself
("Height-only resizes never reach here, and must not"), and
`plans/impl/2026-07-18-0119-primary-scrollback-reflow.md` states it as an engine
invariant -- **I8: "a height-only change alters no row's cells or wrap flag."**
That plan's D4 deferred semantic-prompt handling until the protocols landed, and
when they landed four days later nobody went back to reconcile I8. The shipped
capability doc already describes the behavior we want: `docs/terminal-capabilities.md`
says the parser "blanks exactly that much **before a reflow**."

So on a height-only resize the vacate collects on a promise that buys nothing,
and destroys content to do it.

### Evidence

- **Live app, 2026-08-05.** A pane emitting `133;A;redraw=1` + four printed
  lines + `133;B`, then a height-only window shrink (width byte-identical):
  all four lines gone from the visible grid *and* from 500 lines of scrollback.
  Control -- same pane, same script, no resize -- retained them at t=1s and
  t=5s.
- **fish 4.7.1 on a real PTY.** On a height-only SIGWINCH fish repaints its
  whole prompt and clears as it goes (`\r ESC[A ESC[K <line> ... ESC[J`).
  Confirmed in the app: with fish nothing is permanently lost, so the
  user-visible symptom is flicker only. This is why no shell-driven fixture
  caught it.
- **bash** self-clears too: `references/bash/lib/readline/display.c#_rl_redisplay_after_sigwinch`
  calls `rl_clear_visible_line()` on every SIGWINCH.

### Why this reverses a standing instruction

`docs/research/24-osc-133-dialect/findings.md` (F21) ends: *"Accept the brief
blank and revisit only if resize flicker becomes a recurring user complaint or a
materially simpler design appears. Do not weaken `clearPromptForResizeIfNeeded`
or the ADR's vacate-before-reflow contract."* Both revisit conditions are now
met, and the change is a scoping rather than a weakening:

- F21 priced **flicker**, against a shell that repaints. It never priced
  **erasure** with no repaint, which is what the height-only case is.
- F21's own justification is stated in reflow terms: the vacate exists so a
  stale-width prompt cannot "determine reflow's intermediate logical lines and
  cursor mapping." A width-invariant resize computes neither.
- `clearPromptForResizeIfNeeded` and `clearPromptCells` are not edited. Only
  the domain in which they are called changes.

`plans/impl/2026-07-22-1422-osc-133-prompt-redraw.md` is genuinely reversed: it
specifies the clear "runs for height-only resizes too -- verified Ghostty
behavior." That verification was correct -- `.ghostty-src/src/terminal/Terminal.zig#resize`
returns early only when both dimensions match and passes `prompt_redraw`
unconditionally. **This is a deliberate divergence from Ghostty**, taken on
evidence Ghostty's design does not have, and consistent with AGENTS.md: "Ghostty
does X" is not a rationale.

## Decision

Vacating becomes a precondition of reflow rather than of resize, expressed as a
gate at the two existing call sites: `clearPromptForResizeIfNeeded` runs only
when the column count changes. Nothing else moves. A combined width+height
resize stays byte-identical to today, and a width-only resize stays
byte-identical to today; only the width-invariant case changes, which is exactly
the defect.

The vacate stays *above* `resizePrimaryScreen`, ahead of both legs, because it
can only find the block it must erase while that block is intact.
`clearPromptForResizeIfNeeded` locates the head by walking up from `cursor.row`
through `.continuation`/`.none` rows; reaching row `-1` without finding a head,
it returns having vacated nothing. `resizeHeight`'s shrink path displaces the
top rows of the grid into scrollback. So on a combined shrink whose displaced
prefix contains the prompt head, any placement after the height leg finds only
continuation rows, vacates nothing, and lets a stale-width prompt into reflow --
violating I4 (total vacating) and I7. Running before both legs is not an
accident of history; it is the precondition the walk needs.

`Terminal#resizedRectangle` already applies the same `columns != oldColumnCount`
predicate on the alternate-screen branch, so the gate makes the two branches
agree rather than introducing a new idea.

## Invariants

- **I7 -- Reflow domain (new).** Vacating is a precondition of reflow, not of
  resize. A resize that leaves the column count unchanged modifies no
  prompt-block cell and no prompt-block stamp.
- **I6 -- Redraw-mode scope (amended).** Unchanged in substance; scope is now
  further bounded by I7's domain. `redraw=last` takes the same gate as
  `redraw=1`: bash self-clears the one row the `.last` vacate would blank, and
  that vacate's load-bearing job -- dropping the stale wrap claim so reflow
  cannot splice an old-width row into a logical line -- is a width concern.
- **I1, I2, I4 unchanged.** I7 constrains *when* the vacate fires, never what it
  does. It is a transition invariant, so it joins I3/I5/I6 on the
  bracketed-behavioral-test side of the doc's proof partition.
- **I8 restored.** A height-only resize alters no row's cells or wrap flag,
  including when a prompt block is live.

Selection behavior follows from I7 and is a fix, not a casualty:
`clearPromptCells` invalidates an overlapping selection *because* it is about to
destroy those cells. Once a height-only resize stops destroying them, dropping
the selection would be a spurious loss. `clampSelectionToRetainedStream` still
runs on every resize and still handles anything that left the retained stream.

## Proof obligations

One entry per invariant and per load-bearing premise. An entry may need several
scenarios; one test may discharge several entries.

1. **I7 / the incident.** A `redraw=1` prompt block spanning several rows
   survives a height-only resize sized so the block straddles the
   history/live seam -- every line present, on whichever side it lands, in both
   the visible grid and history. This is the test that must go red first, and
   it must go red on the content assertion rather than on a projection detail.
2. **I7 is a gate, not a removal.** A width-only resize still vacates the same
   block, under both `redraw=1` and `redraw=last`. A *combined* resize whose
   height leg would displace the prompt head still vacates the whole block --
   the case that pins the vacate above `resizePrimaryScreen` rather than
   between its legs.
3. **I8 for prompted terminals.** A height walk across many row counts with a
   live prompt block conserves history text and holds the prompt oracle at
   every step. The unprompted case is already covered by
   `TerminalResizeTests`; the prompted case is the newly load-bearing one.
4. **Seam round-trip.** A prompt block displaced into history by a height
   shrink and pulled back by a height grow still reflows to exactly one prompt
   on the next width change. The gate makes this path load-bearing for the
   first time, because the old per-resize vacate used to mask any stamp drift.
5. **Selection.** A selection over the prompt block survives a height-only
   resize and is still dropped by a width-only one.

Existing tests that change, and why each is legitimate rather than edited to
green:

- The `heightOnly` leg of `TerminalOSC133Tests#actionAndMarkerLifecycle` is the
  one assertion in the suite whose truth value this change reverses. It carries
  no preamble and its width sibling already pins the width side; obligation 1
  takes over the claim under a name and a scenario.
- `TerminalSemanticPromptInvariantTests#redrawModeScopesResizeBlanking` drives
  both legs with a height-only resize purely as an "a resize happened" trigger;
  its stated intent is `redraw=0` vs `redraw=last` *scope*. Re-drive it on a
  width change: assertions unchanged, intent preserved, and it stays green in
  both directions -- which is the evidence it is not being bent.

## Non-goals

- **Grid copy-back**, kitty-style or otherwise. Already adjudicated in
  `docs/research/24-osc-133-dialect/findings.md`: a copied row is nonempty while
  semantically vacated, and nonemptiness is the safety check that lets reclaim
  delete a row. Cells also feed history, `pane read`, search, selection, and
  equality. Upstream does not help -- kitty's copy-back is unreflowed,
  truncated, wrong-width cosmetics, and Ghostty declined it.
- **The presentation-transaction alternative.** Prototyped, passed the full
  gate, withdrawn on maintenance cost. Not reopened.
- **Doc 32's open item** -- the full repaint per resize frame that
  `SwiftTerminalSessionView#setFrameSize` forces, still uninstrumented. A
  separate mechanism that can also present as drag flicker; if flicker persists
  after this lands, that is where it belongs.
- Restructuring the anchor code, unifying the resize and stamp paths, or
  changing the reclaim design.

## Accepted risks

- **AR-A (scrollback debris).** A width-invariant resize can now displace an
  un-vacated prompt row into history, where it stays. This is the "stale head"
  variant of `AR1` in `plans/impl/2026-08-01-0029-prompt-anchor-invariants.md`,
  which already accepts both variants; the gate changes which one occurs, not
  whether debris is possible. Reachable only when the prompt block extends to
  the top of the live grid -- normally output is displaced, not prompt.
- **AR-B (seam re-presentation).** `LogicalLineStore` hands the open tail
  record's last partial row back to the next reflow with its prompt mark
  inherited. A prompt head displaced by the height leg can therefore re-enter a
  later width reflow as stale-width prompt cells. Pre-existing for any block
  that straddles the seam by ordinary scrolling, and unchanged by the gate,
  which does not fire on the resizes that reach it. The only in-place remedy
  would decline to prepend a seam prefix
  the store has already cut from the record, which deletes retained bytes --
  the trade AR1 already refused. Characterize it; do not fix it here.
- **AR-C (shell assumption).** We bet no shell relies on the terminal
  pre-clearing on a width-invariant SIGWINCH. fish and bash are measured to
  self-clear, and zsh's recorded repaint in the fixtures is `\r ESC[A ESC[J`.
  A shell that does neither would leave stale rows until its next prompt mark,
  where reclaim takes them.
- **AR-D (grow pull-back ordering).** On a height grow, `resizeHeight` pulls
  rows out of history and `LogicalLineStore` restores their `.prompt` stamp
  *after* the vacate has already run, so a combined grow+width resize can reflow
  an un-vacated stale-width `.prompt` row. Pre-existing and unchanged by this
  plan -- the gate does not fire on width-invariant grows and does not move the
  call site. Fixing it needs the vacate to run twice or to run after the pull
  with a head it can still find; both are new mechanism for a bug this change
  neither causes nor worsens. Out of scope.
- **AR-E (D1 does not hold for prompted combined resizes).**
  `plans/impl/2026-07-18-0119-primary-scrollback-reflow.md` D1 -- "a combined
  width+height change behaves exactly as height change then width change" --
  is false whenever a prompt block is live and the height leg displaces its
  head: the decomposed form's second call cannot find the head, so it vacates
  nothing. This is a property of `clearPromptForResizeIfNeeded`'s upward walk,
  not of any placement, and it is true today. Scope D1 to unprompted terminals
  in the docs; do not restore it here.

## Rejected ideas

- **Move the vacate between the height and width legs of
  `resizePrimaryScreen`.** Collapses two call sites into one and would fix
  AR-D, but on a combined shrink whose displaced prefix contains the prompt
  head the walk from `cursor.row` reaches row `-1` through continuation rows
  and vacates nothing, admitting a stale-width prompt into reflow (I4, I7).
  The head must be intact when the walk runs.
- **Branch the placement on height direction** (grow: resize then vacate;
  shrink: vacate then resize). Avoids the shrink hazard and fixes AR-D, but
  buys a second ordering and a direction predicate to fix a pre-existing bug
  this change does not touch, and leaves the two orderings' equivalence as a
  new thing to prove. If AR-D is ever worth fixing, it is its own plan.
- **Special-case `redraw=last`.** Keeping the height-only vacate for bash was
  considered on the grounds that its blast radius is one row. That argues for
  lower priority, not a different rule, and it would turn I6 from a pure scope
  statement into a trigger statement as well.
- **Follow Ghostty.** Ghostty blanks on height-only, verified. It also has no
  measured content-loss report and no height/width split in its screen resize
  to hang a gate on.

## Verification

**Unit.** Obligations 1-5 above, red-first in that order.

**Fixture oracles -- the empirical check, not a formality.** Two committed
recordings contain genuine height-only resizes. `milestone-4-viability` is inert
(its height-only event precedes any feed, so the guard already short-circuits).
`zsh-stale-width-repaint` is live: the vacate fires there today and will stop.
Its consumers are the per-event oracle, `#staleWidthRepaintLeavesNoDebris`, and
the 390-event prefix arm of `#staleWidthDebrisSurvivesNoFollowingResize`. Run
the whole `lib/TerminalCore` package, then `just test`. If any of these move,
investigate -- do not rebless. `#staleWidthRepaintLeavesNoDebris` names three
separate maintainer reports in its preamble.

**Real app.** Build an isolated slot with `just launch` and drive it with an
explicit `--socket` on every call. Capture the before-state on the unpatched
build first, so the fix has recorded evidence rather than a recollection:

- The destructive case, which no shell reproduces:
  `danterm tab new --title DRAG-ME --foreground --cmd 'printf "\033]133;A;redraw=1\007KEEP-1\nKEEP-2\nKEEP-3\nKEEP-4\033]133;B\007"; sleep 100000'`
  then a height-only window resize (read the current width back and reuse it
  verbatim). Pass: all four lines present in `pane read` and in
  `pane read --lines 500`.
- The reported symptom: a fish pane at its prompt, repeated height-only
  shrinks. Pass: no visible blank-and-repaint.
- What the vacate still buys: fish, zsh, and bash panes under a continuous
  *width* drag must each keep exactly one prompt -- no staircase, no fragment.
- Corner drags are unchanged by the gate, but confirm it once: a corner drag in
  zsh with a two-row prompt, then `pane read --lines 500` checked for duplicate
  prompt heads.
- A height-only shrink with `less` or `vim` on the alternate screen, since the
  vacate reaches the hidden primary through the alternate branch.

`just test-ui` last; it needs a GUI session.

## Documentation

- `docs/design/2026-08-01-osc-133-prompt-anchoring.md`: add I7, amend I6's scope
  sentence, change the lifecycle step from "before resize" to "before reflow",
  and extend the scrollback-boundary section with AR-A and AR-B. Record AR-E's
  D1 scoping next to I7, since a reader arriving at I7 is exactly the reader who
  will ask whether combined resizes still decompose.
- `docs/research/24-osc-133-dialect/findings.md`: append a new finding carrying
  the live repro and its control, the fish PTY trace, the I8 and
  capability-doc conformance argument, and the explicit claim that this scopes
  rather than weakens F21. Add one cross-reference line at F21's "Next action"
  so a future reader cannot follow a superseded instruction -- do not rewrite
  F21's body; its measurements stand.
- `plans/impl/2026-07-22-1422-osc-133-prompt-redraw.md` and
  `plans/impl/2026-07-18-0119-primary-scrollback-reflow.md` are historical
  records; leave them. This plan cites the first as the decision it reverses and
  the second's I8 as the invariant it restores.
- `docs/terminal-capabilities.md` needs no change -- verify it now reads true.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- `#resize` (the two
  gated call sites), `#clearPromptForResizeIfNeeded` (body unchanged; its doc
  comment gains the domain statement *and* the reason it must run before
  `resizePrimaryScreen`, so a future reader does not relocate it),
  `#resizeWidth` (extend the existing "never reach here" comment to note the
  vacate now shares that guarantee).
- `lib/TerminalCore/Tests/TerminalCoreTests/` --
  `TerminalSemanticPromptInvariantTests.swift`, `TerminalOSC133Tests.swift`,
  `TerminalResizeTests.swift`, and the inspection-invalidation suite.
