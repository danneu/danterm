# Settings form rows are addressed by identity, never by index

Source: CHROME-4 in `docs/scratch/2026-08-18-construction-audit.md`, verified
against the tree on 2026-08-20.

## 1. Problem and evidence

`PreferencesPanel.buildUI` builds the settings form as one positional
`NSGridView(views:)` literal (`app/PreferencesPanel.swift:78-98`) and then
reaches back into it by literal row number: four `topPadding` statements and
the three warning-row captures (`:107-116`). The UI harness hardcodes the same
numbers (`tests-ui/PreferencesPanelTests.swift:46,159-164`). Inserting,
removing, or reordering a row silently retargets all of them; nothing fails at
compile time and the harness breaks alongside production instead of catching
it.

The hazard is already shaping the code: commit `47af3e7a` (2026-08-19) added
the tailnet section with an eleventh index statement and a comment saying the
section "goes last so the row indices above it, which the warning rows and the
UI harness both address by number, stay put" (`:91-92`). That comment is a
workaround for this finding.

Load-bearing premises, checked against the macOS SDK `NSGridView.h`:
`addRow(with:)` returns the `NSGridRow` it creates; `NSGridCell.emptyContentView`
is honored by every `...WithViews:` method, `addRow` included; `cell(for:)` and
`NSGridCell.row` locate a row from a view it contains.

## 2. Decision

Build the grid by appending rows one at a time and take every row handle from
the call that creates it. No statement in `app/` or `tests-ui/` names a grid
row by position. The warning rows are captured, padded, hidden, and
width-constrained as they are created; the "tailnet goes last" comment and the
index-free width loop (`:118-129`, whose only job was to survive reordering)
both go away because the builder makes them unnecessary.

The UI harness locates rows the same way: from the view the row contains,
via `cell(for:)`. The two warning labels the harness cannot currently reach
(`themeWarningLabel`, `remoteThemeWarningLabel`) become harness-readable, the
way `fontFamilyWarningLabel` already is.

Scope: `app/PreferencesPanel.swift#buildUI` and
`tests-ui/PreferencesPanelTests.swift`. The projection, `apply(_:)`, the
warning show/hide channel, and Core are untouched. Layout-only; the panel's
visible form is identical before and after.

## 3. Invariants

- I1. Every warning row collapses exactly when its own warning is absent and
  expands exactly when it is present, independent of the other two.
- I2. Every control cell in the second column is at least
  `preferencesControlColumnWidth` wide, for every row, including rows added
  after this change.
- I3. No code in `app/` or `tests-ui/` addresses a settings-grid row by
  numeric index (`row(at:)`, `cell(atColumnIndex:rowIndex:)` with a literal
  row). Enumerating all rows is allowed; naming one row by number is not.
- I4. Adding, removing, or reordering a settings row does not change which
  row a warning controls or which row carries section padding.

## 4. Proof obligations

- PO1 (I1). Harness: with only the font-family warning projected, its row is
  expanded and the theme and remote-theme rows are collapsed; with both theme
  warnings projected and then cleared, both rows expand and then collapse.
  Rows are found from their warning label, not by index. The existing
  "the absent font warning collapses its grid row" and "theme fallback warnings
  show inline and collapse when resolved" tests are rewritten to this form.
- PO2 (I2). The existing width tests ("the input controls get the full width
  the labels do not need", "the label column reserves no width beyond its
  widest label", "the settings window is exactly as wide as its content needs")
  pass unchanged.
- PO3 (I3). `grep -n 'row(at:' app/PreferencesPanel.swift tests-ui/PreferencesPanelTests.swift`
  returns nothing; no literal `rowIndex:` remains outside an all-rows loop.
- PO4 (I4, warning ownership). Discharged by construction plus PO1: the
  rewritten harness tests must pass without edits when a row is inserted
  anywhere in the form during implementation (the implementer verifies once,
  then removes the probe row).
- PO5 (I4, padding ownership). Harness: every row that starts a section carries
  top padding and every other row carries none. Each row is located from a view
  it contains, never by index, so the assertion re-targets with the row. The
  test asserts padded / not padded, not the padding constant, so it survives a
  spacing change. It runs under the same probe-row insertion as PO4.

Run: `just test-ui > .build/ui.log 2>&1`, then grep the log.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: no test asserts a `topPadding` number; the constant is layout, not
  behavior. Which rows carry padding at all is ownership, and PO5 asserts it.
- Non-goal: no row-descriptor data type. The audit proposed a descriptor list;
  appending rows through one helper achieves "no index is ever written down"
  with less code, and there is no second consumer of such a table.
- Rejected idea: keep the array literal and look rows up by identity at the
  use sites (the audit's cheaper fallback). It removes the silent retarget but
  leaves two ways to address a row and keeps the width loop and the
  ordering comment alive.

## 6. Implementation discretion

- Shape of the row-building helper and whether the warning-row properties stay
  optional.

## Implementation notes

- The grid starts as `NSGridView(numberOfColumns: 2, rows: 0)` rather than an
  empty `NSGridView(views:)` literal. Both work with `addRow(with:)`, but the
  two-column form states the shape the form has and lets `column(at:)` run
  before the first row is appended.
- The row helper takes a `topPadding` value, not a `startsSection` flag. The
  "Config file" section opens with 4pt where the other three open with 8pt, so
  a flag would have needed an override beside it. The section-start invariant
  lives in the PO5 test instead, which names the four rows that start a section
  and asserts padded / not padded.
- PO4 and PO5 were discharged with a probe row appended above "Theme". The
  whole UI harness passed with no test edits (380/380), and the probe was then
  removed.
