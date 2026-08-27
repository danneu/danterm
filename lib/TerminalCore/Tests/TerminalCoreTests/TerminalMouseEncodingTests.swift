// Verifies pure X10 and SGR mouse bytes plus explicit tracker-state transitions.
import Testing

@testable import TerminalCore

/// Pins mouse wire compatibility independently from AppKit and PTY ownership.
struct TerminalMouseEncodingTests {
    @Test("X10 encodes buttons modifiers releases and wheels")
    func x10Matrix() {
        var tracker = TerminalMouseTracker()
        let modes = TerminalInputModes(mouseTracking: .click)

        #expect(encode(.move(column: 20, row: 10), tracker: &tracker, modes: modes).isEmpty)
        #expect(encode(.down(.left, column: 20, row: 10, modifiers: [.control]), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x30, 0x35, 0x2B])
        #expect(encode(.up(.left, column: 20, row: 10, modifiers: [.control]), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x33, 0x35, 0x2B])
        #expect(encode(.down(.middle, column: 20, row: 10), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x21, 0x35, 0x2B])
        #expect(encode(.up(.middle, column: 20, row: 10), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x23, 0x35, 0x2B])
        #expect(encode(.down(.right, column: 20, row: 10, modifiers: [.shift, .alt]), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x2E, 0x35, 0x2B])
        #expect(encode(.up(.right, column: 20, row: 10), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x23, 0x35, 0x2B])

        for (direction, code) in zip(
            [TerminalMouseWheelDirection.up, .down, .left, .right],
            [UInt8(0x60), 0x61, 0x62, 0x63]
        ) {
            #expect(encode(.wheel(direction, column: 20, row: 10), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, code, 0x35, 0x2B])
        }
    }

    // Intent: a legacy report carries each coordinate in a single byte, so a
    // cell past 222 has no encoding at all -- the encoder sends nothing rather
    // than a byte naming a cell the pointer was not on.
    // Why it exists: DanTerm used to clamp the byte to 0xFF, following
    // `libvterm/src/mouse.c#output_mouse`, which reports column 222 for every
    // column past it. `ghostty/src/Surface.zig#mouseReport`,
    // `vte/src/vte.cc#Terminal::feed_mouse_event`,
    // `kitty/kitty/mouse.c#encode_mouse_event_impl`,
    // `foot/terminal.c#report_mouse_click`, and
    // `windows-terminal/src/terminal/input/mouseInput.cpp#_GenerateDefaultSequence`
    // all suppress instead.
    // Scenario: a pane wide enough to hold column 223 -- ordinary at 4K with a
    // small font -- under mode 1000 with SGR off.
    @Test("X10 sends nothing for a cell that one coordinate byte cannot name")
    func x10UnencodableCoordinates() {
        var tracker = TerminalMouseTracker()
        let legacy = TerminalInputModes(mouseTracking: .click)

        #expect(encode(.down(.left, column: 222, row: 222), tracker: &tracker, modes: legacy) == [0x1B, 0x5B, 0x4D, 0x20, 0xFF, 0xFF])
        #expect(encode(.up(.left, column: 222, row: 222), tracker: &tracker, modes: legacy) == [0x1B, 0x5B, 0x4D, 0x23, 0xFF, 0xFF])

        for (column, row) in [(223, 0), (0, 223), (400, 400), (-1, 0), (0, -1)] {
            #expect(encode(.down(.left, column: column, row: row), tracker: &tracker, modes: legacy).isEmpty)
            #expect(encode(.up(.left, column: column, row: row), tracker: &tracker, modes: legacy).isEmpty)
            #expect(encode(.wheel(.up, column: column, row: row), tracker: &tracker, modes: legacy).isEmpty)
        }

        // The tracker advanced through every suppressed report, so the next
        // in-range press still names its own cell.
        #expect(encode(.down(.left, column: 10, row: 10), tracker: &tracker, modes: legacy) == [0x1B, 0x5B, 0x4D, 0x20, 0x2B, 0x2B])

        // SGR has no one-byte limit, so the same cells still report there.
        var sgrTracker = TerminalMouseTracker()
        let sgr = TerminalInputModes(mouseTracking: .click, sgrMouseEncoding: true)
        #expect(encode(.down(.left, column: 223, row: 400), tracker: &sgrTracker, modes: sgr) == Array("\u{1B}[<0;224;401M".utf8))
    }

    @Test("SGR preserves button identity on release and passes through large coordinates")
    func sgrMatrix() {
        var tracker = TerminalMouseTracker()
        let modes = TerminalInputModes(mouseTracking: .click, sgrMouseEncoding: true)

        for (button, code) in zip(
            [TerminalMouseButton.left, .middle, .right],
            [0, 1, 2]
        ) {
            #expect(encode(.down(button, column: 300, row: 300), tracker: &tracker, modes: modes) == Array("\u{1B}[<\(code);301;301M".utf8))
            #expect(encode(.up(button, column: 300, row: 300), tracker: &tracker, modes: modes) == Array("\u{1B}[<\(code);301;301m".utf8))
        }
        #expect(encode(.wheel(.right, column: 300, row: 300, modifiers: [.alt]), tracker: &tracker, modes: modes) == Array("\u{1B}[<75;301;301M".utf8))
    }

    @Test("drag and any-motion reporting use held-button state and suppress duplicate cells")
    func motionSuppression() {
        var tracker = TerminalMouseTracker()
        let drag = TerminalInputModes(mouseTracking: .drag)

        #expect(encode(.move(column: 5, row: 5), tracker: &tracker, modes: drag).isEmpty)
        #expect(encode(.down(.middle, column: 5, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x21, 0x26, 0x26])
        #expect(encode(.down(.left, column: 5, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x20, 0x26, 0x26])
        #expect(encode(.move(column: 6, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x40, 0x27, 0x26])
        #expect(encode(.move(column: 6, row: 5), tracker: &tracker, modes: drag).isEmpty)
        #expect(encode(.up(.left, column: 6, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x23, 0x27, 0x26])
        #expect(encode(.move(column: 7, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x41, 0x28, 0x26])
        #expect(encode(.up(.middle, column: 7, row: 5), tracker: &tracker, modes: drag) == [0x1B, 0x5B, 0x4D, 0x23, 0x28, 0x26])
        #expect(encode(.move(column: 8, row: 5), tracker: &tracker, modes: drag).isEmpty)

        let anyMotion = TerminalInputModes(mouseTracking: .anyMotion)
        #expect(encode(.move(column: 9, row: 5), tracker: &tracker, modes: anyMotion) == [0x1B, 0x5B, 0x4D, 0x43, 0x2A, 0x26])
    }

    @Test("redundant button transitions are silent but wheels remain repeatable")
    func transitionSuppression() {
        var tracker = TerminalMouseTracker()
        let modes = TerminalInputModes(mouseTracking: .click)

        #expect(encode(.down(.left, column: 0, row: 0), tracker: &tracker, modes: modes).isEmpty == false)
        #expect(encode(.down(.left, column: 1, row: 1), tracker: &tracker, modes: modes).isEmpty)
        #expect(encode(.up(.left, column: 2, row: 2), tracker: &tracker, modes: modes).isEmpty == false)
        #expect(encode(.up(.left, column: 3, row: 3), tracker: &tracker, modes: modes).isEmpty)
        #expect(encode(.wheel(.up, column: 4, row: 4), tracker: &tracker, modes: modes).isEmpty == false)
        #expect(encode(.wheel(.up, column: 5, row: 5), tracker: &tracker, modes: modes).isEmpty == false)
    }

    @Test("tracker updates while disabled before later mode-gated reports")
    func disabledStateUpdates() {
        var tracker = TerminalMouseTracker()

        #expect(encode(.move(column: 4, row: 7), tracker: &tracker, modes: .default).isEmpty)
        #expect(encode(.down(.left, column: 4, row: 7), tracker: &tracker, modes: .default).isEmpty)
        #expect(encode(.down(.left, column: 8, row: 9), tracker: &tracker, modes: TerminalInputModes(mouseTracking: .click)).isEmpty)
        #expect(encode(.up(.left, column: 8, row: 9), tracker: &tracker, modes: TerminalInputModes(mouseTracking: .click)) == [0x1B, 0x5B, 0x4D, 0x23, 0x29, 0x2A])
    }

    private func encode(
        _ event: TerminalMouseReportEvent,
        tracker: inout TerminalMouseTracker,
        modes: TerminalInputModes
    ) -> [UInt8] {
        encodeTerminalMouse(event, tracker: &tracker, modes: modes)
    }
}
