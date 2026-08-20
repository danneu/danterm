// Deterministic workload generation and duration-stable offscreen draw measurement.
//
// Two workloads, because the executor has two content paths and one of them was
// invisible here for the benchmark's whole life. The btop-shaped workload is
// entirely sprite geometry; the text-shaped one is entirely CoreText glyphs. Any
// new workload should be added for the same reason -- a path the existing ones
// cannot reach -- not to add another flavor of content.
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

/// Selects which of the executor's two content paths a measurement exercises.
///
/// The distinction is not decorative. `btopShaped` is dense TUI box, block, and
/// braille art: the executor classifies every one of its cells into a sprite
/// family and fills rects, reaching CoreText's glyph calls zero times.
/// `textShaped` is printable ASCII, which no sprite family claims, so every cell
/// goes through `CTFontGetGlyphsForCharacters` and `CTFontDrawGlyphs` instead.
/// A change to either path is invisible to the other workload.
public enum DrawBenchmarkWorkload: String, Codable, CaseIterable, Sendable {
    case btopShaped = "btop-shaped"
    case textShaped = "text-shaped"
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
    targetNanoseconds: UInt64 = 400_000_000
) throws -> DrawBenchmarkReport {
    precondition(iterations >= 2)
    precondition(targetNanoseconds > 0)
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
                    targetNanoseconds: targetNanoseconds,
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
    private let restrictedRows: [Int]?
    private let metrics: TerminalRenderMetrics
    private var context: CGContext?
    private let storage: UnsafeMutableRawPointer

    init(plan: RenderFramePlan, scenario: DrawBenchmarkScenario, displayScale: CGFloat) throws {
        guard let metrics = TerminalRenderMetrics(displayScale: displayScale) else {
            throw DrawBenchmarkError.invalidMetrics
        }
        let rows = Array(0..<min(4, plan.rowCount))
        let restriction: [Int]? = scenario == .fullFrame ? nil : rows
        self.plan = plan
        self.restrictedRows = restriction
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
                total + (restriction == nil || restriction?.contains(element.offset) == true
                    ? element.element.textRuns.count : 0)
            },
            drawnCellCount: plan.rows.enumerated().reduce(0) { total, element in
                total + (restriction == nil || restriction?.contains(element.offset) == true
                    ? element.element.textRuns.reduce(0) { $0 + $1.cells.count } : 0)
            }
        )
        self.metrics = metrics
        self.context = context
        self.storage = storage
    }

    deinit {
        context = nil
        storage.deallocate()
    }

    func draw() {
        guard let context else { return }
        drawRenderFrame(plan, rows: restrictedRows, metrics: metrics, in: context)
    }
}
