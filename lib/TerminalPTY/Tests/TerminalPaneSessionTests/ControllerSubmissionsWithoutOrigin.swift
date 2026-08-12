// Origin-free submission spellings for the controller tests that are not about input origin.
//
// `TerminalPaneSessionController`'s submissions take `origin` with no default, so a production
// call site cannot forget the stamp: omitting it is a compile error rather than a silent claim
// that the bytes originated at the pane itself. That requirement is worth its weight in `app/`,
// where a missing stamp corrupts what a tape reports about app-owned time. It buys nothing in
// these tests, which submit input to drive a controller and never read a tape back.
//
// These are plain overloads rather than defaulted parameters, and they live in the test target,
// so the production requirement stays intact everywhere it means anything. A test that *is*
// about origin calls the real submission and states its stamp.
import TerminalCore

@testable import TerminalPaneSession

extension TerminalPaneSessionController {
    func sendText(_ text: String) { sendText(text, origin: nil) }

    func send(_ bytes: [UInt8]) { send(bytes, origin: nil) }

    func sendKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {
        sendKey(key, modifiers: modifiers, origin: nil)
    }

    func sendPaste(_ text: String) { sendPaste(text, origin: nil) }

    func sendFocus(_ focused: Bool) { sendFocus(focused, origin: nil) }

    func sendPointer(_ event: TerminalPointerEvent) { sendPointer(event, origin: nil) }

    func sendWheel(_ event: TerminalWheelEvent) { sendWheel(event, origin: nil) }
}
