# Sidebar context menus: one typed payload, no id laundering

Audit item CHROME-3 in `docs/scratch/2026-08-18-construction-audit.md`,
pivoted: the sidebar menu payload becomes the already-constructed `Msg`,
instead of an intent enum that mirrors `Msg`.

## Problem

`app/SidebarView.swift` builds two context menus (group row, tab row). Four
items store `groupId.rawValue` / `tabId.rawValue` -- a bare `UUID` -- in
`NSMenuItem.representedObject`, and their `@objc` handlers cast it back and
re-wrap it as `GroupId` or `TabId`. Both ids are UUID-backed, so wiring a
group item to a tab handler (or the reverse) compiles, passes AppKit
validation, and acts on the wrong entity or on nothing, with no diagnostic.
This defeats the phantom-typed ids AGENTS.md requires. The other six items
carry two ad-hoc `NSObject` boxes (`TabIdsBox`, `SetTabColorsInfo`), so the
file holds two payload patterns and nine handlers whose only job is to unwrap
a payload and send one message.

Nothing is mis-wired today (each item's action and payload are set on adjacent
lines). The work removes the possibility, not a live defect.

Load-bearing premises, verified in the tree:

- `representedObject` is `Any?`; a Swift value stored there comes back through
  `as?`. The erasure exists only because the code appends `.rawValue`.
- `SidebarView` is long-lived, so its menus need no `representedObject`
  lifetime anchor (`docs/design/2026-06-09-appkit-lifetime-safety.md`, rule 7).
- Two handlers (`Rename Group`, `Rename Tab`) hop through
  `DispatchQueue.main.async` before sending `.beginSidebarRename`, because the
  model's begin drives a reconcile pass that installs a field editor while
  AppKit is still tearing the menu down. The other seven send synchronously.
- `tests-ui/SidebarContextMenuTests.swift` pins `Delete Group` enablement with
  `autoenablesItems = false`; the shim `AppRuntime` records `sentMessages`, and
  `pumpMainQueue` in `tests-ui/SidebarTestSupport.swift` drains main-queue hops.

## Decision

**D1.** Every sidebar context-menu item points at one selector, and its
`representedObject` is a single payload holding two things: the fully
constructed `Msg` the item sends, and whether that send is immediate or
deferred by one main-queue hop. The `Msg` is built where the item is built,
from the typed `GroupId` / `TabId` (or `[TabId]` and `TabColor?`) already in
hand. The single handler reads the payload and sends the message at the
stated time. The nine per-action handlers, `TabIdsBox`, and `SetTabColorsInfo`
are deleted. Item construction names the outcome (the message it will send),
not a selector paired with a loose payload.

Why the message itself and not the audit's intent enum: an enum with cases
`newTab(GroupId)`, `renameTab(TabId)`, `setColors([TabId], TabColor?)`, ...
re-declares the sidebar's slice of `Msg` a second time and needs a switch to
translate it back -- one more vocabulary to keep in step. `Msg` already
carries the typed ids, so an id stays inside typed Swift from construction to
`send`, with no translation table and no cast on an id at all; the only cast
left is to the payload type, identical for every item. Action and entity
become one value, so they cannot be paired independently.

Every item's message is fully determined when the menu is built:
`contextMenu(forTabId:clickedRow:)` resolves `targetIds` up front and returns
`nil` when it is empty, and `Move to New Group` uses a constant group name.
So the per-handler `!ids.isEmpty` guards are dead and go with the handlers.

Scope: `app/SidebarView.swift` context menus only (group menu, tab menu, Color
submenu). The payload type lives in `SidebarView.swift`, so `test-ui.sh`'s
explicit source list does not change.

## Invariants

- **I1.** A sidebar menu item's payload cannot name an entity of a different
  kind than the one its action targets; constructing such an item is not
  expressible.
- **I2.** Firing each item sends exactly the message it sends today, with the
  same ids: group `New Tab` -> `.createTab(inGroupId:)`, `Delete Group` ->
  `.requestDeleteGroup(id:)`, `Rename Group`/`Rename Tab` ->
  `.beginSidebarRename(target:)`, tab `Clear Custom Title` ->
  `.clearCustomTitles(tabIds:)`, Color swatch / `Clear Color` ->
  `.requestSetTabColors(tabIds:requested:)`, `Clear Alerts` ->
  `.clearAlertsForTabs(tabIds:)`, `Move to New Group` ->
  `.extractTabsToNewGroupInteractively(tabIds:groupName:)`, `Close` ->
  `.requestCloseTabs(ids:)`. Batch items target the multi-select resolution
  (`contextTargetTabIds`); `Rename Tab` targets only the clicked row.
- **I3.** The two rename items still send after the menu's tracking has ended
  (one main-queue hop), never synchronously from the action; the other items
  still send synchronously.
- **I4.** Menu titles, suffixes, separators, Color submenu structure,
  swatch images, checkmarks, and `Delete Group` enablement under
  `autoenablesItems = false` are unchanged.

## Proof obligations

- **PO1 (I1).** Compile-time: there is no handler that accepts a raw `UUID`
  or re-wraps an id, and no `as? UUID` in the menu path. Grep-level check in
  review; not a runtime test.
- **PO2 (I2, I3)** -- `tests-ui/SidebarContextMenuTests.swift`: build the
  group menu against a recording runtime, fire each item through its
  `target`/`action`, and assert `sentMessages` names the clicked group; for
  `Rename Group` assert nothing is sent synchronously and the message
  arrives after `pumpMainQueue` under the house hang guard. Build the tab
  menu with a two-tab selection and a clicked row, fire `Rename Tab`, `Clear
  Custom Title`, a swatch, `Clear Color`, `Clear Alerts`, `Move to New
  Group`, `Close`, and assert the dispatched messages carry the selection ids
  (rename: the clicked row only). `Rename Tab` gets the same deferred-delivery
  assertion as `Rename Group`: nothing is sent synchronously, and the clicked
  tab's `.beginSidebarRename(target: .tab)` arrives after `pumpMainQueue`.
  Write these tests before the change; they pass before and after, so they pin
  dispatch across the refactor.
- **PO3 (I4).** The existing enablement and `clickedRow` tests keep passing
  unchanged.

## Docs

`docs/design/2026-06-09-appkit-lifetime-safety.md`, "Consequences": the
sentence saying `SidebarView` menus "carry model ids or id boxes in
`representedObject`" is updated to describe the one payload, and its stale
`file:line` references to `SidebarView.swift` are dropped for identifiers.

## Non-goals / Accepted risks / Rejected ideas

- **NG1.** The drag/drop path (`outlineView(_:acceptDrop:...)`) decodes
  `TabId`/`GroupId`/`PaneId` from pasteboard UUID strings. That is a
  serialization boundary with a different fix (a typed pasteboard codec) and
  stays as is.
- **NG2.** `AppDelegate`'s menubar Color submenu encodes `TabColor` as
  `item.tag` into `TabColor.allCases`. Same loose-payload shape, different
  menu; out of scope.
- **NG3.** `PaneWrapperView.makePaneMenu` and `ThemeBrowserView`'s menu
  payload are already typed and stay as they are.
- **RI1.** Intent enum + exhaustive switch (the audit's ideal): rejected as
  above -- it mirrors `Msg` and reintroduces a translation step.
- **RI2.** Keep per-action selectors and store the typed id directly
  (`representedObject = groupId`, `as? GroupId`): one-line change that turns a
  mis-wire into a runtime no-op, but leaves nine handlers and two payload
  patterns; rejected because the `Msg` payload removes the cast and the
  handlers together.
- **RI3.** Payload holding a closure that sends the message: rejected because
  a closure can capture `SidebarView`, which adds a lifetime rule the plan
  would then have to state and check by hand, and its contents cannot be
  read. A `Msg` payload has neither problem.

## Implementation discretion

- Name and shape of the payload type and the single selector, and how the
  payload spells the immediate/deferred choice. PO2 still fires each item even
  though a test could read the message off it, because the selector wiring is
  part of what PO2 pins.

## Implementation notes

- The payload is a Swift struct (`SidebarMenuAction`), not an `NSObject`
  subclass. `representedObject` is `Any?`, so a struct stored there comes back
  through `as?` unchanged, and a struct cannot be captured by an AppKit object
  graph the way the old boxes could.
- The immediate/deferred choice is a nested `Timing` enum with cases
  `immediate` and `afterMenuTracking`, passed as a defaulted argument to the
  item builder, so an item that hops off menu tracking says so at the call site.
- The lifetime doc's field-editor bullet also cited a `SidebarView.swift` line
  range that this diff shifted. It now names the `NSTextFieldDelegate`
  conformance instead, so the pointer stays true.
