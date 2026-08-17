# Pane focus reports from interaction sites, not the responder callback

## Problem

`reconcilePaneFocus` repairs the AppKit first responder from the model.
The repair calls `window.makeFirstResponder(session.hostView)`, AppKit
synchronously calls the pane view's `becomeFirstResponder`, and that
override emits an event the session funnel turns into a
`.paneBecameFirstResponder` send -- from mid-sweep. The message does not
coalesce, so the send runs a full nested reconcile inside the outer one.
The outermost-only drain rule contains the follow-up dispatch but not the
nested sweep itself. This is the one named exception to the Read-Only
Model Rule in
[docs/design/2026-05-27-model-driven-view-reconciliation.md](docs/design/2026-05-27-model-driven-view-reconciliation.md),
and `scripts/reconcile-pass-lint.sh` cannot see the edge because it is
laundered through AppKit responder dispatch.

Desired outcome: no reconcile pass originates a `Msg`, with no exception,
and the echo mechanism that made the exception necessary is gone.

### Load-bearing premises (verified against source)

- **P1. The echo is redundant for a pass-issued move.** The pass applies
  `desiredPaneFocus`, which targets the terminal view only for the
  selected tab's `focusedPaneId` and only when that pane's search
  `focusOwner` is not `.field`. The handler's focus-and-alert branch
  therefore no-ops (the pane already is `focusedPaneId`), and the one
  surviving write -- `focusOwner = .terminal` -- is a no-op in both
  remaining states: `SearchFocusOwner` has exactly the two cases
  `.terminal` and `.field`, and a pane with no search state optional-chains
  to nothing. The search-field arm of the repair emits nothing today
  (field ownership is reported from `controlTextDidBeginEditing`, the
  first text change, not from focus). So there is nothing to route: the
  emission can be deleted.
- **P2. The echo is load-bearing for exactly one genuine interaction.**
  The pane view's `mouseDown` never calls `makeFirstResponder`; AppKit's
  window moves the responder on a left-button click, and the model learns
  of the click only through the echo. Every other genuine focus path
  already goes through the model (keyboard shortcuts, menu, IPC, pane
  open/close) or an existing interaction-site send
  (`AppRuntime.focusPaneSession` from the todo popover).
- **P3. The echo adopts drift.** Any responder move into a pane view --
  programmatic, key-view-loop traversal, or AppKit's own restoration --
  mutates the model as if the user asked. The defensive stray-pane guard
  in the `.paneBecameFirstResponder` handler exists to fence exactly this.

## Decision

**Delete the responder-state echo; user focus reports from interaction
sites.** The `.becameFirstResponder` boundary event is removed end to end
(view emission, boundary enum case, message translation, characterization
recorder arm). Presentation-focus forwarding to the engine (mode 1004,
cursor style) is untouched -- it is view-local state, not a model fact.

- A left-button click into a pane's terminal view sends
  `.paneBecameFirstResponder` synchronously, in the same turn as the
  interaction -- the same rule interaction-site sends already follow
  elsewhere (a pointer fact dispatches in its own turn; no sweep is
  running to report it to). The send rides the left-button entry point
  only, and control-click sends with it: control-click is routed to the
  terminal as a right click, but it arrives through the left-button
  handler and AppKit still moves the responder for it, so a send-less
  control-click would leave drift for the next sweep to fight. Genuine
  right- and middle-button clicks move no responder and send nothing.
- The semantics flip from adopt to repair: a responder move with no user
  gesture behind it no longer mutates the model, and the next
  `reconcilePaneFocus` repairs the responder back to model intent.
- The `.paneBecameFirstResponder` handler in `update()` is unchanged,
  including the stray-pane guard -- it is cheap and still correct against
  a mis-carried pane id.
- The audit of genuine focus entry points is the real work. Each path by
  which a user moves key focus into a pane target either already goes
  through the model or gets an interaction-site send:
  - terminal-view click: the new send (P2);
  - search-field click: a genuine gesture into the `.field` target that
    today produces no message until the first keystroke, leaving a window
    in which any unrelated sweep steals focus back to the terminal. The
    interaction-site contract closes this pre-existing gap: the gesture
    reports field ownership when the field gains focus, not at first text
    change. The report carries the whole gesture -- "this pane's field
    owns focus" -- and its handler adopts the pane along with the
    ownership, so a click into a non-focused pane's open search field
    focuses that pane and lands in its field in the same turn. Today the
    handler drops the report for a non-focused pane; under the new
    regime that drop would make the send's own sweep yank focus out of
    the field the user just clicked, so the handler's guard narrows from
    "the pane is focused" to "the pane is in the selected tab" (the same
    stray fence the terminal message keeps).
  - key-view-loop traversal (Tab out of the search field): establish
    empirically where it lands today and preserve that observable outcome
    under the new regime;
  - window-key restoration, popover close, field-editor teardown: all
    restore a responder the model already names, so repair-not-adopt is a
    no-op parity case.
- The Read-Only Model Rule's exception paragraph is deleted in the same
  change; the rule becomes a true statement about the sweep. The lint
  script's comment naming the responder-move edge as a live laundered
  send is updated to record it as removed.
- The outermost-only drain rule stays. Its justification is
  enumeration-independence -- correctness must not rest on having found
  every laundered edge -- and that holds whether or not this edge exists.

### The named fallback (not chosen)

The cheap fix is a suppression flag around the pass's responder repair so
the echo is ignored when the pass caused it. It is smaller, but it keeps
the catch-all echo and its adopt-drift semantics, adds caller-context
state every future pass author must know about, and leaves the defensive
guard load-bearing. The ideal removes the mechanism instead of fencing
it. Choosing the flag anyway is a trade-off the user would have to make
knowingly; this plan proposes the removal.

## Invariants

- **I1.** No reconcile pass originates a `Msg` -- no exception. A
  pass-issued responder repair produces no model mutation of any kind: no
  nested sweep, no alert clearing, no search focus-ownership change.
- **I2.** A genuine user gesture that moves key focus into a pane target
  (terminal view or search field) reports it to the model synchronously,
  in the gesture's own turn.
- **I3.** A responder move with no user gesture behind it never mutates
  the model; the next sweep repairs the responder to model intent.
- **I4.** Genuine-click behavior is preserved: a click into a non-focused
  pane's terminal updates `focusedPaneId`, clears that pane's alerts
  under `alertClearMode == .focus`, and hands search focus ownership to
  the terminal; a click into the focused pane's terminal while its
  search field owns focus hands ownership to the terminal; a click into
  a non-focused pane's open search field updates `focusedPaneId` with
  the same alert semantics and hands ownership to the field.
- **I5.** A click into a pane's open search field keeps the field focused
  across subsequent sweeps.
- **I6.** A focus report -- `.paneBecameFirstResponder` or the
  field-ownership message -- carrying a pane outside the selected tab
  does not corrupt `focusedPaneId` or the foreign pane's alerts.

## Proof obligations

The UI harness does not execute `update()`: its shim runtime records
sent messages and the harness does not compile the reducer. So any
obligation spanning an interaction and its model effect splits at the
message boundary -- the harness half proves the interaction emits the
right message (or that a repair emits none), and the core half proves
the message's model effect. The harness compiles the session view, the
search overlay, and the pane-focus pass, so both halves are drivable.

- **PO1** (I1): drive sweeps through both repair arms -- one that
  repairs the responder to a terminal view and one that repairs it to a
  search field -- and assert neither dispatches anything: no follow-up,
  no re-entered `update()`. Discharging only the terminal arm does not
  discharge this obligation. Alongside, the ADR exception text and the
  lint comment no longer name the edge as live; the docs lint stays
  green.
- **PO2** (I1): a pass-issued repair clears no alerts and steals no
  search focus ownership. Today this is masked by the handler's no-op;
  the test pins it as structural.
- **PO3** (I2, I4): the click paths, as paired proofs. The harness half
  drives the real interaction entry points and asserts the emitted
  message across the full input classification this plan changes: left
  click and control-click emit `.paneBecameFirstResponder`; genuine
  right- and middle-button clicks emit nothing; a click into an open
  search field -- on the focused pane and on a non-focused pane -- emits
  the field-ownership message. The core half asserts
  the message produces the I4 behaviors -- largely the existing
  `update()` suites. If the key-view-loop audit gives Tab traversal an
  interaction-site send, that gesture joins the harness matrix.
- **PO4** (I5): click into an open search field, then run an unrelated
  sweep; the field keeps focus. Two arms, both red first: the focused
  pane's field (fails today on the drift window named in the Decision)
  and a non-focused pane's field (fails today because the handler drops
  the report for a non-focused pane).
- **PO5** (I3): move the responder to a non-focused pane's view with no
  gesture; the model is unchanged and the next sweep restores the
  responder to the model's target. This inverts today's adoption
  behavior; the test pins the new contract.
- **PO6** (P1): for a model in which `desiredPaneFocus` names a target,
  dispatching `.paneBecameFirstResponder` for that target leaves the
  model unchanged. Core-layer test; this is the premise that justifies
  deletion over routing.
- **PO7** (I6): the existing stray-pane guard tests for
  `.paneBecameFirstResponder` keep passing unchanged; the field-ownership
  handler's narrowed guard gets its own scenario -- a report for a pane
  outside the selected tab changes nothing.
- Key-view-loop traversal: an empirical check, not a unit test -- record
  where Tab from the search field lands before the change and show the
  same outcome after, adding an interaction-site send only if the model
  visibly adopted it before.

## Non-goals

- Changing what `.paneBecameFirstResponder` does in `update()`.
- Removing or weakening `ReconcileFollowUps` or the outermost-only drain
  rule.
- Giving right- or middle-click focus semantics; neither moves the
  responder today, and that parity is kept.
- Reworking how search start and end move focus through the model
  (`searchStarted` / `endSearch` already own it).

## Accepted risks

- **AR1.** The entry-point audit may miss a genuine path. The failure
  mode is benign and visible -- focus snaps back to model intent instead
  of silently corrupting the model -- and the fix is one interaction-site
  send at the missed path. I3 is what bounds the damage.
- **AR2.** Anything relying on programmatic responder moves being
  adopted into the model must switch to model-driven focus. The audit
  found no such reliers: no UI test asserts a model change from a bare
  `makeFirstResponder`, and no consumer reads the
  `session.becameFirstResponder` characterization line.
- **AR3.** A click on an already-focused pane now dispatches a message
  (and a diff-based sweep) where the echo previously fired only on an
  actual responder change. Clicks are rare and the sweep no-ops; the
  implementer may gate the send on "not already first responder" if it
  proves noisy.

## Rejected ideas

- **RI1.** Route the echo through the follow-up channel instead of
  deleting it. P1 shows there is nothing to route for a pass-issued move,
  and routing keeps a state callback originating model facts and keeps
  adopting drift.
- **RI2.** Make `.paneBecameFirstResponder` coalesce so the nested sweep
  defers. Hides the re-entry without removing the origination; drift is
  still adopted.
- **RI3.** The suppression flag (the named fallback above): rejected as
  the recommendation for the reasons stated there, kept on the table for
  the user.
- **RI4.** Report the cross-pane search-field click as a two-message
  pair (`.paneBecameFirstResponder` then the field-ownership message).
  The sweep that runs between the two dispatches would repair focus to
  the terminal mid-turn and flicker the field the user just clicked; one
  message carrying the whole gesture has no intermediate state.

## Implementation discretion

- The transport by which the view's interaction handlers reach the
  runtime (reuse of the session callback gate with a renamed
  interaction-semantic event, or a direct hook), and the treatment of the
  now-single-purpose boundary plumbing.
- How the search field's focus-gain is detected, provided I2 and I5 hold
  AND the detection originates from the user's gesture, not from
  responder state. A state-callback mechanism (field-editor delegate,
  window notification) is admissible only if it provably cannot fire
  from a pass-issued repair: the pass's own search-field arm moves the
  responder to the field, and a detector that fires there would ship a
  new AppKit-laundered mid-sweep send in place of the one this plan
  retires.

## Verification

- `just test-ui` for the interaction and repair scenarios (UI harness;
  run once into a file and grep it). Wall-clock guards follow the house
  rules: nothing waits on a deadline a passing run can approach.
- `just test` for the core premise test, the lint self-checks, and the
  docs lint on the ADR edit.
- TDD order: PO4 and PO5 go red before the mechanism changes.
- Live check via the danterm CLI (`integrations/danterm/SKILL.md`): split
  two panes, click between them confirming focus and alert behavior via
  the focus-inspection query; control-click the non-focused pane and
  confirm it focuses (the premise behind including control-click in the
  send); open search, click the field, wait through output-driven
  sweeps, confirm the field keeps focus; click into a non-focused pane's
  open search field and confirm the pane focuses with the field active;
  confirm a sidebar rename ending returns focus to the pane without a
  focus flicker.

## Critical files

- `app/SwiftTerminalSessionView.swift` -- the `becomeFirstResponder`
  emission and the mouse handlers.
- `app/PaneFocusReconciliation.swift` -- the pass whose repair must
  originate nothing.
- `app/SearchOverlayView.swift` -- field focus-gain reporting.
- `lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift` --
  the boundary event case and its translation.
- `app/AppRuntime.swift` -- the characterization recorder arm and the
  session event funnel.
- `docs/design/2026-05-27-model-driven-view-reconciliation.md` -- the
  exception paragraph.
- `scripts/reconcile-pass-lint.sh` -- the comment naming the edge.

## Commit progress
- [x] 1. search-field focus reports from the click gesture
- [ ] 2. delete the responder echo; the terminal click reports focus

## Implementation notes

- The search-field click reports *before* `super.mouseDown`, not after the
  tracking loop returns at mouse-up. Reporting after would leave the whole
  press-and-drag gesture in the pre-existing drift window the plan set out to
  close: the model would still name the terminal, and any sweep landing during
  the drag would repair the responder out of the field.
- `controlTextDidBeginEditing` keeps its report. The plan's discretion admits a
  state callback that provably cannot fire from a pass-issued repair, and the
  new repair test asserts exactly that -- a sweep that moves the responder to
  the field sends nothing. Keeping it preserves the report for a keyboard path
  into the field, which no click reports.
- The field-click test drives the production field outside a window. AppKit's
  own mouse tracking inside `NSSearchField` blocks on real events that the
  harness cannot post, so a windowed click hangs the suite; windowless, the
  same production entry point runs and returns.
