# Document why .movePane is selected-tab-scoped (and pin it with a test)

## Context

A consistency finding (verified 2026-06-11) flagged that the
`.movePane(source:target:intent:)` handler in
`lib/DanTermCore/Sources/DanTermCore/Update.swift:256-288` resolves
`selectedTab(in:)` / mutates via `updateSelectedTab`, even though it carries
pane ids -- unlike `.closePane`/`.splitPane`/`.toggleZoomPane`, which resolve
`tabForPane` after the pane-context-menu unification (8da7613).

Verification concluded the scoping is not convention debt but the *correct*
semantics, for reasons that are invisible at the callsite today:

- `.movePane` has exactly one producer: the interactive pane drag-drop
  gesture (`app/PaneWrapperView.swift:651`), which is bound to the selected
  tab by construction -- `startPaneDrag` snapshots target ids from
  `selectedTab` (`app/AppRuntime.swift:991-993`) and the frame provider only
  resolves mounted (selected-tab) wrappers. No IPC/CLI route exists.
- A stale dispatch whose panes live in a background tab is guarded out
  before the `tab.focusedPaneId = source` write: `swapLeaves`
  (`ModelOperations.swift:219-222`) and `moveLeaf`
  (`ModelOperations.swift:245-259`) both return nil unless *both* ids are
  leaves of the tree they're given, and `guard let newRoot` precedes the
  `updateSelectedTab` mutation.
- Migrating to `tabForPane` would make a stale dispatch silently rearrange
  a background tab the user isn't looking at -- strictly worse than the
  current no-op. Contrast `.closePane`, where background-tab dispatches are
  real (`.surfaceClosed` routes background shell exits), forcing
  pane-scoped resolution there.

Without a comment, the asymmetry will keep attracting the same review
finding. Outcome: a handler comment that dissolves future findings, plus one
behavioral test pinning the claim the comment makes.

## Changes

### 1. Handler comment -- `lib/DanTermCore/Sources/DanTermCore/Update.swift:256`

Add a `//` comment directly under `case .movePane(...)`, mirroring the
existing `.closePane` comment style (`Update.swift:206-209`). Proposed text
(wording may be tightened at impl time, content must keep all four beats:
deliberate contrast with pane-scoped siblings, sole producer, nil-on-miss
guard before the focus write, tripwire for new producers):

```swift
case .movePane(let source, let target, let intent):
    // Selected-tab scoping is deliberate (contrast .closePane/.splitPane,
    // which resolve tabForPane because background-tab dispatches are real
    // there). The only producer is the pane drag gesture (PaneWrapperView),
    // bound to the selected tab by construction; a stale dispatch whose
    // panes live elsewhere no-ops below -- swapLeaves/moveLeaf return nil
    // unless both ids are in this tree -- before the focusedPaneId write.
    // Resolving the panes' real tab instead would silently rearrange a tab
    // the user isn't looking at. Revisit if .movePane gains an IPC producer.
```

### 2. Pinning test -- `lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift`

Add one test in the existing `// MARK: - movePane Tests` section (~line 810)
pinning the comment's behavioral claim: a `.movePane` whose panes live in a
non-selected tab returns `[]` and leaves the model unchanged (no
`focusedPaneId` corruption, no zoom clobber, no checkpoint).

- Reuse `makeTwoTabFixture()` (same file, line 1738-1773; used by
  `closePaneBackgroundTabPreservesSuccessorAlert` at line 750-790): panes
  `fx.a1`/`fx.a2` live in tab A while tab B is selected.
- The fixture builds tab B as a ZOOMED split (`tabB.isZoomed = true`,
  line 1763), and `.movePane` returns at `guard !tab.isZoomed`
  (`Update.swift:259`) before either tree op runs -- dispatching against
  the raw fixture would pin the zoom guard, not the nil-on-miss guard.
  So the test must first unzoom the selected tab in place (e.g.
  `fx.model.groups[0].tabs[1].isZoomed = false`, matching how sibling
  tests hand-mutate the fixture, line 779), leaving tab B an unzoomed
  split, and only then snapshot `before`.
- Two legs to cover both tree-op branches: `intent: .swap` (swapLeaves
  path) and `intent: .splitRight` (moveLeaf path). Assert
  `commands.isEmpty` and `fx.model == before` for each, following the
  shape of `closePaneVanishedPaneIsNoOp` (line 792-808).
- Preamble per AGENTS.md test-preamble format: Intent / Why it exists
  (pins the invariant the new `.movePane` handler comment documents) /
  Scenario (spec-first -- no incident; a drop racing a tab switch is the
  hypothetical).
- This is a pinning test for existing behavior, not TDD-red-first: there is
  no code change to make it red against. Write it, verify it passes, and
  optionally confirm it *would* go red by inspection (the guard at
  `Update.swift:281` is what keeps it green).

## Out of scope

- No migration of `.movePane` to `tabForPane` resolution (verified as the
  wrong direction).
- No change to `.splitRatioChanged` (`Update.swift:1165`) -- the referenced
  "migration" has no queued plan; the only WIP plan mentioning it concerns
  reconcile diffing, not tab resolution.
- No changes to `ModelOperations.swift` -- `swapLeaves`/`moveLeaf` doc
  comments already state nil-on-miss.

## Verification

1. `swift test --package-path lib/DanTermCore --filter UpdatePaneTests` --
   new test passes alongside the existing movePane suite.
2. `just test` -- full local gate (protocol tests, core tests, support
   tests, core-purity lint, shell self-tests) stays green; the comment-only
   Update.swift change must not trip the purity lint.
