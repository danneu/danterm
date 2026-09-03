# Settings window: sidebar navigation

## Problem

The Settings window has one flat form plus a Key Bindings table, switched by a
two-item `NSToolbar`. The form has grown to eleven rows spanning four unrelated
concerns (terminal behavior, fonts and theme, the config file, tailnet status),
separated only by extra top padding on the rows that start a group. Padding is
not navigation: the user cannot see the shape of the settings, and every new
setting makes the single column longer.

Desired outcome: four named sections in a native macOS sidebar, each holding
settings that belong together, with room to grow.

## Decision

Replace the toolbar with a source-list sidebar hosted by an
`NSSplitViewController`, and split the form's rows across four sections.

**Section contents** (this is the user-facing contract):

| Section | Rows |
|---|---|
| General | Copy on select, Clear Alerts, Config file (Open / Reload) |
| Appearance | Theme, Font Family, Font Size, Unfocused Panes, Remote Theme |
| Keyboard | Option as Alt, keybinding search + browser, Reset All Key Bindings |
| Remote | Tailnet configured / endpoint / listener, config-file note |

General is the section shown when the window opens. Each theme and font row
keeps the collapsible warning row directly beneath it.

**Window contract changes.** The window becomes resizable. It no longer
shrink-wraps to the selected section, and it no longer changes size when the
section changes; instead it has a minimum content size that admits every
section. Extra width goes to the detail column with the form hugging its
top-leading corner -- never to the form's label column, which is the failure
mode the existing `preferencesControlColumnWidth` comment describes. Extra
height goes to the keybinding table in Keyboard and to empty space elsewhere.

The sidebar is a real `NSSplitViewItem` sidebar (`sidebarWithViewController:`)
rather than a hand-built list over an `NSVisualEffectView`, so it gets the
platform's sidebar material, collapse behavior, and macOS 26 safe-area
insetting without reimplementation. The app has no existing
`NSSplitViewController` usage; `references/iterm2/sources/SSHFilePanel.swift`
and `FileBrowserWindowController.swift` are the local precedents for the item
configuration, including the asymmetric `automaticallyAdjustsSafeAreaInsets`
(false on the sidebar, true on the detail).

**Section ownership.** Each of the four sections is its own `NSViewController`
owning its controls and its layout, installed into one stable detail host by an
exhaustive `PreferencesSection` factory. The panel stays the projection
coordinator: it receives `apply(_:)` and routes each field to the controller
that owns it. This makes "only the selected section is in the hierarchy"
structural rather than a hidden-view discipline, and makes the compiler reject a
new section case that has no controller.

**Model.** `PreferencesSection` (`lib/DanTermCore/Sources/DanTermCore/Model.swift`)
gains `.appearance` and `.remote`. It becomes the single source of the sidebar's
order and per-row presentation data -- display title and SF Symbol name -- so a
new section cannot be added without the compiler demanding both. `.prefSelectSection`
stays the only writer of section state, and the sidebar drives it the same way
the toolbar does today: the click sends the Msg, and the resulting projection
sets the selected row. No selection state lives in the view.

Files: `app/PreferencesPanel.swift` plus the new section controllers alongside
it, `lib/DanTermCore/Sources/DanTermCore/Model.swift`, and the tests named under
Proof obligations. The UI suite reaches controls through the owning section
(`panel.appearanceSection.fontFamilyCombo` rather than
`panel.fontFamilyCombo`); this is a mechanical rename that changes no
assertion.

## Invariants

- **I1** Every setting the panel exposes today is reachable in exactly one
  section, per the table above. Nothing is dropped, duplicated, or orphaned.
- **I2** The sidebar's selected row is a function of the projection's section.
  A click changes the view only by round-tripping through `.prefSelectSection`.
- **I3** Only the selected section's controller is installed in the detail
  host. No other section's controls exist in the view hierarchy, so none can
  receive focus or contribute to layout.
- **I4** Widening the window widens the form's control column region, never the
  label column: the form's labels stay adjacent to their controls at every
  window width the user can reach.
- **I5** Switching sections while a text field is mid-edit still ends editing on
  the send frame rather than re-entering reconcile. This is existing behavior
  from the 2026-08-21 Key Bindings crash, and the path that carries it is being
  rewritten by this change.
- **I6** Adding a `PreferencesSection` case fails to compile until it has a
  title, a symbol, and a controller.
- **I7** The window is resizable and its frame does not change when the section
  changes. Every section is fully visible at the minimum content size, Appearance
  with all three of its warning rows expanded; width added above the minimum goes
  to the detail column and height added above it goes to the keybinding table.

## Proof obligations

- **PO1** (I1) Each section shows its own rows and none of another section's,
  and in Appearance each collapsible warning row sits immediately below the
  setting it belongs to -- asserted through the section controllers' controls
  and the existing descendant walkers, scoped to the detail area rather than
  `contentView` now that the sidebar contributes labels of its own.
- **PO2** (I2) Selecting a sidebar row sends `.prefSelectSection` for that
  section, and, separately, applying a projection selects the matching row and
  sends nothing.
- **PO3** (I2, model side) `.prefSelectSection` round-trips through
  `update` into the projection for every case, extending the existing
  single-case test in `lib/DanTermCore/Tests/DanTermCoreTests/KeybindingPreferencesTests.swift`.
- **PO4** (I4) At a window width well above the minimum, the widest form label
  still sits within a few points of the form's leading edge -- the surviving
  form of the current "labels hug the grid's leading edge" test.
- **PO5** (I5) A field edit begun in one section, with a projection selecting a
  different section applied during the send frame, still defers its save until
  the frame exits. The existing test synthesizes the end-editing notification
  directly and never switches sections, so it does not exercise the path this
  change rewrites; it is replaced by one that drives the edit and the switch.
- **PO6** (I7) The geometry contract holds against a real window: the frame
  survives a pass through every section, each section is fully visible at the
  minimum content size with Appearance's warnings expanded, and added width and
  height reach the detail column and the keybinding table.

The existing tests asserting the window is non-resizable and exactly as wide as
its fitting size encode the retired shrink-wrap contract and are replaced by
PO4 and PO6. The existing toolbar-selection
assertion is replaced by PO2. The existing "only rows that start a section carry
top padding" test describes the padding-as-grouping mechanism this change
removes, and goes with it.

## Non-goals

- No new settings. Every row that exists today moves; none is added or removed.
- No change to how settings are read, written, or persisted -- `PreferenceEdit`,
  `prefSave`, and the config file are untouched.
- No sidebar search, no collapsible sidebar groups, no per-section deep links.

## Accepted risks

- **AR1** The window stops sizing itself to its content, so a section shorter
  than the minimum shows trailing empty space. This is what every native
  sidebar settings window does, and the alternative (resizing the window on
  every sidebar click) is worse.
- **AR2** Splitting one grid across four controllers risks a row silently
  losing the control-column width constraint that `addRow` applies. Every
  section must build its rows through the same shared helper.

## Rejected ideas

- **RI1** A fifth "Terminal" section alongside General. In a terminal emulator
  the two names denote the same bucket; General is the one that also has a
  natural home for the config-file row.
- **RI2** Keeping `NSWindowToolbarStylePreference` with a tab strip. It is the
  idiom being replaced, and it does not grow past a handful of sections.

## Implementation discretion

- How the panel routes projection fields to the section controllers.
- Sidebar thickness, minimum content size, and the exact SF Symbols.

## Commit progress

- [x] 1. feat(core): give settings sections appearance and remote
- [x] 2. refactor(settings): give each section its own controller
- [ ] 3. feat(settings): navigate sections from a sidebar

## Implementation notes

- Section-controller properties use a `Section` suffix because
  `PreferencesPanel` inherits `NSWindow.appearance`.
