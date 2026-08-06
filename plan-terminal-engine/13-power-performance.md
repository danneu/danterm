# Power and Performance

## Problem

The replacement is motivated partly by terminal runtime behavior that can
prevent or interfere with macOS sleep. Correct terminal output is insufficient
if idle or hidden panes keep scheduling display work.

## Decision

The engine is event-driven. PTY input updates terminal state, state damage
requests visible rendering, and AppKit coalesces presentation. There is no
permanent display link or periodic redraw loop.

Terminal mutations also drive the bounded enriched-recovery checkpoint policy
in [Inspection, search, and recovery](06-inspection-recovery.md). Recovery work
coalesces while content is changing and stops once the latest mutation is
durable; a clean terminal has no repeating checkpoint timer.

Visibility, focus, activation, and damage feed a deterministic scheduling
policy. AppKit performs the resulting scheduling and drawing actions; system
callbacks do not decide terminal semantics.

System sleep is a presentation-availability input independent of pane
visibility. It suppresses frame planning without suppressing PTY consumption,
terminal mutation, semantic delivery, or recovery tracking. Wake requests one
complete current frame when the pane is visible and retains that bounded request
until reveal otherwise. Repeated sleep and wake signals are idempotent.

Screen sleep has no separate adapter. A 2026-08-06 AppKit probe observed screen
sleep clear `NSWindow.OcclusionState.visible`, and the maintained occlusion route
already drives pane visibility. A second screen-sleep input would duplicate that
broader signal and could disagree with it. Application deactivation alone does
not suppress visible rendering.

Application-runtime shutdown is a terminal state. It cancels every runtime-owned
timer, debouncer, event monitor, subscription, and deferred callback, makes
callbacks captured before shutdown inert, and prevents scheduling entry points
from rearming.

The initial power contract is:

- no periodic work for unchanged terminal content
- no rendering work for hidden or occluded panes
- no accidental macOS power assertions
- background PTY output is consumed and parsed without drawing
- system sleep/wake resumes presentation from current state correctly
- idle CPU is effectively zero
- no initial periodic visual behavior; application-requested cursor blinking is
  a deferred post-milestone enhancement

Correctness takes priority over peak rendering throughput for the initial
CoreText/CoreGraphics renderer. Heavy visible output must still keep the app
responsive and use bounded queues. The maintained responsiveness gate covers
keyboard input: a keystroke reaches the child before a sustained-output producer
finishes, then the pane converges to the final output state. This is an
ordering/liveness contract, not a numerical latency budget.

## Invariants

- Hidden rendering state cannot prevent PTY consumption or terminal-state
  updates.
- Rendering demand is coalesced without losing the final visible state.
- Damage retention is bounded by active-grid state plus a full-redraw marker;
  output bursts do not create an event-by-event render queue.
- Becoming visible after hidden updates produces a complete current frame.
- System sleep/wake does not duplicate events, lose bytes already read, or leave
  stale display scheduling active.
- Teardown cancels every owner-bound timer and scheduled callback.
- Once enriched recovery covers the latest terminal mutation, no checkpoint
  callback remains scheduled.
- No engine component creates a macOS power assertion in the initial design.
- Identical scheduling inputs produce identical requests for work independent
  of AppKit timing.

## Proof obligations

- An unchanged focused terminal performs no recurring engine or recovery work.
- Hidden panes receiving output update their logical state while producing no
  draw calls.
- A revealed pane displays the same final state as one rendered continuously.
- Occlusion, system sleep, wake, and teardown stop and restart only the work
  required by visible behavior; application deactivation does not suppress a
  visible pane.
- Sustained output uses bounded pending work and does not make AppKit input
  unresponsive.
- Explicit scheduling traces prove quiescence and required redraw requests
  without relying only on elapsed-time assertions.
- Recovery scheduling traces prove bounded freshness during isolated and
  sustained output, then quiescence after the latest mutation is durable.

## Non-goals

- A first-version GPU renderer or maximum benchmark parity with Ghostty.
- Keeping the display awake for terminal activity.
- Rendering every intermediate frame of an output burst.

## Implementation discretion

- Rendering and recovery coalescing cadences and damage-merging policy, provided
  latency remains interactive and the visibility, recovery-freshness, and
  hidden/idle invariants hold.
- Performance thresholds used to decide when a Metal renderer is warranted.

## Milestone 9 evidence

The maintained gate and its evidence map are recorded in
[the 2026-08-06 power-and-performance evidence](../docs/evidence/2026-08-06-milestone-9-power-performance.md).
The gate closes scheduling, lifecycle, recovery, responsiveness, and teardown
behavior without claiming a battery-life reduction or an uncalibrated CPU
threshold.
