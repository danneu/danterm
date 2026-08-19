// Pins stream event payloads to the neutral recording encoder used by replay snapshots.
import Foundation
import Testing
import DanTermProtocol
import TerminalCoreRecording
@testable import DanTerm

struct PaneTapeFollowEncodingTests {
    @Test("stream event payloads equal neutral feed, write, resize, and checkpoint encodings")
    func streamPayloadsUseNeutralEncoding() throws {
        // Intent: the `event` object a record puts on the wire is byte-for-byte the encoding
        //   the neutral recording event writes for itself.
        // Why it exists: the producer carries the engine's event through to the wire encoder
        //   rather than restating it. A second dialect anywhere on that path -- a hand-built
        //   object, a re-keyed copy -- would drift from the replay tapes readers expect.
        // Scenario: one followed pane emits non-ASCII output bytes, input bytes, a geometry
        //   change, and a checkpoint marker.
        for event in [
            NeutralTerminalRecordingEvent.feed(Array("Hi \u{1F602}".utf8)),
            .write(Array("ls".utf8)),
            .resize(columns: 100, rows: 30, pinned: true),
            .checkpoint,
        ] {
            let batch = makePaneTapeBatch(from: PaneTapeSnapshot(
                events: [.init(
                    sequence: 1,
                    elapsedNanoseconds: 2,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: 0, byteLength: 2),
                    event: event,
                    needsCompleteHistory: paneTapeEventNeedsCompleteHistory(event)
                )],
                droppedEventCount: 0,
                droppedFeedBytes: 0,
                droppedWriteBytes: 0,
                nextCursor: .init(
                    recorderLifetimeId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                    nextSequence: 2,
                    feedBytesBeforeNextSequence: 2,
                    writeBytesBeforeNextSequence: 0
                )
            ))

            let record = try #require(batch.records.first)
            let written = try JSONDecoder().decode(
                JSONValue.self,
                from: try encodeIpcLine(record)
            )
            let alone = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(event)
            )
            #expect(written[PaneTapeRecordKey.event] == alone)
        }
    }

    // Intent: the resize is the only recorded event a replica cannot replay without the
    //   source's whole history.
    // Why it exists: a bounded stream replaces a suffix carrying such an event with a fresh
    //   sync. Classifying an ordinary event that way would resync on plain output and throw
    //   away the incremental path; missing the resize would hand a truncated replica a reflow
    //   it computes differently from the source.
    // Scenario: spec-first contract for the one engine fact the resize-resync rule rests on.
    @Test("a resize is the only recorded event that needs the replica's whole history")
    func onlyAResizeNeedsCompleteHistory() {
        #expect(paneTapeEventNeedsCompleteHistory(.resize(columns: 100, rows: 30, pinned: false)))
        for event: NeutralTerminalRecordingEvent in [
            .feed(Array("Hi".utf8)),
            .write(Array("ls".utf8)),
            .paste("text"),
            .focus(true),
            .checkpoint,
        ] {
            #expect(paneTapeEventNeedsCompleteHistory(event) == false)
        }
    }
}
