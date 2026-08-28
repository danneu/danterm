# Let `paneAlertCommands` be the only owner of focused-pane alert suppression

Source: `docs/scratch/2026-08-26-improvement-audit.md`, UPDATE-1 (Wave 9).

## Problem

"Do not alert for the pane the user is looking at" is one rule, and
`paneAlertCommands` (`lib/DanTermCore/Sources/DanTermCore/Update.swift`) owns
it: suppress only when the app is active and the pane is the selected tab's
focused pane. The agent-waiting arm of `.sessionReport` restates the rule
without the app-active half, so an agent that reports `waiting` on the
focused pane raises nothing even when DanTerm is in the background. A bell or
OSC 9 from the same pane in the same second does raise a banner and an unread
alert.

Evidence: the guard arrived with the feature (`9eb70822`) and nothing in the
tree -- commit message, comment, or design doc -- says why waits should differ
from bells. The neighbouring test for OSC 9 while inactive argues the opposite
("a backgrounded app cannot rely on focused-pane visibility").

Desired outcome: an agent waiting for input notifies a backgrounded DanTerm
exactly as a bell does, and the suppression rule has one writer.

## Decision

Delete the agent-waiting arm's own focused-pane guard and let
`paneAlertCommands` decide. The user has confirmed the behavior change.

Behavioral scope: only the agent-waiting alert on the selected tab's focused
pane while the app is inactive changes (silent -> alert + notification). The
active-app case, the repeat-wait guard, and notification throttling are
untouched.

## Invariants

- I1. Every pane alert kind (bell, OSC notification, agent waiting) gets the
  same answer to "is this pane suppressed", and that answer is written in one
  place.
- I2. An agent wait on the focused pane while DanTerm is inactive produces one
  unread alert and one `.sendNotification` for that pane.
- I3. An agent wait on the focused pane while DanTerm is active produces no
  command and no alert.
- I4. A report that repeats an already-visible wait raises nothing.

## Proof obligations

- PO1 (I2): existing test "agent waiting stays silent for the focused pane
  while the app is inactive" in `UpdateSessionEventTests.swift` is rewritten
  to assert the alert and notification.
- PO2 (I3, I4): the existing active-app and repeat-wait tests stay green.
- PO3 (I1): covered by PO1 plus the existing bell / OSC-9 inactive-focused
  tests agreeing on the same outcome; no structural test.

## Non-goals / Accepted risks

- AR1. A user who backgrounds DanTerm with an agent pane focused sees banners
  they did not see before. Throttling (one per pane per kind per interval) and
  I4 bound the volume; this is the point of the change.
- Non-goal: touching `reconcileFocusedPaneAlerts` or the read/unread policy.

## Verification

- `swift test --package-path lib/DanTermCore --filter UpdateSessionEventTests`
- `just lint`, then `just test` before commit.
- After landing: tick UPDATE-1 in `## Plan of work` of the audit file with
  `-- done <sha>`.

## Commit progress

- [x] 1. fix(alerts): notify for focused agent waits while inactive
- [x] 2. docs(audit): mark UPDATE-1 complete
