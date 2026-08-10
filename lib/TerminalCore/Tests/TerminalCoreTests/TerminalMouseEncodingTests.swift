// Verifies pure X10 and SGR mouse bytes plus explicit tracker-state transitions.
import Testing

@testable import TerminalCore

/// Pins mouse wire compatibility independently from AppKit and PTY ownership.
struct TerminalMouseEncodingTests {
    @Test("X10 encodes buttons modifiers releases wheels and bounded coordinates")
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

        #expect(encode(.move(column: 300, row: 300), tracker: &tracker, modes: modes).isEmpty)
        #expect(encode(.down(.left, column: 300, row: 300), tracker: &tracker, modes: modes) == [0x1B, 0x5B, 0x4D, 0x20, 0xFF, 0xFF])
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
