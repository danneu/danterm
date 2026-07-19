// Behavioral tests for the shared neutral recording decoder and replay path.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves DanTerm-authored recordings use the same public replay path as corpus evidence.
struct NeutralTerminalRecordingTests {
    @Test("DanTerm recordings encode, decode, and replay output around resize")
    func danTermRecordingRoundTrip() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "output-resize-output"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("before".utf8)),
                .resize(columns: 12, rows: 3),
                .feed(Array("\nafter".utf8)),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        let replayed = try decoded.replay()

        #expect(decoded == recording)
        #expect(replayed.geometry.columns == 12)
        #expect(replayed.geometry.rows.count == 3)
        #expect(replayed.screenText.contains("after"))
    }
}
