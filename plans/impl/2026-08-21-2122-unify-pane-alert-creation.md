# Unify pane alert creation

## Summary

Replace the two alert-insertion implementations with one policy owner used by
bells, terminal notifications, and agent-wait alerts. This is a
behavior-preserving refactor: alert admission, presentation, history, unread
state, and notification throttling must not change.

No public API, persistence, IPC, or command shape changes.

## Decision

- Route every production alert insertion through one shared core function.
- Make that function own live-pane validation, active focused-pane suppression,
  marking older pane alerts read, alert creation, newest-first insertion, the
  100-item history bound, and notification throttling.
- Keep source-specific admission and presentation outside the shared policy.
  Bell alerts use the existing DanTerm presentation. Terminal notifications
  validate sender title and body at ingress before resolving their presentation.
  Agent-wait alerts retain their resolved presentation from the live agent or
  command identity, with the pane title as fallback, and their stronger
  focused-pane suppression rule.
- Remove the desktop-specific alert helper after all of its callers use the
  common path.
- State the 100-item history bound once instead of repeating it at each insertion
  site.

## Invariants

- An active, focused pane does not raise a bell or terminal-notification alert.
- A focused pane can raise those alerts while the app is inactive. An agent-wait
  transition remains silent for a focused pane in either app state.
- Raising an alert marks every older alert for that pane read, leaving exactly
  the new alert unread.
- Alert history stays newest-first and never exceeds 100 items.
- Notification throttling remains per pane and per alert kind at one second. A
  throttled notification still creates and stores its alert.
- Agent-wait alerts remain desktop notifications and share their per-pane
  throttle bucket with terminal notifications.
- Stored alerts and macOS notification commands use the same alert identity,
  presentation, body, and timestamp.
- Terminal metadata keeps its 64 KiB admission boundary. Internal agent alerts
  are not treated as terminal metadata.
- Unknown or stale session callbacks remain inert.

## Proof obligations

- Characterize rapid same-kind alerts: both remain in history, only the newest
  is unread, and only the first emits a macOS notification.
- Exercise the 100-item history bound through both bell and terminal-notification
  messages. The new alert remains and the oldest alert is removed.
- Keep the existing behavioral coverage for focused-pane suppression, inactive
  delivery, throttle isolation and boundary timing, terminal metadata limits,
  deterministic timestamps, and resolved agent-wait presentation green.
- Prove that an agent-wait alert and a terminal notification for the same pane
  share one notification throttle bucket.
- Run the targeted DanTermCore alert and session-event suites plus `just lint`
  during the refactor, then run `just test` before commit.

## Assumptions

- MODEL-5, REDUCE-2, and REDUCE-3 are complete. No prerequisite work remains.
- `AlertPresentation` remains the presentation boundary.
- No compatibility layer or migration is needed because no external interface
  changes.

## Implementation discretion

- Helper naming, parameter layout, and test factoring are free choices as long
  as there is exactly one production alert insertion path and the invariants
  hold.

## Commit progress

- [x] 1. refactor(alerts): unify pane alert creation
- [x] 2. docs(audit): mark REDUCE-5 done
