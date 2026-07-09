# Fix link-preview pill truncating every URL by ~4pt

## Context

Commit 2bcc774 (link preview pill on hover) sizes the pill from a raw
`NSAttributedString.size()` measurement, but the text is rendered by an
`NSTextField`, whose `NSTextFieldCell` needs ~2pt of internal horizontal
padding per side beyond the raw string width. Measured with the exact
font/cell config from the commit:

```
NSAttributedString.size().width : 106.66   <- what pillFittingSize() measures
width the label is given        : 107.00   (ceil)
label.cell.cellSize.width       : 110.66   <- what the cell actually needs
shortfall                       : 3.66pt
```

Because the label uses `.byTruncatingMiddle`, any shortfall forces an
ellipsis, and the ellipsis glyph itself costs ~9pt, so ~3 characters get
dropped: `https://example.com` renders as `https://e...ple.com` even in a
wide pane. Every URL truncates regardless of pane width.

Root-cause fix (fix #1 from the analysis): derive the pill size from the
label cell's own measurement (`cell.cellSize`) so the number that sizes the
pill is produced by the same machinery that draws the text. After this,
URLs render fully whenever they fit in the pane; only URLs genuinely wider
than the pane still middle-truncate. (Wrapping for those is fix #2, out of
scope here.)

Note: `intrinsicContentSize` is NOT a valid substitute — under this cell
config (single-line mode + truncation) it reports the compressed 107pt.
Use `cell.cellSize` (110.66) or `fittingSize` (111.0); we use `cellSize`.

## Changes

### 1. Regression test first (TDD) — `tests-ui/LinkPreviewViewTests.swift`

Add a `uiTest` to `linkPreviewViewTests()` pinning "the pill is never too
small for its own text", behavioral and insensitive to the padding
constants:

```swift
uiTest("pill gives the label its full required width in a wide pane") {
    // Intent: after show + layoutPill in a pane with room to spare, the
    //   label's frame is at least the width its own cell needs to draw
    //   without truncation.
    // Why it exists: guards the measure/render seam -- pill width must come
    //   from the same machinery that draws the text (cellSize), not a raw
    //   NSAttributedString measurement.
    // Scenario: 2026-07-09 incident -- pill sized labels from
    //   NSAttributedString.size(), ~4pt short of NSTextFieldCell's needs,
    //   so https://example.com middle-truncated to https://e...ple.com in
    //   panes with hundreds of points to spare.
    let view = LinkPreviewView()
    view.show(url: "https://example.com")
    view.layoutPill(in: NSRect(x: 0, y: 0, width: 800, height: 200))

    let needed = view.label.cell?.cellSize.width ?? .infinity
    try uiExpect(needed <= view.label.frame.width,
                 "label needs \(needed)pt but got \(view.label.frame.width)pt")
}
```

Run `just test-ui` and confirm it fails for the expected reason
(needs ~110.66pt, gets 107pt).

The existing test `"label truncates middle on a single line"` stays as-is:
fix #1 keeps the single-line middle-truncation contract for URLs wider
than the pane.

### 2. The fix — `app/LinkPreviewView.swift`, `pillFittingSize()`

Replace the `NSAttributedString` measurement with the label cell's own:

```swift
private func pillFittingSize() -> NSSize {
    let cellSize = label.cell?.cellSize ?? .zero
    return NSSize(
        width: ceil(cellSize.width) + Self.padding * 2,
        height: ceil(cellSize.height) + Self.padding * 2
    )
}
```

The `let font = label.font ?? ...` line goes away (cellSize uses the
cell's configured font). Both callers (`layoutPill`, `pointerMoved`)
consume the result unchanged; the `linkPreviewFrame` container-width cap
still applies on top. Pill height may shift ~1-2pt if cellSize's vertical
metric differs slightly from the raw string height — cosmetic and fine.

## Verification

1. `just test-ui` — new regression test passes (and failed before the fix);
   existing LinkPreviewView + split-view + sidebar suites stay green.
2. `just test` — local gate unaffected but cheap sanity.
3. Manual: `just build-run`, print a link in the terminal (e.g.
   `printf 'https://example.com\n'`), Cmd-hover it, confirm the pill shows
   the full URL with no ellipsis. Also hover a very long URL and confirm it
   still middle-truncates at pane width (unchanged contract).
