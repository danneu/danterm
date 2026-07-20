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

    @Test("recording replay drains core replies after every feed")
    func replayDrainsReplies() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "query-output"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("\u{1B}[6n".utf8)),
                .feed(Array("visible".utf8)),
            ]
        )

        let replayed = try recording.replay()

        #expect(replayed.pendingReplyBytes.isEmpty)
        #expect(replayed.screenText.contains("visible"))
    }

    @Test("viewport navigation encodes, decodes, and replays whole-value exactly")
    func viewportNavigationRoundTrip() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "viewport-navigation"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("one\ntwo\nthree\nfour".utf8)),
                .viewport(.byRows(-1)),
                .viewport(.toTopRow(0)),
                .viewport(.toBottom),
                .viewport(.byRows(-1)),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        let replayed = try decoded.replay()
        var expected = try #require(Terminal(columns: 8, rows: 2))
        expected.feed(Array("one\ntwo\nthree\nfour".utf8))
        expected.scroll(byRows: -1)
        expected.scroll(toTopRow: 0)
        expected.scrollToBottom()
        expected.scroll(byRows: -1)

        #expect(decoded == recording)
        #expect(replayed == expected)
        #expect(replayed.scrollProjection.isFollowing == false)
    }

    @Test("legacy recordings decode without viewport events")
    func legacyRecordingCompatibility() throws {
        let data = Data(#"""
        {
          "version": 1,
          "provenance": {"source":"danterm","author":"DanTerm","test":"legacy"},
          "initial": {"columns": 8, "rows": 2},
          "events": [
            {"type":"feed", "text":"legacy"},
            {"type":"resize", "columns": 10, "rows": 3}
          ]
        }
        """#.utf8)

        let recording = try JSONDecoder().decode(NeutralTerminalRecording.self, from: data)

        #expect(recording.events == [
            .feed(Array("legacy".utf8)),
            .resize(columns: 10, rows: 3),
        ])
        #expect(try recording.replay().geometry.columns == 10)
    }
}
