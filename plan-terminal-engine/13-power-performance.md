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

Visibility, focus, activation, damage, and cursor-blink demand feed a
deterministic scheduling policy. AppKit performs the resulting scheduling and
drawing actions; system callbacks do not decide terminal semantics.

The initial power contract is:

- no periodic work for unchanged terminal content
- no rendering work for hidden or occluded panes
- no accidental macOS power assertions
- background PTY output is consumed and parsed without drawing
- sleep/wake resumes IO and redraws current state correctly
- idle CPU is effectively zero
- the only initial periodic visual behavior is application-requested cursor
  blinking while its pane is visible and focused and DanTerm is active

Correctness takes priority over peak rendering throughput for the initial
CoreText/CoreGraphics renderer. Heavy visible output must still keep the app
responsive and use bounded queues.

## Invariants

- Hidden rendering state cannot prevent PTY consumption or terminal-state
  updates.
- Rendering demand is coalesced without losing the final visible state.
- Damage retention is bounded by active-grid state plus a full-redraw marker;
  output bursts do not create an event-by-event render queue.
- Becoming visible after hidden updates produces a complete current frame.
- Sleep/wake does not duplicate events, lose bytes already read, or leave stale
  display scheduling active.
- Teardown cancels every owner-bound timer and scheduled callback.
- Once enriched recovery covers the latest terminal mutation, no checkpoint
  callback remains scheduled.
- No engine component creates a macOS power assertion in the initial design.
- Identical scheduling inputs produce identical requests for work independent
  of AppKit timing.

## Proof obligations

- An unchanged focused terminal without requested cursor blinking performs no
  recurring engine or recovery work.
- Hidden panes receiving output update their logical state while producing no
  draw calls.
- A revealed pane displays the same final state as one rendered continuously.
- App deactivation, occlusion, sleep, wake, and teardown stop and restart only
  the work required by visible behavior.
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
