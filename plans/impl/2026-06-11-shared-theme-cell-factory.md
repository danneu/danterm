# Extract shared theme cell factory into ThemeSwatchViews

## Context

`ThemeBrowserView` (sidebar theme browser) and `RemoteThemePickerSheet`
(preferences sheet) each implement `tableView(_:viewFor:row:)` with a
hand-copied ~45-line body: make-or-reuse a `ThemeBrowserCellView`, build the
`ColorSwatchView` + label subtree with identical constraints, set checkmark
text for the current theme, call `updateTextColor()`, and assign swatch
colors from `ThemeCatalog.shared.colors[name]` (clear colors on miss). The
two bodies are byte-identical except the reuse identifier string
(`"ThemeCell"` vs `"ThemePickerCell"`).

This duplication was flagged as out-of-scope follow-up in
`plans/impl/2026-06-11-remote-theme-picker-ui-harness.md` ("## Follow Up"):
extraction was deliberately deferred until both surfaces had UI-harness
coverage. That precondition landed with cb82c5b (ThemeBrowserView) and
c1d2a7b (RemoteThemePickerSheet), so the extraction is now safe to do as a
behavior-preserving refactor pinned by existing tests.

The callers genuinely differ in what *selection* means (sidebar dispatches
`.setPaneTheme` through the runtime; the sheet fires `onSelect`), but not in
*row rendering*. Only row rendering moves; all selection/model/runtime
behavior stays in the callers.

## Current duplication (re-grep before editing; line numbers drift)

- `app/ThemeBrowserView.swift` -- `func tableView(_ tableView: NSTableView, viewFor`
  (currently ~:272-318), identifier `"ThemeCell"`.
- `app/RemoteThemePickerSheet.swift` -- same method (currently ~:156-202),
  identifier `"ThemePickerCell"`.
- `app/ThemeSwatchViews.swift` -- extraction target; already holds
  `ColorSwatchView` and `ThemeBrowserCellView`, and is already in the
  `test-ui.sh` compile list. No compile-list changes needed.

## Design

### Helper API (in `app/ThemeSwatchViews.swift`)

One internal static factory on `ThemeBrowserCellView` that does both
make-or-reuse construction and per-row configuration. Splitting into
`make` + `configure` buys nothing here: both callers always do both, in the
same order, with the same inputs.

```swift
extension ThemeBrowserCellView {
    /// Make-or-reuse + configure the shared theme row cell used by the sidebar
    /// theme browser and the remote theme picker sheet. Owns the full row
    /// rendering contract: swatch + label subtree, checkmark prefix for the
    /// current theme, selected/unselected text color, and ambient swatch-color
    /// lookup (`ThemeCatalog.shared.colors[name]`, clear colors on miss --
    /// colors are only SHOWN, so they stay ambient per the inject-vs-ambient
    /// rule). Callers keep their own reuse identifiers so the two tables never
    /// share recycled cells.
    static func themeCell(
        in tableView: NSTableView,
        reuseIdentifier: NSUserInterfaceItemIdentifier,
        themeName: String,
        isCurrentTheme: Bool
    ) -> ThemeBrowserCellView
}
```

Body = the existing duplicated block, moved verbatim with two mechanical
substitutions: `id` becomes the `reuseIdentifier` parameter, and the
`name == currentThemeName` check becomes the `isCurrentTheme` parameter
(the caller computes it -- the helper must not know about either caller's
`currentThemeName` storage).

Decisions locked in (from the handoff's judgment calls, all confirmed
against the code):

- **Identifiers stay distinct.** `"ThemeCell"` and `"ThemePickerCell"` are
  passed in by each caller. No reason to unify: distinct identifiers keep
  each table's reuse pool to itself, and unifying would change observable
  `cell.identifier` values for zero benefit.
- **Swatch colors stay ambient.** The helper reads
  `ThemeCatalog.shared.colors[name]` exactly as both callers do today.
  Colors are only SHOWN (never saved/sent/asserted on value), so per the
  inject-vs-ambient rule they stay ambient. In the harness the catalog is
  empty and swatches render clear -- unchanged.
- **`internal` visibility, no new module.** `test-ui.sh` compiles app and
  test files as one module; `app/ThemeSwatchViews.swift` is already in its
  compile list and in the app target. No shim, no package changes.
- **File header.** Extend the one-line header of `ThemeSwatchViews.swift` to
  mention it also owns the shared row factory (per the AGENTS.md file-header
  rule, the header should say what belongs in the file).

### Call sites after extraction

Both `viewFor` methods collapse to the same 3-line shape; each keeps its own
identifier and its own `filteredNames`/`currentThemeName`:

```swift
func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let name = filteredNames[row]
    return ThemeBrowserCellView.themeCell(
        in: tableView,
        reuseIdentifier: NSUserInterfaceItemIdentifier("ThemeCell"),   // sheet: "ThemePickerCell"
        themeName: name,
        isCurrentTheme: name == currentThemeName
    )
}
```

Nothing else in either file changes. `numberOfRows`, selection handling,
filtering, commit/cancel, and runtime dispatch are untouched.

## Test strategy

This is a behavior-preserving refactor, so "test-first" here means **pin
first, then move**: land any missing pins against the *current* code (they
must pass before the refactor), then refactor and rerun.

### What existing UI-harness tests already prove

Both suites drive the real delegate path -- `cellText` goes through
`tableView.view(atColumn:row:makeIfNecessary: true)`, which calls the
production `viewFor` including the `makeView` reuse branch. Pinned today:

- Row text per filter state, including case-insensitive narrowing and
  restore-on-clear (`tests-ui/ThemeBrowserViewTests.swift`,
  `tests-ui/RemoteThemePickerSheetTests.swift` -- the `cellText(row:in:)`
  helpers and filter tests).
- Checkmark rendering: current theme shows `"\u{2713} <name>"`, others show
  the bare name; checkmark moves/clears on apply
  (ThemeBrowserViewTests "apply moves selection and checkmark...",
  RemoteThemePickerSheetTests "current theme row should show checkmark").
- Cell type: `cellText` force-casts to `ThemeBrowserCellView`, so the
  helper returning a different view class fails both suites.

### Coverage gap -> two new pin tests (written BEFORE the refactor)

No existing test asserts the swatch subtree exists: `cellText` reads only
`textField`, so an extraction that silently dropped the `ColorSwatchView`
wiring (or the `cell.swatchView` back-reference) would stay green. Pin it
with one test per suite, asserting wiring only (no constraint or geometry
assertions -- those are structure-sensitive -- and no swatch-color
assertions: color values come from the ambient `ThemeCatalog.shared`
lookup, and asserting them would make them ASSERTED under the
inject-vs-ambient rule, forcing injection for no benefit and coupling the
test to the test bundle's catalog contents):

- `tests-ui/ThemeBrowserViewTests.swift` and
  `tests-ui/RemoteThemePickerSheetTests.swift` each gain:

```swift
uiTest("theme cell wires a swatch view") {
    // Intent: the row cell built by viewFor carries a ColorSwatchView
    //   installed in the cell with the swatchView back-reference set.
    // Why it exists: cellText() only reads textField, so before this pin the
    //   swatch subtree could be dropped entirely without failing the suite;
    //   this guards the cell-factory extraction.
    // Scenario: spec-first; pins existing rendering ahead of refactoring the
    //   duplicated viewFor bodies into ThemeBrowserCellView.themeCell.
    let fx = makeThemeBrowserFixture()   // sheet suite: makeRemotePickerFixture()
    defer { fx.window.close() }
    guard let cell = /* view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeBrowserCellView */
    else { throw ... }
    try uiExpect(cell.swatchView != nil, "cell should carry a swatch view")
    try uiExpect(cell.swatchView?.superview === cell, "swatch should be installed in the cell")
}
```

(Adapt each to its suite's fixture/access idiom; reuse the existing
cell-fetch pattern from that file's `cellText`.)

No other new tests. The helper has no behavior of its own beyond what the
two suites already exercise through the delegate path, and unit-testing
constraint layouts would be structure-sensitive churn.

## Implementation order

1. **Pin tests.** Add the two swatch-wiring tests above. Run `just test-ui`
   -- all green against current code (109 existing + 2 new = 111/111). These
   are pins, not red-first tests; passing-before is the point.
2. **Extract.** Add `ThemeBrowserCellView.themeCell(in:reuseIdentifier:themeName:isCurrentTheme:)`
   to `app/ThemeSwatchViews.swift` (move the block verbatim from one caller);
   update the file header line.
3. **Rewire both callers.** Collapse both `viewFor` bodies to the 3-line
   call. Delete the duplicated blocks.
4. **Verify** (gate below).

## Verification gate

- `just test-ui` -> green, `111/111 passed` (109 pre-existing + 2 pins),
  exit 0. Needs a logged-in GUI session; fine from an agent shell.
- `just test` -> green. Nothing in its scope changes (no core/lib/protocol
  edits), so this is a regression backstop only.
- `just build` -> green. Required: both callers and the helper compile in
  the production app target, and `just test-ui`'s single-module compile
  would not catch an app-target-only issue.
- Negative check (repo precedent): temporarily make the helper pass
  `isCurrentTheme: false` unconditionally, confirm the checkmark tests in
  both suites go red naming the mismatch, restore.

## Commit strategy

Two commits, matching the repo's test-then-change history:

1. `test(theme): pin theme cell swatch wiring in both table views`
   -- the two new pin tests only.
2. `refactor(theme): extract shared theme cell factory into ThemeSwatchViews`
   -- helper + both call-site rewires + header touch-up.

## Boundaries

- Do not edit `lib/GhosttyKit.xcframework/` or `.ghostty-src/`.
- No new module, package, or shim; no `test-ui.sh` compile-list changes
  (all three files are already listed).
- No behavior changes: identifiers, checkmark format, ambient color lookup,
  text color handling, and constraint values move verbatim.
- Selection semantics (runtime dispatch vs `onSelect`) stay entirely in the
  callers.
- No release commands.
