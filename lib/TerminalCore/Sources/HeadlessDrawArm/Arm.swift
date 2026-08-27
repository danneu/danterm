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

/// Holds the one prepared surface a batch redraws, so per-draw cost excludes all setup.
private final class PreparedDraw {
    private let plan: RenderFramePlan
    private let restriction: TerminalDamage?
    private let metrics: TerminalRenderMetrics
    private let context: CGContext
    private let storage: UnsafeMutableRawPointer

    /// `clipRows <= 0` selects the full-frame scenario; a positive value restricts to that many
    /// leading rows, which is the damage-scoped path the GUI benchmark cannot measure quietly.
    /// `textShaped` selects the all-ASCII workload, which is the only one of the two that
    /// reaches CoreText's glyph calls at all; the default sprite workload never does.
    init?(
        columns: Int,
        rows: Int,
        clipRows: Int,
        textShaped: Bool = false,
        displayScale: CGFloat = 2
    ) {
        guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
        terminal.feed(
            textShaped
                ? Self.textShapedANSI(columns: columns, rows: rows)
                : Self.btopShapedANSI(columns: columns, rows: rows)
        )
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
}

nonisolated(unsafe) private var prepared: PreparedDraw?

/// Builds this arm's surface once. Returns 0 on success, 1 on failure.
///
/// `textShaped` is nonzero for the ASCII workload. Both arms are compiled from THIS copy of
/// the file even when their TerminalCore checkouts differ, so adding a parameter here changes
/// both arms together and cannot desynchronize the driver from an older baseline.
@_cdecl("arm_prepare")
public func arm_prepare(
    _ columns: Int32,
    _ rows: Int32,
    _ clipRows: Int32,
    _ textShaped: Int32
) -> Int32 {
    prepared = PreparedDraw(
        columns: Int(columns),
        rows: Int(rows),
        clipRows: Int(clipRows),
        textShaped: textShaped != 0
    )
    return prepared == nil ? 1 : 0
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
