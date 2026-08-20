# REDUCE-7: delete the senderless `.markAlertRead` message

Source finding: `docs/scratch/2026-08-18-construction-audit.md` REDUCE-7
(anchor `#reduce-7`). Verified 2026-08-20; action: fix.

## 1. Problem and evidence

`Msg.markAlertRead` has no producer. Its only senders are two unit tests
in `lib/DanTermCore/Tests/DanTermCoreTests/UpdateAlertTests.swift`, so
the `Msg` case, its reducer arm in `Update.swift`, and those tests all
describe a path the product cannot take. A reader of the `Msg` surface
sees per-alert acknowledgement as a capability the app does not have.

Verified against the current tree:

- `grep -rn markAlertRead app lib ios integrations` returns exactly the
  declaration (`Msg.swift`), the reducer arm (`Update.swift`), the two
  test sends, and the test file's header comment. No IPC method, menu
  action, or popover row sends it; the alerts popover and `AppDelegate`
  use `.activateAlert` and `.markAllAlertsRead`.
- The arm's whole effect -- flip one alert's `isUnread` to false, emit no
  commands -- is reachable through `.activateAlert` (single alert, outside
  manual mode) and `.markAllAlertsRead` / `.clearAlertsForPane` /
  `.clearAlertsForTabs` (bulk). Nothing is lost by deleting it.
- Of the 103 `Msg` cases, `markAlertRead` is the only one with zero
  senders outside `Msg.swift` and `case .x` arms; the other dead cases the
  2026-08-11 simplification audit named are already gone, so there is no
  wider sweep to fold in. IOS-5 and STORE-2 share the audit's root cause
  but are separate pipeline items.

## 2. Decision

Delete the dead vocabulary: the `Msg.markAlertRead` case, its reducer arm,
the two tests that are its only senders, and the `markAlertRead /` mention
in the test file's header comment. Then tick the REDUCE-7 checkbox in the
audit doc with the commit sha, in the same form as the PTY-6 line.

Why this and not keep-and-wire: the finding's own rule holds -- if
per-alert acknowledgement is ever wanted, it comes back together with the
UI or IPC producer that sends it, so `Msg` vocabulary always names
something a user or script can do.

Behavioral scope: none. No user-visible or IPC-visible behavior changes.

## 3. Invariants

- I1. Every `Msg` case has at least one producer outside `Msg.swift`,
  reducer arms, and the test suite. After this change that holds for the
  whole enum.
- I2. The live mark-read paths are unchanged: `.activateAlert` marks its
  alert read outside manual mode and leaves it unread in manual mode;
  `.markAllAlertsRead` clears every alert's unread flag.

## 4. Proof obligations

- PO1 (I1, and the premise that no real producer existed): the full build
  -- `lib/DanTermCore` standalone and the app target that compiles the
  same files via the `app/DanTermCore` symlink -- succeeds with the case
  removed. A surviving sender anywhere would be a compile error.
- PO2 (I2): the remaining alert tests still pass and still pin the live
  paths -- `testMarkAllAlertsRead` and the `activateAlert` mark-read /
  manual-mode tests in `UpdateAlertTests.swift`. No new test is needed;
  deleting the two `markAlertRead` tests leaves I2's coverage intact.
- PO3: `grep -rn markAlertRead app lib ios integrations` returns nothing
  after the change.

## 5. Non-goals

- Adding a per-alert acknowledgement producer (UI row action or IPC
  method). If wanted, it is a feature with its own producer, not a
  reason to keep the case.
- Touching IOS-5 or STORE-2, the audit's sibling "dead vocabulary" items.
- Any other change to the alerts reducer or its tests.

## 6. Implementation discretion

- Whether the remaining alert tests' header comment is reworded beyond
  dropping `markAlertRead /` is the implementer's call.

## Commit progress

- [x] 1. Delete the senderless mark-alert-read path
- [x] 2. Record REDUCE-7 completion in the construction audit
