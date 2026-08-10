// Pure scrollbar coordinate math functions. No AppKit dependency so they can be
// compiled in both the app build and the unit test build. Live for the Swift
// terminal backend via `app/ScrollableTerminalView.swift`.

import Foundation

/// Compute document view height from scrollbar state.
/// Total rows * cellHeight + padding, where padding accounts for content that doesn't
/// fill an exact number of rows.
func scrollbarDocumentHeight(
    contentHeight: CGFloat, cellHeight: CGFloat,
    total: UInt64, len: UInt64
) -> CGFloat {
    guard cellHeight > 0 else { return contentHeight }
    let documentGridHeight = CGFloat(total) * cellHeight
    let padding = contentHeight - (CGFloat(len) * cellHeight)
    return documentGridHeight + padding
}

/// Convert scrollbar offset to AppKit Y position (for programmatic scroll).
/// Terminal offset is from top (row 0 = oldest history); AppKit Y is from bottom.
func scrollbarOffsetY(
    total: UInt64, offset: UInt64, len: UInt64, cellHeight: CGFloat
) -> CGFloat {
    return CGFloat(total - offset - len) * cellHeight
}

/// Convert AppKit scroll position to terminal row (for scrollbar drag).
/// Returns the top-row offset the session should be scrolled to.
func scrollbarRowFromPosition(
    documentHeight: CGFloat, visibleOriginY: CGFloat,
    visibleHeight: CGFloat, cellHeight: CGFloat
) -> Int {
    guard cellHeight > 0 else { return 0 }
    let scrollOffset = documentHeight - visibleOriginY - visibleHeight
    return Int(scrollOffset / cellHeight)
}
