# Move jump-mode hint to the left of the tab title

## Context

When jump mode is active, each tab in the sidebar shows a single-letter
hint badge that the user types to jump to that tab. Today the hint is
rendered on the far right of the tab row, inside the trailing accessory
stack (alongside the bell-alert badge). That puts the hint visually
distant from the title -- the eye is on the title, and the hint sits at
the opposite edge.

Moving the hint between the color stripe and the title puts it right
next to the text the user is targeting, so the eye doesn't have to jump
across the row to read the hint key.

Target layout:

```
[color stripe][hint badge][title]                            [bell badge]
                          [subtitle]
```

## Files to modify

- `app/SidebarView.swift` -- only file that touches the jump badge view.
  - `makeTabCell(for:)` at lines 1100-1167: build a left-side stack that
    will host the optional jump badge plus the title text field; remove
    title's standalone leading constraint.
  - `configureTabCell(_:tab:skipTitle:)` at lines 1173-1218: move the
    jump-badge insertion/removal from the trailing accessory stack to
    the new left stack.

No model or `Msg`/`Update` changes. `Model.jumpMode.keyMap` already
drives this rendering; we're only relocating the view.

## Implementation

### 1. New left-side stack in `makeTabCell`

Replace the direct `textField` placement with a horizontal
`NSStackView` (call it `tabLeadingStack`, identifier
`"tabLeadingStack"`) whose arranged subviews are `[textField]` by
default. The jump badge will be inserted at index 0 when jump mode is
active.

- `leadingStack.orientation = .horizontal`
- `leadingStack.alignment = .centerY` -- the badge has a fixed 20pt
  height while the title's intrinsic height is ~17pt at 13pt system
  font; centering keeps the title's vertical position invariant
  whether or not the badge is present (a `.top` or `.firstBaseline`
  stack grows downward by ~3pt when the badge inserts, which would
  nudge the subtitle as jump mode toggles).
- `leadingStack.spacing = 4`
- `leadingStack.setHuggingPriority(.required, for: .horizontal)` so it
  doesn't stretch.

New constraints (replacing the existing `textField.leadingAnchor`/
`textField.trailingAnchor`/`textField.topAnchor` rules at lines 1156-1158):

```
leadingStack.leadingAnchor == cell.leadingAnchor + 8
leadingStack.topAnchor == cell.topAnchor + 4
leadingStack.trailingAnchor <= accessoryStack.leadingAnchor - 4
subtitleField.leadingAnchor == textField.leadingAnchor          (kept)
subtitleField.trailingAnchor <= accessoryStack.leadingAnchor - 4 (kept)
subtitleField.topAnchor == textField.bottomAnchor + 1          (kept)
```

The trailing edge is anchored on the stack, not on `textField`, so the
right-edge bound holds regardless of which arranged subview is last.
The textField's own truncation is governed by the stack's compression
behavior (and its existing `.byTruncatingTail` line break mode).

`subtitleField.leadingAnchor == textField.leadingAnchor` continues to
work even when the textField has shifted right because the badge was
inserted -- the subtitle tracks the textField's actual leading edge.

### 2. Move badge insertion to the left stack in `configureTabCell`

Currently lines 1187-1209 read the trailing `accessoryStack`, look for
an existing `jumpModeBadge` among its arranged subviews, and add/remove
it based on `currentModel?.jumpMode?.keyMap[tab.id]`.

Change this to:

- Early-return the jump-badge branch when `skipTitle == true`. Inline
  rename is the only caller that passes `skipTitle: true`, and jump
  mode is gated to its own keyboard state -- in practice they don't
  overlap, but inserting a badge at index 0 while a field editor is
  active on the textField would shift the editor's frame horizontally
  mid-keystroke. The guard keeps the leading-stack arrangement frozen
  for the duration of a rename.
- Locate the new `tabLeadingStack` by identifier.
- If `currentModel?.jumpMode?.keyMap[tab.id]` has a key:
  - Reuse the existing badge if present, else build one via
    `makeJumpModeBadge(identifier:)` (unchanged helper at lines
    1220-1237).
  - Set `badge.stringValue = String(key).uppercased()`.
  - If the badge is not currently in the leading stack, insert it at
    index 0 via `leadingStack.insertArrangedSubview(badge, at: 0)`.
- Else (no key):
  - Remove the existing badge from the leading stack and from its
    superview.

The trailing accessory stack handling collapses to just the bell badge
-- drop the jump-badge branch entirely from it (lines 1193-1208).

### 3. Keep `makeJumpModeBadge` as-is

The badge view itself (font, color, corner radius, min-width 22, height
20) is unchanged. We're only moving where it gets parented.

## Verification

1. `just build` -- compiles cleanly.
2. `just test` -- existing pure tests still pass (no UI test touches
   this layout; `tests/UpdateJumpTests.swift` verifies the model only).
3. Manual check in `just build-run`:
   - Open multiple tabs (>= 3) so jump mode has work to do.
   - Trigger jump mode (the binding that populates
     `Model.jumpMode.keyMap`).
   - Verify each tab shows its hint letter immediately to the right of
     the color stripe (or to the right of cell padding when no color is
     set) and immediately to the left of the title text.
   - Verify the bell-alert badge still renders on the right when a tab
     has unread alerts, and that the title truncates correctly when the
     row is narrow with both the hint and bell visible.
   - Exit jump mode and verify the title slides back left flush with
     its normal position (no leftover gap where the badge used to sit).
   - Verify the title's vertical position does not shift when the
     badge appears/disappears (confirms `.centerY` keeps the row
     stable across jump-mode toggles).
   - Open a tab with a subtitle (e.g. via working-dir display) and
     verify the subtitle still aligns under the title, not under the
     hint badge.
   - Start an inline rename on a tab, then toggle jump mode while the
     field editor is open: the textField's horizontal position should
     not shift (the `skipTitle` guard freezes the leading stack
     arrangement during rename).
