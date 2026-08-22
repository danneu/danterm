# Replace expanding keybinding rows with a native transactional editor

## Problem

The Key Bindings pane mixes browsing and editing in one expanding list. Opening
one command moves every command below it and exposes a row of equally prominent
CRUD buttons. The result is harder to scan and does not resemble a native macOS
settings table.

The pane should remain a stable command browser. Editing one command should be
a focused, reversible task that does not disturb the list or alter live behavior
until the user accepts it.

## Decision

Use a native table for the command browser and an attached modal sheet for one
command's editor.

- Category headings are group rows. Each command is one selectable row with its
  title, status, and every assigned shortcut. Multiple shortcuts are stacked
  vertically inside that command's shortcut cell, so they stay aligned without
  becoming independent command rows.
- A single click selects a command. Double-click, Return, or a subtle trailing
  pencil opens its editor. The browser has no Show/Hide or inline CRUD controls.
  Remove the old disclosure state and transitions with the expanding editor.
- The sheet contains an enable control, an ordered shortcut list, native add and
  remove controls, Reset to Defaults, Cancel, and Done. The first shortcut is the
  menu shortcut. Each later row has a Make Primary action; shortcut rows are not
  draggable.
- Adding a shortcut or activating an existing shortcut starts recording in that
  row. The recorder owns key equivalents while active. Escape first cancels an
  active recording; otherwise it cancels the sheet.
- The sheet edits a model-owned candidate for the whole override map while the
  browser continues to project committed config. Every sheet action that stages
  a chord -- capture, re-enable, Reset to Defaults, or held-MRU partner update --
  removes it from any current candidate owner before inserting it here. The row
  shows a persistent note naming each prior owner. Invalid and same-command
  duplicate captures leave the candidate unchanged and keep recording active
  with an inline explanation.
- Held-MRU commands show exactly one shortcut with no add or remove controls.
  Changing either command's modifiers stages the same modifiers on its partner's
  first shortcut, when present, so the pair stays valid in one transaction. If
  an invalid committed config contains extra held-MRU shortcuts, the sheet stages
  only the displayed first shortcut and explains that accepting will remove the
  extras.
- Disabling stages an empty binding but keeps the prior shortcut list visible and
  inactive. Re-enabling restores that list; a command already disabled when the
  sheet opened restores catalog defaults instead. Adding or replacing a shortcut
  while disabled re-enables it. Reset to Defaults enables the command and returns
  it to inherited catalog bindings.
- Done validates and saves the complete candidate once while preserving unknown
  action IDs. A validation failure keeps the sheet open with its diagnostic.
  Cancel and sheet dismissal discard the candidate.
- An invalid committed config remains browsable: catalog rows show their saved
  override or default shortcuts with the config diagnostic instead of hiding all
  shortcuts. Because an invalid binding map is not applied as a unit, every
  displayed shortcut is styled as inactive and has an accessible "not applied"
  value. The config diagnostic says that menu shortcuts keep the last valid map,
  or catalog defaults on a cold launch.
- Reset All Key Bindings moves into a trailing action menu beside search and
  requires confirmation before it commits.
- User-facing shortcut text uses native macOS modifier and named-key glyphs with
  equivalent spoken accessibility values. The compact config spelling remains
  unchanged.

The settings model owns sheet existence, the candidate, recording target, and
diagnostics. Pure projection supplies both the browser and sheet, including any
cross-command move note derived from the committed map and candidate; AppKit only
renders them and reports user actions. The sheet keeps only a weak runtime
reference and its retained handle is cleared when it closes.

## Invariants

- I1. Browser rows never expand. Opening or editing a command does not move or
  replace the surrounding command list.
- I2. One command owns one browser row, including all of its vertically ordered
  shortcuts and one edit entry point.
- I3. The live config, menu equivalents, and input behavior do not change until
  Done accepts a valid candidate.
- I4. Cancel, ordinary sheet dismissal, Settings close, and external config
  reload leave no partial edit and no stale sheet.
- I5. One Done action installs the complete valid candidate and requests one
  config save. Unknown keybinding action IDs survive the transaction.
- I6. A shortcut never becomes owned by two configurable commands. Staging an
  owned shortcut visibly updates both sides and Done commits them atomically.
- I7. The active recorder receives representable shortcuts before menu dispatch;
  recording cancellation does not cancel the containing sheet.
- I8. Shortcut order remains meaningful: the first binding is the menu shortcut
  and later bindings are alternates.
- I9. The external keybinding JSON schema, catalog validation, reserved Cocoa
  shortcuts, gesture constraints, and runtime dispatch precedence do not change.
- I10. The browser and sheet support mouse, keyboard-only, Full Keyboard Access,
  and meaningful accessibility labels.

## Proof obligations

- PO1. Prove category order, search filtering, stable selection, status, and
  vertically ordered shortcut presentation for default, customized, disabled,
  and multi-shortcut configurations; prove invalid committed shortcuts are
  visible but marked inactive and "not applied," with the last-valid-map
  diagnostic.
- PO2. Prove pencil, double-click, and Return open the selected command's sheet,
  with no inline editor controls left in the browser.
- PO3. Prove add, replace, remove, Make Primary, enable, disable, and reset remain
  isolated until Done while the browser stays committed; prove disabled-list
  restoration, edit-to-enable, Cancel, and every teardown path.
- PO4. Prove valid Done saves exactly once, preserves unknown overrides, and
  updates menu and modal-continuation behavior only after acceptance; prove
  invalid Done keeps the sheet open with its diagnostic and emits no save.
- PO5. Prove invalid, duplicate, reserved, and gesture-invalid captures preserve
  a valid candidate; prove capture, re-enable, and reset conflicts stage both
  owners with persistent move notes. Prove changing held-MRU modifiers succeeds
  while keeping the pair consistent, and accepting an invalid over-count keeps
  the displayed first shortcut while visibly removing the extras.
- PO6. Prove recorder focus is established only after its sheet row is attached
  and visible, key equivalents reach it first, and the two Escape behaviors are
  distinct.
- PO7. Prove Reset All requires confirmation and preserves unknown action IDs.
- PO8. Prove the sheet releases with its parent and no callback can message a
  released Settings panel or runtime.
- PO9. Prove glyph and spoken shortcut text for modifier combinations, named
  keys, function keys, and characters; prove config serialization still uses
  compact spelling and the browser and sheet expose accessible keyboard paths.
- PO10. Run the focused core suite and lint during implementation, then the AppKit
  UI suite and full local gate before each commit.

## Non-goals and rejected ideas

- Non-goal: change the keybinding config format, catalog membership, validation
  policy, or runtime dispatch architecture.
- Non-goal: add profiles, global hotkeys, physical-key bindings, sequences, or
  contextual bindings.
- Rejected idea: keep disclosure rows and restyle their buttons. Expansion still
  destabilizes the browser and mixes two tasks.
- Rejected idea: use a popover. Multiple bindings, ordering, disable/reset, and
  atomic cross-command moves form a real transaction that needs stable modal space.
- Rejected idea: make each shortcut an independent browser row. Selection and
  editing belong to the command, and duplicate blank command cells obscure that
  ownership.

## Implementation discretion

- Exact table column widths, sheet dimensions, and native control subclasses are
  implementation choices as long as the behavior and accessibility contract hold.
- Internal helper and file boundaries are discretionary; pure state and
  projection remain outside AppKit.

## Commit progress

- [x] 1. Add transactional keybinding editor state and projections
- [ ] 2. Replace the expanding list with a native table and sheet, and wire config persistence

## Implementation notes

- `DanTermConfigDocument.projectKeybindings` and `applyKeybindings` already own
  the lossless schema boundary, but `DanTermConfigStore` does not call them.
  Commit 2 must connect those existing helpers so Done and reload affect the
  persisted keybinding map without dropping unknown action IDs.
