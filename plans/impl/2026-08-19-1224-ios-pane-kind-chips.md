# Pane-kind chips in the iOS pane list

## Context

The iOS client's pane list (`ios/DanTermMobileApp/Sources/DanTermMobileApp/PaneSheetViewController.swift`)
shows a title and a `group / tab` subtitle per row and nothing else. On macOS the
same pane carries a brand-colored chip -- the Claude mark in its own orange, the
Codex mark, a terminal glyph -- so a glance at the sidebar says what each pane is
running. On the phone every row looks the same.

Two things block the port, and neither is an iOS problem:

- **The chip kind is not on the wire.** `PaneRosterItem`
  (`lib/DanTermProtocol/Sources/DanTermProtocol/PaneRoster.swift`) carries ids,
  titles, and selection, and says nothing about agents. The classification
  already exists as `ChipKind` in the pure core, but `ChipKind` is internal to
  `DanTermCore`, which `DanTermProtocol` cannot see.
- **The artwork is parked in the AppKit target.** `app/ChipArtwork.swift`
  (generated) and `app/ChipRenderer.swift` import only CoreGraphics and are
  already portable, but nothing outside the macOS app target can link them.

The outcome: every row in the iOS pane list shows the same chip the macOS
sidebar row shows for that pane, drawn from the same artwork, and updates live
when an agent attaches or detaches.

## Decision

Ship the chip kind as a roster fact, and lift the artwork into a package both
apps link.

- `ChipKind` moves from `DanTermCore` to `DanTermProtocol` and becomes public
  wire vocabulary with a stable string spelling. `ChipKind.init(agent:)` stays
  in the core, where `AgentLifecycle` lives.
- `PaneRosterItem` gains the chip, set by `paneRoster(in:)` from the pane's agent
  lifecycle -- the same expression the sidebar and toolbar projections already
  use.
- A new `lib/ChipArtwork` package owns the generated artwork data, the renderer,
  the `ChipKind` -> artwork mapping, and a platform-neutral way to get a drawn
  chip that either client can wrap in its own image type. macOS and iOS both
  consume it as an ordinary package dependency; the AppKit `ChipView` and the
  pane-strip drawing stay in `app/`.
- The iOS row draws the chip in the agent's own brand colors, matching the
  macOS sidebar row rather than the macOS pane strip.

Critical files: `lib/DanTermProtocol/Sources/DanTermProtocol/PaneRoster.swift`,
`lib/DanTermCore/Sources/DanTermCore/{ChipKind,PaneRosterProjection}.swift`,
`app/{ChipArtwork,ChipRenderer,ChipView}.swift`, `icon/gen-chips.sh`,
`icon/render-check.sh`, `test-ui.sh`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/PaneSheetViewController.swift`.

## Invariants

- **I1 -- The server classifies, the client renders.** The roster states which
  chip a pane shows. No client maps an agent kind to a chip, so the known-agent
  collapse exists in exactly one place.
- **I2 -- A chip change is a roster change.** A pane whose chip differs makes the
  roster projection differ, so subscribers are pushed a new roster when an agent
  attaches or detaches. Agent *activity* does not change the chip and must not,
  on its own, move the projection.
- **I3 -- One artwork, one renderer.** macOS and iOS draw a chip from the same
  generated data through the same drawing code. No second copy of the geometry
  or the palettes exists in any form, including exported images.
- **I4 -- The artwork data and the renderer name no UI framework and no chip
  vocabulary.** They stay compilable as loose files against CoreGraphics alone,
  which is what lets `icon/render-check.sh` grade them without a build. The
  `ChipKind` -> artwork mapping, and anything else that needs it, therefore sit
  in separate files from those two.
- **I5 -- The iOS list uses brand colors.** A row's chip wears the agent's own
  colors, as the macOS sidebar row does. The shared monochrome pane-strip
  treatment is not used here.

## Proof obligations

- **PO1 (I1)** -- A roster item reports the terminal chip for an unattached
  pane, each known agent's own chip when that agent is attached, and the generic
  agent chip for an agent kind DanTerm ships no mark for.
- **PO2 (I2)** -- Attaching an agent moves the roster projection and reaches a
  subscribed client as a pushed roster. An activity change alone does not.
  Note: `nonRosterChangesLeaveTheProjectionAlone` in
  `lib/DanTermCore/Tests/DanTermCoreTests/PaneRosterProjectionTests.swift`
  currently asserts the opposite for agent attach; that case moves to the
  "changes move the projection" test rather than being deleted.
- **PO3 (I1)** -- A roster round-trips through JSON with the chip intact, and an
  item whose encoding omits the chip decodes to nil.
- **PO4 (I3)** -- Every chip kind yields a distinct, non-empty image at a given
  size and appearance, and a kind whose two appearances differ yields different
  images for each. This is the one proof both clients rest on, so it lives in
  the artwork package's own tests: the gate runs them and the portability gate
  cross-compiles them for iOS. Equivalent coverage exists today in
  `tests-ui/ChipViewTests.swift`, which needs no AppKit and is excluded from
  `just test`; it moves rather than being duplicated.
- **PO5 (I4)** -- The artwork data and the renderer compile against CoreGraphics
  alone, with nothing else from their package. This runs in `just test`, so the
  isolation I4 asserts is checked on every commit rather than only when someone
  runs `icon/render-check.sh` by hand -- an import added to either file
  otherwise compiles cleanly and passes every gate.
- **PO6 (I3)** -- The renderer still paints what `icon/chips/preview.html` shows,
  proven by `icon/render-check.sh` after the files move.
- **PO7 (I3)** -- The generator still reproduces the checked-in artwork byte for
  byte from `icon/chips/`, at its new output path.
- **PO8 (I5)** -- An iOS pane-list row shows the chip its roster item names. The
  image half is PO4, which the phone and the Mac share; that a cell hosts it is
  the manual simulator check in `## Verification`, because `ios/DanTermMobileApp`
  has no test estate and this change does not add one.

## Non-goals

- The state dot (unread alert, agent waiting, agent mid-turn) on iOS. It needs a
  second roster field and is its own change.
- Any change to `ls`. It already reports each pane's raw agent kind, session id,
  and activity, which is strictly more informative than the four-value chip.
- Any change to how the macOS sidebar and pane toolbar get their chips. They
  keep their own projections and do not start reading the roster.

## Accepted risks

- **AR1 -- More roster pushes.** Agent attach and detach now move the
  projection, so subscribers see pushes they did not before. Both are
  user-paced events rather than a stream -- and they reconcile inline rather
  than coalescing -- so the added push rate is bounded by how often a person
  starts or stops an agent, which is the point of the change.
- **AR2 -- Two build scripts outside the gate need real edits.**
  `icon/render-check.sh` and `test-ui.sh` name the chip sources by path, and
  neither runs in `just test` (one needs ImageMagick, the other a WindowServer).
  `render-check.sh` needs its paths repointed. `test-ui.sh` needs more than
  that: once the AppKit chip files import the new module, the harness must build
  and link `ChipArtwork` the way it already builds `DanTermProtocol`, and must
  drop its `ChipKind.swift` entry because `ChipKind` now arrives through the
  protocol module it already links. Both get run once during implementation.
- **AR3 -- A phone from this branch cannot talk to an older Mac build.** The
  chip is a required roster field, for consistency with every other one, and a
  roster item that fails to decode fails the whole roster. An older
  `DanTerm.app` therefore fails the phone's connection outright with a
  device-setup error rather than degrading to unchipped rows. The project's
  "one user upgrades by replacing the app" rule does not reach this, because
  the phone and the Mac are separate installs; the disposition is to know the
  symptom and update both, not to make the field optional.

## Rejected ideas

- **RI1 -- Ship chip images or SF Symbols to iOS.** Forks the artwork: the chips
  carry per-kind brand colors, a per-kind optical fill fraction, and a dilation
  stroke that holds thin features at 12pt. Any exported or substituted mark goes
  stale the next time the manifest is tuned, which is exactly what I3 forbids.
- **RI2 -- Put the artwork data in `DanTermProtocol`.** That package is
  dependency-free wire vocabulary with no graphics types anywhere. A color and
  geometry table is not wire vocabulary and would drag CoreGraphics into every
  consumer of the protocol.
- **RI3 -- Send the raw agent kind and let each client classify.** Contradicts
  the roster's stated contract that the server resolves what a client renders
  verbatim, and puts the known-agent collapse in two codebases that must agree.

## Implementation discretion

- **D1** -- How the iOS row turns a chip into something a table cell can show.

## Verification

- `just test` -- covers the core projection, the protocol round-trip, the
  end-to-end push, the new package's own drawing tests, the artwork-isolation
  check (PO5), the iOS portability gate, and the manifest-ownership and
  gate-coverage lints that a new package must satisfy.
- `./icon/gen-chips.sh` followed by a clean `git diff` on the generated file --
  discharges PO7.
- `./icon/render-check.sh` -- discharges PO6. Needs ImageMagick.
- `just test-ui` -- proves the AppKit chip host still works after the artwork
  moves out from under it.
- End to end: `just launch-slot`, attach an agent in one pane and leave another
  as a plain shell, then `scripts/ios-app.sh simulator` and open the pane sheet.
  The rows show the branded chips -- the hosting half of PO8. Detaching the
  agent from the Mac changes that row's icon while the sheet is open, which is
  I2 visible.

## Commit progress
- [x] 1. Ship the pane chip as a roster fact
- [ ] 2. Lift the chip artwork into a shared ChipArtwork package
- [ ] 3. Draw the chip in the iOS pane list

## Implementation notes

- `ChipKind.init(agent:)` went into `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift`
  rather than keeping a `ChipKind.swift` in the core. `PaneLifecycleReducer.swift`,
  where `AgentLifecycle` is declared, states in its header that product
  projections do not belong in it, and `AgentSession.swift` already holds
  `KnownAgent.chipKind` -- the other half of the same collapse. This is also what
  lets `test-ui.sh` drop its `ChipKind.swift` entry as AR2 requires, since the
  harness already compiles `AgentSession.swift`.
- The runtime half of PO2 proves the attach and detach pushes deterministically.
  Its "activity pushes nothing" half uses one explicit 500 ms wait that is meant
  to expire: the activity report defers its sweep by 75 ms, so a roster that
  sweep pushed would be readable by the time the wait ends. The negative itself
  is proved deterministically in the core projection test.
