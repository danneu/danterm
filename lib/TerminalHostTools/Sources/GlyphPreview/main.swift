// Debug-only AppKit viewer comparing system font glyphs with DanTerm sprites.
import AppKit
import CoreText
import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

private let previewColumns = 80

/// Owns the standalone preview window for the lifetime of the debug app.
@MainActor
final class GlyphPreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let layout = GlyphPreviewLayout(
            columns: previewColumns,
            sectionGlyphCounts: glyphPreviewSections.map(\.scalars.count)
        ) else {
            NSApp.terminate(nil)
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let metrics = TerminalRenderMetrics(displayScale: scale),
              let preview = GlyphPreviewView(
                  frame: .zero,
                  metrics: metrics,
                  layout: layout,
                  sections: glyphPreviewSections
              )
        else {
            NSApp.terminate(nil)
            return
        }

        let scrollView = NSScrollView()
        scrollView.documentView = preview
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let visibleRows = 24
        let contentSize = NSSize(
            width: metrics.cellSize.width * CGFloat(layout.columns),
            height: metrics.cellSize.height * CGFloat(visibleRows)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DanTerm Glyph Preview - Font Fallback | Custom Sprite"
        window.contentView = scrollView
        window.setContentSize(contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Draws the system-font half over a frame produced by DanTerm's real renderer.
@MainActor
final class GlyphPreviewView: NSView {
    private let metrics: TerminalRenderMetrics
    private let layout: GlyphPreviewLayout
    private let sections: [GlyphPreviewSection]
    private let plan: RenderFramePlan
    private let systemReferenceFont: CTFont
    private let nerdSymbolsReferenceFont: CTFont
    private let unifontUpperReferenceFont: CTFont
    private let headingFont: CTFont

    override var isFlipped: Bool { true }

    init?(
        frame frameRect: NSRect,
        metrics: TerminalRenderMetrics,
        layout: GlyphPreviewLayout,
        sections: [GlyphPreviewSection]
    ) {
        guard var terminal = Terminal(columns: layout.columns, rows: layout.rows) else {
            return nil
        }
        var input = ""
        for (sectionIndex, section) in sections.enumerated() {
            let sectionLayout = layout.sections[sectionIndex]
            for (glyphIndex, scalar) in section.scalars.enumerated() {
                let origin = sectionLayout.origin(forGlyphAt: glyphIndex)
                for rowOffset in 0..<GlyphPreviewLayout.tileRows {
                    let row = origin.row + rowOffset + 1
                    input += "\u{1B}[\(row);\(origin.column + 1)H"
                    input += "\u{1B}[48;2;30;32;38m  "
                    input += "\u{1B}[48;2;17;44;48m  "
                    if section.customSpriteScalars.contains(scalar) {
                        input += "\u{1B}[\(row);\(origin.column + 3)H"
                        input.unicodeScalars.append(scalar)
                        input.unicodeScalars.append(scalar)
                    }
                }
            }
        }
        input += "\u{1B}[0m"
        terminal.feed(Array(input.utf8))

        self.metrics = metrics
        self.layout = layout
        self.sections = sections
        self.plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )
        let systemReferenceFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.systemReferenceFont = CTFontCreateWithName(
            systemReferenceFont.fontName as CFString,
            systemReferenceFont.pointSize,
            nil
        )
        guard let nerdSymbolsReferenceFont = PackagedSymbolsFace.face(pointSize: 13),
              let unifontUpperReferenceFont = NSFont(name: "UnifontUpper", size: 13)
        else {
            return nil
        }
        self.nerdSymbolsReferenceFont = nerdSymbolsReferenceFont
        self.unifontUpperReferenceFont = CTFontCreateWithName(
            unifontUpperReferenceFont.fontName as CFString,
            unifontUpperReferenceFont.pointSize,
            nil
        )
        let headingFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        self.headingFont = CTFontCreateWithName(
            headingFont.fontName as CFString,
            headingFont.pointSize,
            nil
        )
        super.init(frame: NSRect(
            origin: frameRect.origin,
            size: NSSize(
                width: metrics.cellSize.width * CGFloat(layout.columns),
                height: metrics.cellSize.height * CGFloat(layout.rows)
            )
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = terminalRows(
            intersecting: dirtyRect,
            metrics: metrics,
            rowCount: layout.rows
        )
        let visiblePlan = rows == 0..<layout.rows
            ? plan
            : clipFramePlan(plan, to: TerminalDamage(rows: Set(rows)))
        context.saveGState()
        context.clip(to: dirtyRect)
        drawRenderFrame(visiblePlan, metrics: metrics, in: context)
        drawSectionHeadings(in: context, visibleRows: rows)
        drawReferenceGlyphs(in: context, visibleRows: rows)
        context.restoreGState()
    }

    private func drawReferenceGlyphs(in context: CGContext, visibleRows: Range<Int>) {
        for (sectionIndex, section) in sections.enumerated() {
            let sectionLayout = layout.sections[sectionIndex]
            for (glyphIndex, scalar) in section.scalars.enumerated() {
                let origin = sectionLayout.origin(forGlyphAt: glyphIndex)
                guard visibleRows.overlaps(
                    origin.row..<(origin.row + GlyphPreviewLayout.tileRows)
                ) else {
                    continue
                }
                let referenceFont = referenceFont(for: scalar)
                let attributes: [NSAttributedString.Key: Any] = [
                    kCTFontAttributeName as NSAttributedString.Key: referenceFont,
                    kCTForegroundColorAttributeName as NSAttributedString.Key:
                        NSColor.textColor.cgColor,
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: String(scalar),
                    attributes: attributes
                ))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                for rowOffset in 0..<GlyphPreviewLayout.tileRows {
                    for columnOffset in 0..<2 {
                        let cellX = CGFloat(origin.column + columnOffset)
                            * metrics.cellSize.width
                        context.textMatrix = CGAffineTransform(
                            a: 1,
                            b: 0,
                            c: 0,
                            d: -1,
                            tx: cellX + (metrics.cellSize.width - width) / 2,
                            ty: CGFloat(origin.row + rowOffset) * metrics.cellSize.height
                                + metrics.baselineOffset
                        )
                        CTLineDraw(line, context)
                    }
                }
            }
        }
    }

    private func referenceFont(for scalar: Unicode.Scalar) -> CTFont {
        switch scalar.value {
        case 0xE0B0...0xE0BF, 0xE0D2, 0xE0D4:
            nerdSymbolsReferenceFont
        case 0x1FB00...0x1FBEF, 0x1CC1B...0x1CC1E, 0x1CC21...0x1CC3F,
             0x1CD00...0x1CDE5, 0x1CE00...0x1CE01, 0x1CE0B...0x1CE0C,
             0x1CE16...0x1CE19, 0x1CE51...0x1CEAF:
            unifontUpperReferenceFont
        default:
            systemReferenceFont
        }
    }

    private func drawSectionHeadings(in context: CGContext, visibleRows: Range<Int>) {
        for (index, section) in sections.enumerated() {
            let row = layout.sections[index].headingRow
            guard visibleRows.contains(row) else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: headingFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    NSColor.secondaryLabelColor.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: section.title,
                attributes: attributes
            ))
            context.textMatrix = CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: -1,
                tx: 2,
                ty: CGFloat(row) * metrics.cellSize.height + metrics.baselineOffset
            )
            CTLineDraw(line, context)
        }
    }
}

let application = NSApplication.shared
let delegate = GlyphPreviewAppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
