// UI-harness tests for the passive link-preview pill's frame math, dodge
// behavior, styling, and non-hit-testing event contract.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func linkPreviewViewTests() async {
    print("LinkPreviewView")

    await uiTest("dodge moves right when pointer is inside the left pill frame") {
        let leftFrame = NSRect(x: 0, y: 0, width: 120, height: 24)

        let side = linkPreviewDodgeSide(pointer: NSPoint(x: 40, y: 10), leftPillFrame: leftFrame)

        try uiExpect(side == .right, "pointer inside left frame should dodge right")
    }

    await uiTest("dodge stays left when pointer is outside the left pill frame") {
        let leftFrame = NSRect(x: 0, y: 0, width: 120, height: 24)

        let side = linkPreviewDodgeSide(pointer: NSPoint(x: 140, y: 10), leftPillFrame: leftFrame)

        try uiExpect(side == .left, "pointer outside left frame should leave the pill left")
    }

    await uiTest("dodge region is the fixed left frame regardless of current side") {
        // Intent: the dodge decision is keyed to the bottom-left pill footprint,
        //   not the pill's current frame.
        // Why it exists: mirrors upstream Ghostty's left-pill hover driver and
        //   prevents left/right oscillation when the visible pill sits on the
        //   right. Spec-first.
        // Scenario: a link under the left pill moves the preview right; while
        //   the pointer is over that right-side pill frame, the next decision
        //   should send the preview back left.
        let leftFrame = NSRect(x: 0, y: 0, width: 120, height: 24)
        let rightFrame = NSRect(x: 280, y: 0, width: 120, height: 24)

        let side = linkPreviewDodgeSide(pointer: NSPoint(x: rightFrame.midX, y: rightFrame.midY),
                                        leftPillFrame: leftFrame)

        try uiExpect(side == .left, "right-side frame should not be the dodge region")
    }

    await uiTest("left frame anchors at origin") {
        let frame = linkPreviewFrame(side: .left,
                                     fittingSize: NSSize(width: 160, height: 24),
                                     containerWidth: 400)

        try uiExpect(frame.origin == .zero, "left frame should anchor at origin, got \(frame)")
    }

    await uiTest("right frame anchors at bottom right") {
        let frame = linkPreviewFrame(side: .right,
                                     fittingSize: NSSize(width: 160, height: 24),
                                     containerWidth: 400)

        try uiExpect(frame.maxX == 400 && frame.minY == 0, "right frame should anchor bottom-right, got \(frame)")
    }

    await uiTest("frame width is capped at container width") {
        let frame = linkPreviewFrame(side: .left,
                                     fittingSize: NSSize(width: 800, height: 24),
                                     containerWidth: 300)

        try uiExpect(frame.width == 300, "frame width should be capped, got \(frame.width)")
    }

    await uiTest("show unhides and displays URL, hide hides") {
        let view = LinkPreviewView()

        view.show(url: "https://example.com/path")
        try uiExpect(!view.isHidden, "show should unhide the pill")
        try uiExpect(view.label.stringValue == "https://example.com/path", "show should set label text")

        view.hide()
        try uiExpect(view.isHidden, "hide should hide the pill")
    }

    await uiTest("pointerMoved out of the left region moves the frame back to bottom-left") {
        let view = LinkPreviewView()
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 200)
        view.show(url: "https://example.com")
        view.layoutPill(in: bounds)
        let leftFrame = view.frame

        view.pointerMoved(to: NSPoint(x: leftFrame.midX, y: leftFrame.midY), in: bounds)
        try uiExpect(view.frame.maxX == bounds.width, "pointer in left region should move pill right, got \(view.frame)")

        view.pointerMoved(to: NSPoint(x: bounds.midX, y: bounds.midY), in: bounds)

        try uiExpect(view.frame.minX == 0 && view.frame.minY == 0, "pointer outside left region should move pill left, got \(view.frame)")
    }

    await uiTest("hitTest returns nil") {
        let view = LinkPreviewView()
        view.show(url: "https://example.com")
        view.layoutPill(in: NSRect(x: 0, y: 0, width: 300, height: 100))

        try uiExpect(view.hitTest(NSPoint(x: 1, y: 1)) == nil, "pill should never receive hits")
        try uiExpect(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil,
                     "pill should not receive interior hits")
    }

    await uiTest("label truncates middle on a single line") {
        let view = LinkPreviewView()

        try uiExpect(view.label.lineBreakMode == .byTruncatingMiddle, "label should truncate in the middle")
        try uiExpect(view.label.cell?.truncatesLastVisibleLine == true,
                     "label cell should truncate the last visible line")
        try uiExpect(view.label.maximumNumberOfLines == 1, "label should be single-line")
    }

    await uiTest("pill gives the label its full required width in a wide pane") {
        // Intent: after show + layoutPill in a pane with room to spare, the
        //   label's frame is at least the width its own cell needs to draw
        //   without truncation.
        // Why it exists: guards the measure/render seam -- pill width must come
        //   from the same machinery that draws the text (cellSize), not a raw
        //   NSAttributedString measurement.
        // Scenario: 2026-07-09 incident -- pill sized labels from
        //   NSAttributedString.size(), ~4pt short of NSTextFieldCell's needs,
        //   so https://example.com middle-truncated to https://e...ple.com in
        //   panes with hundreds of points to spare.
        let view = LinkPreviewView()
        view.show(url: "https://example.com")
        view.layoutPill(in: NSRect(x: 0, y: 0, width: 800, height: 200))

        let needed = view.label.cell?.cellSize.width ?? .infinity
        try uiExpect(needed <= view.label.frame.width,
                     "label needs \(needed)pt but got \(view.label.frame.width)pt")
    }

    await uiTest("masked corners follow the current side") {
        let view = LinkPreviewView()
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 200)
        view.show(url: "https://example.com")
        view.layoutPill(in: bounds)

        try uiExpect(view.layer?.maskedCorners == [.layerMaxXMaxYCorner],
                     "left pill should round only top-right, got \(String(describing: view.layer?.maskedCorners))")

        let leftFrame = view.frame
        view.pointerMoved(to: NSPoint(x: leftFrame.midX, y: leftFrame.midY), in: bounds)

        try uiExpect(view.layer?.maskedCorners == [.layerMinXMaxYCorner],
                     "right pill should round only top-left, got \(String(describing: view.layer?.maskedCorners))")
    }

    await uiTest("pointerMoved into the left region moves the frame to bottom-right") {
        let view = LinkPreviewView()
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 200)
        view.show(url: "https://example.com")
        view.layoutPill(in: bounds)
        let leftFrame = view.frame

        view.pointerMoved(to: NSPoint(x: leftFrame.midX, y: leftFrame.midY), in: bounds)

        try uiExpect(view.frame.maxX == bounds.width && view.frame.minY == 0,
                     "pointer in left region should move pill bottom-right, got \(view.frame)")
    }
}
