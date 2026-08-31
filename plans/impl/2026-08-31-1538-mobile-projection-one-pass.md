# One projection pass: stored outline, typed menu, needsTarget

Source findings: MOBKIT-2 + MOBAPP-2 + MOBAPP-3 in
docs/scratch/2026-08-26-improvement-audit.md (one pass; MOBKIT-2 owns).

## Problem

Three defects share one seam, the `MobileSessionProjection` built by
`MobileSessionModel.projection(at:)` and read by
`MobileRootViewController`:

- **Rebuilt representation.** The model stores the raw wire roster
  (`panes: [PaneRosterItem]`) and rebuilds the whole prepared
  `MobilePaneOutline` -- every group, tab, and pane title through the
  per-character `MobileDisplayText(preparing:)` scan -- on every
  projection read. The roster has exactly two writers, but the shell
  reads the projection fourteen times, seven of them for
  `selectedPaneId` alone, and one redraw builds it up to three times
  (`render` -> `showArrowPad` -> `layoutArrowPad`). Roster pushes
  arrive several times a second while an agent renames its pane.
- **Duplicated menu rule.** The session's action vocabulary is stated
  twice in `MobileRootViewController`: `sessionMenuItems()` builds an
  item per condition, and `render` restates the same three conditions
  as an `||` chain for `setMenuOffered`. Nothing ties them together,
  and the vocabulary lives in the app target, which has no tests.
- **Duplicated launch rule.** `MobileLaunchPlan.connectsImmediately`
  decides, tested, whether a launch names a server; the model never
  publishes it, so `viewDidAppear` re-derives it as
  `draft.host == nil || draftProblem != nil` in the untested shell.

## Decision

One pass over the projection, in the kit:

- **The prepared outline becomes the model's authority.** The model
  stores `MobilePaneOutline`, built at the two roster-write sites (the
  `.attemptSucceeded` arm and the `PaneRosterNotification` arm), and
  the raw `[PaneRosterItem]` array is deleted. This is a change of
  authority, not a cache: the raw list and the prepared outline stop
  both being representable, so they cannot disagree.
- **The outline carries only roster facts.** `initiallyExpandedTabId`
  depends on the selection, so it leaves the stored value and becomes a
  query taking the selection (`initiallyExpandedTabId(for:)`). Outline
  equality then means exactly "the same rows", which is what
  `PaneSheetViewController.show` and `rowsNeedingRefresh` already
  treat it as.
- **One-field reads get a one-field accessor.** The model and
  `MobileSessionController` expose `selectedPaneId` directly, and the
  seven shell reads that want only a pane id (arrow-pad show/layout/
  drag, tap, toggle, move-to-corner) use it instead of building a
  projection. `render` no longer triggers extra full projection builds.
- **The menu is projection data.** The projection gains an ordered
  list of typed session actions (new pane / claim / release), decided
  by the model where `canCreatePane` and `MobileClaimControl` already
  live. The shell enables the overflow button on the list being
  non-empty and renders each action through an exhaustive switch, so a
  new action fails the build instead of silently missing from the menu.
  "Menu offered" stops being a separate boolean.
- **The launch decision is projection data.** The projection gains
  `needsTarget`: true while the session has no target it can attempt
  and is not attempting one -- covering both no-host and
  model-refused-host (`draftProblem`). `viewDidAppear` reduces to
  guarding on it and holds no launch rule.

## Invariants

- I1. The model holds one representation of the roster; a projection
  read after an unchanged roster prepares no new title text.
- I2. `MobilePaneOutline` equality means "the same rows": it is
  unaffected by selection changes.
- I3. The overflow button is enabled exactly when the projected action
  list is non-empty; every projected action appears in the opened menu.
- I4. The connect sheet is offered on first appearance exactly when
  `needsTarget` is true: no host anywhere, or a host the model
  refused; a launch that names a usable server never sees the sheet.
- I5. The shell decides nothing: menu vocabulary, launch
  connectability, and pane selection are all read from the kit.

## Proof obligations

- PO1 (I2, I1): existing `MobileSessionModelTests` outline tests and
  `PaneOutlineRefreshTests` stay green, with only the
  `initiallyExpandedTabId(for:)` call-shape change; roster-push and
  reconnect-fallback tests still see correct outline, titles, and
  selection through the projection. The default-pane choice needs a
  new test the fixtures currently cannot express (their focused pane
  is always first): a roster whose first entry is a background pane
  and whose focused pane sits later in the selected tab, asserting
  `.attemptSucceeded` attaches the focused pane, not the first.
- PO2 (I3): model tests assert the projected action list per lifecycle
  state -- empty while disconnected, exactly new-pane while serving
  without a claim, claim/release tracking `MobileClaimControl` -- and
  that it agrees with `canCreatePane` where both exist.
- PO3 (I4): model tests assert `needsTarget` after `.launched` -- false
  with an environment host, true with no host, true when the model
  refused the draft -- and false while an attempt is in flight.
- PO4 (I5): the app target compiles with the shell reading only
  projection fields and `selectedPaneId`; the iOS smoke run still
  connects without a sheet when launched with a host.

## Non-goals / accepted risks

- **Non-goal: a measured cost win.** The audit's correction stands:
  the pass is justified structurally; no benchmark or measurement
  harness gates it.
- **Non-goal: re-offering the connect sheet after a target is
  cleared.** `hasAnsweredLaunch` stays one-shot; `needsTarget` merely
  makes that future change expressible.
- **Accepted risk: consumers noticing selection via outline
  inequality.** Both live consumers already compare the selection
  beside the outline (`PaneSheetViewController.show`'s guard,
  `rowsNeedingRefresh`'s parameters); verified before this plan.

## Implementation discretion

- How the `.attemptSucceeded` default-pane choice (preferred, else
  focused-and-selected, else first) is answered once the raw list is
  gone -- from the arriving roster or from outline queries -- and how
  `canCreatePane` / `.newPaneRequested` answer their containment and
  tab lookups against the outline.
- Whether a projected menu action carries its event or the shell's
  exhaustive switch maps case to event alongside title and symbol.

## Critical files

- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`
  -- stored outline, `selectedPaneId` accessor, projection fields.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDisplayText.swift`
  -- outline init without selection, `initiallyExpandedTabId(for:)`.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift`
  -- `render`, `sessionMenuItems`, `viewDidAppear`, arrow-pad reads.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift`
  -- `selectedPaneId` accessor.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/PaneSheetViewController.swift`
  -- `viewDidLoad`'s expansion seed.
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`
  -- PO2, PO3, and the PO1 call-shape change.

## Verification

- `swift test --package-path ios/DanTermMobileKit` and `just lint` in
  the edit loop; `just test` before commit.
- `just test-portability` for the iOS cross-compile of the app target
  (it has no test target).
- Optional live check: `just ios-app simulator --slot <n>` against a
  `just launch-slot --tailnet` slot -- launch with a host connects with
  no sheet; launch without one shows it; the overflow menu opens with
  the projected actions.

## Commit progress

- [x] 1. refactor(ios): make session projection data authoritative
- [ ] 2. docs(audit): mark the mobile projection findings complete

## Implementation notes

- The `.attemptSucceeded` default-pane choice reads the arriving
  roster, not the outline. The two flags it needs -- `isSelectedTab`
  and `isFocused` -- are wire facts the outline deliberately drops, so
  keeping them out of the outline was cheaper than adding them back
  for one decision.
- `canCreatePane` and `.newPaneRequested` ask the outline one question,
  `tabId(for:)`. Containment is "the answer is not nil", so the two
  call sites cannot disagree about which panes are in the roster.
- A projected action carries no event. The shell's exhaustive switch
  maps each case to its title, symbol, and event together, because the
  claim and release events are a different type from the new-pane one
  and a carried event would have had to name both.
- `needsTarget` is stated as "no attempt in flight, and the draft
  validates to no server". It uses `MobileTargetDraft.validate()`
  rather than `draftProblem`, so a draft nothing has yet tried to
  connect with -- a launch with no host -- answers the same way as one
  the model refused.
- `canCreatePane` stays on the projection beside the action list. The
  shell no longer reads it; the model tests do, to hold the action
  list against the fact it is built from.
