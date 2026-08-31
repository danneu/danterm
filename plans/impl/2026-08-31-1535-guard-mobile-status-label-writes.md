# Guard the mobile status label writes on change (MOBAPP-6)

## Problem

`MobileRootViewController.render` runs on every `.redraw`, and every keystroke
produces one. Two views it paints write UIKit label properties without stating
a guard, while every neighbouring guarded write in the render path carries a
comment saying why it is guarded (`TerminalPaneRowView.show` is the template,
`TerminalPaneRowView.swift:46-60`; `statusPill.isHidden` in `render` itself):

- `ConnectionStatusPillView.show`
  (`ios/DanTermMobileApp/Sources/DanTermMobileApp/ConnectionStatusPillView.swift:36-39`)
  writes `statusLabel.text` and `statusLabel.textColor` bare.
- `ConnectSheetViewController.showStatus` and `showDraftProblem`
  (`ios/DanTermMobileApp/Sources/DanTermMobileApp/ConnectSheetViewController.swift:46-55`)
  are the same pattern, live whenever the sheet is up.

This is a consistency simplification, not a cost fix: the audit's Correction
(MOBAPP-6 in `docs/scratch/2026-08-26-improvement-audit.md`) retracts the
original layout-cost claim -- the pill is hidden in exactly the quiet-typing
state the claim named, and an equal-string `UILabel` write has no confirmed
invalidation behavior. What survives is that these are the only label writes
in the render path that do not state their own guard, and a few lines make the
files uniform. Scope extends the audit item to the connect-sheet sibling it
did not name.

## Decision

Guard each write in the three methods on inequality with the value the view
already holds -- the same shape as `TerminalPaneRowView.show`. No other
structure changes.

## Invariants

- I1: A render call that repeats a status or draft-problem label's text and
  color performs no UIKit write for them (scope: the pill and the connect
  sheet's two labels).
- I2: Each guard compares against the view's own held value (the authority),
  never a remembered mirror -- every call still states the whole control, so
  no stale value has anywhere to live. Text and color are guarded
  independently: a changed color with unchanged text must still paint.

## Proof obligations

- PO1 (I1, I2): discharged in implementation review of the diff -- each
  property guarded against, and writing, that property alone, matching the
  `TerminalPaneRowView.show` shape. This is the available proof: the app
  shell has no test target, and no real status transition reproduces equal
  text with a changed color, so a runtime color-only check would need a
  harness this change does not earn.
- Build proof: the compile is the regression gate -- `just ios-app simulator`
  (or the portability cross-compile).

## Non-goals

- No shared guarded-label helper across the three views: the existing
  convention is per-view guards with a comment.
- No change to `render`'s call-every-time shape or to `MobileSessionModel`'s
  redraw emission.
- No guard for `arrowPad.frame`'s unconditional assignment in
  `layoutArrowPad` -- outside this item's label-write scope.

## Implementation discretion

- Comment wording on each guard (follow the neighbouring comments' voice).

## Commit progress

- [x] 1. refactor(ios): guard unchanged status label writes
- [ ] 2. docs(audit): mark MOBAPP-6 complete

## Implementation notes

- Build proof for commit 1 was a direct iOS cross-compile of the app shell
  (`swift build --package-path ios/DanTermMobileApp --triple arm64-apple-ios26.0
  --sdk <iphoneos>`), not `just ios-app simulator`. `scripts/ios-portability-gate.sh`
  only builds the `lib/` packages that pin an iOS platform, so it never compiles
  the three edited files; the direct build does, without installing or launching
  anything.
