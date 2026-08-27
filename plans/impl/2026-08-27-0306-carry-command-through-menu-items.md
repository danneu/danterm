# Carry the command itself through the menu item

## Context

A DanTerm menu command's identity is already a closed vocabulary: 43 cases of
`ConfigurableCommand`, one catalog row each. The AppKit menu layer does not use
it. It moves the identity around as a string -- `NSMenu.addCommand` takes the
unvalidated config wire type `KeybindingActionID`, the item stores
`descriptor.id.rawValue` in `representedObject`, and both consumers sniff it
back with `as? String`. On top of that, the tab-colour submenu adds a second,
parallel channel:

```swift
for (i, color) in TabColor.allCases.enumerated() {
    let item = colorSubmenu.addCommand(KeybindingActionID(rawValue: "tab.color-\(color.rawValue)"))[0]
    item.tag = i
```

```swift
let colors = TabColor.allCases
guard sender.tag >= 0, sender.tag < colors.count else { return }
if let msg = menubarTabActionMsg(.setColor(colors[sender.tag]), ...)
```

A colour menu item carries its identity twice: once as the `ConfigurableCommand`
case in `representedObject`, and once as an integer index into
`TabColor.allCases`. `performConfiguredCommand` switches on the first, routes
every colour case to one handler, and that handler re-derives the colour from
the second. Reorder `TabColor`'s cases and Cmd-1 sets the wrong colour --
silently, with no trap and no diagnostic. Nothing in the tree tests it.
`setTabColorFromMenu` is the only place a command menu item's `.tag` is read.

The same vocabulary is already handled correctly one file over: the sidebar's
colour menu carries the typed `TabColor` inside the `Msg` it stores in
`representedObject`, which is what `db4b5a06 refactor(sidebar): carry the
message itself in context-menu items` landed. The menubar is the half that never
got the treatment.

Two further consequences of the untyped channel: `commandDescriptor(id:)`
`preconditionFailure`s on an id it cannot find, and
`ConfigurableCommand.init(stringLiteral:)` does the same, so a typo in a
hand-written command name is a launch-time trap rather than a compile error --
across 37 `addCommand("...")` call sites and 43 catalog rows.

Outcome: the command travels as itself. A menu item naming a command outside the
vocabulary stops being constructible, colour identity has one channel derived
from one declaration, and both `preconditionFailure`s are deleted rather than
reworded.

## Decision

Type the whole menu path on `ConfigurableCommand`, declare the
`TabColor` -> `ConfigurableCommand` link exactly once, and make the descriptor
lookup total by construction.

- **Invert the catalog.** `commandDescriptor(_ command: ConfigurableCommand)`
  becomes an exhaustive `switch` and `commandCatalog` is derived from
  `ConfigurableCommand.allCases`. "Every command has exactly one descriptor"
  becomes a compile-time fact rather than a tested one -- no dictionary, no
  force-unwrap, no duplicate-row trap in a global initializer, and the existing
  `preconditionFailure` deletes with nothing put in its place. `allCases` order
  is declaration order and the enum's order already mirrors the catalog's, so
  the grouped inventory survives the change of shape.
- **Type the channel.** `NSMenu.addCommand(_ command: ConfigurableCommand)`;
  `item.representedObject = command`; `MenuCommandPolicy`'s configurable
  overload and the binding surface's item filter take the enum. The 37
  `addCommand("...")` sites and the 43 catalog rows name cases, after which
  `ConfigurableCommand: ExpressibleByStringLiteral` and its trap are deleted.
  The wire spellings then live only in the enum's own case declarations, plus
  the one test that pins them deliberately. Every other source site that names a
  command with a bare string goes through the enum too -- the held-MRU pair in
  `CommandCatalog.swift`, the partner lookup in `KeybindingPreferences.swift`,
  the binding reads in `AppRuntime.swift`, and the recorder button's default
  action in `PreferencesPanel.swift`. A search of the production sources is what
  establishes the set, not a list written here: the first inventory of these
  missed a file.
- **One colour declaration.** `TabColor` gains an exhaustive `switch` naming its
  command, and the reverse is derived from it rather than written again. The
  submenu maps through it, dispatch recovers the colour through the same
  declaration, and `item.tag` and the `allCases` index are deleted.
- **The mapping and the lookup live in `DanTermCore`**, beside the catalog they
  must agree with. Both are pure. This is what puts their tests inside
  `just test`, which excludes the AppKit suite. `MenuCommandPolicy`'s overload
  and the swatch image stay in `app/`.
- `KeybindingActionID` stays as it is. `DanTermProtocol` cannot depend on
  `DanTermCore`, so the config wire type remains a string wrapper and
  `CommandDescriptor.id` remains the one enum-to-wire bridge. The catalog still
  supplies the known-id set, so an unknown key in `~/.danterm` is preserved and
  never becomes a command.

### Rejected: giving colour items a `Msg` payload

The sidebar's shape does not transfer, and the reason is a hard constraint
rather than a preference. `ConfigurableMenuBindingSurface` finds every
configurable item by walking the menu tree and matching `representedObject`,
then rewrites its key equivalent from the effective binding map. The colour
commands are catalog commands with user-rebindable chords. An item carrying a
`Msg` instead of a command drops out of that walk, so a user's configured
`cmd+1` would silently stop applying. The sidebar can carry a `Msg` precisely
because its context-menu items are not configurable; the menubar's are.

### Rejected: an associated value on the command

`case setColor(TabColor)` is the structure in which no inverse exists to get
wrong. But `ConfigurableCommand`'s raw `String` *is* the config wire spelling,
and an associated value forfeits raw-value synthesis -- `rawValue`,
`init?(rawValue:)` and `allCases` all become hand-written, reintroducing 43
hand-authored strings. It buys safety in one arm and pays for it across all of
them.

### Rejected: deriving the catalog's colour rows

Generating the seven colour rows from `TabColor.allCases` would need a second
per-colour table for the irregular chords (cmd+1/2/3 on three of the seven, none
on the rest), trading one declaration for two.

### Rejected: converting the preferences and reducer layers

`Msg.selectBrowserAction`, `Msg.openEditor`, the keybinding projections, the
editor draft and `PreferencesPanel` all speak `KeybindingActionID`. Retyping
them is a real improvement and a much wider change across the reducer,
projections and their tests. It is not what makes the wrong colour
unrepresentable.

## Invariants

- **I1.** A menu item naming a command outside the declared vocabulary is not
  constructible, and every item using the shared dispatcher carries a typed
  command.
- **I2.** Every `ConfigurableCommand` has exactly one descriptor, and the lookup
  cannot fail. Discharged by construction, not by test.
- **I3.** Colour identity travels one channel. A tab-colour menu item dispatches
  the colour its own command names; no second channel exists that could disagree.
- **I4.** Adding a `TabColor` case does not build until it names a command.
- **I5.** In production sources under `app/` and `lib/DanTermCore/Sources/`, no
  `ConfigurableCommand` or `KeybindingActionID` value is initialized from a
  string literal outside the enum's own case declarations. Dotted strings that
  are not command identities -- diagnostic paths, notification names -- are
  untouched, and tests keep their `KeybindingActionID` literals: they exercise
  the wire type on purpose, which is the layer this change deliberately leaves
  alone.
- **I6.** The config wire is unchanged: the same 43 action ids with the same
  spellings, and an unknown key in `~/.danterm` still preserved rather than
  rejected. No raw value moves; only case names and call sites do.
- **I7.** The menus the user sees are unchanged -- same items, titles, key
  equivalents, hidden alternates, and enablement -- and a user-configured chord
  still reaches every configurable item, colour items included.

## Proof obligations

- **PO1 (I3, I4).** Every `TabColor` dispatches its own colour, end to end
  through the real menu the delegate builds, driven by `TabColor.allCases` so a
  new colour fails until it is wired. Items are located by their catalog title,
  not by `representedObject`, so the test does not assert the channel it is
  meant to outlive. Because the two orders currently agree, that alone would
  pass before the fix and prove nothing -- so the test first makes a colour
  item's legacy `tag` disagree with the command it carries, then asserts the
  command decides. That fails on today's tree, passes once the second channel is
  gone, and stays meaningful afterwards as the pin against reintroducing one.
  Nothing covers any of this today.
- **PO2 (I1).** Walking the built menu, every item using the shared dispatcher
  selector carries a `ConfigurableCommand`.
- **PO3 (I1, I7).** A typed application-scoped item and a typed window-scoped
  item, passed through the delegate's own menu validation with no live window,
  get different answers. PO2 pins the writer; this pins the reader, which is
  where the silent-nil hazard in AR2 actually costs the user: a command whose
  identity fails to cast falls through to selector-based validation, and every
  configurable item shares one selector that is not window-independent, so
  application commands would go dark with no window. The existing scope test
  calls the policy directly and cannot see this.
- **PO4 (I7).** For each menu, the sequence of configurable items -- their
  titles and default key equivalents -- is what it is today. This is the only
  thing standing between the 37-site retype and a mechanical slip that names a
  valid but wrong case: the catalog, the typed-payload walk, the binding tests
  and the colour tests all stay green through such a slip while the user sees
  the wrong item. The expected sequence is written out in the test from today's
  menus, not read back from the catalog -- derived from the catalog it would
  accept the very slip it exists to catch.
- **PO5 (I3).** The colour submenu covers `TabColor.allCases` and offers Clear
  Color, and Clear Color dispatches the cleared colour.
- **PO6 (I4).** The colour mapping is injective, every mapped command is a tab
  command, and none of them is the clear-colour command. Lives in `DanTermCore`
  so it runs in `just test`.
- **PO7 (I5, I6).** The existing catalog and menu suites pass unedited apart
  from the mechanical retype of their own command literals, and a search of the
  production sources named in I5 finds no command identity built from a string
  literal outside the enum.
  The hand-written set of 43 wire names in `CommandCatalogTests` stays
  hand-written: after this change it is the only place the user-visible config
  spellings are stated independently of the enum, which is what makes it a spec
  test rather than a restatement.

## Non-goals

- Renaming any action id, config key, menu title, or key equivalent.
- Retyping `Msg`, the keybinding projections, the editor draft, or
  `PreferencesPanel` off `KeybindingActionID`. Their properties keep that type;
  only the hand-written command spellings that initialize them move behind the
  enum, which is a one-line change per site and not the wider retype.
- Removing `KeybindingActionID` or its `ExpressibleByStringLiteral`
  conformance; tests and the config layer rely on both.

## Accepted risks

- **AR1.** `representedObject` is `Any?` and four subsystems store four
  different payload types in it, one of them for object lifetime rather than
  identity. Storing a Swift enum there is sound and matches the sidebar
  precedent, but the change must read only its own type and leave the other
  three to fall through as they do today.
- **AR2.** A `String` and a `ConfigurableCommand` are not interchangeable
  through `Any`, so every surviving `as? String` reader compiles and silently
  returns nil -- a dead menu item, or in the binding surface, every configured
  chord quietly ceasing to apply. All of them must move in the one commit that
  changes the write. PO2 and PO3 are the pins -- writer and reader -- and a
  tree-wide search for the old cast returning nothing is the mechanical check.
- **AR3.** The AppKit suite is excluded from `just test` because it needs a
  WindowServer, and most of this change's coverage lives there. Run the UI suite
  before each commit, not just the gate. Moving the colour mapping and the
  lookup into `DanTermCore` is what pulls PO6 into the gate.
- **AR4.** I5 gets no lint of its own. Deleting the literal conformance makes
  the `ConfigurableCommand` half a compile error, which is the half that governs
  every menu call site; what stays a convention is a `KeybindingActionID` built
  from a literal, whose worst case is a binding read that quietly finds nothing.
  A gate script plus an allowlist for the enum's own declarations is more
  standing machinery than that residue is worth.
- **AR5.** A user who binds two chords to one colour gets a hidden alternate
  with no swatch, because the binding surface rebuilds twins without the image.
  Pre-existing and invisible (the twin is hidden), and this change makes the
  colour items' participation in that surface explicit rather than altering it.

## Implementation discretion

- How the descriptor rows are spelled once the catalog is inverted -- whether
  the row builder keeps its current parameters or sheds the action it no longer
  needs -- provided the switch is exhaustive and no raw value moves.
- The shape by which dispatch recovers the `TabColor`, provided it derives from
  the single declared mapping rather than restating the pairing.

## Commit progress

Ordering against the launch sequence: the menu build must stay after the runtime
exists, because its tail wires the binding surface into it. The extraction below
lifts menu construction into static builders beside the existing App-menu
builder and leaves the two process-global side effects behind, so it does not
reorder anything in the launch path. The in-flight `--init` bootstrap change
edits that same function; neither constrains the other's design, but they want a
stated order.

- [x] 1. Delete the colour channel. `TabColor` gains its exhaustive mapping and
      the derived inverse; the submenu maps through it; dispatch recovers the
      colour from the same declaration; `item.tag` and the `allCases` index are
      deleted. Extract the menu builders so PO1, PO4 and PO5 can drive real
      items. This rides on the existing string channel, so it does not depend on
      slice 2 and is independently shippable. PO1, PO4, PO5 and PO6 land here,
      PO1 written first and confirmed red for the right reason. The one slice
      that removes a reachable defect.
- [ ] 2. Type the channel and invert the catalog. `commandDescriptor` moves to
      `DanTermCore`, takes the enum, and becomes the exhaustive switch the
      catalog is derived from -- retyping the lookup without inverting it would
      leave one commit whose only options are a force-unwrap or a reworded
      precondition, which is what I2 forbids. `addCommand`,
      `representedObject`, `MenuCommandPolicy`'s overload and the binding
      surface's filter follow; the 37 call sites name cases. Every `as? String`
      reader moves here, in this commit, the UI suite's included (AR2). PO2 and
      PO3 land here -- PO3 is what catches the reader this slice is most likely
      to leave behind. No behavior change; PO4's and PO7's suites passing is the
      proof.
- [ ] 3. Finish the sweep. Every remaining bare-string command name goes through
      the enum, and `ConfigurableCommand: ExpressibleByStringLiteral` and its
      `preconditionFailure` are deleted (I5). PO7's search is what closes the
      slice, since the written inventory has already proved incomplete once. The
      diff must not change any string between quotes (I6). No test asserts a
      string literal into a `ConfigurableCommand`, so nothing test-side moves.
