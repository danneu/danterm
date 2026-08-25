# State text presentation for the text the phone shows

## Context

`plans/impl/2026-08-25-0555-own-text-vs-color-font-decision.md` decided that
DanTerm, not the host font machinery, says whether a terminal-authored scalar
draws as text or as color emoji. That decision was implemented for grid cells
only, in the `CTLine` fallback of `TerminalRenderExecution`.

Everything DanTerm draws outside the grid still delegates. A pane titled with
U+2733 (`✳`) draws as a flat asterisk in the Mac sidebar and in the grid on both
hosts, and as a green color tile in the phone's status pill and pane sheet --
the same divergence, one layer up. U+2733 is `Emoji_Presentation=No`, so Unicode
already calls it text; no iOS UI face maps it, so CoreText falls through to
Apple Color Emoji and answers the presentation question by font availability.

The phone is where it shows because the phone has no preparation step at all.
Every Mac surface renders `DisplayLine`, the projection-layer type whose only
constructor runs a normalizer. The pane roster is the one projection that
bypasses it: `paneRoster(in:)` puts `SessionModel.title` on the wire verbatim,
and the iOS shell assigns those strings straight to UIKit labels. Presentation
is what was noticed; C0/C1 controls and bidi overrides reach the same labels by
the same route.

Desired outcome: a terminal-authored string cannot reach a phone label without
DanTerm having decided how it reads.

## Decision

Split the preparation along the line the architecture already draws.

**D1. Titles leave the Mac already normalized.** The roster projection resolves
its group, tab, and pane titles through the existing `DisplayLine` normalizer
before they are encoded. The roster field is display-only by its own contract
("a client shows this verbatim"), so preparing it on the server is what that
contract already implies. No normalizer is duplicated, and the model, IPC JSON,
and checkpoints keep the verbatim strings they need.

**D2. The phone states presentation at one boundary.** `DanTermMobileKit` gains
a display-text value whose only constructor states the presentation Unicode
defines, reusing `terminalPresentationSelectorToAppend` from `TerminalCore` --
the same gate and the same pinned table the grid fallback uses. The session
projection stops handing the shell `PaneRosterItem` and hands it display-ready
rows instead, so a view controller has no raw title to assign.

The gate is per grapheme cluster of the display string and transforms only
single-scalar clusters; it already declines every other shape. Segmentation
follows the host's own rules, because the label lays the string out by those
rules and there is no terminal cell here to disagree with.

The presentation half must live on the phone: the pinned table is in
`TerminalCore`, which `DanTermCore` may not name (`terminal-backend-boundary-lint.sh`),
and which `DanTermMobileKit` already depends on. Its test target runs in the
gate on macOS, where the iOS app target has no tests at all.

Critical files: `lib/DanTermCore/Sources/DanTermCore/PaneRosterProjection.swift`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/PaneSheetViewController.swift`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/ConnectionStatusPillView.swift`.

## Invariants

- **I1.** Every terminal-authored string the phone renders outside the grid
  states its presentation: a bare emoji variation base whose Unicode default
  presentation is text carries U+FE0E when it reaches UIKit, by the same rule
  and the same pinned table the grid fallback applies.
- **I2.** Nothing else is transformed. A multi-scalar cluster, a cluster that
  already carries a variation selector, a default-emoji scalar, and ordinary
  text all reach UIKit as they arrived.
- **I3.** The shell cannot render an unprepared terminal string: the projection
  exposes the roster's titles only as prepared display text.
- **I4.** Titles on the roster wire hold no C0 or C1 control, no bidi override
  or isolate, and no leading, trailing, repeated, or non-space whitespace.
- **I5.** The model, the IPC entity inspection replies (`ls`, `pane info`), and
  checkpoint persistence keep titles verbatim. The roster wire surface is the
  one scripted consumer that sees a change, and it is display-only text: a
  subscriber reads normalized titles from the moment this lands (AR4).
- **I6.** Coverage is never reduced. U+FE0E expresses a preference CoreText may
  fall through, so a scalar only a color face can draw still draws.

## Proof obligations

- **PO1 (I1).** A pure test in the kit's suite: a title holding a default-text
  variation base reaches the projection's display value with U+FE0E appended,
  including one such base that is East Asian Wide, so a width proxy cannot creep
  back in.
- **PO2 (I2).** The excluded shapes reach the display value unchanged: a cluster
  ending in an explicit selector, a ZWJ sequence, a default-emoji scalar, and
  plain text.
- **PO3 (I3).** Every title the projection offers the shell is a prepared value,
  for a transformed and an untransformed input alike.
- **PO4 (I4).** Each text source the roster resolves independently -- the group
  name, the pane title, and the tab title through each of its fallbacks -- is
  normalized on the wire when the model holds a newline, a C1 control, and a
  bidi override in it. One source per case, because an implementation can
  prepare one and miss another. `DisplayLine`'s own suite already pins the rule;
  this pins that every roster field runs it.
- **PO5 (I5).** For the same model, the IPC encoding and the checkpoint snapshot
  still carry the verbatim title.
- **PO6.** The existing suites stay green, `just test` included.

## Non-goals

- Improving emoji rendering. A real emoji still resolves to the color face.
- Stating presentation for the Mac's own chrome (see AR1).
- An iOS test target. The gap stands as the earlier plan accepted it.

## Accepted risks

- **AR1.** The Mac's chrome still delegates the text-versus-color decision to
  the host. macOS resolves the observed scalars to a text face, so nothing is
  visibly wrong there today. Closing it would need the pinned table reachable
  from `DanTermCore`, which the engine boundary forbids, or the table split out
  of `TerminalCore` and a hot per-scalar lookup pushed across a module boundary.
  A Mac label seen drawing a color glyph the grid draws as text is grounds to
  re-open.
- **AR2.** Preparation for phone display is split across two layers: text
  hygiene on the Mac, presentation on the phone. It follows the layering -- each
  half sits where its authority lives -- but a reader must know both halves to
  see the whole contract.
- **AR3.** No test runs on iOS. The kit's tests execute on macOS, and the phone
  half is confirmed by eye, as it was for the grid.
- **AR4.** Roster titles on the wire are no longer verbatim. A future client
  wanting the raw string must ask through a machine-readable surface instead.
- **AR5.** Presentation is stated against the host's grapheme segmentation
  rather than DanTerm's pinned tables, so a host whose segmentation disagrees
  with the pin could offer a single-scalar cluster the terminal would have
  joined. The host is also the party that lays the label out, which is why its
  answer is the right one here.

## Rejected ideas

- **RI1. One shared display-text type for both hosts.** Move `DisplayLine` into
  an iOS-pinned package and make the presentation table reachable from it, so
  one type prepares text everywhere. The better shape, and rejected on price:
  it spends the engine boundary and risks the parser's hot table lookups to fix
  a Mac defect that is not visible. AR1 records the residual.
- **RI2. Append the selector at the three iOS label assignments.** Fixes what
  was seen and leaves the shell able to render raw titles, so the next
  unprepared string is a new bug rather than an impossible one.
- **RI3. State presentation where the title enters the model.** It would put
  U+FE0E into IPC JSON and checkpoint files, breaking I5.

## Verification

- `just test` green.
- Build and run the phone app (`scripts/ios-app.sh`), attach to a pane whose
  title holds `✳`, and confirm the status pill and the pane sheet draw a flat
  asterisk matching the Mac sidebar.

## Implementation discretion

- The display value's name and whether rows expose composed or separate fields.

## Commit progress

- [x] 1. fix(roster): normalize the titles the roster puts on the wire
- [x] 2. fix(mobile): state text presentation for the titles the phone renders

## Implementation notes

- The display value is `MobileDisplayText` (one `init(preparing:)`), and the
  projection's rows are `MobilePaneRow` with separate `groupName`, `tabTitle`,
  and `paneTitle` fields plus the identity and chip the shell already used. The
  model keeps the raw `[PaneRosterItem]` internally for pane lookups and
  converts at `projection(at:)`, so no shell code can see a roster string.
