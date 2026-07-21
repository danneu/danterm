// Pixel-level proofs for terminal decoration geometry, continuity, layering, and containment.
import CoreGraphics
import Testing

import TerminalRenderExecution
import TerminalRenderPlanning

struct DecorationExecutionTests {
    @Test("Dotted and dashed underlines are distinct and contained", arguments: [1.0, 1.5, 2.0])
    func patternedUnderlineGeometry(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let dotted = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31;4:4m   ", columns: 4, rows: 2),
            metrics: metrics
        )
        let dashed = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31;4:5m   ", columns: 4, rows: 2),
            metrics: metrics
        )
        let span = cellRect(row: 0, column: 0, columnCount: 3, metrics: metrics)
        let dottedMask = inkMask(in: span, bitmap: dotted)
        let dashedMask = inkMask(in: span, bitmap: dashed)

        #expect(dottedMask != dashedMask)
        #expect(dotted.inkCount(in: span) > 0)
        #expect(dashed.inkCount(in: span) > dotted.inkCount(in: span))
        #expect(dotted.inkCount(in: cellRect(row: 1, column: 0, columnCount: 3, metrics: metrics)) == 0)
        #expect(dashed.inkCount(in: cellRect(row: 1, column: 0, columnCount: 3, metrics: metrics)) == 0)
    }

    @Test(
        "Straight decorations occupy their pixel-snapped bands",
        arguments: [
            DecorationSample(input: "\u{1B}[31;4m  ", expectedBand: .single),
            DecorationSample(input: "\u{1B}[31;21m  ", expectedBand: .double),
            DecorationSample(input: "\u{1B}[31;9m  ", expectedBand: .strikethrough),
        ]
    )
    func straightDecorationBands(sample: DecorationSample) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let bitmap = try renderBitmap(
            plan: makePlan(input: sample.input, columns: 3, rows: 2),
            metrics: metrics
        )
        let decoratedSpan = cellRect(
            row: 0,
            column: 0,
            columnCount: 2,
            metrics: metrics
        )
        let expectedColor = Pixel(RenderTheme.dark.ansiColors[1])
        let coloredRows = rowsContaining(
            expectedColor,
            in: decoratedSpan,
            bitmap: bitmap
        )
        let expectedRows = sample.expectedBand.rows(metrics: metrics)

        #expect(coloredRows == expectedRows)
        for y in decoratedSpan.y {
            for x in decoratedSpan.x {
                let expected = expectedRows.contains(y)
                    ? expectedColor
                    : Pixel(RenderTheme.dark.defaultBackground)
                #expect(bitmap.pixel(x: x, yFromTop: y) == expected)
            }
        }
        #expect(
            bitmap.inkCount(in: cellRect(
                row: 1,
                column: 0,
                columnCount: 2,
                metrics: metrics
            )) == 0,
            "Decoration ink must stay out of the next row."
        )
    }

    @Test("Curly underline varies vertically and keeps phase across color splits")
    func curlyUnderlineHasGlobalPhase() throws {
        // Intent: the wave shape is anchored to absolute grid x, even when a
        //   foreground change divides one visual underline into two runs.
        // Why it exists: restarting the sine phase per run creates a visible
        //   kink in otherwise continuous underlined terminal output.
        // Scenario: one underlined word changes from red to green midway while
        //   retaining the same curly underline style.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let continuous = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[31;4:3m    ",
                columns: 5,
                rows: 2
            ),
            metrics: metrics
        )
        let split = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[31;4:3m  \u{1B}[32m  ",
                columns: 5,
                rows: 2
            ),
            metrics: metrics
        )
        let decoratedSpan = cellRect(
            row: 0,
            column: 0,
            columnCount: 4,
            metrics: metrics
        )
        let continuousMask = inkMask(in: decoratedSpan, bitmap: continuous)
        let splitMask = inkMask(in: decoratedSpan, bitmap: split)
        let inkRows = split.inkRows(in: decoratedSpan)
        let cellWidth = metrics.cellWidthPixels
        let phaseZero = try curlyInkCenter(
            at: decoratedSpan.x.lowerBound,
            in: decoratedSpan,
            bitmap: continuous
        )
        let quarterPeriod = try curlyInkCenter(
            at: decoratedSpan.x.lowerBound + cellWidth / 4,
            in: decoratedSpan,
            bitmap: continuous
        )
        let halfPeriod = try curlyInkCenter(
            at: decoratedSpan.x.lowerBound + cellWidth / 2,
            in: decoratedSpan,
            bitmap: continuous
        )
        let threeQuarterPeriod = try curlyInkCenter(
            at: decoratedSpan.x.lowerBound + cellWidth * 3 / 4,
            in: decoratedSpan,
            bitmap: continuous
        )
        let thickness = metrics.underlineThickness * metrics.displayScale
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let continuousInk = continuous.pixels(in: decoratedSpan).filter { $0 != background }

        #expect(continuousMask == splitMask)
        #expect(inkRows.count >= 2, "Curly underline rows: \(inkRows)")
        #expect(quarterPeriod > phaseZero)
        #expect(threeQuarterPeriod < phaseZero)
        #expect(abs(halfPeriod - phaseZero) <= 1)
        #expect(quarterPeriod - threeQuarterPeriod >= thickness)
        #expect(continuousInk.isEmpty == false)
        #expect(continuousInk.allSatisfy { $0.red > 0 && $0.green == 0 && $0.blue == 0 })
        #expect(
            split.inkCount(in: cellRect(row: 1, column: 0, columnCount: 4, metrics: metrics)) == 0,
            "Curly decoration ink must stay out of the next row."
        )
    }

    @Test("Decorations overwrite glyph ink because they draw last")
    func decorationDrawsAfterText() throws {
        // Intent: prove the final solid underline replaces antialiased glyph
        //   coverage where an underscore and its decoration overlap.
        // Why it exists: the same resolved color feeds both layers, so mere
        //   ink presence cannot distinguish the required drawing order.
        // Scenario: an underlined underscore reaches the underline band in a
        //   styled command prompt.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plain = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31m_", columns: 2, rows: 1),
            metrics: metrics
        )
        let decorated = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31;4m_", columns: 2, rows: 1),
            metrics: metrics
        )
        let foreground = Pixel(RenderTheme.dark.ansiColors[1])
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let band = DecorationBand.single.rows(metrics: metrics)
        let overlappingPixel = try #require(
            cellRect(row: 0, column: 0, metrics: metrics).x.lazy.flatMap { x in
                band.lazy.map { y in (x, y) }
            }.first { x, y in
                let pixel = plain.pixel(x: x, yFromTop: y)
                return pixel != background && pixel != foreground
            },
            "The underscore must provide antialiased ink in the underline band."
        )

        #expect(decorated.pixel(
            x: overlappingPixel.0,
            yFromTop: overlappingPixel.1
        ) == foreground)
    }
}

struct DecorationSample: Sendable, CustomTestStringConvertible {
    let input: String
    let expectedBand: DecorationBand

    var testDescription: String { String(describing: expectedBand) }
}

enum DecorationBand: Sendable {
    case single
    case double
    case strikethrough

    func rows(metrics: TerminalRenderMetrics) -> [Int] {
        let scale = metrics.displayScale
        let thickness = Int((metrics.underlineThickness * scale).rounded())
        let primary = Int((metrics.underlineOffset * scale).rounded())
        let strike = Int((metrics.strikethroughOffset * scale).rounded())
        switch self {
        case .single:
            return Array(primary..<primary + thickness)
        case .double:
            let upper = primary - thickness * 2
            return Array(upper..<upper + thickness) + Array(primary..<primary + thickness)
        case .strikethrough:
            return Array(strike..<strike + thickness)
        }
    }
}

private func rowsContaining(_ pixel: Pixel, in rect: PixelRect, bitmap: Bitmap) -> [Int] {
    rect.y.filter { y in
        rect.x.contains { x in bitmap.pixel(x: x, yFromTop: y) == pixel }
    }
}

private func inkMask(in rect: PixelRect, bitmap: Bitmap) -> [Bool] {
    let background = Pixel(RenderTheme.dark.defaultBackground)
    return rect.y.flatMap { y in
        rect.x.map { x in bitmap.pixel(x: x, yFromTop: y) != background }
    }
}

private func curlyInkCenter(at x: Int, in rect: PixelRect, bitmap: Bitmap) throws -> CGFloat {
    try #require(rect.x.contains(x))
    let background = Pixel(RenderTheme.dark.defaultBackground)
    let rows = rect.y.filter { bitmap.pixel(x: x, yFromTop: $0) != background }
    try #require(rows.isEmpty == false)
    return CGFloat(rows.reduce(0, +)) / CGFloat(rows.count)
}
