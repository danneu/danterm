// Vertical ink reach: how far one plan row's drawing can extend past its cell
// band, and the erase/plan shape an incremental render derives from it
// (research/33 T14, D9). Pure row/pixel arithmetic so the frame store and the
// t5 research probe run the same derivation; the measured envelope itself is
// produced by the metrics layer, which owns the fonts. Nothing here draws.
import TerminalCore

/// The measured vertical ink envelope of the styled faces' printable-ASCII
/// glyph tables, in backing pixels -- the only unclipped draw path, so the
/// only one whose reach is not the cell band itself (research/33 D9).
///
/// Offsets are signed and relative to the cell: `inkTopOffsetPixels` is how
/// far below the row's top edge the highest ink begins (positive = a margin,
/// negative = ink escapes upward), and `inkBottomOffsetPixels` is how far
/// below the row's bottom edge the lowest ink ends (positive = descenders
/// spill into the next row, negative = fully contained).
public struct RenderInkEnvelope: Equatable, Sendable {
    public let inkTopOffsetPixels: Int
    public let inkBottomOffsetPixels: Int

    public init(inkTopOffsetPixels: Int, inkBottomOffsetPixels: Int) {
        self.inkTopOffsetPixels = inkTopOffsetPixels
        self.inkBottomOffsetPixels = inkBottomOffsetPixels
    }
}

/// One row's vertical drawing footprint as pixel offsets relative to the
/// row's own top edge: `lowerOffsetPixels` may be negative (ink above the
/// row) and `upperOffsetPixels` may exceed the cell height (ink below it).
/// Absent entirely for rows that draw nothing.
public struct RenderRowReach: Equatable, Sendable {
    public var lowerOffsetPixels: Int
    public var upperOffsetPixels: Int

    public init(lowerOffsetPixels: Int, upperOffsetPixels: Int) {
        self.lowerOffsetPixels = lowerOffsetPixels
        self.upperOffsetPixels = upperOffsetPixels
    }
}

/// Maps every plan row's metrics-free ink class to its pixel reach, per the
/// containment facts research/33 D9 audited:
///
/// - a single-scalar cell in `0x20...0x7E` is submitted unclipped from the
///   measured ASCII tables, so it reaches exactly the envelope;
/// - any other single-scalar cell may be submitted unclipped from the styled
///   face's wider cmap, whose extents are not tabulated, so it is assumed to
///   reach one full cell past both edges -- the pre-T14 global halo, kept as
///   the per-row worst case;
/// - a multi-scalar cell draws through `drawTextCell`, which clips to the
///   cell, so it contributes the band only;
/// - background, overlay, and decoration runs and the cursor are clipped or
///   exact, so they contribute the band only.
///
/// A nil `envelope` (unmeasurable faces) degrades ASCII cells to the
/// full-cell assumption, reproducing the pre-T14 shape everywhere.
public func renderRowReaches(
    of plan: RenderFramePlan,
    envelope: RenderInkEnvelope?,
    cellHeightPixels: Int
) -> [RenderRowReach?] {
    let cellHeight = cellHeightPixels
    let asciiLower = envelope?.inkTopOffsetPixels ?? -cellHeight
    let asciiUpper = envelope.map { cellHeight + $0.inkBottomOffsetPixels } ?? 2 * cellHeight
    var reaches = [RenderRowReach?](repeating: nil, count: plan.rowCount)

    func include(row: Int, lower: Int, upper: Int) {
        guard row >= 0, row < reaches.count else { return }
        if var reach = reaches[row] {
            reach.lowerOffsetPixels = min(reach.lowerOffsetPixels, lower)
            reach.upperOffsetPixels = max(reach.upperOffsetPixels, upper)
            reaches[row] = reach
        } else {
            reaches[row] = RenderRowReach(lowerOffsetPixels: lower, upperOffsetPixels: upper)
        }
    }

    for (rowIndex, row) in plan.rows.enumerated() {
        if row.inkClass.contains(.asciiText) {
            include(row: rowIndex, lower: asciiLower, upper: asciiUpper)
        }
        if row.inkClass.contains(.generalText) {
            include(row: rowIndex, lower: -cellHeight, upper: 2 * cellHeight)
        }
        if row.inkClass.contains(.band) {
            include(row: rowIndex, lower: 0, upper: cellHeight)
        }
    }
    if let cursor = plan.cursor {
        include(row: cursor.row, lower: 0, upper: cellHeight)
    }
    return reaches
}

/// The stale vertical pixel strips a row translation leaves at the moved
/// block's four edges, computed on the reach ledger *before* the move.
///
/// A translation preserves every interior row relationship, but at each edge
/// of the moved block the neighbor changes: spill carried with the moved
/// pixels becomes a ghost of the old neighborhood (imported strips, inside
/// the block's edge bands), and spill the block's old edge rows left in
/// unmoved neighbors goes stale (outward strips, just outside the block).
/// Each strip is sized by the larger of the ghost's reach and the reach the
/// new neighborhood must repaint, so erasing the strips and replanning by
/// reach intersection restores every edge exactly. All-ASCII content pays a
/// few pixels; strips are empty wherever no spill exists.
///
/// `region` and `delta` follow the recorded-shift contract
/// (`0 < abs(delta) < region.count`, region inside the grid); the caller
/// validates them, as `TerminalFrameBackingStore.translateRows` does.
public func renderTranslationStaleStrips(
    region: Range<Int>,
    delta: Int,
    cellHeightPixels: Int,
    reaches: [RenderRowReach?]
) -> [Range<Int>] {
    let cellHeight = cellHeightPixels
    let survivors = region.count - abs(delta)
    let destinationLow = delta > 0 ? region.lowerBound + delta : region.lowerBound
    let sourceLow = delta > 0 ? region.lowerBound : region.lowerBound - delta
    let destinationHigh = destinationLow + survivors
    let sourceHigh = sourceLow + survivors

    func spillBelow(_ row: Int) -> Int {
        guard row >= 0, row < reaches.count, let reach = reaches[row] else { return 0 }
        return max(0, reach.upperOffsetPixels - cellHeight)
    }
    func spillAbove(_ row: Int) -> Int {
        guard row >= 0, row < reaches.count, let reach = reaches[row] else { return 0 }
        return max(0, -reach.lowerOffsetPixels)
    }

    var strips: [Range<Int>] = []
    func strip(_ lower: Int, _ upper: Int) {
        if lower < upper { strips.append(lower..<upper) }
    }
    let destinationTop = destinationLow * cellHeight
    let destinationBottom = destinationHigh * cellHeight
    strip(
        destinationTop,
        destinationTop + max(spillBelow(sourceLow - 1), spillBelow(destinationLow - 1))
    )
    strip(
        destinationBottom - max(spillAbove(sourceHigh), spillAbove(destinationHigh)),
        destinationBottom
    )
    strip(
        destinationTop - max(spillAbove(destinationLow), spillAbove(sourceLow)),
        destinationTop
    )
    strip(
        destinationBottom,
        destinationBottom + max(spillBelow(destinationHigh - 1), spillBelow(sourceHigh - 1))
    )
    return strips
}

/// The exact shape one incremental render must execute: the vertical pixel
/// spans to refill, and the rows whose runs must be drawn into them.
public struct RenderApplyShape: Equatable, Sendable {
    /// Disjoint ascending vertical spans in absolute backing pixels. Every
    /// pixel a damaged row's band, old ink, or new ink can occupy.
    public let erasePixelSpans: [Range<Int>]

    /// Every row whose drawing intersects an erase span, as row damage the
    /// render clips its plan to.
    public let planDamage: TerminalDamage
}

/// Derives the erase spans and plan rows for one damaged-row render on top of
/// pixels holding the previous frame (research/33 D9).
///
/// The erase region is each damaged row's band extended by the reach of the
/// content its pixels currently show (`oldReaches` -- stale ink must go) and
/// of the content the plan will draw (`newReaches` -- new ink must land
/// inside the clip). The plan set is every row whose new reach intersects
/// that region; undamaged rows' content is unchanged between the two frames,
/// so their old and new reaches agree by construction.
public func renderApplyShape(
    damagedRows: [Int],
    rowCount: Int,
    cellHeightPixels: Int,
    oldReaches: [RenderRowReach?],
    newReaches: [RenderRowReach?],
    extraEraseIntervals: [Range<Int>] = []
) -> RenderApplyShape {
    let cellHeight = cellHeightPixels
    let frameHeight = rowCount * cellHeight
    var isDamaged = [Bool](repeating: false, count: rowCount)
    for row in damagedRows where row >= 0 && row < rowCount {
        isDamaged[row] = true
    }

    func reach(_ reaches: [RenderRowReach?], _ row: Int) -> RenderRowReach? {
        row < reaches.count ? reaches[row] : nil
    }

    var intervals: [Range<Int>] = []
    for row in 0..<rowCount where isDamaged[row] {
        var lower = 0
        var upper = cellHeight
        if let old = reach(oldReaches, row) {
            lower = min(lower, old.lowerOffsetPixels)
            upper = max(upper, old.upperOffsetPixels)
        }
        if let new = reach(newReaches, row) {
            lower = min(lower, new.lowerOffsetPixels)
            upper = max(upper, new.upperOffsetPixels)
        }
        let top = max(0, row * cellHeight + lower)
        let bottom = min(frameHeight, row * cellHeight + upper)
        if top < bottom {
            intervals.append(top..<bottom)
        }
    }
    for extra in extraEraseIntervals {
        let clamped = max(0, extra.lowerBound)..<min(frameHeight, extra.upperBound)
        if clamped.isEmpty == false {
            intervals.append(clamped)
        }
    }

    var spans: [Range<Int>] = []
    for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = spans.last, interval.lowerBound <= last.upperBound {
            spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, interval.upperBound)
        } else {
            spans.append(interval)
        }
    }

    // A row's reach never exceeds one cell past either edge (the envelope is
    // clamped there by its producer, and the general class is defined as one
    // cell), so only rows within one of a span's row range can intersect it.
    var isPlanned = [Bool](repeating: false, count: rowCount)
    for span in spans {
        let firstCandidate = max(0, span.lowerBound / cellHeight - 1)
        let lastCandidate = min(rowCount - 1, (span.upperBound - 1) / cellHeight + 1)
        guard firstCandidate <= lastCandidate else { continue }
        for row in firstCandidate...lastCandidate where isPlanned[row] == false {
            guard let rowReach = reach(newReaches, row) else { continue }
            let lower = row * cellHeight + rowReach.lowerOffsetPixels
            let upper = row * cellHeight + rowReach.upperOffsetPixels
            if lower < span.upperBound, upper > span.lowerBound {
                isPlanned[row] = true
            }
        }
    }

    let plannedRows = (0..<rowCount).filter { isPlanned[$0] }
    return RenderApplyShape(
        erasePixelSpans: spans,
        planDamage: TerminalDamage(rows: plannedRows, rowCount: rowCount)
    )
}
