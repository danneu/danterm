// Behavioral coverage for choosing the pane-tape encoding or unsupported-backend reply.
import Foundation
import Testing
@testable import DanTermSupport

struct PaneTapeDumpPreparationTests {
    @Test("missing pane recorder prepares the unsupported-backend RPC error")
    func missingRecorderPreparesUnsupportedError() {
        let preparation = preparePaneTapeDump(encoder: nil)

        guard case .error(let code, let message) = preparation else {
            Issue.record("expected unsupported-backend error preparation")
            return
        }
        #expect(code == -32603)
        #expect(message == "pane tape unavailable for this terminal backend")
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
