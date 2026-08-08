// The owned, translatable frame store behind research/33 T9's view half.
// AppKit's layer backing store cannot realize a translation (research/33 F22),
// so the pane view mirrors its last published frame here: a scroll becomes a
// row-range move in owned memory plus a damaged-row render, and the on-screen
// store is only ever a blit target. Validity policy stays with the view; this
// type holds pixels and geometry, nothing about when they may be trusted.
import CoreGraphics
import TerminalCore
import TerminalRenderPlanning

/// Owns the pixels of one rendered frame at backing resolution so a recorded
/// scroll shift is realized as an exact row translation instead of a
/// region-wide glyph repaint.
///
/// Main-thread only, like the drawing seam it mirrors. The store never tracks
/// whether its contents are current -- the owning view keeps that single
/// validity bit -- so every method assumes the caller has established the
/// pixels it builds on.
public final class TerminalFrameBackingStore {
    public let columns: Int
    public let rows: Int
    public let metrics: TerminalRenderMetrics

    /// Frame extent in point space, for callers clipping or invalidating.
    public let pointSize: CGSize

    private let pixelWidth: Int
    private let pixelHeight: Int
    private let bytesPerRow: Int
    private let byteCount: Int
    private let data: UnsafeMutableRawPointer
    private let context: CGContext
    private let colorSpace: CGColorSpace

    /// Fails on non-positive geometry or a backing allocation CoreGraphics
    /// refuses, mirroring `renderFrameSize`'s overflow refusals.
    ///
    /// `colorSpace` defaults to sRGB; the view passes its window's space so
    /// the blit is conversion-free and byte-equal to direct drawing.
    public init?(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace? = nil
    ) {
        guard columns > 0, rows > 0 else { return nil }
        let width = metrics.cellWidthPixels.multipliedReportingOverflow(by: columns)
        let height = metrics.cellHeightPixels.multipliedReportingOverflow(by: rows)
        guard width.overflow == false, height.overflow == false,
              width.partialValue > 0, height.partialValue > 0
        else { return nil }
        let rowBytes = width.partialValue.multipliedReportingOverflow(by: 4)
        guard rowBytes.overflow == false else { return nil }
        let totalBytes = rowBytes.partialValue.multipliedReportingOverflow(
            by: height.partialValue
        )
        guard totalBytes.overflow == false else { return nil }
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let allocated = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes.partialValue,
            alignment: MemoryLayout<UInt32>.alignment
        )
        allocated.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: totalBytes.partialValue
        )
        guard let context = CGContext(
            data: allocated,
            width: width.partialValue,
            height: height.partialValue,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes.partialValue,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            allocated.deallocate()
            return nil
        }
        // Same flip as the view's AppKit context: top-left origin, y down,
        // point units -- so `drawRenderFrame` produces identical geometry here
        // and memory row 0 is the top pixel row.
        context.translateBy(x: 0, y: CGFloat(height.partialValue))
        context.scaleBy(x: metrics.displayScale, y: -metrics.displayScale)

        self.columns = columns
        self.rows = rows
        self.metrics = metrics
        pointSize = CGSize(
            width: metrics.cellSize.width * CGFloat(columns),
            height: metrics.cellSize.height * CGFloat(rows)
        )
        pixelWidth = width.partialValue
        pixelHeight = height.partialValue
        bytesPerRow = rowBytes.partialValue
        byteCount = totalBytes.partialValue
        data = allocated
        self.context = context
        self.colorSpace = space
    }

    deinit {
        data.deallocate()
    }

    /// Renders the complete plan, making every pixel current.
    public func renderFull(_ plan: RenderFramePlan) {
        precondition(
            plan.columns == columns && plan.rows == rows,
            "full render of a \(plan.columns)x\(plan.rows) plan into a \(columns)x\(rows) store"
        )
        drawRenderFrame(plan, metrics: metrics, in: context)
    }

    /// Applies one published frame on top of pixels that hold the previous
    /// one: realizes the recorded shift as a row translation, then renders the
    /// damaged rows plus the glyph halo. Returns false without touching the
    /// store when the value cannot be realized exactly (full damage, grid
    /// mismatch, an out-of-range shift); the caller treats that as stale.
    public func apply(plan: RenderFramePlan, damage: TerminalDamage) -> Bool {
        guard plan.columns == columns, plan.rows == rows else { return false }
        guard damage.isFull == false else { return false }
        var indices = damage.rowIndices
        guard indices.allSatisfy({ $0 < rows }) else { return false }
        if let shift = damage.shift {
            guard translateRows(region: shift.region, delta: shift.delta) else {
                return false
            }
            // A translation is exact for interior bands -- overhanging glyph
            // ink rides the moved pixels -- but at the region's edges it
            // imports the wrong neighbor's spill and leaves the boundary
            // rows' own outward spill stale. Redrawing the two boundary rows
            // restores both, at the same O(1) cost as the cursor pair.
            indices.append(shift.region.lowerBound)
            indices.append(shift.region.upperBound - 1)
        }
        guard indices.isEmpty == false else { return true }

        // Byte-exactness needs two distinct row sets. The *erase* set is the
        // damage plus glyph halo: every band a damaged row's ink can reach is
        // refilled. The *plan* set is the erase set's own halo: every erased
        // band is rebuilt from all rows whose ink reaches it, so an undamaged
        // neighbor's overhang is redrawn rather than lost. (The folded view
        // seam erases and plans the same haloed set, which drops a neighbor's
        // sub-pixel spill; this store is held to the stricter contract.)
        let eraseDamage = TerminalDamage(rows: indices, rowCount: rows)
            .withGlyphHalo(rowCount: rows)
        let planDamage = eraseDamage.withGlyphHalo(rowCount: rows)
        context.saveGState()
        for span in eraseDamage.maximalContiguousSpans() {
            context.addRect(CGRect(
                x: 0,
                y: CGFloat(span.lowerBound) * metrics.cellSize.height,
                width: pointSize.width,
                height: CGFloat(span.count) * metrics.cellSize.height
            ))
        }
        context.clip()
        drawRenderFrame(clipFramePlan(plan, to: planDamage), metrics: metrics, in: context)
        context.restoreGState()
        return true
    }

    /// Moves the surviving rows of `region` by `delta`, leaving the vacated
    /// strip stale for the damaged-row render that follows. Refuses anything
    /// the recorded-shift contract forbids (`0 < abs(delta) < region.count`,
    /// region inside the grid) instead of trusting the producer.
    private func translateRows(region: Range<Int>, delta: Int) -> Bool {
        guard delta != 0,
              region.lowerBound >= 0,
              region.upperBound <= rows,
              abs(delta) < region.count
        else { return false }
        let survivorRows = region.count - abs(delta)
        let destinationRow = delta > 0 ? region.lowerBound + delta : region.lowerBound
        let sourceRow = delta > 0 ? region.lowerBound : region.lowerBound - delta
        let rowBytes = metrics.cellHeightPixels * bytesPerRow
        memmove(
            data + destinationRow * rowBytes,
            data + sourceRow * rowBytes,
            survivorRows * rowBytes
        )
        return true
    }

    /// Blits the store into `target` -- a flipped, point-space AppKit context
    /// -- covering exactly the frame rect, clipped to `rect`.
    ///
    /// The image wraps the store's memory without copying; CoreGraphics
    /// rasterizes synchronously inside this call, and the store mutates only
    /// on the main thread, so the borrow cannot outlive the pixels it names.
    public func blit(into target: CGContext, rect: CGRect) {
        guard rect.isEmpty == false else { return }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: data,
            size: byteCount,
            releaseData: { _, _, _ in }
        ), let image = CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        target.saveGState()
        target.clip(to: rect)
        // The target is flipped (top-left origin, y down); CGImage rows draw
        // bottom-up, so unflip around the frame rect for an exact 1:1 blit.
        target.translateBy(x: 0, y: pointSize.height)
        target.scaleBy(x: 1, y: -1)
        target.interpolationQuality = .none
        target.setBlendMode(.copy)
        target.draw(image, in: CGRect(origin: .zero, size: pointSize))
        target.restoreGState()
    }
}
