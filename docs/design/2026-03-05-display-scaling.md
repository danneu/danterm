# Display Scaling

- Status: Accepted
- Date: 2026-03-05
- Amended: 2026-08-06 -- the mechanism below is gone with libghostty; the
  invariant it protects still holds. See the banner.

> **2026-08-06: mechanism superseded by the libghostty removal; invariant
> retained.** `app/TerminalView.swift`,
> `lib/DanTermCore/Sources/DanTermCore/BackingGeometry.swift`, and every
> `ghostty_surface_*` call named below are gone. The equivalent code is
> `SwiftTerminalSessionView.synchronizePresentation`, which derives cell metrics
> and grid dimensions from `window?.backingScaleFactor`; the layer's contents
> scale rides the surface it shows.
> What still holds is the rule this ADR exists for: scale and pixel size are one
> invariant, and the non-positive-dimension guard is part of it, not a cosmetic
> defensive check. The body is unedited on purpose.

<!-- docs-lint: allow-missing app/TerminalView.swift -->
<!-- docs-lint: allow-missing lib/DanTermCore/Sources/DanTermCore/BackingGeometry.swift -->

## Context

DanTerm hosts Ghostty surfaces in AppKit views that may run on Retina and
non-Retina displays. Ghostty needs two values kept in sync: the content scale
for the active backing store, and the surface size in backing pixels.

For example, an 800x600 point view on a 2x display must be sent as a
1600x1200 pixel surface with a 2.0 content scale. If these values diverge,
fonts render at the wrong size and mouse hit testing lands on the wrong grid
cell.

Split rebuilds add one more edge case. AppKit can temporarily remove terminal
views from the window and re-add them with a zero frame before layout assigns a
real size.

## Decision

DanTerm treats backing-pixel size and content scale as one invariant. Whenever
a terminal view has a valid frame and its size or display backing changes, it
sends both values to Ghostty:

```swift
syncBackingGeometry(logicalSize: newSize)
```

The touch points are:

- `TerminalView.init` seeds `config.scale_factor` from
  `NSScreen.main?.backingScaleFactor` before `ghostty_surface_new`.
- `TerminalView.setFrameSize`,
  `TerminalView.viewDidMoveToWindow`, and
  `TerminalView.viewDidChangeBackingProperties` all call
  `TerminalView.syncBackingGeometry(logicalSize:)`.
- `TerminalView.syncBackingGeometry(logicalSize:)` converts the logical size to
  backing pixels and delegates the scale/pixel derivation to
  `backingGeometry(logicalSize:backingSize:)` in
  `lib/DanTermCore/Sources/DanTermCore/BackingGeometry.swift`.

DanTerm sends mouse coordinates in point space with
`convert(event.locationInWindow, from: nil)`. Ghostty uses the content scale to
map those points back to grid cells.

`backingGeometry(logicalSize:backingSize:)` returns nil for any non-positive
logical or backing dimension, and callers treat nil as "skip the update." This
prevents:

- Sending 0x0 to Ghostty, which can corrupt terminal state.
- Dividing 0 by 0 and passing NaN to `ghostty_surface_set_content_scale`, which
  Ghostty clamps to 1.0 and silently halves Retina scale.

## Consequences

Display-scaling fixes must preserve the pairing between backing-pixel size and
content scale. Updating only one side of the pair can make rendering and input
mapping disagree.

The common scale-mismatch symptoms are:

| Scale too low (1.0 on 2x display) | Scale too high (2.0 on 1x display) |
|------------------------------------|-------------------------------------|
| Fonts render at half size          | Fonts render at double size         |
| Mouse selection offset by 2x       | Mouse selection offset by 0.5x      |
| Grid thinks it has 2x the cells    | Grid thinks it has 0.5x the cells   |

Zero-frame guards are part of the invariant, not cosmetic defensive checks. The
guard lives in `backingGeometry(logicalSize:backingSize:)`, so it cannot be
dropped from one AppKit path while surviving in another. Removing it can break
Retina scaling during split, tab, and layout rebuilds.

## References

- `lib/DanTermCore/Sources/DanTermCore/BackingGeometry.swift`: `backingGeometry`
- `app/TerminalView.swift`: `init`, `setFrameSize`,
  `viewDidMoveToWindow`, `viewDidChangeBackingProperties`
