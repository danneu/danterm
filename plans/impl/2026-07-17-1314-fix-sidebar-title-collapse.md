# Fix Sidebar Title Collapse

## Problem and desired outcome

A sidebar title can collapse to roughly 2 px even though the model and the
field's string remain correct. The load-bearing premise is established by the
2026-07-17 incident and the existing 2026-06-11 regression: AppKit can discard
an inline field editor without completing DanTerm's rename cleanup, while an
editable `NSTextField` has no intrinsic horizontal width.

Tab and group titles must remain readable during editing and after every rename
exit path. No abandoned rename state may survive in a visible or recycled cell.

## Decision

Fix both sides of the failure:

- Allocate the title lane independently of the text field's editable-state
  intrinsic width, while preserving title truncation and fixed-width badges.
- Make DanTerm's rename target the authority for cleanup. Non-structural pointer
  interactions finish a live edit before AppKit changes selection;
  reconciliation detects and normalizes any editor AppKit has already
  abandoned.
- Keep the existing recycled-cell reset as a final defense.

No public model, persistence, IPC, or CLI interface changes.

## Invariants

- **I1 - Stable geometry:** Tab and group title lanes retain useful available
  width in display and edit modes. Jump, alert, count, and caret accessories do
  not overlap the title and retain their intended width.
- **I2 - Single rename owner:** The sidebar rename target and its matching field
  are either both live or both cleared. A missing field editor is never treated
  as a live rename.
- **I3 - Existing completion semantics:** Enter commits and restores terminal
  focus; Esc cancels and restores terminal focus; non-structural pointer
  click-away that leaves the renamed row live commits without stealing the
  clicked destination's focus.
- **I4 - Safe abandonment:** Structural or programmatic teardown cancels the
  rename, including when the teardown is pointer-initiated. This takes
  precedence over I3 for collapse, removal, movement, and rebuild. If AppKit has
  already discarded the editor, DanTerm restores the model title instead of
  committing potentially stale field contents.
- **I5 - Reuse safety:** Every cell returned to steady state or reused for
  another row is non-editable, has no rename association, and displays its live
  model title.

## Proof obligations

- **PO1 (I1):** UI coverage forces a fresh layout pass for tab and group rename
  fields and proves they keep useful width, including a tab with a jump badge.
- **PO2 (I2, I4):** Reproduce direct-click ordering where selection changes and
  AppKit removes the editor before reconciliation; prove the sidecar and field
  are normalized even when selection already matches.
- **PO3 (I3):** Prove Enter, Esc, and non-structural pointer click-away preserve
  their commit, cancellation, and focus behavior, with no duplicate rename
  dispatch.
- **PO4 (I4, I5):** Prove collapse, removal, movement, and recycled-cell paths
  cancel the rename and leave no editable field, including when pointer-initiated
  or when `currentEditor()` is already nil.
- **PO5:** Keep the existing Cmd-T, cosmetic-reconcile, collapse, rename, and
  recycled-cell regression suites green. Run `just test-ui`, `just test`, and
  `just build`.

## Rejected idea

- **RI1 - Separate overlay editor:** Rejected for this fix because it adds
  scrolling, coordinate, and reuse ownership without changing the required
  behavior. Stable title-lane geometry plus explicit lifecycle ownership closes
  the failure directly.

## Implementation discretion

- Exact helper names and internal constraint priorities are left to
  implementation, provided I1-I5 and PO1-PO5 hold.
