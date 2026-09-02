# Dim non-focused panes

## Context

In a split tab, nothing about the pane body says which pane the keyboard is
aimed at. The only signal today is a 2pt green ring drawn in the focus-ring
gutter (`ScrollableTerminalView.setFocusRing`), which is easy to miss on a wide
window and disappears entirely in a single-pane tab.

The outcome: every pane except the focused one draws at a user-chosen opacity,
so the active pane is obvious from the body of the grid, not from a hairline at
its edge. The dim level is a setting, adjustable from a slider in Settings and
from the config file, and shipping at 1.0 so nothing changes until the user asks
for it.

## Direction

Dimming is pane chrome, not terminal state. A translucent `CALayer` scrim,
owned by `ScrollableTerminalView` and covering exactly `gutteredBounds()`, is
composited over the terminal area of a non-focused pane. Its color is the
session's own background (`TerminalSessionState.background`, already tracked and
already refreshed on theme change), so dimming means "pull foreground and
background together", which reads correctly in both light and dark themes.

The scrim rides the existing per-pane focus channel rather than a second one.
`desiredFocusBorders` -> `BorderState` -> `reconcileFocusBorders` ->
`PaneWrapperView.setFocusRing` -> `ScrollableTerminalView.setFocusRing` becomes
one pane-emphasis projection carrying the ring state and the scrim alpha
together. Both outputs derive from one tab-local focus fact, so which pane is
focused is answered once. They narrow that fact differently and keep their own
contracts: the ring stays selected-tab-only and suppressed for a lone leaf,
while the scrim applies in every tab and has no lone-leaf exemption to make.

The core computes the alpha the view applies; AppKit performs no arithmetic and
holds no default.

## Invariants

- A pane draws a scrim iff it is not the focused pane of its own tab. Derived
  from tab-local focus, not from visibility, so a tab reveals already correct
  rather than dimming and then correcting.
- A tab's only pane is never dimmed. (Follows from the rule above; unlike the
  focus ring, this needs no separate lone-leaf exemption.)
- The green ring keeps exactly its current meaning: the focused pane of the
  selected tab, and never a lone leaf. Adding the scrim changes no pane's ring.
- The scrim alpha is the complement of the setting -- `1 - the resolved
  unfocused-pane opacity` -- so a mid-range setting dims by the complement and
  not by the setting itself. Alpha 0 means the scrim composites nothing: the
  layer stays mounted and its opacity goes to 0, so a focus change or the
  default setting is a property write, not a layer-tree add or remove. Core
  Animation culls a zero-opacity layer, so the default costs no blend.
- The scrim covers the terminal area only. The pane toolbar and the focus/bell
  ring keep full strength, so an alerting unfocused pane still reads loudly and
  its toolbar controls stay legible.
- The scrim receives no input events, and it composites above the terminal
  content and below the focus/bell ring.
- The scrim never changes layout. It occupies the existing terminal rect, so
  focus changes reflow nothing and resize no grid.
- A hand-edited config value outside the range, non-finite, or absent resolves
  to a value inside the range; nothing downstream re-checks.

## Setting

- Config key `ui.unfocusedPaneOpacity`, a number.
- Range 0.1 through 1.0. Default 1.0 (feature off).
- Absent key means the default; the range is applied on the read path as well as
  on what Settings commits, following `fontSize`'s bounded/resolved pair in
  `DanTermConfig`.
- Settings gets a slider in the General section, plus a live percentage readout.
- Documented as a row in the README config table.

### Live preview

Dragging the slider re-dims the panes continuously. The config file is written
when the gesture ends: a live mouse drag commits once, on release, and any
change that is not part of a live drag -- an arrow key, Home/End, an
accessibility action -- is itself a complete gesture and commits at once, so the
file reflects the slider without waiting for the panel to close. Closing
Settings keeps its current behavior: it saves any remaining draft, then
discards it. This needs one named rule in the core: a projection may read
the open preferences draft in place of the committed config when every
intermediate value of the control is valid. That holds for a slider and does not
hold for the half-typed font-size field, so the rule is stated and used at the
one projection that qualifies, not applied to config reads generally.

## Critical files

- `lib/DanTermProtocol/.../DanTermConfig.swift`,
  `lib/DanTermProtocol/.../DanTermConfigDocument.swift`
- `lib/DanTermCore/.../Projections.swift`, `.../Msg.swift`, `.../Update.swift`
- `app/Reconcile.swift`, `app/PaneWrapperView.swift`,
  `app/ScrollableTerminalView.swift`, `app/PreferencesPanel.swift`
- `README.md`

`.prefSave` needs no new arm: the slider's value is committed in the draft
config already, with no raw-text form to resolve.

## Non-goals

- Dimming the pane toolbar, the sidebar, or any window chrome.
- A per-pane or per-theme override of the level.
- Reading or reacting to `NSWindow` key state. DanTerm runs one main window and
  the projection stays a pure function of the model; macOS already dims an
  inactive window on its own.
- CLI get/set for config values. None exists today and this setting does not
  introduce the first one.

## Rejected ideas

- **Dimming in the renderer** (folding the level into the glyph/background
  colors as they are shaded). No extra pixels are composited, but it makes the
  engine's color path depend on pane focus, duplicates the theme background, and
  forces a full pane repaint on every focus change. The scrim keeps the whole
  feature as one layer and one number.
- **`layer.opacity` on the pane view.** Composites the pane against whatever is
  behind the window and forces an offscreen group-opacity pass. Wrong appearance
  and higher cost than the scrim.
- **A `CIFilter` / `compositingFilter` brightness pass.** Requires
  `layerUsesCoreImageFilters` and adds a real offscreen render pass per frame on
  every unfocused pane.
- **A universal "draft config wins while Settings is open".** Live-previews
  every setting uniformly, but a half-typed font size would resize panes
  mid-keystroke.

## Accepted risks

- One extra full-terminal-area blend on every rendered frame of an unfocused
  pane. Core Animation composites the scrim over each frame; the app mutates
  nothing per frame, the layer has no content to update, and a focus change is
  two property writes.
- The dim reads as low contrast on a theme whose background is already close to
  its foreground. The slider is the remedy, and 1.0 restores today's behavior
  exactly.

## Verification

Behavioral proofs, one per claim above:

1. **Config contract.** Default resolves to 1.0 with no key present; values
   below, above, non-finite, and absent all resolve inside the range; a value
   round-trips through the document parser without disturbing unknown sibling
   keys; a save writes the key and a save of an equivalent number writes nothing.
   (`DanTermProtocolTests` -- follow `DanTermConfigDocumentTests`' font-size
   cases.)
2. **Who gets dimmed, and by how much.** The pane-emphasis projection gives the
   tab's focused pane no scrim and every sibling the complement of the setting,
   proven at a mid-range value where the setting and its complement differ; a
   single-pane tab gets none; a non-selected tab's focused pane already carries
   none before that tab is revealed.
   (`DanTermCoreTests/ProjectionsTests.swift`, beside the existing
   `desiredFocusBorders` cases.)
3. **The ring is unchanged.** The existing ring scenarios still hold once the
   projection carries both outputs: focused pane of a split selected tab rings,
   a lone leaf does not, a bell rings independently of focus, and no pane of a
   non-selected tab rings. (The current `desiredFocusBorders` cases, carried
   over to the renamed projection rather than rewritten.)
4. **Level reaches panes.** A `.configLoaded` carrying a new level changes the
   projection's value for a live pane, proving reconcile re-pushes it -- the
   shape `ConfigCopyOnSelectTests.swift` already uses for a pane-affecting
   setting.
5. **Live preview and commit.** With the panel open, a `.prefSet` alone moves
   the projected scrim alpha; a `.prefSave` emits `.saveDanTermConfig` only when
   the committed value actually changed.
6. **Panel round-trip.** The projection drives the slider position and the
   readout text; a drag sends the edit and saves on release, and a slider change
   made outside a drag saves immediately.
   (`tests-ui/PreferencesPanelTests.swift`; its `makeProjection` fixture must
   gain the new field or the whole UI suite stops compiling.)
7. **Geometry and layering.** The scrim covers exactly the terminal rect, moves
   with it on resize and stays ordered above the scroll view's layer across a
   relayout, is invisible at opacity 1.0 and on the focused pane while staying
   in the layer tree, does not cover
   the ring, and takes the session background across a theme change.
   (`tests-ui/ScrollableTerminalViewTests.swift`, which already owns the gutter
   and ring cases and has a fake session that can emit a new background.)

Gate: `swift test --package-path lib/DanTermCore`, same for
`lib/DanTermProtocol`, plus `just lint` in the loop; `just test` before the
commit; `just test-ui` for the two UI suites above.

End to end: `just launch-slot`, split a tab, and confirm the non-focused pane
dims and that moving the slider in Settings re-dims it live while the config
file gains the key only on release.

## Commit progress

- [x] 1. feat(pane): dim non-focused panes at `ui.unfocusedPaneOpacity`
- [ ] 2. feat(settings): unfocused-pane opacity slider with live preview

## Implementation notes

- `desiredPaneEmphasis` walks groups and tabs itself instead of calling
  `forEachPane(in: model)`. The scrim is derived from each pane's own tab, which
  the model-wide traversal does not hand back. Nothing is materialized, so the
  no-per-sweep-array intent of that helper still holds.
- The scrim layer sets `actions` to `NSNull` for `position`, `bounds`,
  `opacity`, and `backgroundColor`. A hand-made layer is not a view's backing
  layer, so without this Core Animation would run its implicit quarter-second
  animation and the scrim would trail the grid through a divider drag. This
  could not be pinned by a test: the UI harness renders nothing, so Core
  Animation creates no implicit animation to observe there, and
  `action(forKey:)` returns nil either way. The reason lives in a code comment
  instead.
- `DanTermConfigDocument.setUnfocusedPaneOpacity` rejects only a non-finite
  number and does not clamp what it writes, matching `setFontSize`. The range is
  applied on the read path, in `resolvedUnfocusedPaneOpacity`.
