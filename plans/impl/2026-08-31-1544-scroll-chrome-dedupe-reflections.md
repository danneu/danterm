# Reflect the scroll chrome only when the description it reflects moved

Source finding: MOBKIT-4 in `docs/scratch/2026-08-26-improvement-audit.md`.

## Problem

`TerminalScrollChromeView.refresh()` runs after every published frame, so on a
pane producing output it runs at display-link rate. Whenever the user is not
touching the screen, `MobileScrollDriver.replicaChanged` answers with a
reflection unconditionally, whether or not any scroll fact moved. The shell
then writes `showsVerticalScrollIndicator` and `contentSize` on a
`UIScrollView` every frame, and in delta mode the driver re-seeds its baseline
every frame too.

Evidence: `replicaChanged` ends with an unconditional `return [reflection()]`
(`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileScrollDriver.swift`),
and `reflection()` is a pure function of `mode`
(`MobileScrollGeometry.swift`). The driver's other two inputs already dedupe:
`offsetChanged` via `lastNamedTopRow`, `interactionChanged` via the
active/idle edge. `replicaChanged` is the lone unconditional path.

## Decision

Fix it in the driver, not the shell. The chrome view's contract is "the shell
decides nothing", and only the driver can also stop the per-frame delta
baseline re-seed.

The dedupe authority is the chrome description last emitted -- the
`(contentHeight, offset, showsIndicator)` triple the shell writes -- not the
held `MobileScrollMode`. The chrome observes nothing else, so this is the
exact contract: mode facts that leave the description unchanged
(`isFollowing`, projected `windowRows`, delta `rowHeight`) suppress the
reflection, while the held mode still updates so gesture routing always
follows the latest replica facts. A fresh driver has emitted no description,
so its first idle replica change always reflects.

Scope: `MobileScrollDriver` and its tests only. No shell change, no API
change beyond the driver's action stream getting quieter.

## Invariants

- I1: An idle replica change that leaves the chrome description --
  content height, offset, and indicator -- unchanged produces no action.
- I2: A fresh driver's first idle replica change always reflects, whatever
  mode it selects -- the chrome starts undescribed.
- I3: The return-to-idle reflection in `interactionChanged` stays
  unconditional: after a gesture the offset moved under the driver, and only
  a reflection reconciles it.
- I4: An idle replica change that alters any part of the chrome description
  reflects, and a suppressed reflection never stalls gesture routing -- the
  next gesture is routed under the newest replica facts.

## Proof obligations

- PO1 (I1): identical replica facts given twice while idle produce one
  reflection, then none -- in projected and in delta mode.
- PO2 (I1/I4): a replica change that alters only a description-invisible
  fact (e.g. delta `rowHeight`, or projected `isFollowing`) produces no
  action, and a following gesture routes under the new facts.
- PO3 (I2): a fresh driver reflects on its first idle replica change even
  when the selected mode is `.inert` (the existing
  `scrollDriverInertModeEmitsNoMotion` already pins this; it must stay
  green).
- PO4 (I3): existing tests
  `scrollDriverLatchesReflectionDuringInteraction` and
  `scrollDriverDropsMotionAfterAMidGestureModeFlip` stay green.
- PO5 (I4): idle replica changes that alter the description reflect -- a
  moved `topRow`, a changed `totalRows`, and a screen-mode transition.

Tests live in
`ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileScrollTests.swift`.

## Non-goals

- Guarding the shell's `.reflect` writes in `TerminalScrollChromeView` --
  redundant once the driver dedupes (the audit's cheaper fallback, rejected).
- Deduping `interactionChanged`'s return-to-idle reflection (see I3).
- The sibling audit items sharing this root cause (MOBKIT-2, MOBAPP-6, ...);
  each is its own change.

## Rejected ideas

- RI1: dedupe on `MobileScrollMode` equality instead of the emitted
  description -- broader than the chrome state it deduplicates, so
  description-invisible facts (`isFollowing`, `windowRows`, delta
  `rowHeight`) would still emit redundant reflections.

## Implementation discretion

- How the driver stores the last emitted description and orders the
  comparison against `reflection()`'s state re-seeding, provided I1-I4 hold.

## Verification

TDD: add the PO1/PO2/PO5 tests first, watch PO1 fail against current code,
then change the driver. Run the targeted suite plus lint:

- `swift test --package-path ios/DanTermMobileKit --filter MobileScrollTests`
- `just lint`
- `just test` before commit.

## Commit progress

- [x] 1. perf(mobile): dedupe unchanged scroll chrome descriptions
- [x] 2. docs(audit): mark MOBKIT-4 complete

## Implementation notes

- The driver takes `reflection()` on every idle replica change and only then
  decides whether to emit it. The call re-seeds `lastNamedTopRow` and delta's
  baseline against the newest mode, and two different modes can describe the
  same chrome (a doubled `rowHeight` with a halved `topRow` lands on the same
  offset and content height), so comparing before re-seeding would leave that
  state stale.
- `interactionChanged`'s return-to-idle reflection records the description it
  emits, so the identical replica change that follows a gesture is suppressed
  rather than reflected twice.
