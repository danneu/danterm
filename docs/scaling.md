# Display Scaling (HiDPI / Retina)

Ghostty surfaces need two pieces of information kept in sync: the **content
scale** (e.g. 2.0 on Retina) and the **size in backing pixels** (e.g. 1600×1200
for an 800×600 pt view at 2x). If these diverge, fonts render at the wrong size
and mouse hit-testing lands on the wrong grid cell.

## Touch points

### 1. Surface creation (`TerminalView.init`)

`config.scale_factor` is set to `NSScreen.main?.backingScaleFactor` (typically
2.0 on Retina). This seeds the surface via `ghostty_surface_new`.

### 2. Frame resize (`setFrameSize`)

The primary path — fires reliably after every layout pass.

```swift
let scaledSize = convertToBacking(newSize)
let xScale = scaledSize.width / newSize.width   // e.g. 2.0
ghostty_surface_set_content_scale(surface, xScale, yScale)
ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
```

### 3. Display changes (`viewDidMoveToWindow`, `viewDidChangeBackingProperties`)

Handle the view moving to a different display (e.g. Retina → non-Retina).
Both recalculate scale from `convertToBacking` and call `set_content_scale` +
`set_size`.

## Critical invariant

Ghostty always receives **backing-scaled pixel dimensions** for size paired with
a matching content scale. Mouse coordinates are sent in **point space**
(`convert(event.locationInWindow, from: nil)`), and ghostty uses the content
scale internally to map points → grid cells.

## Zero-frame guard

During split rebuilds, views are temporarily removed from the window and
re-added with frame `.zero`. Both `setFrameSize` and `viewDidChangeBackingProperties`
guard against zero-size frames:

- `setFrameSize`: prevents sending 0×0 to ghostty (corrupts terminal state).
- `viewDidChangeBackingProperties`: prevents `0/0 = NaN` content scale, which
  ghostty clamps to 1.0 — silently halving the Retina scale.

## Symptoms of scale mismatch

| Scale too low (1.0 on 2x display) | Scale too high (2.0 on 1x display) |
|------------------------------------|-------------------------------------|
| Fonts render at half size          | Fonts render at double size         |
| Mouse selection offset by 2x      | Mouse selection offset by 0.5x     |
| Grid thinks it has 2x the cells   | Grid thinks it has 0.5x the cells  |
