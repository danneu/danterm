// End-to-end executor proofs for determinism, cursor layers, and caller context ownership.
import CoreGraphics
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct ExecutorContractTests {
    @Test("Damage-row redraw is pixel-identical to a fresh full frame")
    func damageRedrawMatchesFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("old\r\nkeep\r\nlast".utf8))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
        let previous = planFrame(for: terminal, presentation: presentation)

        _ = terminal.drainDamage()
        terminal.feed(Array(
            "\u{1B}[2;1H\u{1B}[41;37;4:4;58:5:2mNEW"
                .appending("\r\n\u{1B}[4:5;58:2:1:2:3mEND").utf8
        ))
        let damage = terminal.drainDamage()
        let current = planFrame(for: terminal, presentation: presentation)

        let incremental = try renderIncrementalBitmap(
            previous: previous,
            current: current,
            damage: damage,
            metrics: metrics
        )
        let full = try renderBitmap(plan: current, metrics: metrics)

        #expect(damage == TerminalDamage(rows: [1, 2]))
        #expect(incremental.bytes == full.bytes)
    }

    @Test("Dirty-rect row clipping is pixel-identical to a fresh full frame")
    func dirtyRectRedrawMatchesFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("old\r\nkeep\r\nlast".utf8))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
        let previous = planFrame(for: terminal, presentation: presentation)

        terminal.feed(Array("\u{1B}[2;1H\u{1B}[41;37;4mNEW".utf8))
        let current = planFrame(for: terminal, presentation: presentation)
        let dirtyRect = CGRect(
            x: 0,
            y: metrics.cellSize.height,
            width: metrics.cellSize.width * 5,
            height: metrics.cellSize.height
        )

        let incremental = try renderDirtyRectBitmap(
            previous: previous,
            current: current,
            dirtyRect: dirtyRect,
            metrics: metrics
        )
        let full = try renderBitmap(plan: current, metrics: metrics)

        #expect(incremental.bytes == full.bytes)
    }

    @Test("Full-grid dirty rect uses the complete frame plan")
    func fullGridDirtyRectRedrawMatchesFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("old\r\nkeep\r\nlast".utf8))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
        let previous = planFrame(for: terminal, presentation: presentation)

        terminal.feed(Array("\u{1B}[H\u{1B}[44;37mwhole frame changed".utf8))
        let current = planFrame(for: terminal, presentation: presentation)
        let frameSize = try #require(renderFrameSize(for: current, metrics: metrics))

        let incremental = try renderDirtyRectBitmap(
            previous: previous,
            current: current,
            dirtyRect: CGRect(origin: .zero, size: frameSize.pointSize),
            metrics: metrics
        )
        let full = try renderBitmap(plan: current, metrics: metrics)

        #expect(incremental.bytes == full.bytes)
    }

    @Test("Rendering styled fallback content cannot alter regular-face metrics")
    func renderingDoesNotAlterMetrics() throws {
        let before = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[1mB\u{1B}[3mI\u{1B}[0m中😀",
            columns: 8,
            rows: 1
        )

        _ = try renderBitmap(plan: plan, metrics: before)

        let after = try #require(TerminalRenderMetrics(displayScale: 2))
        #expect(after == before)
        #expect(
            cellRect(row: 0, column: 2, columnCount: 2, metrics: before).x.count
                == before.cellWidthPixels * 2
        )
    }

    @Test("A visible block cursor preserves its planned colors and grid isolation")
    func visibleCursorUsesPlannedPresentation() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "A\u{1B}[1;1H",
            columns: 3,
            rows: 1,
            isCursorVisible: true
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let cursorCell = cellRect(row: 0, column: 0, metrics: metrics)
        let cursorPixels = bitmap.pixels(in: cursorCell)
        let cursorColor = Pixel(RenderTheme.dark.cursor)

        #expect(cursorPixels.contains(cursorColor))
        #expect(
            cursorPixels.contains { $0 != cursorColor },
            "Cursor-text glyph ink must remain visible over the block."
        )
        #expect(
            bitmap.pixels(in: cellRect(
                row: 0,
                column: 1,
                columnCount: 2,
                metrics: metrics
            )).allSatisfy { $0 == Pixel(RenderTheme.dark.defaultBackground) }
        )
    }

    @Test("A wide cursor block occupies exactly two grid cells")
    func wideCursorUsesExactGridSpan() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[8m中\u{1B}[1;2H",
            columns: 3,
            rows: 1,
            isCursorVisible: true
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let wideSpan = cellRect(
            row: 0,
            column: 0,
            columnCount: 2,
            metrics: metrics
        )

        #expect(wideSpan.x.count == metrics.cellWidthPixels * 2)
        #expect(
            bitmap.pixels(in: wideSpan).allSatisfy { $0 == Pixel(RenderTheme.dark.cursor) }
        )
        #expect(
            bitmap.pixels(in: cellRect(
                row: 0,
                column: 2,
                metrics: metrics
            )).allSatisfy { $0 == Pixel(RenderTheme.dark.defaultBackground) }
        )
    }

    @Test("Underline and bar cursors use pixel-aligned overlays at every supported scale")
    func cursorOverlayGeometry() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
            for shape in [TerminalCursorShape.underline, .bar] {
                let plan = try makePlan(
                    input: "A\u{1B}[1;1H",
                    columns: 3,
                    rows: 1,
                    isCursorVisible: true,
                    cursorShape: shape
                )
                let bitmap = try renderBitmap(plan: plan, metrics: metrics)
                let hiddenPlan = try makePlan(
                    input: "A\u{1B}[1;1H",
                    columns: 3,
                    rows: 1,
                    isCursorVisible: false,
                    cursorShape: shape
                )
                let hiddenBitmap = try renderBitmap(plan: hiddenPlan, metrics: metrics)
                let cursorRect = cellRect(row: 0, column: 0, metrics: metrics)
                let neighborRect = cellRect(
                    row: 0,
                    column: 1,
                    columnCount: 2,
                    metrics: metrics
                )
                let cursorColor = Pixel(RenderTheme.dark.cursor)
                let cursorPixels = bitmap.pixels(in: cursorRect)

                #expect(cursorPixels.contains(cursorColor))
                #expect(cursorPixels.contains { $0 != cursorColor })
                #expect(bitmap.pixels(in: neighborRect).allSatisfy {
                    $0 == Pixel(RenderTheme.dark.defaultBackground)
                })

                let cursorRows = bitmap.inkRows(in: cursorRect)
                switch shape {
                case .underline:
                    #expect(cursorRows.last == cursorRect.y.last)
                    #expect(cursorRows.count < metrics.cellHeightPixels)
                    let overlayStart = cursorRect.y.upperBound
                        - Int((metrics.underlineThickness * scale).rounded())
                    for y in cursorRect.y.lowerBound..<overlayStart {
                        for x in cursorRect.x {
                            #expect(
                                bitmap.pixel(x: x, yFromTop: y)
                                    == hiddenBitmap.pixel(x: x, yFromTop: y)
                            )
                        }
                    }
                case .bar:
                    let cursorColumns = cursorRect.x.filter { x in
                        cursorRect.y.contains { y in
                            bitmap.pixel(x: x, yFromTop: y) == cursorColor
                        }
                    }
                    #expect(cursorColumns.first == cursorRect.x.first)
                    #expect(cursorColumns.count < metrics.cellWidthPixels)
                    let overlayEnd = cursorRect.x.lowerBound
                        + Int((metrics.underlineThickness * scale).rounded())
                    for y in cursorRect.y {
                        for x in overlayEnd..<cursorRect.x.upperBound {
                            #expect(
                                bitmap.pixel(x: x, yFromTop: y)
                                    == hiddenBitmap.pixel(x: x, yFromTop: y)
                            )
                        }
                    }
                case .block:
                    Issue.record("Unexpected block cursor in overlay geometry proof")
                }
            }
        }
    }

    @Test("Cursor overlay phase redraws match a fresh full frame for every shape")
    func cursorOverlayDamageRedrawMatchesFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A\r\nB\u{1B}[1;1H".utf8))

        for shape in [TerminalCursorShape.block, .underline, .bar] {
            let visible = planFrame(
                for: terminal,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: true,
                    cursorShape: shape
                )
            )
            let hidden = planFrame(
                for: terminal,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: false,
                    cursorShape: shape
                )
            )
            let damage = TerminalDamage(rows: [0])

            let hiddenIncremental = try renderIncrementalBitmap(
                previous: visible,
                current: hidden,
                damage: damage,
                metrics: metrics
            )
            let visibleIncremental = try renderIncrementalBitmap(
                previous: hidden,
                current: visible,
                damage: damage,
                metrics: metrics
            )
            let hiddenFull = try renderBitmap(plan: hidden, metrics: metrics)
            let visibleFull = try renderBitmap(plan: visible, metrics: metrics)

            #expect(hiddenIncremental.bytes == hiddenFull.bytes)
            #expect(visibleIncremental.bytes == visibleFull.bytes)
        }
    }

    @Test("Repeated rendering is byte deterministic")
    func repeatedRenderingIsDeterministic() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[44;1;3;4:3mA中😀",
            columns: 7,
            rows: 2,
            isCursorVisible: true
        )

        let first = try renderBitmap(plan: plan, metrics: metrics)
        let second = try renderBitmap(plan: plan, metrics: metrics)

        #expect(first.bytes == second.bytes)
    }

    @Test("Drawing restores CTM, text matrix, and a nonrectangular caller clip")
    func drawingRestoresCallerContext() throws {
        // Intent: prove the executor returns every caller-owned context state,
        //   including the exact shape of a clip rather than only its bounds.
        // Why it exists: clip bounding boxes can compare equal after a leaked
        //   rectangular clip even though later caller drawing is corrupted.
        // Scenario: a view clips terminal drawing to a triangular damage area,
        //   then draws an opaque sentinel through that same clip afterward.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(
            input: "\u{1B}[41;37;4mA",
            columns: 4,
            rows: 2
        )
        let size = try #require(renderFrameSize(for: plan, metrics: metrics))
        let subject = try BitmapSurface(size: size, metrics: metrics)
        let control = try BitmapSurface(size: size, metrics: metrics)
        let subjectContext = try #require(subject.context)
        let controlContext = try #require(control.context)
        applyTriangularClip(to: subjectContext, size: size.pointSize)
        applyTriangularClip(to: controlContext, size: size.pointSize)

        let callerTextMatrix = CGAffineTransform(
            a: 0.75,
            b: 0.125,
            c: -0.25,
            d: 1.25,
            tx: 3,
            ty: 4
        )
        subjectContext.textMatrix = callerTextMatrix
        controlContext.textMatrix = callerTextMatrix
        let callerCTM = subjectContext.ctm

        drawRenderFrame(plan, metrics: metrics, in: subjectContext)

        #expect(subjectContext.ctm == callerCTM)
        #expect(subjectContext.textMatrix == callerTextMatrix)

        try drawSentinel(in: subjectContext, size: size.pointSize)
        try drawSentinel(in: controlContext, size: size.pointSize)
        #expect(subject.bitmap().bytes == control.bitmap().bytes)
    }
}

private func applyTriangularClip(to context: CGContext, size: CGSize) {
    context.setShouldAntialias(false)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: size.width, y: size.height / 3))
    path.addLine(to: CGPoint(x: size.width / 3, y: size.height))
    path.closeSubpath()
    context.addPath(path)
    context.clip()
}

private func drawSentinel(in context: CGContext, size: CGSize) throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    context.setBlendMode(.copy)
    context.setFillColor(try #require(CGColor(
        colorSpace: colorSpace,
        components: [0.25, 0.5, 0.75, 1]
    )))
    context.fill(CGRect(origin: .zero, size: size))
}
