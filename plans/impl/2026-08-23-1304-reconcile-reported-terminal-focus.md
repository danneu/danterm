# One owner for the focus a pane reports to its child

Source: REDUCE-4 in `docs/scratch/2026-08-18-construction-audit.md`, verified
against the tree at `b60cd715`. Pivoted: the finding's stated fix is wrong, and
the tree moved under it twice since the audit.

## Context

"Is this pane's terminal receiving the user's keystrokes" is one fact. A child
process reads it through DECSET 1004, the pane tape carries it to the iOS
replica, and the flight recorder logs every transition. Today three writers
produce it and nothing owns it:

1. `Command.focusSession(paneId:focused:)`, emitted from four verbatim copies of
   a defocus loop in `.createTab`, `.movePaneToTab`, `.movePaneToNewTab`, and
   `applySelectTab`. No production site ever emits `focused: true`.
2. `SwiftTerminalSessionView.becomeFirstResponder` / `resignFirstResponder`,
   which supply the entire `true` half.
3. A post-dispatch loop in `AppRuntime.dispatchInFrame` that pushes application
   activation to every live session, added by `36bf8b55` when activation became
   a second input.

The session then derives the answer itself: `SwiftTerminalSessionView` retains
pane focus and application activation and forwards their conjunction. So the
derivation lives in the leaf, and three independent callers feed it.

`docs/design/2026-05-27-model-driven-view-reconciliation.md` already names this
shape a smell: "Reintroducing a command whose only job is to make the view match
the model is a design smell; it should normally be a pure projection plus a
reconcile pass instead."

**Two corrections to the audit's framing, both load-bearing.**

*The stated defect is not reachable.* Pane focus can only become true through
`becomeFirstResponder`, so only the current first responder holds it, and
`reconcilePaneFocus` moves the responder on every sweep where the desired pane
changed -- which fires `resignFirstResponder` on the old view. The four defocus
loops are effectively dead in production. This work is structural, not a bug
fix. Do not justify it with a defect.

*The audit's proposed fix would ship a regression.* It says to key the new pass
on `desiredPaneFocus(in: model)`. That projection returns `.terminal(paneId)`
whenever a tab is selected, so it cannot express "a non-pane control holds the
keyboard". Nine main-window surfaces can hold it: the theme browser's search
field and table, the three search-overlay buttons, the five pane-toolbar
controls, the five window-chrome buttons, the sidebar rename field editor, and
any Full-Keyboard-Access traversal target. `paneFocusClaimant()` classifies all
of them `.nonPane` and `reconcilePaneFocus` returns early to preserve them;
today the terminal correctly reports unfocused throughout. A model-keyed pass
would report `true` instead -- an externally visible DECSET 1004 change.

**Who has the keyboard is a view fact.** The pass must read it. See RI1 for why
modeling those nine surfaces is not the alternative.

## Decision

One reconcile pass owns the reported focus of every live pane. It computes the
value from the responder classification the sweep has already settled, plus
`model.isAppActive`, and applies the diff against a per-pass cache the way every
other keyed pass does. Every other writer of that fact is deleted.

The decision itself is a pure projection in `DanTermCore` taking the resolved
keyboard owner as an argument; only the claimant read is impure. That split is
what puts the whole decision table inside `just test` while the responder read
stays where it belongs.

Reported focus is true for exactly one pane, and only when the app is active and
the keyboard owner is that pane's *terminal*. A search-field owner yields
all-false: the caret is in the find field, so the child is not receiving
keystrokes. A `.nonPane` or unclaimed responder yields all-false for the same
reason.

Because the value is decided during a sweep, a gesture that moves the keyboard
must cause one. That is already how the pane search field works
(`PaneSearchField.onUserClick`), and its doc comment records why the report has
to ride `mouseDown` rather than a responder-state hook: a responder hook also
fires for the focus-repair pass's own `makeFirstResponder`, which is an
AppKit-laundered send out of a reconcile sweep. Today the deleted
`resignFirstResponder` override is what covers gestures that report nothing;
I5 is what replaces it.

The pass's cache is not pre-seeded when a pane host is installed. A newborn pane
therefore takes one write on its first sweep -- which the engine dedupes to zero
bytes and the flight tape records as an explicit initial state, the same "state
the focus before the bytes" discipline the iOS replica already follows. Seeding
would suppress that write and make PO5 unable to distinguish a pane the pass
reached from one it skipped.

### Why this is the ideal

A background pane reporting focus to its child becomes unrepresentable. The
value is recomputed from the settled responder on every sweep, so no arm can
omit a defocus, no ordering can leave two panes focused, and no future non-pane
control has to remember to declare anything -- `paneFocusClaimant()` already
classifies the responder exhaustively. The derivation leaves the leaf view and
becomes one pure function the gate covers in full.

### Ordering

Both focus passes move to the end of the sweep, after every existence pass and
immediately before occlusion: responder repair first, then focus reporting.

This is the ideal the RUNTIME-2 analysis named and deferred (audit line 1563,
"schedule it with REDUCE-4"). With both focus passes last, "a pass destroyed a
focused view after the focus repair ran" stops being expressible for every panel
at once, instead of for the theme browser alone. The local comment that today
orders `reconcileThemeBrowser` ahead of pane-focus repair is then redundant and
goes.

## Invariants

- **I1** Exactly one writer sets a session's reported terminal focus: the
  reconcile pass. No command, no responder callback, and no post-dispatch loop
  writes it.
- **I2** After a sweep, at most one live pane reports focused, and it is the
  pane whose terminal owns the window's first responder while DanTerm is active.
- **I3** Both focus passes run after every pass that creates or destroys a view,
  in the order repair-then-report. A pass that destroys a focused view therefore
  cannot run after the repair that would have healed it.
- **I4** A sweep that changes nothing writes nothing. Reported focus reaches a
  session only on a real transition, because the flight recorder logs each write
  before the engine dedupes the bytes.
- **I5** Every main-window control a mouse click can move the first responder
  into reports that gesture, so a sweep follows it. The reducer may ignore the
  report; causing the sweep is the point. Click-reachable controls today are the
  pane search field (already conforming) and the theme browser's search field
  and table. Buttons are not click-reachable -- AppKit does not give an
  `NSButton` first responder on a click outside Full Keyboard Access, which is
  what leaves AR1 as the only remaining gap.

## Proof obligations

- **PO1** (I2) The decision table holds for every combination of keyboard owner
  (terminal, search field, non-pane, unclaimed) and activation, over a
  multi-pane model. Pure, in `just test`.
- **PO2** (I1) `Command` has no focus-writing case. The type is the proof; there
  is no test, because once the case is deleted no test can name it and asserting
  the exact command list of `.selectTab` would pin structure rather than
  behavior.
- **PO3** (I1, I2) With a real window: moving the responder between a terminal,
  its search field, and a non-pane control drives the reported value to match,
  and moving it back restores it. In `just test-ui`.
- **PO4** (I3) Closing a focused theme browser through one full sweep leaves the
  terminal owning first responder *and* its session told `true`, within that
  single sweep. This is the ordering invariant's only behavioral proof: it fails
  if focus reporting is ever ordered ahead of an existence pass. In
  `just test-ui`.
- **PO5** (I1, I2) A pane created through the runtime's message entry while the
  app is *active* is told `true` exactly once inside its creating send; one
  created while the app is *inactive* is told `false` exactly once inside its
  creating send. The active half needs a window and lands in `just test-ui`; the
  inactive half is headless and lands in `just test`. Neither may install a
  session by hand -- reach through the message entry is the whole point.

  Together these replace the deleted `applicationActive` field on the session
  request, and both halves assert a write *count*, not just a value: with a
  pre-seeded cache an unfocused newborn would produce no write at all, and
  "reached and decided false" would be indistinguishable from "never reached".
  That is why the cache is unseeded (see Decision).

  The headless half proves *reach*, not the activation arithmetic: with no
  window every pane resolves to unclaimed, so it holds for any activation
  value. Reach is the half the deleted field provided structurally; PO1 covers
  the arithmetic. Say so in the test's preamble rather than letting it read as
  a stronger proof than it is.

- **PO6** (I4) Two consecutive sweeps with nothing changed produce one write,
  not two. In `just test-ui`.

- **PO7** (I5) With a terminal focused and the app active, clicking the theme
  browser's search field drives that terminal's reported focus to `false` with
  no other message intervening. In `just test-ui`. This is the regression guard
  for the gesture channel the deleted `resignFirstResponder` override covered.

## Deletion scope

The point of the change is the subtraction. All of this goes:

- `Command.focusSession`, its `perform` arm, and the four defocus loops -- each
  of which is also a `paneIdsForTab` flatten call site LOOKUP-4 left behind.
- The `becomeFirstResponder` / `resignFirstResponder` overrides on the pane
  view. They exist only to write pane focus. The gesture coverage the resign
  override incidentally provided is replaced by I5, not lost.
- The pane view's two retained focus inputs and the conjunction it derives from
  them, including its own dedupe. The pass's cache is the only dedupe, which is
  what satisfies I4.
- `TerminalSession.setApplicationActive` and every implementation and fake.
- `TerminalSessionRequest.applicationActive`, its producer, its consumers, the
  pane view's initializer parameter, and the corresponding tests-ui pane-making
  seam.
- The activation push loop in `AppRuntime.dispatchInFrame`.

Kept: the runtime's `applicationActive` launch argument seeding
`model.isAppActive`. That is the model fact the pass reads, and the reason
`36bf8b55` made it a required argument stands.

The request field is safe to drop because the pass reaches a newborn pane in the
same frame -- commands perform, then the sweep runs, inside one dispatch. PO5
is what holds that true.

## Verification

`just test` covers PO1 and PO5's inactive half; PO2 is proved by the type.
`just test-ui` covers PO3, PO4, PO5's active half, PO6 and PO7.

Existing tests that assert the deleted command or the deleted conjunction are
retired with it: the reducer cases pinning `.focusSession`, the pane view's
dedupe and conjunction cases in tests-ui, and the app-tests activation suite,
whose claim moves to PO3/PO5. The reducer case asserting that a focus report
naming the already-desired pane emits nothing survives unchanged -- it is the
premise for deleting the responder echo.

`app/PaneFocusReconciliation.swift` joins `scripts/reconcile-pass-lint.sh`'s
whole-file list. It holds reconcile passes and is not scanned today; adding a
second focus pass is the moment to close that. The lint's header note about the
responder-move edge becomes fully true once the overrides are gone and should
say so.

The ordering paragraph in
`docs/design/2026-05-27-model-driven-view-reconciliation.md` is rewritten to
state I3, and records I5 and AR1. I5 belongs in that doc beside the existing
rule that a pane target's key focus is reported by the gesture that asks for it
-- this generalizes that rule to every main-window control rather than adding a
second one.

Manual, after the change: `danterm focus` reports the live claimant, and the
pane tape's `focused` field shows what the child was told. Open the theme
browser, click its search field, and confirm the tape reports unfocused; close
it and confirm focus returns.

## Non-goals and accepted risks

- **AR1** With I5 in place, Full-Keyboard-Access Tab traversal is the only
  remaining path that moves the responder out of a pane without causing a sweep,
  so the report waits for the next unrelated message. FKA is off by default, and
  Tab inside a terminal goes to the child rather than traversing, so a terminal
  cannot be the traversal source under the default configuration. If it ever
  bites, the traversal reports through the same gesture channel I5 names; it
  does not get a second writer.
- **AR2** The end-to-end claimant path is display-bound, so PO3, PO4, PO6, PO7
  and PO5's active half sit outside `just test`. This is a real reduction
  against today, where the activation regression is pinned headlessly, and it is
  the price of reading the responder instead of guessing at it from the model.
  PO1 and PO5's inactive half keep the decision and the reach in the gate.
- **AR3** The decision ignores main-window key status. While a secondary window
  is key -- the preferences panel, a sheet, a popover -- the terminal remains
  the main window's first responder and the app is active, so the pass reports
  `true` while keystrokes go elsewhere. This is exactly today's behavior, so the
  change neither introduces nor fixes it, and correcting it means a third input
  (`windowDidBecomeKey`/`windowDidResignKey` as a model fact) that no finding
  has yet shown to matter to a real client.

## Rejected ideas

- **RI1 Model the keyboard owner and keep the projection pure.** Would put every
  proof obligation in `just test`. Rejected on the inventory: of the nine
  main-window surfaces that can hold the responder, only the sidebar rename has
  a model slot, and it holds a *request* to begin editing rather than live
  ownership -- which is why `SidebarReconcileDriver` reads the view instead of
  the model, for the reason written down in `SidebarView`: AppKit destroys a
  field editor with no delegate callback, so the model cannot derive who owns
  one. Modeling focus ownership for five toolbar buttons and five chrome buttons
  is mechanism in service of a test.
- **RI2 Seam the claimant reader so app-tests drive the full path.** Recovers
  the headless activation proof. Rejected: it puts a production seam in the
  runtime whose only consumer is tests and which production never varies. PO1
  plus PO5 buy most of the same coverage with no seam.
- **RI3 Keep `Command.focusSession` and emit it from one shared helper.** The
  audit's own cheaper fallback. Rejected: it collapses four copies into one but
  leaves the fact with two owners and the `true` half still coming from AppKit,
  which is the problem.
- **RI4 Observe `NSWindow.firstResponder` (KVO) instead of per-gesture reports.**
  Would dissolve I5 and AR1 together. Rejected on the rationale already written
  into `PaneSearchField`: a responder-state hook also fires for the focus-repair
  pass's own `makeFirstResponder`, so every repair mints a message and a
  redundant sweep -- an AppKit-laundered send out of a reconcile pass, which is
  the exact edge `scripts/reconcile-pass-lint.sh` cannot see and the outbox rule
  exists to contain. Deferring delivery through the outbox stops re-entrancy but
  not the spurious traffic. Independently, `NSWindow.firstResponder` KVO
  compliance is undocumented and AppKit is not in `references/`, so adopting it
  would mean guessing at framework behavior. Reconsider only if a gesture
  surface appears that cannot report its own click.

## Implementation discretion

Naming and placement of the projection and the pass, the cache's field name, and
whether the pass lives beside `reconcilePaneFocus` or in the sweep file are
free -- the lint file list must cover wherever it lands.

Whether I5's theme-browser reports reuse `PaneSearchField`'s shape or share one
small type with it is free, as is which message they carry: the reducer is
allowed to ignore it entirely, because causing the sweep is the whole effect.

## Commit progress

Each commit lands the obligations that would fail if its own change were
reverted.

- [x] 1. Add the projection, the pass and its cache; move both focus passes last;
      update the ADR and the lint file list. Lands **PO1** (the projection),
      **PO4** (the reorder) and **PO6** (the cache). Leave `Command.focusSession`
      and the responder overrides in place -- the pane view's existing dedupe
      makes the overlap silent, and none of these three obligations can see it.
- [x] 2. Delete `Command.focusSession`, its `perform` arm, and the four defocus
      loops; retire the reducer tests that assert the command. **PO2** holds by
      construction once the case is gone.
- [x] 3. Add I5's theme-browser click reports; delete the pane view's retained
      inputs, the responder overrides, `setApplicationActive`, the request field,
      and the activation push. Lands **PO3**, **PO5** and **PO7**, each of which
      proves an old writer was redundant, and retires the superseded suites.

## Out of scope

`ThemeBrowserView.captureFocusTarget()` and `restoreFocus(_:)` have no callers
anywhere in `app/` or `tests-ui/`. Noted because the inventory found them while
enumerating `.nonPane` producers; deleting them is a separate change.

## Implementation notes

- Theme-browser controls report after `super.mouseDown` returns. Unlike the pane
  search field, no model change asks focus repair to move the responder for this
  gesture, so the reporting sweep must read AppKit's settled responder.
