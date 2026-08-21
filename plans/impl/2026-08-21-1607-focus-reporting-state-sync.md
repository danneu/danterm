# Synchronize terminal focus when DEC mode 1004 is enabled

## Problem

`danterm tab new --cmd` creates its tab in the background. The new terminal
therefore receives no AppKit focus transition. An application such as Codex
starts with an assumed focused state, enables DEC mode 1004, and never learns
that its pane is unfocused. It then suppresses notifications intended only for
unfocused terminals.

The same wrong state can survive when DanTerm resigns application focus: a
terminal view can remain the window's first responder while its application is
inactive. Pane focus alone therefore cannot define the focus reported to the
child.

DanTerm v0.1.14 and current HEAD both have this gap. Focus changes are encoded
only when they occur after mode 1004 is enabled; enabling the mode does not
report the pane's current state.

## Decision

The host session retains pane focus and application activation as independent
inputs and derives effective terminal focus as their conjunction. AppKit
supplies pane-focus changes. Runtime startup seeds application activation from
the real `NSApplication` state instead of relying on the model default, and
later lifecycle changes update that input for every live session. They never
infer pane focus from tab selection. This keeps a sidebar, popover, or other
non-terminal focus claimant authoritative across application activation. The
same seed deliberately lets the existing pane-alert path deliver alerts for a
selected pane when DanTerm was launched inactive.

`TerminalCore.Terminal` retains only effective terminal focus and owns the
protocol interaction with child-controlled focus-reporting mode. The host sends
the derived value only when it changes. A new terminal starts unfocused and
receives the host session's current effective value when the session is
created.

Every valid `DECSET 1004` request immediately queues `CSI I` or `CSI O` for the
current derived state. Later input changes emit a report only when the derived
state changes while mode 1004 is enabled. Disabling the mode, resetting terminal
modes, and switching screens do not discard retained effective focus; the host
also keeps its two source inputs independent of the mode.

The enable-time report uses the existing ordered terminal-reply path. A report
caused by a retained input change is transmitted during that change and never
waits for later child output. Neither path counts as user input. Background tab
creation does not gain a synthetic focus cycle or steal selection.

Flight tapes continue to record effective focus as one `focus(Bool)` event. A
tape synchronization carries effective focus beside the serialized terminal
state so a replay starting after earlier focus events has the correct baseline.
Synchronization bootstrap seeds effective focus before applying serialized
terminal state, then discards every reply produced by that reconstruction.
Byte validation begins with subsequent events, which reproduce the same focus
changes and later mode-1004 bytes as the live pane.

Amend `docs/design/2026-08-06-swift-terminal-engine.md` G3 with this contract.
The immediate report matches `references/foot/csi.c#decset_decrst`.

## Invariants

- A child that enables mode 1004 always learns the pane's current focus,
  including in a pane that has never received an AppKit focus callback.
- A pane is reported focused only while its terminal view owns pane focus and
  DanTerm is active.
- The initial application-active input reflects the real launch state. A
  detached or background launch does not begin focused because of a model
  default.
- Pane-focus and application-active changes while reporting is disabled update
  retained effective focus and affect the next enable response but write no
  bytes at the time of the change.
- An input change while reporting is enabled reaches an otherwise silent
  child without waiting for more output.
- An input change that leaves derived focus unchanged writes no bytes.
- Repeated mode-enable requests report the current state each time.
- Focus reports remain ordered with terminal replies and pane input, and never
  satisfy an agent wait as user input.
- Live capture and byte-validating replay preserve the same derived focus
  events and later focus-report bytes.
- Synchronization bootstrap produces no validated reply bytes from state that
  precedes its cursor.
- `tab new` keeps its existing background default and focus policy.
- The pane-tape synchronization wire adds effective focus. No CLI command or
  flag, configuration, or Codex-specific behavior changes.

## Proof obligations

- A deterministic TerminalCore test drives effective focus and proves initial
  unfocused reporting, disabled-mode retention, enabled-mode transitions
  without redundant reports, repeated enable, reset, screen switching, and
  input chunk invariance.
- A real-PTY TerminalPTY test proves that a child enabling mode 1004 in a
  never-focused session immediately receives `CSI O`, a later focus gain sends
  `CSI I` while the child remains silent, ordering is preserved, and neither
  report records user input.
- DanTermCore lifecycle coverage proves only the lifecycle commands and session
  state payloads. Host-session or app-runtime coverage proves that the real
  launch activation state reaches both the model and newly created session
  requests, that effective focus is `paneFocused && applicationActive`, that
  unchanged effective values are suppressed, and that activation changes do
  not overwrite retained pane focus.
- Recording and protocol coverage proves that effective focus survives tape
  synchronization encoding, decoding, and assembly. A replay whose
  `focus(true)` precedes the synchronization cursor and whose `CSI ?1004h`
  follows it emits `CSI I`; later replayed focus events affect mode traffic just
  as they do live. A synchronization captured with mode 1004 already enabled
  seeds focus before reconstruction and discards the reconstruction's focus
  report before validating later events.
- Existing DanTermCore and CLI coverage continues to prove that background tab
  creation leaves selection unchanged and mounts the new pane hidden.
- The targeted TerminalCore and TerminalPTY suites pass, followed by the
  escalated `just test` gate.

## Rejected ideas

- Setting Codex `tui.notification_condition` to `always` hides incorrect
  terminal focus state from every other mode-1004 application.
- Repairing the symptom in `tab new`, AppKit reconciliation, or Codex detection
  splits terminal protocol policy across layers and creates synthetic focus
  transitions.

## Implementation discretion

- The exact host-session focus API and internal names are left to
  implementation. `Terminal` accepts only effective focus; callers cannot
  control its mode-1004 state or reports directly.

## Commit progress

- [x] 1. terminal: retain effective focus and report mode 1004 state
- [x] 2. app: derive terminal focus from pane and application state
- [ ] 3. tape: preserve effective focus across synchronization

## Implementation notes

- Commit 1 deletes `encodeTerminalFocus` instead of keeping it beside the new
  `Terminal.setFocused`, so no caller can produce a focus report out of band.
  `TerminalInputModes.focusReporting` stays: it is a read-only projection of a
  child-set mode that replay fixtures assert, and it grants no control over the
  report.
- Recording replay now applies `.focus` events to the replica terminal. Before
  this commit focus changed no terminal state, so replay could skip the event;
  now a skipped event would make the replica answer a later mode-1004 enable
  with focus the pane never had, and the controller replay test that compares a
  replica against the live terminal would fail.
- The ported libvterm `state-input` fixture gained a recorded deviation: pinned
  libvterm reports only transitions that happen while mode 1004 is enabled,
  while DanTerm retains focus and answers every enable.
- Commit 2 gives `AppRuntime.init` a required `applicationActive` argument rather
  than one defaulting to true. The invariant is that the launch state is chosen,
  not inherited, and a default would let a new call site inherit it silently.
- The restore reducer now preserves the live `isAppActive` the way it already
  preserves the notice queue. `isAppActive` is ephemeral and never snapshotted, so
  a staged model always claims "active"; installing it would undo the launch seed
  at exactly the launch a restore happens on, and would leave sessions -- created
  from the live model before the swap -- disagreeing with the model.
- Application activation is pushed to live sessions from `model.isAppActive` after
  the lifecycle message reduces, so the runtime keeps no second copy of the fact.
