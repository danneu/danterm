# Make one command catalog own configurable keybindings

## Problem, outcome, and evidence

DanTerm's app shortcuts have two authorities. Ordinary shortcuts are literal
`NSMenuItem` key equivalents in `app/AppDelegate.swift#buildMenu`; jump and the
held MRU switcher also match hard-coded virtual key codes in
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#classifyJumpInput`
and `#classifySwitcherInput`. A Settings editor built beside these paths would
create a third authority, could display bindings that do not fire, and could
leave menu discovery out of sync with runtime behavior.

The existing config and Settings flow already has the right ownership shape:
DanTermProtocol projects an unknown-preserving JSON document that retains exact
number tokens. `PreferencesDraft` holds editable state in the pure model,
`prefSave` commits a valid config and emits one write command, and reconciliation
applies model projections to AppKit. Keybindings should extend that flow rather
than create a side channel.

The outcome is one typed command catalog and one effective binding map. The
config file stores overrides, the model validates and owns committed bindings,
AppKit menu dispatch and Settings consume the same projection, and the existing
event monitor consults it only while completing an active modal gesture. All
stable DanTerm menu and toolbar actions are customizable, including jump and
held MRU. Cocoa responder commands, native
window/app commands, and runtime-entity context actions remain outside the
feature. `TerminalCore` does not change.

## Decision

### Config contract

Schema version 1 gains an optional `keybindings` object. Keys are stable dotted
action ids. Values are ordered arrays of compact chord strings:

```json
{
  "schemaVersion": 1,
  "keybindings": {
    "tab.new": ["cmd+t"],
    "pane.focus-left": ["cmd+shift+h", "cmd+option+left"],
    "tab.jump": []
  }
}
```

- An absent action uses the catalog default. A non-empty array replaces every
  default for that action. An empty array disables it. Reset deletes the
  override. The first chord is primary and is the one the menu displays.
- Canonical modifier order is `cmd+ctrl+option+shift+key`. A chord requires at
  least one of Cmd, Control, or Option; Shift alone is invalid. The key token is
  the unshifted logical character in the active keyboard layout, with Shift
  represented only by its modifier token. Shifted-output spellings such as
  `cmd+H` or `cmd++` are invalid. Documented names cover an unshifted character
  that conflicts with the separator, whitespace/control keys, arrows,
  navigation keys, and function keys.
- Unknown action ids are ignored and semantically preserved across Settings
  writes, as is unrelated JSON. Stored number tokens remain exact; after a
  semantic edit, whitespace, string escapes, and object order may normalize
  when the document is encoded.
- Malformed JSON or an unsupported schema keeps the current whole-config
  failure. A malformed, conflicting, or reserved known binding rejects the
  keybinding section as one atomic unit while other valid settings still load.
  Launch uses catalog defaults; reload retains the last valid bindings.
  Before dispatching `configLoaded`, the config application boundary combines
  the newly loaded ordinary settings with either the valid replacement bindings
  or the prior committed bindings. The reducer therefore receives one complete,
  valid config and keeps its plain whole-value assignment. Diagnostics identify
  the exact JSON path and reason.

The shared protocol boundary exposes typed action ids, chords, modifiers,
overrides, and a load result that distinguishes a valid binding replacement
from a rejected binding section. `DanTermConfig` continues to represent only
valid committed state.

### Command and input ownership

One pure DanTermCore catalog owns each configurable action's stable id, title,
category, defaults, application/window scope, text-edit availability, and
ordinary, repeatable, jump, or held-MRU gesture semantics. It covers every
stable DanTerm menu or toolbar action, including currently unbound actions and
fixed tab-color choices. Native Cocoa responder actions and app/window shortcuts
are represented as non-configurable reservations so conflict validation cannot
drift from the native menu.

AppKit remains the dispatch mechanism for every configurable activation chord.
Each action has a menu item, visible or hidden, and reconciliation applies the
effective chords through `keyEquivalent` and `keyEquivalentModifierMask`. The
primary chord appears on the visible item; alternate chords and actions with no
visible menu row use hidden twin items with hidden-key-equivalent dispatch
enabled. Every item sends through the same exhaustive action dispatcher.

Canonical chords remain layout-free in the catalog and conflict model. The
AppKit reconciliation boundary translates an unshifted logical key plus Shift
into the shifted glyph `keyEquivalent` expects for the active input source. An
input-source change refreshes that projection without changing the committed
canonical map.

The responder chain therefore keeps first refusal: DanTerm-owned popovers and
controls that implement `performKeyEquivalent` retain their existing key claims
before a configurable menu equivalent. Field-editor Control commands occur
later, so `validateMenuItem` also enforces application/window scope and the
catalog's text-edit availability: while a DanTerm text control or field editor
is first responder, it declines every configurable action not available during
text editing; only application-scoped commands are available there. While the
focused terminal has marked text, configurable key equivalents are suppressed
so IME composition receives every key, but opening a menu with the mouse keeps
otherwise available actions enabled. User bindings may otherwise consume
Control or Option chords. A configurable chord cannot replace a fixed Cocoa or
macOS shortcut.

The existing runtime-owned event monitor remains the sole monitor and keeps its
current lifetime and teardown. It no longer activates configurable commands.
It consults the effective map only after jump or MRU is active. For jump it
handles targets, Escape, and mouse cancellation. For MRU it handles Older/Newer
steps, Escape, and modifier release without repeated menu activation. The
shortcut recorder uses its responder chain, not another monitor; while active,
its own `performKeyEquivalent` claims a chord before the main menu so an existing
binding can be recorded without invoking its action.

Jump activates through its configured menu equivalents, then keeps its existing
temporary unmodified target-key language. The active mode ignores the
activation chord's own still-held modifiers when it classifies a target, so a
Control- or Option-based activation can select before those modifiers are
released. Recent Older and Recent Newer each accept one configurable held chord
and must share the same non-key modifiers. A key equivalent starts the cycle
from an inactive keyboard event and remains one-shot from a menu click.
Once active, the monitor swallows and applies Older/Newer steps without repeated
menu activation; the cycle commits when any required modifier is released and
Escape cancels.

### Settings behavior

Settings becomes a reusable window with General and Key Bindings toolbar
sections. Key Bindings is a searchable, categorized list with expandable action
rows. Each row exposes its ordered primary and alternate chords and supports
record, add, remove, make primary, disable, and reset; the section also offers
Reset All and distinguishes default, customized, and disabled actions.

Recording and pending conflict state belong to `PreferencesDraft`. Escape
cancels recording. Delete removes the selected chord. An unmodified,
unrepresentable, reserved, or cross-action gesture-invalid chord reports inline
validation without changing the draft. Recording either MRU direction therefore
rejects a modifier set that differs from its partner before any config change.

If another configurable action owns a recorded chord, Settings names that
action and asks whether to move it. Confirmation removes the chord from the old
action and adds it to the new action in one model transition and one config
write. If the old action has no chord left, its override becomes `[]`; it must
not fall back to a default that restores the conflict. Native reservations are
errors, not confirmable conflicts.

Every accepted shortcut operation updates both the committed config and any
open `PreferencesDraft.config` in the same transition, reconciles immediately,
then performs one atomic config save. A later General edit therefore starts
from the binding state already visible and cannot restore the pre-edit map. A
write failure leaves the live committed setting active and uses the existing
notice flow. A rejected hand-edited binding section raises one notice on
load/reload and remains visible as a diagnostic banner in Key Bindings until a
valid reload or Settings repair.
Reload while Settings is open cancels transient recording/conflict state and
reseeds the draft from the resulting committed config.

The README documents the JSON grammar, action ids, override/disable/reset
semantics, logical-key behavior, and reserved-shortcut policy.

## Invariants

- I1. One catalog determines every configurable action's identity, defaults,
  scope, gesture semantics, Settings presentation, and menu discovery.
- I2. Menu dispatch, active modal-gesture handling, and Settings always consume
  the same effective binding map.
- I3. A config transition installs either one conflict-free binding map or no
  binding change; it never partially applies known entries.
- I4. Unknown config content survives Settings writes, and absent, overridden,
  disabled, and reset actions remain distinguishable.
- I5. Existing responder-chain claims, text input, and active IME composition
  keep priority over configurable keyboard dispatch; mouse-driven menu
  availability is unchanged, and unmatched terminal input reaches the terminal.
- I6. Fixed Cocoa/macOS shortcuts remain native and cannot become ambiguous with
  a DanTerm binding.
- I7. A confirmed conflict move cannot allow the displaced action's default to
  recreate the conflict.
- I8. Jump and held-MRU preserve their modal behavior under customized
  activation chords; MRU commits from the modifiers that its effective pair
  declares.
- I9. An accepted Settings edit changes live behavior immediately even if its
  later disk write fails; a rejected edit changes neither live nor stored
  bindings, and a later General save cannot revert it.

## Proof obligations

- PO1. With no overrides, prove every current DanTerm shortcut and gesture stays
  effective, including both font-increase chords, jump, and held-MRU release.
  Prove every stable DanTerm menu and toolbar action belongs to exactly one
  configurable catalog entry or explicit non-configurable reservation,
  including actions that currently have no shortcut.
- PO2. Prove config projection and writing implement I3 and I4, report precise
  known-entry failures, preserve unrelated and unknown JSON values and exact
  number tokens, and leave the effective map unchanged across a reload whose
  binding section is rejected.
  Prove recorder output and hand-authored input normalize to one unshifted-key
  spelling and reject shifted-output aliases.
  With Settings open, prove a binding edit followed by a General edit and save
  retains the edited binding live and on disk.
- PO3. Prove conflict detection covers configurable and native reservations,
  and that Settings add, reorder, remove, disable, reset, Reset All, and
  confirmed move operations maintain one unambiguous effective map.
- PO4. Prove AppKit dispatch and menu validation preserve existing TODO and
  shortcut-help key claims, sidebar rename and other native text editing, and
  marked-text composition without disabling mouse-driven menus, while unclaimed
  Control and Option input still reaches the terminal. Prove an
  application-scoped configurable command still dispatches while a DanTerm text
  control is first responder.
- PO5. Prove menu clicks, primary chords, and alternate chords invoke the same
  action behavior, and config save/reload reconciles effective dispatch and
  visible menu equivalents immediately. Prove an input-source change reprojects
  shifted menu equivalents without changing the committed canonical map.
- PO6. Prove custom jump and MRU bindings retain activation, stepping, cancel,
  and commit behavior; prove jump accepts a target while its activation
  modifiers remain held; prove repeated active MRU steps bypass menu dispatch;
  and reject either MRU edit inline when its modifiers differ from its partner.
- PO7. Prove Settings recording, conflict confirmation, diagnostics, and toolbar
  section transitions are model-driven and survive re-rendering without stale
  AppKit state. Prove search filters the action catalog and category/action
  expansion stays correct across projection re-renders. Prove recording a chord
  already assigned to an action captures it without invoking that action.
- PO8. Run focused protocol, core, app, and UI suites during TDD, then run the
  escalated `just test` gate once and `just test-ui` once from a captured log.

## Non-goals and rejected ideas

- **Non-goal:** Customize Cocoa responder commands, Hide/Minimize/window-cycle
  commands, OS-global shortcuts, modal continuation keys, or entity-specific
  context-menu actions.
- **Non-goal:** Add physical-key bindings, global hotkeys outside DanTerm, chord
  sequences, or per-pane/per-profile binding maps.
- **Accepted risk:** A DanTerm-owned popover may shadow a configurable chord
  while that popover has focus. Its responder claim is intentional; duplicating
  those contextual claims in the catalog would create a second authority that
  can drift.
- **Rejected idea:** Route ordinary configurable commands through a local event
  monitor above AppKit. It duplicates the responder chain and preempts existing
  DanTerm-owned popover and text-input key claims.
- **Rejected idea:** Require Cmd on every binding. Scope-aware menu validation
  and AppKit dispatch can support the requested Control and Option chords while
  preserving responder priority.
- **Rejected idea:** Allow duplicate chords and resolve them by menu order or
  runtime priority. That makes behavior depend on presentation structure rather
  than the committed config.

## Implementation discretion

- The concrete AppKit controls and layout mechanics inside each toolbar section
  are discretionary as long as the projected behavior and accessibility remain
  testable.
- Internal file boundaries and helper decomposition are discretionary; the
  protocol/core/app ownership split, single catalog/effective map, and AppKit
  dispatch boundary are not.

## Commit progress

- [x] 1. `feat(config): add typed keybinding overrides and unknown-preserving JSON projection`
- [x] 2. `feat(core): define the command catalog and effective binding validation`
- [x] 3. `refactor(menu): derive default shortcuts and command dispatch from the catalog`
- [x] 4. `refactor(input): derive jump and MRU modal continuation from effective bindings`
- [x] 5. `feat(keybindings): reconcile configured bindings into AppKit dispatch`
- [ ] 6. `feat(settings): add atomic keybinding edit state and conflict transactions`
- [ ] 7. `feat(settings): add the native keybinding editor and recorder`
