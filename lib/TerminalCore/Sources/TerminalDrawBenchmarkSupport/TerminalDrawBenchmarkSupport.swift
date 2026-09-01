// Deterministic workload generation and duration-stable offscreen draw measurement.
//
// Four workloads, because the executor has four content paths and each was
// invisible here until a workload reached it. The btop-shaped workload is entirely
// sprite geometry; the text-shaped one is entirely batched CoreText glyphs; the
// fallback-shaped one is entirely per-cell `CTLine` typesetting; the symbols-shaped
// one is entirely packaged-symbol icons. Any new workload should be added for the
// same reason -- a path the existing ones cannot reach -- not to add another flavor
// of content.
import CoreGraphics
import Dispatch
import Foundation
import TerminalCore
import TerminalCoreBenchmarkSupport
import TerminalRenderExecution
import TerminalRenderPlanning

/// Names a fixed terminal geometry so benchmark results remain comparable between runs.
public struct DrawBenchmarkGrid: Codable, Equatable, Sendable {
    /// Number of cells in each generated row.
    public let columns: Int
    /// Number of rows in the generated viewport.
    public let rows: Int

    /// Allows tests and future benchmark grids to use the same workload contract.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// The two geometries every run measures: a linearity control and the real one.
    ///
    /// 179x66 is DanTerm's actual full-screen geometry and the geometry the rest
    /// of the research corpus already standardizes on -- doc 10's feed benchmarks,
    /// doc 12's cell census, and all four of doc 13's live captures. This
    /// benchmark used to sit on an arbitrary 160x50 and extrapolate, which left
    /// every frame-budget number in `docs/research/11-render-frame-budget.md` a
    /// projection rather than a measurement.
    ///
    /// 80x24 stays because two grids are worth more than one: per-cell cost is
    /// linear in cell count, so a run whose two grids disagree on ns/cell is a run
    /// with an arithmetic bug in it. That check is what `research/11/F4` needed and did not
    /// have. It costs 1920 cells. Adding a third grid buys nothing the second does
    /// not already buy.
    public static let standard = [
        DrawBenchmarkGrid(columns: 80, rows: 24),
        DrawBenchmarkGrid(columns: 179, rows: 66),
    ]
}

/// Separates today's full draw cost from the intended few-row hot path.
public enum DrawBenchmarkScenario: String, Codable, CaseIterable, Sendable {
    case fullFrame = "full-frame"
    case damageClipped = "damage-clipped"
}

/// Selects which of the executor's four content paths a measurement exercises.
///
/// The distinction is not decorative. `btopShaped` is dense TUI box, block, and
/// braille art: the executor classifies every one of its cells into a sprite
/// family and fills rects, reaching CoreText's glyph calls zero times.
/// `textShaped` is printable ASCII, which no sprite family claims, so every cell
/// goes through `CTFontGetGlyphsForCharacters` and `CTFontDrawGlyphs` instead.
/// `fallbackShaped` is CJK and multi-scalar clusters, which the batched glyph
/// call cannot map, so every cell builds an attributed string and a `CTLine` in
/// `drawTextCell`. `symbolsShaped` is private-use icons the base face cannot map
/// and no sprite family claims, so every cell is resolved against the packaged
/// symbols face and drawn one glyph at a time inside a clipped, fitted span.
/// A change to any one path is invisible to the other workloads.
public enum DrawBenchmarkWorkload: String, Codable, CaseIterable, Sendable {
    case btopShaped = "btop-shaped"
    case textShaped = "text-shaped"
    case fallbackShaped = "fallback-shaped"
    case symbolsShaped = "symbols-shaped"
}

/// The denominators a per-draw duration has to be read against.
///
/// Exists because a duration alone cannot be checked. A published finding
/// (`research/11/F2`) quoted per-draw times 16x
/// below what a bare `CGContextFillRects` of the same cells costs -- the numbers
/// had been divided by the batch count twice in a summarizing script, and the
/// report carried nothing a reader could have divided to catch it. The tool
/// itself was sound, which is exactly why the error survived. Carrying the
/// surface and the content counts makes the plausibility check take seconds.
public struct DrawBenchmarkSurface: Codable, Equatable, Sendable {
    /// Width of the allocated bitmap in device pixels.
    public let bitmapPixelWidth: Int
    /// Height of the allocated bitmap in device pixels.
    public let bitmapPixelHeight: Int
    /// Cell width in device pixels at the measured display scale.
    public let cellPixelWidth: Int
    /// Cell height in device pixels at the measured display scale.
    public let cellPixelHeight: Int
    /// Text runs selected for the executor after any row restriction.
    public let drawnRunCount: Int
    /// Cells selected for the executor after any row restriction.
    public let drawnCellCount: Int
    /// Columns those cells occupy, which is the cell count only while every cell is
    /// one column wide. Reported beside the cell count because the fallback workload
    /// is half wide cells, so a reader checking a per-draw duration against the
    /// surface it covered cannot derive either number from the other.
    public let drawnColumnCount: Int
}

/// Retains raw batch totals alongside normalized draw durations to prove the timing floor.
public struct DrawBenchmarkMeasurements: Codable, Equatable, Sendable {
    /// Geometry used to construct the terminal and surface.
    public let grid: DrawBenchmarkGrid
    /// Content path measured by these samples.
    public let workload: DrawBenchmarkWorkload
    /// Drawing path measured by these samples.
    public let scenario: DrawBenchmarkScenario
    /// What each of these draws actually covered, so the durations can be checked.
    public let surface: DrawBenchmarkSurface
    /// Fixed number of draws included in every raw sample.
    public let batchCount: Int
    /// Per-draw durations normalized from each fixed-batch total.
    public let drawDurationNanoseconds: [UInt64]
    /// Raw fixed-batch totals retained to prove the duration floor.
    public let sampleDurationNanoseconds: [UInt64]
}

/// Provides one stable JSON envelope for every grid and scenario in a benchmark run.
public struct DrawBenchmarkReport: Codable, Equatable, Sendable {
    /// Results in stable grid-major, then workload, then scenario order.
    public let measurements: [DrawBenchmarkMeasurements]

    /// Keeps all scenario results in one executable-boundary value.
    public init(measurements: [DrawBenchmarkMeasurements]) {
        self.measurements = measurements
    }
}

/// Reports an offscreen allocation failure instead of silently omitting a scenario.
public enum DrawBenchmarkError: Error {
    case invalidMetrics
    case invalidTerminal
    case invalidFrame
    case allocationFailed
}

/// Generates one workload's bytes, so callers name a workload rather than a generator.
public func workloadANSI(
    for grid: DrawBenchmarkGrid,
    workload: DrawBenchmarkWorkload
) -> [UInt8] {
    switch workload {
    case .btopShaped: btopShapedANSI(for: grid)
    case .textShaped: textShapedANSI(for: grid)
    case .fallbackShaped: fallbackShapedANSI(for: grid)
    case .symbolsShaped: symbolsShapedANSI(for: grid)
    }
}

/// Generates repeatable dense ANSI whose changing color and emphasis prevent adjacent text-run folding.
public func btopShapedANSI(for grid: DrawBenchmarkGrid) -> [UInt8] {
    let glyphs = ["┌", "─", "┐", "│", "⣿", "⣷", "⣯", "█", "▆", "▃", "└", "┘"]
    var output = "\u{1b}[?25l\u{1b}[H"
    for row in 0..<grid.rows {
        for column in 0..<grid.columns {
            let color = 16 + ((row * grid.columns + column) * 37) % 216
            let bold = (row + column).isMultiple(of: 2) ? "1" : "22"
            output += "\u{1b}[\(bold);38;5;\(color)m"
            output += glyphs[(row * 5 + column * 7) % glyphs.count]
        }
        if row + 1 < grid.rows {
            output += "\r\n"
        }
    }
    output += "\u{1b}[0m"
    return Array(output.utf8)
}

/// Vocabulary the text-shaped workload lays down, sized and punctuated like source
/// code so run lengths land where real terminal output puts them. Printable ASCII
/// only: that is what keeps every cell off the executor's sprite paths.
let textShapedVocabulary = [
    "fn", "render_frame(&self,", "plan:", "&Plan)", "->", "Result<(),", "Error>", "{",
    "let", "mut", "cursor", "=", "self.grid.cursor();", "//", "clamp", "to", "the",
    "viewport", "before", "drawing", "0x1f04", "42", "assert_eq!(rows,", "24);", "}",
]

/// Generates repeatable full-screen ASCII whose color and emphasis change at token
/// boundaries rather than per cell, so its runs are the several-cell spans real
/// output produces and its `CTFontDrawGlyphs` calls carry representative batches.
public func textShapedANSI(for grid: DrawBenchmarkGrid) -> [UInt8] {
    var output = "\u{1b}[?25l\u{1b}[H"
    var token = 0
    for row in 0..<grid.rows {
        var column = 0
        while column < grid.columns {
            let word = textShapedVocabulary[token % textShapedVocabulary.count]
            let color = 16 + (token * 53) % 216
            let bold = token.isMultiple(of: 2) ? "1" : "22"
            let italic = token.isMultiple(of: 3) ? "3" : "23"
            output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
            // The row must end exactly at the margin, so the token that would
            // overrun it is truncated instead of wrapped: a wrap would push the
            // remainder onto the next row and desynchronize every row after it.
            let remaining = grid.columns - column
            let text = word.count < remaining ? word + " " : String(word.prefix(remaining))
            output += text
            column += text.count
            token += 1
        }
        if row + 1 < grid.rows {
            output += "\r\n"
        }
    }
    output += "\u{1b}[0m"
    return Array(output.utf8)
}

/// One column-one cell the fallback workload pads a row's odd remainder with.
///
/// `a` plus three combining marks, which is kitten's `unique_unicode` cluster. It
/// is a fallback cell for a reason no installed font can remove -- the executor
/// routes every multi-scalar cluster to `drawTextCell` before it consults a cmap
/// -- so it is also what keeps the workload's floor independent of the base face.
let fallbackShapedPadding = "a\u{0301}\u{0302}\u{0303}"

/// Tokens the fallback workload lays down, with the columns each one occupies.
///
/// Every entry misses the executor's batched-glyph fast path, and the three
/// reasons a cell can miss it are all represented, because the shaped result a fix
/// would cache is keyed on the cluster and a corpus of one reason prices one
/// branch. The CJK and kana words are single BMP scalars the monospaced system
/// face's cmap does not map (glyph zero); `fallbackShapedPadding` repeated is a
/// multi-scalar cluster; the CJK Extension B word is scalars above `UInt16.max`,
/// which reach the batch as surrogate halves and resolve to glyph zero there.
/// Columns are stated rather than derived so a row can be laid out to the margin
/// without consulting the width table the terminal will apply.
let fallbackShapedVocabulary: [(text: String, columns: Int)] = [
    ("中文终端", 8),
    (String(repeating: fallbackShapedPadding, count: 3), 3),
    ("渲染字体", 8),
    ("𠀀𠀁", 4),
    ("こんにちは", 10),
    (String(repeating: fallbackShapedPadding, count: 2), 2),
    ("測定基準", 8),
    ("グリフ", 6),
]

/// Generates a repeatable full screen of cells that all take the executor's
/// `drawTextCell` fallback, so a run brackets per-cell `CTLine` typesetting and
/// nothing else the other two workloads already cover.
///
/// Style changes land on token boundaries, as in `textShapedANSI`, so runs are the
/// several-cell spans real output produces: the fallback attributes are built once
/// per run, and a per-cell style churn would price that construction instead of the
/// typesetting. Wide cells cannot be cut in half, so a token that would overrun the
/// margin is replaced by the one-column cluster repeated to it rather than
/// truncated -- a wrap would push the remainder onto the next row and
/// desynchronize every row after it.
public func fallbackShapedANSI(for grid: DrawBenchmarkGrid) -> [UInt8] {
    var output = "\u{1b}[?25l\u{1b}[H"
    var token = 0
    for row in 0..<grid.rows {
        var column = 0
        while column < grid.columns {
            let entry = fallbackShapedVocabulary[token % fallbackShapedVocabulary.count]
            let color = 16 + (token * 53) % 216
            let bold = token.isMultiple(of: 2) ? "1" : "22"
            let italic = token.isMultiple(of: 3) ? "3" : "23"
            output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
            let remaining = grid.columns - column
            if entry.columns <= remaining {
                output += entry.text
                column += entry.columns
            } else {
                output += String(repeating: fallbackShapedPadding, count: remaining)
                column += remaining
            }
            token += 1
        }
        if row + 1 < grid.rows {
            output += "\r\n"
        }
    }
    output += "\u{1b}[0m"
    return Array(output.utf8)
}

/// Number of cells one symbols-shaped style token covers.
///
/// Every icon is one column wide, so a token is a plain span rather than a word:
/// four keeps runs several cells long, like the other two text workloads, so the
/// measurement is the per-icon draw rather than a per-cell style change.
let symbolsShapedTokenColumns = 4

/// Icons the symbols-shaped workload lays down, all of which reach the executor's
/// packaged-symbols path and nothing else.
///
/// Each scalar satisfies four conditions at once, and a scalar that misses any of
/// them measures a different path: it is private-use, so the executor consults the
/// symbols face at all; it is outside every sprite family's coarse range
/// (`PowerlineSprite` claims E0B0-E0D4 and `BranchDrawingSprite` claims F5D0-F60D),
/// so no sprite draws it as rects; the monospaced system face's cmap does not map
/// it, so the batched glyph call yields glyph zero; and the packaged symbols face
/// does map it, so the cell is drawn rather than dropped to `drawTextCell`.
///
/// Both private-use shapes are present. The BMP icons reach the batched glyph call
/// as one code unit; the plane-15 ones reach it as surrogate halves, which is the
/// second way a cell arrives at the symbols path and the one whose glyph-index
/// arithmetic in `drawTextRuns` is easy to get wrong.
let symbolsShapedScalars: [Unicode.Scalar] = [
    "\u{E0A0}", "\u{E5FA}", "\u{E702}", "\u{F001}",
    "\u{F0001}", "\u{E200}", "\u{F0A0}", "\u{F0100}",
    "\u{E7C5}", "\u{F11C}", "\u{F1000}", "\u{E62B}",
]

/// Generates a repeatable full screen of packaged-symbol icons, so a run brackets
/// the per-icon glyph lookup and clipped glyph draw that no other workload reaches.
///
/// Style changes land on token boundaries, as in the other text workloads, so runs
/// are the several-cell spans real output produces. Every icon is one column wide,
/// so the final token of a row is shortened to the margin rather than wrapped -- a
/// wrap would push the remainder onto the next row and desynchronize every row
/// after it.
public func symbolsShapedANSI(for grid: DrawBenchmarkGrid) -> [UInt8] {
    var output = "\u{1b}[?25l\u{1b}[H"
    var token = 0
    for row in 0..<grid.rows {
        var column = 0
        while column < grid.columns {
            let color = 16 + (token * 53) % 216
            let bold = token.isMultiple(of: 2) ? "1" : "22"
            let italic = token.isMultiple(of: 3) ? "3" : "23"
            output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
            let span = min(symbolsShapedTokenColumns, grid.columns - column)
            for offset in 0..<span {
                let index = token * symbolsShapedTokenColumns + offset
                output.unicodeScalars.append(
                    symbolsShapedScalars[index % symbolsShapedScalars.count]
                )
            }
            column += span
            token += 1
        }
        if row + 1 < grid.rows {
            output += "\r\n"
        }
    }
    output += "\u{1b}[0m"
    return Array(output.utf8)
}

/// Feeds one workload's generated bytes through the production terminal and planner used by the app.
public func makeWorkloadPlan(
    for grid: DrawBenchmarkGrid,
    workload: DrawBenchmarkWorkload
) -> RenderFramePlan? {
    guard var terminal = Terminal(columns: grid.columns, rows: grid.rows) else { return nil }
    terminal.feed(workloadANSI(for: grid, workload: workload))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}

/// Executes one scenario against an allocated sRGB bitmap and returns its byte count.
public func executeDrawScenario(
    _ scenario: DrawBenchmarkScenario,
    plan: RenderFramePlan,
    displayScale: CGFloat = 2
) throws -> Int {
    let prepared = try PreparedDraw(plan: plan, scenario: scenario, displayScale: displayScale)
    prepared.draw()
    return prepared.byteCount
}

/// Measures every standard workload with calibration excluded and a fixed batch per reported sample.
public func measureDrawBenchmarks(
    iterations: Int,
    floorNanoseconds: UInt64 = 400_000_000
) throws -> DrawBenchmarkReport {
    precondition(iterations >= 2)
    precondition(floorNanoseconds > 0)
    var results: [DrawBenchmarkMeasurements] = []
    for grid in DrawBenchmarkGrid.standard {
        for workload in DrawBenchmarkWorkload.allCases {
            guard let plan = makeWorkloadPlan(for: grid, workload: workload) else {
                throw DrawBenchmarkError.invalidTerminal
            }
            for scenario in DrawBenchmarkScenario.allCases {
                let prepared = try PreparedDraw(plan: plan, scenario: scenario, displayScale: 2)
                let stable = measureDurationStable(
                    iterations: iterations,
                    floorNanoseconds: floorNanoseconds,
                    measureBatch: { count in
                        let start = DispatchTime.now().uptimeNanoseconds
                        for _ in 0..<count { prepared.draw() }
                        return DispatchTime.now().uptimeNanoseconds - start
                    }
                )
                results.append(DrawBenchmarkMeasurements(
                    grid: grid,
                    workload: workload,
                    scenario: scenario,
                    surface: prepared.surface,
                    batchCount: stable.batchCount,
                    drawDurationNanoseconds: stable.totals.map { $0 / UInt64(stable.batchCount) },
                    sampleDurationNanoseconds: stable.totals
                ))
            }
        }
    }
    return DrawBenchmarkReport(measurements: results)
}

private final class PreparedDraw {
    let byteCount: Int
    /// Describes the surface and content this instance draws, so a measurement
    /// reports the work it actually did rather than the work it was asked for.
    let surface: DrawBenchmarkSurface
    private let plan: RenderFramePlan
    private let restriction: TerminalDamage?
    private let metrics: TerminalRenderMetrics
    private let context: CGContext
    private let storage: UnsafeMutableRawPointer

    init(plan: RenderFramePlan, scenario: DrawBenchmarkScenario, displayScale: CGFloat) throws {
        guard let metrics = TerminalRenderMetrics(displayScale: displayScale) else {
            throw DrawBenchmarkError.invalidMetrics
        }
        let rows = 0..<min(4, plan.rowCount)
        let restriction: TerminalDamage? = scenario == .fullFrame
            ? nil
            : TerminalDamage(rows: rows, rowCount: plan.rowCount)
        self.plan = plan
        self.restriction = restriction
        guard let size = renderFrameSize(for: plan, metrics: metrics) else {
            throw DrawBenchmarkError.invalidFrame
        }
        let pixels = size.pixelWidth.multipliedReportingOverflow(by: size.pixelHeight)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard pixels.overflow == false, bytes.overflow == false else {
            throw DrawBenchmarkError.invalidFrame
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: bytes.partialValue,
            alignment: MemoryLayout<UInt32>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes.partialValue)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: storage,
                  width: size.pixelWidth,
                  height: size.pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: size.pixelWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else {
            storage.deallocate()
            throw DrawBenchmarkError.allocationFailed
        }
        context.translateBy(x: 0, y: CGFloat(size.pixelHeight))
        context.scaleBy(x: displayScale, y: -displayScale)
        if scenario == .damageClipped {
            for row in rows {
                context.addRect(CGRect(
                    x: 0,
                    y: CGFloat(row) * metrics.cellSize.height,
                    width: size.pointSize.width,
                    height: metrics.cellSize.height
                ))
            }
            context.clip()
        }
        self.byteCount = bytes.partialValue
        self.surface = DrawBenchmarkSurface(
            bitmapPixelWidth: size.pixelWidth,
            bitmapPixelHeight: size.pixelHeight,
            cellPixelWidth: metrics.cellWidthPixels,
            cellPixelHeight: metrics.cellHeightPixels,
            drawnRunCount: plan.rows.enumerated().reduce(0) { total, element in
                total + (restriction == nil || restriction?.contains(row: element.offset) == true
                    ? element.element.textRuns.count : 0)
            },
            drawnCellCount: plan.rows.enumerated().reduce(0) { total, element in
                total + (restriction == nil || restriction?.contains(row: element.offset) == true
                    ? element.element.textRuns.reduce(0) { $0 + $1.cells.count } : 0)
            },
            drawnColumnCount: plan.rows.enumerated().reduce(0) { total, element in
                total + (restriction == nil || restriction?.contains(row: element.offset) == true
                    ? element.element.textRuns.reduce(0) { runTotal, run in
                        runTotal + run.cells.reduce(0) { $0 + $1.columnWidth }
                    } : 0)
            }
        )
        self.metrics = metrics
        self.context = context
        self.storage = storage
    }

    // `context` does not own `storage` -- CGContext(data:) borrows the buffer. A deinit
    // body runs before the stored properties are released, so freeing the buffer here
    // would leave the still-live context pointing at freed memory. The context has to
    // outlive the free, which is what `withExtendedLifetime` states. The arm in
    // Sources/HeadlessDrawArm mirrors this class and must keep the same ordering.
    deinit { withExtendedLifetime(context) { storage.deallocate() } }

    func draw() {
        drawRenderFrame(plan, restrictedTo: restriction, metrics: metrics, in: context)
    }
}
