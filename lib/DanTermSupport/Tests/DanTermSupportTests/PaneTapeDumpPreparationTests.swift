// Behavioral coverage for choosing the pane-tape encoding or unsupported-backend reply.
import Foundation
import Testing
@testable import DanTermSupport

struct PaneTapeDumpPreparationTests {
    // Intent: the only tape failure names the one condition that can produce it.
    // Why it exists: every terminal pane now records, so the former
    //   unsupported-backend wording described a configuration that cannot occur and
    //   sent an incident investigation after the terminal backend instead of the app.
    @Test("a session without a terminal prepares the no-terminal RPC error")
    func sessionWithoutTerminalPreparesNoTerminalError() {
        let preparation = preparePaneTapeDump(encoder: nil)

        guard case .error(let code, let message) = preparation else {
            Issue.record("expected no-terminal error preparation")
            return
        }
        #expect(code == -32603)
        #expect(message == "pane has no terminal to read a tape from")
    }

    @Test("available pane recorder preserves deferred encoding work")
    func availableRecorderPreservesEncoding() throws {
        let expected = Data([0x7B, 0x7D])
        let preparation = preparePaneTapeDump(encoder: { expected })

        guard case .encode(let encode) = preparation else {
            Issue.record("expected deferred encoder preparation")
            return
        }
        #expect(try encode() == expected)
    }
}
