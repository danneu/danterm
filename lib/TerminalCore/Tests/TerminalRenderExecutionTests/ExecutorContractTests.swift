// End-to-end executor proofs for determinism, cursor layers, and caller context ownership.
import CoreGraphics
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct ExecutorContractTests {
    @Test("Row-restricted drawing matches the same rows of a whole-frame draw")
    func rowRestrictedDrawingMatchesWholeFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("plain\r\n\u{1B}[41;4mB\u{1B}[0m\r\n\u{4E2D}\u{1B}[2;1H".utf8))
        terminal.setSelection(.init(
            start: .init(row: 1, column: 0),
            end: .init(row: 1, column: 1)
        ))
        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: .dark, isCursorVisible: true, cursorShape: .block)
        )
        let restrictions: [Set<Int>] = [
            Set(0..<plan.rowCount),
            [],
            [1],
            [0, 1, plan.rowCount],
        ]

        for rows in restrictions {
            let restricted = try renderRows(plan: plan, rows: rows, metrics: metrics)
            let whole = try renderRows(plan: plan, rows: rows, metrics: metrics, unrestricted: true)
            expectBitmap(restricted, matches: whole, "rows \(rows.sorted())")
        }
    }

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
        expectBitmap(incremental, matches: full)
    }

    @Test("Shift-damage redraw of a scrolled screen is pixel-identical to a fresh full frame")
    func shiftDamageRedrawMatchesFullFrame() throws {
        // Intent: research/33 T9's bitmap-equivalence gate at the drawing seam --
        //   an incrementally redrawn scrolled screen matches a full redraw bit
        //   for bit, for a whole-viewport scroll and a DECSTBM sub-region one.
        // Why it exists: the drained value now carries `(region, delta)` instead
        //   of whole-region rows, and the drawer (pre view-half) must recover the
        //   full repaint by folding the shift; a fold that under-covers shows up
        //   here as stale pixels, not as a test-only inequality.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: true,
            cursorShape: .block
        )
        let scripts: [(name: String, prefix: [UInt8], scroll: [UInt8])] = [
            (
                name: "whole-viewport",
                prefix: Array("one\r\ntwo\r\nthree".utf8),
                scroll: Array("\r\nfour".utf8)
            ),
            (
                name: "sub-region",
                prefix: Array("one\r\ntwo\r\nthree\u{1B}[1;2r\u{1B}[2;1H".utf8),
                scroll: Array("\r\nmid".utf8)
            ),
        ]
        for script in scripts {
            var terminal = try #require(Terminal(columns: 5, rows: 3))
            terminal.feed(script.prefix)
            let previous = planFrame(for: terminal, presentation: presentation)

            _ = terminal.drainDamage()
            terminal.feed(script.scroll)
            let damage = terminal.drainDamage()
            #expect(damage.shift != nil, "\(script.name) did not scroll")
            let current = planFrame(for: terminal, presentation: presentation)

            let incremental = try renderIncrementalBitmap(
                previous: previous,
                current: current,
                damage: damage,
                metrics: metrics
            )
            let full = try renderBitmap(plan: current, metrics: metrics)
            expectBitmap(incremental, matches: full, "\(script.name)")
        }
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

        expectBitmap(incremental, matches: full)
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

        expectBitmap(incremental, matches: full)
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

            expectBitmap(hiddenIncremental, matches: hiddenFull)
            expectBitmap(visibleIncremental, matches: visibleFull)
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

        expectBitmap(first, matches: second)
    }

    @Test("Non-text sRGB colors convert identically in a Display P3 destination")
    func nonTextColorsRetainSRGBMeaningInDisplayP3() throws {
        // Intent: every non-text layer keeps its sRGB meaning when the destination
        //   bitmap uses Display P3, including both fill and stroke decorations.
        // Why it exists: component setters interpret values in the context's current
        //   color space, so adopting the destination space silently changes pixels.
        // Scenario: a frame combines a truecolor background, selection overlay,
        //   curly underline plus strikethrough, and a block cursor in one P3 bitmap.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array(
            "\u{1B}[48;2;241;19;43m "
                .appending("\u{1B}[0m ")
                .appending("\u{1B}[38;2;29;217;83;58;2;31;97;239;4:3;9m ")
                .appending("\u{1B}[0m \u{1B}[1;4H").utf8
        ))
        terminal.setSelection(.init(
            start: .init(row: 0, column: 1),
            end: .init(row: 0, column: 2)
        ))
        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: .dark, isCursorVisible: true, cursorShape: .block)
        )
        let size = try #require(renderFrameSize(for: plan, metrics: metrics))
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let subject = try BitmapSurface(size: size, metrics: metrics, colorSpace: displayP3)
        let reference = try BitmapSurface(size: size, metrics: metrics, colorSpace: displayP3)
        let subjectContext = try #require(subject.context)
        let referenceContext = try #require(reference.context)

        drawRenderFrame(plan, metrics: metrics, in: subjectContext)
        try drawReferenceNonTextLayers(plan, metrics: metrics, in: referenceContext)

        let truecolor = try #require(plan.rows.first?.backgroundRuns.first)
        let convertedPixel = reference.bitmap().pixel(
            x: truecolor.startColumn * metrics.cellWidthPixels,
            yFromTop: 0
        )
        #expect(convertedPixel != Pixel(truecolor.color))
        expectBitmap(subject.bitmap(), matches: reference.bitmap())
    }

    @Test("Drawing restores CTM, text matrix, clip, and component color spaces")
    func drawingRestoresCallerContext() throws {
        // Intent: prove the executor returns every caller-owned context state,
        //   including the exact clip shape and fill and stroke color spaces.
        // Why it exists: clip bounding boxes can compare equal after a leaked
        //   rectangular clip, while object colors cannot reveal a leaked space.
        // Scenario: a view clips terminal drawing to a triangular damage area,
        //   then draws raw-component fill and stroke sentinels through it afterward.
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
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        applyTriangularClip(to: subjectContext, size: size.pointSize)
        applyTriangularClip(to: controlContext, size: size.pointSize)
        subjectContext.setFillColorSpace(displayP3)
        subjectContext.setStrokeColorSpace(displayP3)
        controlContext.setFillColorSpace(displayP3)
        controlContext.setStrokeColorSpace(displayP3)

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

        drawComponentSentinel(in: subjectContext, size: size.pointSize)
        drawComponentSentinel(in: controlContext, size: size.pointSize)
        expectBitmap(subject.bitmap(), matches: control.bitmap())
    }
}

private func renderRows(
    plan: RenderFramePlan,
    rows: Set<Int>,
    metrics: TerminalRenderMetrics,
    unrestricted: Bool = false
) throws -> Bitmap {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let surface = try BitmapSurface(size: size, metrics: metrics)
    let context = try #require(surface.context)
    let validRows = rows.filter { plan.rowCount > $0 && $0 >= 0 }
    for row in validRows {
        context.addRect(CGRect(
            x: 0,
            y: CGFloat(row) * metrics.cellSize.height,
            width: size.pointSize.width,
            height: metrics.cellSize.height
        ))
    }
    if validRows.isEmpty {
        context.clip(to: .zero)
    } else {
        context.clip()
    }
    if unrestricted {
        drawRenderFrame(plan, metrics: metrics, in: context)
    } else {
        drawRenderFrame(
            plan,
            restrictedTo: TerminalDamage(rows: rows),
            metrics: metrics,
            in: context
        )
    }
    return surface.bitmap()
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

private func drawComponentSentinel(in context: CGContext, size: CGSize) {
    context.setBlendMode(.copy)
    context.setFillColor([0.25, 0.5, 0.75, 1])
    context.fill(CGRect(origin: .zero, size: size))

    context.setStrokeColor([0.8, 0.3, 0.1, 1])
    context.setLineWidth(2)
    context.stroke(CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
}

private func drawReferenceNonTextLayers(
    _ plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    in context: CGContext
) throws {
    let size = try #require(renderFrameSize(for: plan, metrics: metrics))
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    func color(_ value: RenderColor) throws -> CGColor {
        try #require(CGColor(
            colorSpace: sRGB,
            components: [
                CGFloat(value.red) / 255,
                CGFloat(value.green) / 255,
                CGFloat(value.blue) / 255,
                1,
            ]
        ))
    }
    func rect(row: Int, column: Int, count: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * metrics.cellSize.width,
            y: CGFloat(row) * metrics.cellSize.height,
            width: CGFloat(count) * metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    context.setBlendMode(.copy)
    context.setFillColor(try color(plan.defaultBackground))
    context.fill(CGRect(origin: .zero, size: size.pointSize))
    for row in plan.rows {
        for run in row.backgroundRuns {
            context.setFillColor(try color(run.color))
            context.fill(rect(row: run.row, column: run.startColumn, count: run.columnCount))
        }
    }
    for row in plan.rows {
        for run in row.overlayRuns {
            context.setFillColor(try color(run.color))
            context.fill(rect(row: run.row, column: run.startColumn, count: run.columnCount))
        }
    }
    if let cursor = plan.cursor, cursor.shape == .block {
        context.setFillColor(try color(cursor.color))
        context.fill(rect(row: cursor.row, column: cursor.column, count: cursor.columnWidth))
    }
    for row in plan.rows {
        for run in row.decorationRuns {
            let runRect = rect(row: run.row, column: run.startColumn, count: run.columnCount)
            context.saveGState()
            context.clip(to: runRect)
            context.setBlendMode(.copy)
            context.setFillColor(try color(run.color))
            context.setStrokeColor(try color(run.color))
            for kind in run.kinds {
                switch kind {
                case .underlineCurly:
                    drawReferenceCurlyUnderline(in: runRect, metrics: metrics, context: context)
                case .strikethrough:
                    context.setFillColor(try color(run.strikethroughColor))
                    context.fill(CGRect(
                        x: runRect.minX,
                        y: CGFloat(run.row) * metrics.cellSize.height
                            + metrics.strikethroughOffset,
                        width: runRect.width,
                        height: metrics.underlineThickness
                    ))
                default:
                    Issue.record("Unexpected decoration kind in Display P3 fixture: \(kind)")
                }
            }
            context.restoreGState()
        }
    }
}

private func drawReferenceCurlyUnderline(
    in runRect: CGRect,
    metrics: TerminalRenderMetrics,
    context: CGContext
) {
    let deviceStep = 1 / metrics.displayScale
    let amplitude = max(metrics.underlineThickness, deviceStep)
    let period = max(metrics.cellSize.width, deviceStep * 4)
    let centerY = runRect.minY + metrics.underlineOffset - amplitude
    let firstSample = Int((runRect.minX / deviceStep).rounded(.down)) - 1
    let lastSample = Int((runRect.maxX / deviceStep).rounded(.up)) + 1
    let path = CGMutablePath()
    for sample in firstSample...lastSample {
        let x = CGFloat(sample) * deviceStep
        let y = centerY + amplitude * sin(2 * .pi * x / period)
        if sample == firstSample {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    context.addPath(path)
    context.setLineWidth(metrics.underlineThickness)
    context.setLineCap(.butt)
    context.setLineJoin(.round)
    context.strokePath()
}
