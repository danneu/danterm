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
        var planner = PaneFramePlanner()
        let initial = planner.planFrame(
            for: terminal,
            searchReadout: terminal.searchReadout,
            presentation: blockCursor,
            damage: .full
        )
        let store = try #require(TerminalFrameBackingStore(
            columns: initial.columns,
            rows: initial.rowCount,
            metrics: metrics
        ))
        store.renderFull(initial)

        var shifted = 0
        var applied = 0
        for (index, bytes) in steps.enumerated() {
            terminal.feed(bytes)
            let damage = terminal.drainDamage()
            if damage.shift != nil { shifted += 1 }
            let plan = planner.planFrame(
                for: terminal,
                searchReadout: terminal.searchReadout,
                presentation: blockCursor,
                damage: damage
            )
            if store.apply(plan: plan, damage: damage) {
                applied += 1
            } else {
                store.renderFull(plan)
            }
            let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
            let direct = try renderBitmap(plan: plan, metrics: metrics)
            guard expectBitmap(
                blitted,
                matches: direct,
                "\(context) diverged at step \(index), damage: \(damage)"
            ) else {
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
            rows: plan.rowCount,
            metrics: metrics
        ))
        store.renderFull(plan)
        let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        expectBitmap(blitted, matches: direct)
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

    @Test("streaming mixed sprite, accent, and ASCII rows stays byte-identical")
    func mixedContentStreaming() throws {
        // Intent: the derived halo's per-row reach classes (research/33 T14)
        //   hold byte-exact when general-class rows -- accents from the wider
        //   cmap, sprite scalars -- scroll past ASCII rows and sit beside
        //   damage.
        // Why it exists: a reach classifier that under-reads a non-ASCII
        //   row's ink would drop that ink exactly at the class boundary, a
        //   defect only content mixing can surface.
        // Scenario: alternating ASCII and mixed lines (e-acute, box drawing,
        //   blocks) stream through a full screen, one line per step.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let mixed = "caf\u{E9} \u{2500}\u{2500}\u{2502} \u{2588}\u{2593} gjpqy \u{E9}\u{E8}"
        let steps = (0..<20).map { index in
            Array(((index.isMultiple(of: 2) ? line : mixed) + "\r\n").utf8)
        }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "mixed-content streaming"
        )
        #expect(result.shifted == 20)
        #expect(result.applied == 20)
    }

    @Test("pure sprite rows stream and edit byte-identically")
    func spriteOnlyStreamingAndEditing() throws {
        // Intent: rows whose every cell is a sprite stay byte-exact through
        //   scrolling and in-place edits once the planner prices them at the
        //   band their families declare.
        // Why it exists: this is the only suite that runs the reach ledger end
        //   to end, so a family that overscanned its cell while declaring the
        //   band would show here as a byte difference rather than as stale
        //   pixels nobody notices.
        // Scenario: box drawing, blocks, braille, and geometric shapes stream
        //   a full screen, then one row is rewritten in place twice.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        let sprites = "\u{2554}\u{2550}\u{2557}\u{2502}\u{253C}"
            + "\u{2588}\u{2593}\u{2591}\u{2580}\u{2584}"
            + "\u{28FF}\u{2801}\u{28A5}\u{25E2}\u{25FF}"
        for _ in 0..<20 { terminal.feed(Array((sprites + "\r\n").utf8)) }
        let streaming = (0..<12).map { _ in Array((sprites + "\r\n").utf8) }
        let edits: [[UInt8]] = [
            Array("\u{1B}[9;1H\u{2500}\u{2500}\u{2588}\u{28FF}\u{1B}[K".utf8),
            Array("\u{1B}[9;1H\u{2502}\u{2591}\u{2801}\u{1B}[K".utf8),
        ]
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: streaming + edits,
            context: "sprite-only streaming and editing"
        )
        #expect(result.shifted == 12)
        #expect(result.applied == 14)
    }

    @Test("colored backgrounds and underlines beside damage stay byte-identical")
    func decoratedNeighborsOfDamage() throws {
        // Intent: a row whose only content is a band layer -- background
        //   fill, underline -- is replanned whenever the erase region
        //   touches its band, including the sub-cell descender band below a
        //   damaged ASCII row.
        // Why it exists: T14's erase can end a few pixels inside a
        //   neighbor's band; refilling those pixels with default background
        //   instead of the neighbor's own layers would show as a pinstripe
        //   under exactly this content.
        // Scenario: a colored-background row and an underlined row bracket a
        //   plain row; the plain row and each neighbor are edited in turn.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let steps: [[UInt8]] = [
            Array("\u{1B}[10;1H\u{1B}[44mblue background row\u{1B}[49m\u{1B}[K".utf8),
            Array("\u{1B}[12;1H\u{1B}[4munderlined gjpqy row\u{1B}[24m\u{1B}[K".utf8),
            Array("\u{1B}[11;1Hedited between decorated rows gjpqy".utf8),
            Array("\u{1B}[10;24H\u{1B}[44m more\u{1B}[49m".utf8),
            Array("\u{1B}[12;24H\u{1B}[4m more\u{1B}[24m".utf8),
            Array("\u{1B}[13;1Hrow below the underline gjpqy".utf8),
        ]
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "decorated neighbors"
        )
        #expect(result.shifted == 0)
        #expect(result.applied == 6)
    }

    @Test("a row transitioning between ASCII and accented content stays byte-identical")
    func reachClassTransitions() throws {
        // Intent: the store's reach ledger follows content transitions, so a
        //   row rewritten from accented to ASCII still erases the stale
        //   accent's full-cell reach, and back again.
        // Why it exists: deriving the erase from the new content alone would
        //   leave the old class's ink outside the new class's band -- the
        //   ledger exists for exactly this step.
        // Scenario: one row alternates ASCII, accented, box-drawing, ASCII;
        //   each rewrite is a row-damage apply on the previous content.
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        let rewrites = [
            "plain gjpqy start",
            "\u{C0}\u{C9} accented \u{E9}\u{E8} tall",
            "\u{2554}\u{2550}\u{2550} box \u{2550}\u{2557}",
            "plain gjpqy again",
        ]
        let steps = rewrites.map { Array("\u{1B}[8;1H\($0)\u{1B}[K".utf8) }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "reach class transitions"
        )
        #expect(result.shifted == 0)
        #expect(result.applied == 4)
    }

    @Test("accented rows bracketing a DECSTBM region survive both scroll directions")
    func generalNeighborsOfRegionScroll() throws {
        // Intent: a translation beside general-class rows leaves no stale
        //   spill at the moved block's edges -- the imported and outward
        //   strips the pre-move reach ledger prices (research/33 T14).
        // Why it exists: an accented row just outside a scroll region paints
        //   up to a full cell into the region's edge band; a translation that
        //   only re-rendered the region's boundary rows would ghost that ink
        //   one row over in four distinct edge cases (each scroll direction,
        //   each region edge).
        // Scenario: rows 3 and 11 (1-based) hold ink that measurably escapes
        //   the cell on the shipped font (U+01FA +1.4 px above at 2x,
        //   U+1E01 +2.35 px below), the region is rows 4..10, escaping rows
        //   also feed through the region, and the region scrolls up (newline
        //   at its bottom) then down (RI at its top) repeatedly.
        var terminal = try #require(Terminal(columns: 60, rows: 12))
        prefill(&terminal, rows: 12)
        let tall = "\u{01FA}\u{1EAA} tall \u{1E01} deep gjpqy \u{01FA}\u{1E01}"
        terminal.feed(Array("\u{1B}[3;1H\(tall)\u{1B}[K".utf8))
        terminal.feed(Array("\u{1B}[11;1H\(tall)\u{1B}[K".utf8))
        terminal.feed(Array("\u{1B}[4;10r".utf8))
        var steps: [[UInt8]] = []
        for index in 0..<8 {
            let fed = index.isMultiple(of: 2) ? tall : "up \(index) gjpqy"
            steps.append(Array("\u{1B}[10;1H\(fed)\u{1B}[K\r\n".utf8))
            // Cursor-neutral scrolls (SU/SD with the cursor parked
            // mid-region): neither the vacated row's rewrite nor the cursor
            // pair's damage can mask a stale strip at the moved block's
            // edges, so escaped ink left there survives to the comparison.
            steps.append(Array("\u{1B}[7;1H\u{1B}[S".utf8))
            steps.append(Array("\u{1B}[T".utf8))
            steps.append(Array("\u{1B}[4;1H\u{1B}Mdown \(index) gjpqy\u{1B}[K".utf8))
        }
        let result = try assertStoreEqualsFullRender(
            terminal: &terminal,
            steps: steps,
            context: "general neighbors of a region scroll"
        )
        #expect(result.shifted == 32)
        #expect(result.applied == 32)
    }

    @Test("full damage, a grid mismatch, and an out-of-grid row are refused with the store untouched")
    func refusalLeavesStoreIntact() throws {
        // Intent: apply's false return is a no-op, not a partial write.
        // Why it exists: the view maps false to "stale, fold this frame"; a
        //   half-applied store would then be re-trusted after the next full
        //   render of a *different* frame lineage.
        // Scenario: a valid store refuses `.full`, a differently-sized plan,
        //   and damage sized to a taller grid that names a row the store does
        //   not have; its pixels still equal the frame it last rendered.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 24, rows: 6))
        prefill(&terminal, rows: 6)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let store = try #require(TerminalFrameBackingStore(
            columns: plan.columns,
            rows: plan.rowCount,
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
        #expect(store.apply(
            plan: plan,
            damage: TerminalDamage(rows: [1, 7], rowCount: 8)
        ) == false)

        let blitted = try blitBitmap(store, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        expectBitmap(blitted, matches: direct)
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
            rows: plan.rowCount,
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
            expectBitmap(blitted, matches: direct, "step \(step) diverged")
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
            rows: initial.rowCount,
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
        expectBitmap(blitted, matches: direct)
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
            rows: current.rowCount,
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
