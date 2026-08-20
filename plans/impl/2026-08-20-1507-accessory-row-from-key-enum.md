# Build the phone accessory key row from the key enum

Source: IOS-4 in `docs/scratch/2026-08-18-construction-audit.md` (theme T3:
a vocabulary enumerated once per consumer).

## 1. Problem

The phone's bottom bar (`ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift`)
carries which key a button sends as a bare integer written in three places
that nothing checks against each other: a literal presentation table tagged
`0...9`, a private `MobileAccessoryKey.init?(tag:)` switch mapping the same
literals back with a silent `default: return nil`, and `entry.tag == 1` to
find the Ctrl button for the latch highlight. A mismatch compiles cleanly and
either sends a different key to the Mac or sends nothing. A case added to
`MobileAccessoryKey` (`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileInputMapper.swift`)
is silently unreachable from the bar.

Evidence: verified on HEAD (`d825f0db`); the file's recent commits
(`46d63586`, `82b6a79d`, `72e587b2`) did not touch the coupling. No sibling
tag tables exist anywhere in `ios/`. The app package has no test target, so
nothing in the gate can observe the mismatch today; only the kit mapper is
tested (`InputMappingTests.accessoryRowMapping`).

Desired outcome: the two bugs -- "a button sends a key other than the one
the row intended" and "a key the bar cannot send" -- stop being expressible.

## 2. Decision

Each key button holds its `MobileAccessoryKey` value directly (a `UIAction`
closure that captures the key and reports it through `onAccessoryKey`), and
the row is derived from `MobileAccessoryKey.allCases` with an exhaustive
switch supplying title and image. `MobileAccessoryKey` becomes `CaseIterable`
in the kit; declaration order is row order. The integer tag, `init?(tag:)`,
and the `@objc` tap recovery are deleted.

Presentation (title, SF Symbol) stays in the app view, not on the kit enum:
the kit is input vocabulary, and the bar's own header forbids coupling
presentation to input mapping.

Behavioral scope: none. The row shows the same ten keys in the same order;
each sends what it sends today; the Ctrl button's latch highlight is still
rendered from the session projection via `setControlLatched`. The bar still
holds no session fact.

## 3. Invariants

- I1. Every `MobileAccessoryKey` case has exactly one button in the row, and
  tapping it reports that same case through `onAccessoryKey`. Adding a case
  to the enum fails to compile until the row says how to draw it.
- I2. Row order is the enum's declaration order.
- I3. `setControlLatched` keeps highlighting the button whose key is
  `.control`.
- I4. The bar does not retain itself through a button action (the closure
  captures the view weakly).

## 4. Proof obligations

- PO1 (I1, I2): compile-time -- the presentation switch over
  `MobileAccessoryKey` has no `default`, and the row is built from
  `allCases`. No runtime test can live in the app package; this is the
  by-construction guarantee.
- PO2 (kit contract the bar relies on): a new kit test iterates
  `MobileAccessoryKey.allCases` and asserts the mapper produces traffic for
  every key except `.control`, and none for `.control`. This is the
  behavioral statement `CaseIterable` makes possible; the existing
  `accessoryRowMapping` table test keeps pinning what each key sends.
- PO3 (I3, no regression): the existing latch tests in
  `MobileSessionModelTests` keep passing. I3 is not by-construction -- the
  rewrite could bind the highlight to the wrong button -- so a simulator run
  (`scripts/ios-app.sh simulator`) must show the Ctrl button highlighting on
  tap and a Ctrl chord reaching the pane. That run is the acceptance
  evidence for I3, not a courtesy check.
- Gate: `swift test --package-path ios/DanTermMobileKit`, and
  `scripts/ios-portability-gate.sh` cross-compiles both packages.

## 5. Non-goals / Rejected ideas

- Non-goal: extending the smoke probe (`MobileSmokeInputScript`) to tap the
  bar. Which key each button sends (I1, I2) is the part the new structure
  makes inexpressible, so automating taps would buy nothing there; and
  reaching the bar at all means re-routing `driveSmokeInput` delivery from
  `MobileSessionController` to the root view controller, which is more shell
  mechanism than this change removes.
- AR1: I3 and I4 have no automated coverage, because the app package is an
  executable target with no test target and neither the button/highlight
  binding nor the closure's capture list is compile-time enforced. PO3's
  simulator run backstops I3; I4 is verified by reading the diff for the
  weak capture. Accepted: the worst outcome is a stale highlight or one
  leaked bar view, not wrong bytes to the pane.
- RI1: a side table (`[ObjectIdentifier: MobileAccessoryKey]`) keyed by
  button -- removes the numeric coupling but keeps two lists and no
  exhaustiveness. Strictly worse than the button owning its key.
- RI2: putting `title`/`systemImage` on the kit enum -- couples presentation
  to input mapping.

## 6. Implementation discretion

- How the `UIAction` is attached (`addAction(_:for:)` vs. the
  `primaryAction:` initializer) -- note that a titled `primaryAction` would
  backfill the title on image-only buttons, so the action must carry no
  title or be added separately.

## Commit progress

- [x] One commit: `CaseIterable` on `MobileAccessoryKey` (doc comment notes
  row order), rewrite of `TerminalBottomBarView`'s key row, and the new kit
  test from PO2. Green on the kit tests and the iOS portability gate.

## Implementation notes

- Presentation lives in a private `TerminalAccessoryAppearance` struct in the
  bar file. Its `init(_ key:)` is the exhaustive switch PO1 asks for, and it
  delegates to a private memberwise init so no other call site can build an
  appearance that no key names.
- The action is attached with `addAction(_:for:)` and captures the key by
  value and the bar weakly, per the discretion note: a `primaryAction` would
  backfill a title onto the arrow buttons.
- PO3's simulator run is NOT done. This worktree has no way to tap a
  simulator button (`simctl` has no tap command, and `idb` is not installed),
  and the run also needs a live Mac instance to connect to. The automated half
  of PO3 is green: `MobileSessionModelTests`' latch tests and the whole kit
  suite pass, and the iOS portability gate cross-compiles both packages. I3
  still needs the human acceptance run described in PO3.
