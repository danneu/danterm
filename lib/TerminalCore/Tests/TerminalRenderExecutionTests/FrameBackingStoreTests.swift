// The view half of research/33 T9's equivalence gate: a mirror store that
// realizes shift damage as translate-plus-damaged-render must stay
// byte-identical to a from-scratch full render, blitted, on every frame of
// every scenario D7 names -- below-budget and at-budget streaming, composed
// deltas, DECSTBM sub-regions, row-only damage, and the refusal paths that
// must leave the store untouched. Byte equality here is what replaces the
// live pixel proof F22 showed macOS can no longer offer.

import CoreGraphics
import IOSurface
import Testing

// @testable for the budget-bounded Terminal initializer the at-budget arm
// needs; everything else exercised here is the public seam.
@testable import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct FrameBackingStoreTests {
    private let line = "mirrored gjpqy content 0123456789 abcdefghijklmnopqrstuvwxyz"

    private var blockCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .block)
    }

    private var metrics: TerminalRenderMetrics {
        get throws { try #require(TerminalRenderMetrics(displayScale: 2)) }
    }

    /// Fills every viewport row, leaving the cursor at column 0 of the bottom row.
    private func prefill(_ terminal: inout Terminal, rows: Int) {
        var bytes: [UInt8] = []
        for _ in 0..<(rows - 1) { bytes += Array((line + "\r\n").utf8) }
        bytes += Array((line + "\r").utf8)
        terminal.feed(bytes)
    }

    private func blitBitmap(
        _ store: TerminalFrameBackingStore,
        plan: RenderFramePlan,
        metrics: TerminalRenderMetrics,
        rect: CGRect? = nil
    ) throws -> Bitmap {
        let size = try #require(renderFrameSize(for: plan, metrics: metrics))
        let surface = try BitmapSurface(size: size, metrics: metrics)
        let context = try #require(surface.context)
        store.blit(
            into: context,
            rect: rect ?? CGRect(origin: .zero, size: size.pointSize)
        )
        return surface.bitmap()
    }

    /// Feeds each step, drains its damage into the store, and asserts the
    /// blitted store equals a direct full render of the same frame. Returns
    /// how many drained frames carried a shift and how many the store applied
    /// incrementally, so scenarios cannot pass vacuously through the
    /// re-establish fallback.
    private func assertStoreEqualsFullRender(
        terminal: inout Terminal,
        steps: [[UInt8]],
        context: Comment
    ) throws -> (shifted: Int, applied: Int) {
        let metrics = try metrics
        _ = terminal.drainDamage()
        let initial = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: initial.columns,
            rows: initial.rows,
            metrics: metrics
        ))
        store.renderFull(initial)

        var shifted = 0
        var applied = 0
        for (index, bytes) in steps.enumerated() {
            terminal.feed(bytes)
            let damage = terminal.drainDamage()
            if damage.shift != nil { shifted += 1 }
            let plan = planFrame(for: terminal, presentation: blockCursor)
            if store.apply(plan: plan, damage: damage) {
                applied += 1
            } else {
                store.renderFull(plan)
            }
            let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
            let direct = try renderBitmap(plan: plan, metrics: metrics)
            if blitted.bytes != direct.bytes {
                Issue.record("\(context) diverged at step \(index), damage: \(damage)")
                return (shifted, applied)
            }
        }
        return (shifted, applied)
    }

    @Test("a full render blitted out equals drawing the plan directly")
    func renderFullBlitMatchesDirectRender() throws {
        // Intent: the blit is byte-transparent -- orientation, scale, pixel
        //   format, and color space all cancel out against direct drawing.
        // Why it exists: an upside-down or color-shifted blit passes any
        //   store-vs-store comparison; only direct drawing pins the seam.
        // Scenario: vertically asymmetric content (distinct rows, cursor at
        //   the bottom), full render into the store, one full-frame blit.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 24, rows: 6))
        prefill(&terminal, rows: 6)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: plan.columns,
            rows: plan.rows,
            metrics: metrics
        ))
        store.renderFull(plan)
        let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        #expect(blitted.bytes == direct.bytes)
    }

    @Test("below-budget streaming stays byte-identical through applied shifts")
    func belowBudgetStreaming() throws {
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let steps = (0..<30).map { _ in Array((line + "\r\n").utf8) }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "below-budget streaming"
        )
        #expect(result.shifted == 30)
        #expect(result.applied == 30)
    }

    @Test("at-budget streaming stays byte-identical while eviction freezes topRow")
    func atBudgetStreaming() throws {
        // The regime research/33 F19 flagged: append and arena eviction cancel
        // in `topRow` while content still translates; the drained shift must
        // realize on the store exactly as below budget.
        var terminal = try #require(Terminal(
            columns: 60,
            rows: 20,
            scrollbackBudgetBytes: 4096
        ))
        for _ in 0..<200 { terminal.feed(Array((line + "\r\n").utf8)) }
        let steps = (0..<60).map { _ in Array((line + "\r\n").utf8) }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "at-budget streaming"
        )
        #expect(result.shifted == 60)
        #expect(result.applied == 60)
    }

    @Test("a multi-line delivery composes into one applied shift")
    func composedShiftDelivery() throws {
        // Several scrolled lines drained as one value: the shift arrives with
        // |delta| > 1 plus the whole vacated strip, the T10-batched shape.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let burst = Array((line + "\r\n" + line + "\r\n" + line + "\r\n").utf8)
        let steps = (0..<10).map { _ in burst }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "composed delivery"
        )
        #expect(result.shifted == 10)
        #expect(result.applied == 10)
    }

    @Test("a DECSTBM footer survives sub-region translation byte-for-byte")
    func regionScrollWithPinnedFooter() throws {
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        prefill(&terminal, rows: 12)
        terminal.feed(Array("\u{1B}[1;9r\u{1B}[9;1H".utf8))
        let steps = (0..<20).map { _ in Array((line + "\r\n").utf8) }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "DECSTBM footer"
        )
        #expect(result.shifted == 20)
        #expect(result.applied == 20)
    }

    @Test("row-only damage renders in place without a translation")
    func rowDamageWithoutShift() throws {
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let steps = (0..<10).map { index in Array("edit \(index)".utf8) }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "row-only damage"
        )
        #expect(result.shifted == 0)
        #expect(result.applied == 10)
    }

    @Test("full damage and grid mismatch are refused with the store untouched")
    func refusalLeavesStoreIntact() throws {
        // Intent: apply's false return is a no-op, not a partial write.
        // Why it exists: the view maps false to "stale, fold this frame"; a
        //   half-applied store would then be re-trusted after the next full
        //   render of a *different* frame lineage.
        // Scenario: a valid store refuses `.full` and a differently-sized
        //   plan; its pixels still equal the frame it last rendered.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 24, rows: 6))
        prefill(&terminal, rows: 6)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: plan.columns,
            rows: plan.rows,
            metrics: metrics
        ))
        store.renderFull(plan)

        #expect(store.apply(plan: plan, damage: .full) == false)
        var other = try #require(Terminal(columns: 30, rows: 8))
        prefill(&other, rows: 8)
        let mismatched = planFrame(for: other, presentation: blockCursor)
        #expect(store.apply(
            plan: mismatched,
            damage: TerminalDamage(rows: [0], rowCount: 8)
        ) == false)

        let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        #expect(blitted.bytes == direct.bytes)
    }

    @Test("the surface memory itself holds the rendered frame")
    func surfaceMemoryHoldsTheFrame() throws {
        // Intent: the IOSurface the store owns is the frame -- reading its
        //   memory directly (BGRA, stride-aware) matches a direct render
        //   pixel-for-pixel.
        // Why it exists: the owned-surface route displays this memory as
        //   layer contents; a store that was only blit-correct could hide a
        //   wrong stride or byte order behind CoreGraphics' tolerant blit.
        // Scenario: asymmetric content rendered full; every pixel of the
        //   surface compared against the direct render, BGRA against RGBA.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 24, rows: 6))
        prefill(&terminal, rows: 6)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: plan.columns,
            rows: plan.rows,
            metrics: metrics
        ))
        store.renderFull(plan)
        let direct = try renderBitmap(plan: plan, metrics: metrics)

        let surface = store.ioSurface
        surface.lock(options: [.readOnly], seed: nil)
        defer { surface.unlock(options: [.readOnly], seed: nil) }
        let base = surface.baseAddress
        let stride = surface.bytesPerRow
        var mismatches = 0
        for y in 0..<direct.height {
            let row = base + y * stride
            for x in 0..<direct.width {
                let blue = row.load(fromByteOffset: x * 4, as: UInt8.self)
                let green = row.load(fromByteOffset: x * 4 + 1, as: UInt8.self)
                let red = row.load(fromByteOffset: x * 4 + 2, as: UInt8.self)
                let alpha = row.load(fromByteOffset: x * 4 + 3, as: UInt8.self)
                let expected = direct.pixel(x: x, yFromTop: y)
                if Pixel(red: red, green: green, blue: blue, alpha: alpha) != expected {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("a stride-padded surface stays byte-identical through applied shifts")
    func stridePaddedSurfaceHoldsGates() throws {
        // Intent: the byte-equality gate holds when the surface's row stride
        //   exceeds the tight width*4, including through translateRows.
        // Why it exists: IOSurface aligns bytesPerRow (128 bytes at time of
        //   writing); a store that assumed tight rows would shear every row
        //   after the first on almost every real grid width.
        // Scenario: a column count chosen so tight row bytes miss the
        //   platform's row alignment; streaming shifts apply on the padded
        //   store and every frame blits equal to a direct render.
        let metrics = try metrics
        let alignment = max(
            IOSurfaceGetPropertyAlignment(IOSurfacePropertyKey.bytesPerRow.rawValue as CFString),
            1
        )
        let columns = try #require(
            (20...27).first { ($0 * metrics.cellWidthPixels * 4) % alignment != 0 },
            "every candidate width is row-aligned; padding cannot be exercised"
        )
        var terminal = try #require(Terminal(columns: columns, rows: 8))
        prefill(&terminal, rows: 8)
        _ = terminal.drainDamage()
        let initial = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: columns,
            rows: 8,
            metrics: metrics
        ))
        #expect(store.ioSurface.bytesPerRow > columns * metrics.cellWidthPixels * 4)
        store.renderFull(initial)

        for step in 0..<10 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            let plan = planFrame(for: terminal, presentation: blockCursor)
            #expect(store.apply(plan: plan, damage: damage), "step \(step) refused")
            let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
            let direct = try renderBitmap(plan: plan, metrics: metrics)
            #expect(blitted.bytes == direct.bytes, "step \(step) diverged")
        }
    }

    @Test("a store brought current across missed generations equals a from-scratch render")
    func broughtCurrentAcrossMissedGenerations() throws {
        // Intent: damage the engine composed across several undisplayed
        //   frames applies to a stale store byte-exactly.
        // Why it exists: a swapchain buffer is generations stale when
        //   reacquired; bringing it current rides between-drain damage
        //   composition, and a composition error would show as a band of the
        //   old generation surviving under the new frame.
        // Scenario: the store renders frame 0; three two-line bursts feed
        //   with no drain between; the single composed drain applies and the
        //   store equals a from-scratch render of the final frame.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        _ = terminal.drainDamage()
        let initial = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: initial.columns,
            rows: initial.rows,
            metrics: metrics
        ))
        store.renderFull(initial)

        for _ in 0..<3 {
            terminal.feed(Array((line + "\r\n" + line + "\r\n").utf8))
        }
        let damage = terminal.drainDamage()
        #expect(damage.shift != nil)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        #expect(store.apply(plan: plan, damage: damage))
        let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        #expect(blitted.bytes == direct.bytes)
    }

    @Test("a clipped blit repaints only the requested rect")
    func clippedBlitLeavesOutsidePixelsAlone() throws {
        // Intent: the blit honors the caller's clip exactly, so AppKit's
        //   dirty-rect coarsening can never repaint beyond what draw(_:) was
        //   asked for.
        // Why it exists: the view blits into a context whose other rows hold
        //   the previous frame; a clip miss would be invisible in the
        //   full-frame tests.
        // Scenario: surface holds frame A, the store holds frame B, the blit
        //   is clipped to row 2; row 2 reads as B, every other row as A.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 24, rows: 6))
        prefill(&terminal, rows: 6)
        let previous = planFrame(for: terminal, presentation: blockCursor)
        terminal.feed(Array("changed".utf8))
        let current = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: current.columns,
            rows: current.rows,
            metrics: metrics
        ))
        store.renderFull(current)

        let size = try #require(renderFrameSize(for: current, metrics: metrics))
        let surface = try BitmapSurface(size: size, metrics: metrics)
        let context = try #require(surface.context)
        drawRenderFrame(previous, metrics: metrics, in: context)
        let clipRect = CGRect(
            x: 0,
            y: metrics.cellSize.height * 2,
            width: size.pointSize.width,
            height: metrics.cellSize.height
        )
        store.blit(into: context, rect: clipRect)
        let combined = surface.bitmap()

        let fullPrevious = try renderBitmap(plan: previous, metrics: metrics)
        let fullCurrent = try renderBitmap(plan: current, metrics: metrics)
        for row in 0..<6 {
            let rect = PixelRect(
                x: 0..<size.pixelWidth,
                y: row * metrics.cellHeightPixels..<(row + 1) * metrics.cellHeightPixels
            )
            let expected = row == 2 ? fullCurrent : fullPrevious
            #expect(
                combined.bytes(in: rect) == expected.bytes(in: rect),
                "row \(row)"
            )
        }
    }
}
