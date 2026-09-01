// One benchmark arm: the app's draw path compiled as a standalone dynamic library behind a
// C ABI, so `terminal-headless-draw-compare.py` can load two independently built arms into
// ONE process and interleave their batches.
//
// Single-process interleaving is the point, not an implementation convenience. The headless
// draw measurement drifts 2-4% between process launches, so a cross-process comparison is no
// more precise than the GUI benchmark it replaces. That drift is common-mode -- it moves every
// measurement in a process together -- so a difference taken between two arms microseconds
// apart cancels it, and paired spread collapses to ~0.7%. See F21-F23 in
// docs/research/8-benchmark-variance-regression.md.
//
// This file is copied verbatim into a generated SwiftPM target whose directory name supplies
// the module name. It must stay module-name agnostic: the two arms MUST compile under
// different module names, because Swift classes register with the ObjC runtime, which dedups
// globally even under RTLD_LOCAL, and a collision makes both arms run one arm's code.
//
// It is also a target of this package, so the gate compiles it. That is the whole reason it
// lives here instead of beside its driver in `scripts/`: it sat unbuildable from `13db5f73`
// until this move, because nothing in `just test` compiled a Swift file under `scripts/`.
//
// The four workload generators below are likewise copied from TerminalDrawBenchmarkSupport and
// must stay byte-equivalent to it, so the two benchmarks draw the same corpus.
//
// `PreparedDraw` mirrors the private one in TerminalDrawBenchmarkSupport rather than importing
// it, and the duplication is required: the compare script builds THIS one source against two
// different TerminalCore checkouts, so the arm's own setup has to be the constant that makes
// TerminalCore the only variable. The bitmap context, the plan, and the damage clip are all
// built in `init`, outside the timer, so a timed batch contains `drawRenderFrame`, including
// its row selection, and nothing else.
//
// Because the source is shared across both arms, it can only speak the current TerminalCore
// API: this arm cannot measure a baseline older than `13db5f73`, which is where the executor's
// row restriction became `restrictedTo: TerminalDamage?`.
import CoreGraphics
import Dispatch
import Foundation
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Answers whether this process can draw the packaged symbols face, and is a variable so a
/// test can state the absent case the arm must refuse.
///
/// The render module's own nil-resource seam is internal to it, so an arm in another module
/// cannot reach it. The arm loads as a dylib into the compare driver's process, where the
/// font comes from the SwiftPM resource bundle rather than `Bundle.main`; a missing bundle
/// there must refuse the prepare rather than quietly time the `CTLine` fallback and publish
/// it as a symbols-path number.
nonisolated(unsafe) public var armPackagedSymbolsFaceIsAvailable: @Sendable () -> Bool = {
    PackagedSymbolsFace.face(pointSize: 12) != nil
}

/// Holds the one prepared surface a batch redraws, so per-draw cost excludes all setup.
final class PreparedDraw {
    /// Cells this surface draws through the packaged-symbols path, so the driver can report
    /// an absolute per-draw difference per icon cell instead of leaving the denominator to
    /// be reconstructed outside the instrument.
    let iconCellCount: Int
    private let plan: RenderFramePlan
    private let restriction: TerminalDamage?
    private let metrics: TerminalRenderMetrics
    private let context: CGContext
    private let storage: UnsafeMutableRawPointer

    /// `clipRows <= 0` selects the full-frame scenario; a positive value restricts to that many
    /// leading rows, which is the damage-scoped path the GUI benchmark cannot measure quietly.
    /// `workload` indexes the driver's `WORKLOADS` tuple, which holds `DrawBenchmarkWorkload`'s
    /// raw values in order: the sprite workload reaches CoreText zero times, the ASCII one
    /// reaches the batched glyph calls, the fallback one reaches per-cell `CTLine`
    /// typesetting, and the symbols one reaches the packaged-symbols glyph draw. An
    /// unrecognized index is refused rather than silently drawing the sprite
    /// workload, which would publish a paired difference on a path the caller never asked for.
    init?(
        columns: Int,
        rows: Int,
        clipRows: Int,
        workload: Int = 0,
        displayScale: CGFloat = 2
    ) {
        guard var terminal = Terminal(columns: columns, rows: rows),
              let bytes = Self.workloadANSI(columns: columns, rows: rows, workload: workload)
        else { return nil }
        // Refused rather than measured: without the packaged face every icon cell falls to
        // `drawTextCell`, which is the fallback workload's path wearing this workload's name.
        if workload == 3, armPackagedSymbolsFaceIsAvailable() == false { return nil }
        terminal.feed(bytes)
        let full = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark, isCursorVisible: false, cursorShape: .block))
        guard let metrics = TerminalRenderMetrics(displayScale: displayScale) else { return nil }

        let damaged = 0..<min(max(clipRows, 0), full.rowCount)
        self.plan = full
        self.restriction = clipRows <= 0
            ? nil
            : TerminalDamage(rows: damaged, rowCount: full.rowCount)

        guard let size = renderFrameSize(for: full, metrics: metrics) else { return nil }
        let byteCount = size.pixelWidth * size.pixelHeight * 4
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: storage,
                  width: size.pixelWidth, height: size.pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: size.pixelWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else {
            storage.deallocate()
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(size.pixelHeight))
        context.scaleBy(x: displayScale, y: -displayScale)
        if clipRows > 0 {
            for row in damaged {
                context.addRect(CGRect(
                    x: 0, y: CGFloat(row) * metrics.cellSize.height,
                    width: size.pointSize.width, height: metrics.cellSize.height))
            }
            context.clip()
        }
        self.metrics = metrics
        self.context = context
        self.storage = storage
        self.iconCellCount = Self.iconCellCount(in: full, restrictedTo: self.restriction)
    }

    /// Counts the drawn cells the executor routes to the packaged-symbols face: one
    /// private-use scalar each, which is the condition `drawTextRuns` itself tests before it
    /// consults that face.
    private static func iconCellCount(
        in plan: RenderFramePlan,
        restrictedTo restriction: TerminalDamage?
    ) -> Int {
        plan.rows.enumerated().reduce(0) { total, element in
            guard restriction == nil || restriction?.contains(row: element.offset) == true else {
                return total
            }
            return total + element.element.textRuns.reduce(0) { runTotal, run in
                runTotal + run.cells.count { cell in
                    guard cell.scalars.count == 1, let scalar = cell.scalars.first else {
                        return false
                    }
                    return (0xE000...0xF8FF).contains(scalar.value)
                        || (0xF0000...0xFFFFD).contains(scalar.value)
                        || (0x100000...0x10FFFD).contains(scalar.value)
                }
            }
        }
    }

    /// Generates one workload's bytes, or nil for an index this arm does not know.
    ///
    /// Separate from `init` so the parity test can compare these copies against
    /// TerminalDrawBenchmarkSupport's originals without preparing a surface.
    static func workloadANSI(columns: Int, rows: Int, workload: Int) -> [UInt8]? {
        switch workload {
        case 0: btopShapedANSI(columns: columns, rows: rows)
        case 1: textShapedANSI(columns: columns, rows: rows)
        case 2: fallbackShapedANSI(columns: columns, rows: rows)
        case 3: symbolsShapedANSI(columns: columns, rows: rows)
        default: nil
        }
    }

    // `context` does not own `storage` -- CGContext(data:) borrows the buffer. A deinit
    // body runs before the stored properties are released, so freeing the buffer here
    // would leave the still-live context pointing at freed memory. The context has to
    // outlive the free, which is what `withExtendedLifetime` states.
    deinit { withExtendedLifetime(context) { storage.deallocate() } }

    func draw() {
        drawRenderFrame(plan, restrictedTo: restriction, metrics: metrics, in: context)
    }

    /// Matches TerminalDrawBenchmarkSupport's generator exactly so both benchmarks draw the
    /// same corpus: dense, colour-varying, emphasis-alternating cells that defeat text-run
    /// folding and keep the draw representative of a busy TUI.
    static func btopShapedANSI(columns: Int, rows: Int) -> [UInt8] {
        let glyphs = ["┌", "─", "┐", "│", "⣿", "⣷", "⣯", "█", "▆", "▃", "└", "┘"]
        var output = "\u{1b}[?25l\u{1b}[H"
        for row in 0..<rows {
            for column in 0..<columns {
                let color = 16 + ((row * columns + column) * 37) % 216
                let bold = (row + column).isMultiple(of: 2) ? "1" : "22"
                output += "\u{1b}[\(bold);38;5;\(color)m"
                output += glyphs[(row * 5 + column * 7) % glyphs.count]
            }
            if row + 1 < rows { output += "\r\n" }
        }
        output += "\u{1b}[0m"
        return Array(output.utf8)
    }

    /// Matches TerminalDrawBenchmarkSupport's text generator exactly, for the same reason the
    /// btop one does. Printable ASCII only: no sprite family claims it, so every cell reaches
    /// `CTFontGetGlyphsForCharacters` and `CTFontDrawGlyphs` -- the path the btop workload
    /// leaves entirely uncovered. Style changes land on token boundaries so run lengths match
    /// real output instead of collapsing to one glyph per draw call.
    static func textShapedANSI(columns: Int, rows: Int) -> [UInt8] {
        let words = [
            "fn", "render_frame(&self,", "plan:", "&Plan)", "->", "Result<(),", "Error>", "{",
            "let", "mut", "cursor", "=", "self.grid.cursor();", "//", "clamp", "to", "the",
            "viewport", "before", "drawing", "0x1f04", "42", "assert_eq!(rows,", "24);", "}",
        ]
        var output = "\u{1b}[?25l\u{1b}[H"
        var token = 0
        for row in 0..<rows {
            var column = 0
            while column < columns {
                let word = words[token % words.count]
                let color = 16 + (token * 53) % 216
                let bold = token.isMultiple(of: 2) ? "1" : "22"
                let italic = token.isMultiple(of: 3) ? "3" : "23"
                output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
                let remaining = columns - column
                let text = word.count < remaining ? word + " " : String(word.prefix(remaining))
                output += text
                column += text.count
                token += 1
            }
            if row + 1 < rows { output += "\r\n" }
        }
        output += "\u{1b}[0m"
        return Array(output.utf8)
    }

    /// Matches TerminalDrawBenchmarkSupport's fallback generator exactly, for the same reason
    /// the other two do. Every cell misses the batched glyph call -- CJK and kana the base
    /// face's cmap does not map, `a` plus three combining marks, and CJK Extension B scalars
    /// above `UInt16.max` -- so each one builds an attributed string and a `CTLine` in
    /// `drawTextCell`, the path research 40 owns and neither other workload reaches.
    static func fallbackShapedANSI(columns: Int, rows: Int) -> [UInt8] {
        let padding = "a\u{0301}\u{0302}\u{0303}"
        let vocabulary: [(text: String, columns: Int)] = [
            ("中文终端", 8),
            (String(repeating: padding, count: 3), 3),
            ("渲染字体", 8),
            ("𠀀𠀁", 4),
            ("こんにちは", 10),
            (String(repeating: padding, count: 2), 2),
            ("測定基準", 8),
            ("グリフ", 6),
        ]
        var output = "\u{1b}[?25l\u{1b}[H"
        var token = 0
        for row in 0..<rows {
            var column = 0
            while column < columns {
                let entry = vocabulary[token % vocabulary.count]
                let color = 16 + (token * 53) % 216
                let bold = token.isMultiple(of: 2) ? "1" : "22"
                let italic = token.isMultiple(of: 3) ? "3" : "23"
                output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
                let remaining = columns - column
                if entry.columns <= remaining {
                    output += entry.text
                    column += entry.columns
                } else {
                    output += String(repeating: padding, count: remaining)
                    column += remaining
                }
                token += 1
            }
            if row + 1 < rows { output += "\r\n" }
        }
        output += "\u{1b}[0m"
        return Array(output.utf8)
    }

    /// Matches TerminalDrawBenchmarkSupport's symbols generator exactly, for the same reason
    /// the other three do. Every cell is a private-use icon: no sprite family claims it, the
    /// base face's cmap does not map it, and the packaged symbols face does -- so each one is
    /// resolved through `nominalGlyph` and drawn inside a clipped, fitted span, the path no
    /// other workload reaches.
    static func symbolsShapedANSI(columns: Int, rows: Int) -> [UInt8] {
        let tokenColumns = 4
        let scalars: [Unicode.Scalar] = [
            "\u{E0A0}", "\u{E5FA}", "\u{E702}", "\u{F001}",
            "\u{F0001}", "\u{E200}", "\u{F0A0}", "\u{F0100}",
            "\u{E7C5}", "\u{F11C}", "\u{F1000}", "\u{E62B}",
        ]
        var output = "\u{1b}[?25l\u{1b}[H"
        var token = 0
        for row in 0..<rows {
            var column = 0
            while column < columns {
                let color = 16 + (token * 53) % 216
                let bold = token.isMultiple(of: 2) ? "1" : "22"
                let italic = token.isMultiple(of: 3) ? "3" : "23"
                output += "\u{1b}[\(bold);\(italic);38;5;\(color)m"
                let span = min(tokenColumns, columns - column)
                for offset in 0..<span {
                    output.unicodeScalars.append(
                        scalars[(token * tokenColumns + offset) % scalars.count])
                }
                column += span
                token += 1
            }
            if row + 1 < rows { output += "\r\n" }
        }
        output += "\u{1b}[0m"
        return Array(output.utf8)
    }
}

nonisolated(unsafe) private var prepared: PreparedDraw?

/// Builds this arm's surface once. Returns 0 on success, 1 on failure.
///
/// `workload` is an index into the driver's `WORKLOADS` tuple. Both arms are compiled from
/// THIS copy of the file even when their TerminalCore checkouts differ, so adding a workload
/// here changes both arms together and cannot desynchronize the driver from an older baseline.
@_cdecl("arm_prepare")
public func arm_prepare(
    _ columns: Int32,
    _ rows: Int32,
    _ clipRows: Int32,
    _ workload: Int32
) -> Int32 {
    prepared = PreparedDraw(
        columns: Int(columns),
        rows: Int(rows),
        clipRows: Int(clipRows),
        workload: Int(workload)
    )
    return prepared == nil ? 1 : 0
}

/// Reports how many of the prepared surface's drawn cells take the packaged-symbols path, so
/// the driver can normalize an absolute paired difference by the cells that can carry it.
/// Returns -1 when nothing is prepared, which is not the same answer as a workload with no
/// icon cells in it.
@_cdecl("arm_icon_cell_count")
public func arm_icon_cell_count() -> Int64 {
    guard let prepared else { return -1 }
    return Int64(prepared.iconCellCount)
}

/// Times `count` draws in-library and returns the batch total in nanoseconds, so neither the
/// driver's call overhead nor its language runtime lands inside the measured region.
@_cdecl("arm_batch")
public func arm_batch(_ count: Int32) -> UInt64 {
    guard let prepared else { return 0 }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<Int(count) { prepared.draw() }
    return DispatchTime.now().uptimeNanoseconds - start
}
