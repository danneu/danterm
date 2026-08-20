# A reconcile pass presents through a surface it was given

## 1. Context and problem

`just test` puts real dialog windows on the developer's screen. A config-error
panel from `app-tests/AppRuntimeIpcCommandTests.swift` sits on top of the desktop
until the test process exits, and three restore-prompt panels join it.

The cause is ownership, not the test. App-tests build a real `AppRuntime` with no
window, and every `send()` runs the whole reconcile sweep. Three passes --
`reconcileConfirmation`, `reconcileNotice`, `reconcilePreferencesPanel` in
`app/Reconcile.swift` -- construct their own `NSPanel`/`NSWindow` and call
`makeKeyAndOrderFront`. They are the only passes that conjure a host. Every other
pass renders into a host the runtime was handed (`contentArea`, `chromeView`,
`tabContainers`), and a test that wants such a pass supplies the host itself:
`app-tests/AppRuntimeThemeBrowserTests.swift` assigns a plain `NSView` and asserts
on its subviews.

Desired outcome: a runtime that was given no presentation surface presents
nothing, and this is a property of what the runtime holds rather than a check any
pass performs.

Load-bearing premises, checked against `5afabffe`:

- Reconcile runs on every `send()`, inline or coalesced, so every app-test that
  sends is a presentation site.
- `startsApplicationServices: false` suppresses only the switcher panel, the
  switcher event monitor, and the IPC server. It does not suppress the sweep.
- The main window is created and assigned to the runtime in
  `AppDelegate.applicationDidFinishLaunching`, after the runtime exists and
  before anything reports a notice. `AppDelegate` holds the window strongly for
  the process lifetime, and `windowShouldClose` refuses the close button, so the
  runtime's weak `window` is non-nil from that assignment until exit.
- The four panels do not share a presentation policy. Notice and confirmation
  center on the main window and take key focus once, on the open transition.
  Preferences takes key focus but never centers. The switcher re-centers on
  screen on every change and never takes key focus, because key would pull the
  first responder out of the pane.
- `tests-ui/NoticePanelTests.swift` already covers the real panel's buttons and
  key equivalents in a GUI session. The single app-test assertion on
  `noticePanel?.headingLabel` is the only app-test that reads a panel object.
- `scripts/reconcile-pass-lint.sh` already fences `app/Reconcile.swift` as a
  whole file against a different defect, and states that the gate names the
  boundary rather than the passes.

## 2. Decision

The runtime stops owning dialog windows. It is given a set of presentation
surfaces -- one per dialog, each carrying its own apply, raise, hide, and discard
behavior -- and the passes drive those surfaces. The AppKit implementation owns
the panels, creates them lazily, and reaches the runtime weakly. A runtime built
for a test is given recording surfaces; nothing it does can reach the screen,
whatever hosts a future test assigns it.

The surfaces belong with the effect ports, as something the runtime is given
rather than something it finds. Whatever the mechanism, no message may reach the
runtime before its surfaces do: a pass that applied a projection to a surface
that is not there yet would advance its cache and leave the model claiming a
dialog nobody can see.

Behavioral scope: the four window-presenting passes (confirmation, notice,
preferences, switcher). The popover and theme-browser passes already render into
handed hosts and do not change.

Two consequences the direction buys beyond the fix:

- The three self-creating passes converge on one shared single-optional pass
  body, because each surface carries its own raise behavior. The switcher keeps
  its own, since its contract is to re-apply and re-position on every change.
- `startsApplicationServices` sheds its presentation branch and means only "start
  the event monitor and the IPC server".

`scripts/reconcile-pass-lint.sh` gains a second rule over the same fenced files:
a reconcile pass may only drive an injected presentation surface, and may not
construct or order a window itself. With all four passes converted the rule needs
no exception list.

## 3. Invariants

- **I1.** A runtime whose surfaces present nothing puts nothing on screen, and no
  reconcile pass reads a runtime host to decide whether to present.
- **I2.** A dialog is on screen exactly when its projection is non-nil. A retract
  hides it; a session teardown discards it before the caches reset, so nil
  continues to mean "already hidden" for the first post-restore sweep; and a
  runtime shutdown retracts whatever is still up, so a released runtime cannot
  leave a panel on screen.
- **I3.** Refreshing a visible dialog does not re-raise it. Notice, confirmation,
  and preferences take key focus only on the closed-to-open transition, so a
  projection change while the panel is open cannot pull focus off the pane. The
  switcher re-applies and re-positions on every change and never takes key focus.
- **I4.** Reopening preferences on an unchanged projection still raises the panel.
- **I5.** No projection is ever applied to a surface the runtime does not have
  yet. A pass that applied to a placeholder would advance its cache and leave the
  model claiming a dialog nobody can see, so the surfaces must be in place before
  the first message reaches the runtime.
- **I6.** The switcher's presentation is unchanged: it re-renders and re-centers
  on every step of a cycle, because its row count sets its height.
- **I7.** Window construction and window ordering live only in the live surface
  implementations. `app/Reconcile.swift` contains neither, enforced by the gate
  rather than by review.

## 4. Proof obligations

- **PO1 (I1).** A headless runtime driven through a notice, a confirmation, and a
  preferences open records the presentation on its surfaces and creates no
  window. Covers the reported defect.
- **PO2 (I5).** The very first message a runtime receives presents through its
  surfaces: the projection is applied, not dropped against a surface that arrived
  late, and no cache advances without a matching apply.
- **PO3 (I2).** Reporting then answering a notice applies and then hides it, and
  the projection cache returns to nil. A restore commit discards an open dialog.
  Shutting a runtime down while a dialog is up retracts it.
- **PO4 (I3).** A second projection for an already-visible notice, confirmation,
  and preferences applies again and raises no second time.
- **PO5 (I4).** Opening preferences twice raises twice, including when the second
  open produces an unchanged projection.
- **PO6 (I3, I6).** Each step of an MRU cycle re-applies and re-positions the
  switcher projection, never raises it to key, and ending the cycle hides it.
- **PO7 (I7).** The lint's self-test fails a fixture pass that constructs or
  orders a window, and passes one that builds a subview inside a host it was
  handed -- the rule is scoped to windows, not to view construction.
- **PO8.** The real notice panel renders a projection's title and message into its
  labels -- in the UI harness, where a WindowServer exists. This is the assertion
  the app-test gives up.

## 5. Non-goals, accepted risks, rejected ideas

- **Non-goal.** Removing `startsApplicationServices`. Its event-monitor and IPC
  branches stay as they are; only the presentation branch goes. The ideal --
  both become injected collaborators and the flag disappears -- is named here so
  it is not lost, and is not done in this change.
- **Non-goal.** Changing the popover and theme-browser passes. They already take
  handed hosts and cannot produce the defect.
- **Accepted risk.** The panels send messages back to the runtime, so the AppKit
  implementation holds the runtime weakly and must build nothing once the runtime
  is gone. A strong reference here would be a retain cycle across the boundary the
  object-lifetime rules guard.
- **Accepted risk.** No headless test proves the reconcile sweep drives a real
  panel end to end. It never did: the assertion that appeared to prove it only
  passed by performing the defect under repair.
- **Rejected idea.** Have the three passes decline when the runtime has no window.
  It works today and breaks silently later: the first test that assigns a window
  for an unrelated pass brings every dialog back onto the screen, and the runtime
  is then reading ambient state to infer that it is under test.
- **Rejected idea.** Keep an app-test that builds a real panel outside the sweep.
  It duplicates the UI harness at a worse layer and proves nothing about the pass.

## 6. Documentation

`docs/design/2026-05-27-model-driven-view-reconciliation.md` assumes throughout
that a pass renders into a long-lived host, and states it as a rule nowhere --
which is how three passes became window factories without anyone noticing. It
gains an amendment saying the rule outright: a pass may build a subview inside a
host it was given, and otherwise presents only by driving an injected surface;
window construction and window ordering belong to the live surface
implementations alone. Panel existence stays a projection of a model slot,
exactly as the note already requires; what moves is who owns the window.
Cross-link the test-seam note, since the surfaces are one of its injected
collaborators, and the lint, beside the existing no-send gate.

## 7. Implementation discretion

- The shape of the recording surfaces used by app-tests, and how much of the
  apply/raise/hide sequence each test reads.
- Whether the AppKit implementation is one object owning all four panels or one
  per panel, and how the surfaces reach the runtime given that the panels need
  the runtime back -- constructor input with a late-bound presenter, or a slot
  assigned before the first message. I5 is the constraint either must satisfy.
- How the files fall out: which file holds the surfaces and their AppKit
  implementation, and how the shared pass body is factored.

## 8. Verification

- `just test` -- passes, and no dialog window appears on screen during the run.
  This is the reported symptom; watch the screen for one full run.
- `just test-ui` -- passes, including the new notice-panel content assertion.
- `just launch-slot`, then through the slot's socket: open preferences twice
  (raises both times), trigger a config error against an unwritable config path
  (the notice appears, centered, and OK dismisses it), and cycle the MRU switcher
  (appears, re-centers, never steals key focus from the pane).

## Commit progress

- [x] 1. refactor(app): present windows through injected surfaces

## Implementation notes

- The switcher's presentation policy is structural rather than remembered. The
  four surfaces share `apply`, `hide`, and `discard`; only the three that take
  key focus also carry `raise`, on a `DialogSurface` protocol that refines the
  `OverlaySurface` the switcher conforms to. So the switcher has no `raise` to
  call, and I3's "never takes key focus" is a compile-time fact rather than an
  empty method nobody may call. A first draft gave every surface a `raise` and
  made the switcher's one a no-op; the app-test for PO6 could not tell that from
  a raise that did something, which is what drove the split.
- One pass body, not two nearly identical ones: `reconcileDialog` is
  `reconcileOverlay` plus a raise on the closed-to-open transition, so all four
  dialogs run the same diff, apply, and hide.
- `AppRuntime.init` takes `dialogSurfaces` with no default. A default of `.live`
  would have made "presents nothing" the exception a test has to remember, which
  is the failure mode the change exists to remove.
- The live switcher surface builds its panel with the surface rather than on
  first use, keeping the eager build the old code did at launch to pay the
  first-frame cost off the cmd-shift-i path.
- PO5's assertion is that a second open raises again, not that the count is
  exactly two: opening once both applies a new projection (which raises) and
  raises explicitly, so the meaningful fact is that the raise count grows on an
  open whose projection did not change.

## Follow Up

- `tests-ui/SwiftTerminalSessionViewTests.swift:1974` does not compile, so
  `just test-ui` fails at `HEAD` before this change: `5a86de8b` gave
  `TerminalInputSubmissionResult.rejected` an associated
  `TerminalInputSubmissionFailure` and did not update this harness call site.
  The fix is `results == [.rejected(.bufferLimitExceeded), .rejected(.launchFailed)]`.
  Verified: with that one line applied the whole UI suite passes, including this
  change's new notice-panel content test.
- The plan's third verification step -- open preferences twice, trigger a config
  error against an unwritable config path, and cycle the MRU switcher in a live
  slot -- was not run. None of the three has a `danterm` CLI path, so all three
  need a human at the keyboard. A general `danterm` verb for driving an app-level
  menu action would make them scriptable.
