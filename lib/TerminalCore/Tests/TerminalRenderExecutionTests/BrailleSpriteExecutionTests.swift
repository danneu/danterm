// Behavioral and pixel proofs for executor-local Unicode braille sprites.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct BrailleSpriteExecutionTests {
    @Test("Braille layout is cell-local physical-pixel geometry")
    func cellLocalPhysicalPixelLayout() {
        let layout = BrailleSprite.layout(cellWidthPixels: 9, cellHeightPixels: 18)

        #expect(layout.dotWidth == 2)
        #expect(layout.dotHeight == 2)
        #expect(layout.xPositions == [1, 5])
        #expect(layout.yPositions == [1, 5, 10, 14])
        #expect(
            layout.rect(for: BrailleDot(column: 1, row: 2))
                == BraillePixelRect(x: 5, y: 10, width: 2, height: 2)
        )
    }

    @Test("Sprite membership is exactly one scalar in the Unicode braille block")
    func exactSupportedSet() {
        #expect(BrailleSprite.dots(for: ["\u{2800}"]) == [])
        #expect(BrailleSprite.dots(for: ["\u{28FF}"])?.count == 8)
        #expect(BrailleSprite.dots(for: ["\u{27FF}"]) == nil)
        #expect(BrailleSprite.dots(for: ["\u{2900}"]) == nil)
        #expect(BrailleSprite.dots(for: ["\u{1F600}"]) == nil)
        #expect(BrailleSprite.dots(for: ["\u{2801}", "\u{FE0F}"]) == nil)
    }

    @Test(
        "Each Unicode braille bit maps to its specified 2x4 dot",
        arguments: [
            BrailleBitSample(scalar: "\u{2801}", column: 0, row: 0),
            BrailleBitSample(scalar: "\u{2802}", column: 0, row: 1),
            BrailleBitSample(scalar: "\u{2804}", column: 0, row: 2),
            BrailleBitSample(scalar: "\u{2808}", column: 1, row: 0),
            BrailleBitSample(scalar: "\u{2810}", column: 1, row: 1),
            BrailleBitSample(scalar: "\u{2820}", column: 1, row: 2),
            BrailleBitSample(scalar: "\u{2840}", column: 0, row: 3),
            BrailleBitSample(scalar: "\u{2880}", column: 1, row: 3),
        ]
    )
    func unicodeDotLayout(sample: BrailleBitSample) {
        #expect(
            BrailleSprite.dots(for: [sample.scalar])
                == [BrailleDot(column: sample.column, row: sample.row)]
        )
    }

    @Test("Braille dots are pixel-aligned, contained, colored, and isolated", arguments: [1.0, 2.0])
    func bitmapGeometry(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let bitmap = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31m\u{28FF}", columns: 3, rows: 1),
            metrics: metrics
        )
        let spriteCell = cellRect(row: 0, column: 0, metrics: metrics)
        let adjacentCells = cellRect(
            row: 0,
            column: 1,
            columnCount: 2,
            metrics: metrics
        )
        let foreground = Pixel(RenderTheme.dark.ansiColors[1])
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let spritePixels = bitmap.pixels(in: spriteCell)

        #expect(spritePixels.contains(foreground))
        #expect(spritePixels.allSatisfy { $0 == foreground || $0 == background })
        #expect(bitmap.pixels(in: adjacentCells).allSatisfy { $0 == background })

        let rects = BrailleSprite.rects(
            for: "\u{28FF}",
            row: 0,
            column: 0,
            metrics: metrics
        )
        #expect(rects.count == 8)
        var expectedForegroundOffsets: Set<Int> = []
        for rect in rects {
            #expect(rect.minX * scale == (rect.minX * scale).rounded())
            #expect(rect.minY * scale == (rect.minY * scale).rounded())
            #expect(rect.maxX * scale == (rect.maxX * scale).rounded())
            #expect(rect.maxY * scale == (rect.maxY * scale).rounded())
            #expect(rect.minX >= 0)
            #expect(rect.minY >= 0)
            #expect(rect.maxX <= metrics.cellSize.width)
            #expect(rect.maxY <= metrics.cellSize.height)
            let xRange = Int(rect.minX * scale)..<Int(rect.maxX * scale)
            let yRange = Int(rect.minY * scale)..<Int(rect.maxY * scale)
            for y in yRange {
                for x in xRange {
                    expectedForegroundOffsets.insert(y * metrics.cellWidthPixels + x)
                }
            }
        }
        for y in spriteCell.y {
            for x in spriteCell.x {
                let offset = y * metrics.cellWidthPixels + x
                #expect(
                    bitmap.pixel(x: x, yFromTop: y)
                        == (expectedForegroundOffsets.contains(offset) ? foreground : background)
                )
            }
        }
    }

    @Test("Bold and italic leave braille sprite geometry unchanged", arguments: [1.0, 2.0])
    func traitsDoNotChangeGeometry(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let regular = try spriteCellBytes(input: "\u{28E4}", metrics: metrics)
        let bold = try spriteCellBytes(input: "\u{1B}[1m\u{28E4}", metrics: metrics)
        let italic = try spriteCellBytes(input: "\u{1B}[3m\u{28E4}", metrics: metrics)
        let boldItalic = try spriteCellBytes(
            input: "\u{1B}[1;3m\u{28E4}",
            metrics: metrics
        )

        #expect(bold == regular)
        #expect(italic == regular)
        #expect(boldItalic == regular)
    }

    @Test("Selection stays behind braille drawn with its resolved foreground")
    func selectionLayering() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[31m\u{28FF}".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        let bitmap = try renderBitmap(
            plan: planFrame(
                for: terminal,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: false,
                    cursorShape: .block
                )
            ),
            metrics: metrics
        )
        let pixels = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))

        #expect(pixels.contains(Pixel(RenderTheme.dark.selectionBackground)))
        #expect(pixels.contains(Pixel(RenderTheme.dark.ansiColors[1])))
    }

    @Test("A block cursor supplies braille background and foreground colors")
    func blockCursorLayering() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let bitmap = try renderBitmap(
            plan: makePlan(
                input: "\u{28FF}\u{1B}[1;1H",
                columns: 2,
                rows: 1,
                isCursorVisible: true
            ),
            metrics: metrics
        )
        let pixels = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))

        #expect(pixels.contains(Pixel(RenderTheme.dark.cursor)))
        #expect(pixels.contains(Pixel(RenderTheme.dark.cursorText)))
    }

    @Test("Underline and bar cursor overlays remain above braille")
    func cursorOverlayLayering() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        for shape in [TerminalCursorShape.underline, .bar] {
            let visible = try renderBitmap(
                plan: makePlan(
                    input: "\u{28FF}\u{1B}[1;1H",
                    columns: 2,
                    rows: 1,
                    isCursorVisible: true,
                    cursorShape: shape
                ),
                metrics: metrics
            )
            let hidden = try renderBitmap(
                plan: makePlan(
                    input: "\u{28FF}\u{1B}[1;1H",
                    columns: 2,
                    rows: 1,
                    isCursorVisible: false,
                    cursorShape: shape
                ),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)

            #expect(visible.bytes(in: cell) != hidden.bytes(in: cell))
            #expect(visible.pixels(in: cell).contains(Pixel(RenderTheme.dark.cursor)))
        }
    }

    @Test("A colored underline overwrites braille in its decoration band")
    func decorationLayering() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let bitmap = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[31;4;58:5:2m\u{28FF}",
                columns: 2,
                rows: 1
            ),
            metrics: metrics
        )
        let cell = cellRect(row: 0, column: 0, metrics: metrics)
        let underline = Pixel(RenderTheme.dark.ansiColors[2])
        let foreground = Pixel(RenderTheme.dark.ansiColors[1])

        #expect(bitmap.pixels(in: cell).contains(foreground))
        let underlineStart = Int((metrics.underlineOffset * metrics.displayScale).rounded())
        let underlineThickness = Int(
            (metrics.underlineThickness * metrics.displayScale).rounded()
        )
        for y in underlineStart..<underlineStart + underlineThickness {
            #expect(cell.x.allSatisfy { bitmap.pixel(x: $0, yFromTop: y) == underline })
        }
    }

    @Test("Braille damage-row and dirty-rect redraws match a fresh frame")
    func incrementalRedrawsMatchFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let previous = try makePlan(
            input: "\u{2801}\r\nkeep",
            columns: 4,
            rows: 2
        )
        let current = try makePlan(
            input: "\u{28FF}\r\nkeep",
            columns: 4,
            rows: 2
        )
        let full = try renderBitmap(plan: current, metrics: metrics)
        let damage = TerminalDamage(rows: [0])
        let dirtyRect = CGRect(
            x: 0,
            y: 0,
            width: metrics.cellSize.width * 4,
            height: metrics.cellSize.height
        )

        let damaged = try renderIncrementalBitmap(
            previous: previous,
            current: current,
            damage: damage,
            metrics: metrics
        )
        let dirty = try renderDirtyRectBitmap(
            previous: previous,
            current: current,
            dirtyRect: dirtyRect,
            metrics: metrics
        )

        #expect(damaged.bytes == full.bytes)
        #expect(dirty.bytes == full.bytes)
    }
}

struct BrailleBitSample: Sendable, CustomTestStringConvertible {
    let scalar: Unicode.Scalar
    let column: Int
    let row: Int

    var testDescription: String {
        "U+\(String(scalar.value, radix: 16, uppercase: true))"
    }
}

private func spriteCellBytes(
    input: String,
    metrics: TerminalRenderMetrics
) throws -> [UInt8] {
    let bitmap = try renderBitmap(
        plan: makePlan(input: input, columns: 2, rows: 1),
        metrics: metrics
    )
    return bitmap.bytes(in: cellRect(row: 0, column: 0, metrics: metrics))
}
