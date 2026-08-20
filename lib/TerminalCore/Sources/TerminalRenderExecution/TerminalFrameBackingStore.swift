// The owned, translatable frame store behind research/33 T9's view half.
// AppKit's layer backing store cannot realize a translation (research/33 F22),
// so the pane view mirrors its last published frame here: a scroll becomes a
// row-range move in owned memory plus a damaged-row render, and the on-screen
// store is only ever a blit target. Validity policy stays with the view; this
// type holds pixels and geometry, nothing about when they may be trusted.
import CoreGraphics
import IOSurface
import TerminalCore
import TerminalRenderPlanning

/// Owns the pixels of one rendered frame at backing resolution so a recorded
/// scroll shift is realized as an exact row translation instead of a
/// region-wide glyph repaint.
///
/// The pixels live in an IOSurface so the render server can texture from
/// them directly when a layer displays the store as contents (research/33
/// T25); the row stride is therefore the surface's aligned `bytesPerRow`,
/// not the tight `width * 4`.
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

    /// The pixel memory itself. Callers may attach it as layer contents;
    /// they must never write it -- all mutation goes through this store, on
    /// the main thread, and only while the surface is detached and free.
    public let ioSurface: IOSurface

    private let pixelWidth: Int
    private let pixelHeight: Int
    private let bytesPerRow: Int
    private let byteCount: Int
    private let data: UnsafeMutableRawPointer
    private let context: CGContext
    private let colorSpace: CGColorSpace

    /// The vertical reach of the content each row's pixels currently show,
    /// kept in lockstep with the pixels (full renders reset it, applies update
    /// the damaged rows, translations move it with the memmove) so an
    /// incremental erase can cover the stale ink it is removing without
    /// assuming a full-row halo (research/33 T14, D9).
    private var rowReaches: [RenderRowReach?]

    /// Fails on non-positive geometry, an allocation IOSurface refuses, or a
    /// context CoreGraphics refuses, mirroring `renderFrameSize`'s overflow
    /// refusals.
    ///
    /// `colorSpace` defaults to sRGB; the view passes its window's space so
    /// displaying the surface is conversion-free and byte-equal to direct
    /// drawing.
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
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        guard let surface = IOSurface(properties: [
            .width: width.partialValue,
            .height: height.partialValue,
            .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
        ]) else { return nil }

        // BGRA in memory: premultiplied-first components in little-endian
        // 32-bit words, matching the surface's declared pixel format.
        guard let context = CGContext(
            data: surface.baseAddress,
            width: width.partialValue,
            height: height.partialValue,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
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
        bytesPerRow = surface.bytesPerRow
        byteCount = surface.bytesPerRow * height.partialValue
        ioSurface = surface
        data = surface.baseAddress
        self.context = context
        self.colorSpace = space
        rowReaches = Array(repeating: nil, count: rows)

        surface.lock(options: [], seed: nil)
        memset(data, 0, byteCount)
        surface.unlock(options: [], seed: nil)
    }

    /// Renders the complete plan, making every pixel current.
    public func renderFull(_ plan: RenderFramePlan) {
        precondition(
            plan.columns == columns && plan.rowCount == rows,
            "full render of a \(plan.columns)x\(plan.rowCount) plan into a \(columns)x\(rows) store"
        )
        ioSurface.lock(options: [], seed: nil)
        defer { ioSurface.unlock(options: [], seed: nil) }
        drawRenderFrame(plan, metrics: metrics, in: context)
        rowReaches = renderRowReaches(
            of: plan,
            envelope: metrics.asciiInkEnvelope,
            cellHeightPixels: metrics.cellHeightPixels
        )
    }

    /// Applies one published frame on top of pixels that hold the previous
    /// one: realizes the recorded shift as a row translation, then erases and
    /// re-renders exactly the pixels the damaged rows' bands and measured ink
    /// reach can occupy. Returns false without touching the store when the
    /// value cannot be realized exactly (full damage, grid mismatch, an
    /// out-of-range shift); the caller treats that as stale.
    public func apply(plan: RenderFramePlan, damage: TerminalDamage) -> Bool {
        guard plan.columns == columns, plan.rowCount == rows else { return false }
        guard damage.isFull == false else { return false }
        let indices = damage.rowIndices
        guard indices.allSatisfy({ $0 < rows }) else { return false }
        // CPU writes to IOSurface memory sit between lock and unlock so the
        // surface's seed advances and coherency with a later texture read
        // holds. `translateRows`'s refusal paths return before any mutation,
        // so unlocking through the defer is still a no-write unlock.
        ioSurface.lock(options: [], seed: nil)
        defer { ioSurface.unlock(options: [], seed: nil) }
        var staleStrips: [Range<Int>] = []
        if let shift = damage.shift {
            // A translation is exact for interior bands -- overhanging glyph
            // ink rides the moved pixels -- but at the moved block's edges it
            // imports the old neighborhood's spill and leaves its own spill
            // stale in unmoved neighbors. The strips price those four edges
            // exactly, from the reach ledger as it stands before the move.
            staleStrips = renderTranslationStaleStrips(
                region: shift.region,
                delta: shift.delta,
                cellHeightPixels: metrics.cellHeightPixels,
                reaches: rowReaches
            )
            guard translateRows(region: shift.region, delta: shift.delta) else {
                return false
            }
        }
        guard indices.isEmpty == false || staleStrips.isEmpty == false else { return true }

        // Byte-exactness in two derived sets (research/33 T14, D9). The erase
        // spans cover every pixel a damaged row's band, its stale ink (the
        // ledger), or its new ink (the plan) can occupy; the plan set is every
        // row whose ink reaches an erased pixel, so an undamaged neighbor's
        // overhang is redrawn rather than lost. On all-ASCII rows that is the
        // damaged rows plus a measured sub-cell band and the one neighbor
        // above; a row the envelope cannot vouch for falls back to the
        // full-row reach, so the worst case is the pre-T14 halo shape.
        let newReaches = renderRowReaches(
            of: plan,
            envelope: metrics.asciiInkEnvelope,
            cellHeightPixels: metrics.cellHeightPixels
        )
        let shape = renderApplyShape(
            damagedRows: indices,
            rowCount: rows,
            cellHeightPixels: metrics.cellHeightPixels,
            oldReaches: rowReaches,
            newReaches: newReaches,
            extraEraseIntervals: staleStrips
        )
        context.saveGState()
        for span in shape.erasePixelSpans {
            context.addRect(CGRect(
                x: 0,
                y: CGFloat(span.lowerBound) / metrics.displayScale,
                width: pointSize.width,
                height: CGFloat(span.count) / metrics.displayScale
            ))
        }
        context.clip()
        drawRenderFrame(
            plan,
            rows: shape.planDamage.expandingShift().rowIndices,
            metrics: metrics,
            in: context
        )
        context.restoreGState()
        for row in indices {
            rowReaches[row] = newReaches[row]
        }
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
        // The reach ledger moves with the pixels it describes; the vacated
        // strip keeps its stale entries, exactly as its pixels do, and both
        // are rebuilt by the damaged-row render that follows.
        let moved = Array(rowReaches[sourceRow..<(sourceRow + survivorRows)])
        rowReaches.replaceSubrange(
            destinationRow..<(destinationRow + survivorRows),
            with: moved
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

        ioSurface.lock(options: [.readOnly], seed: nil)
        defer { ioSurface.unlock(options: [.readOnly], seed: nil) }
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
