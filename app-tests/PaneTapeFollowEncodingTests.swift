// Pins stream event payloads to the neutral recording encoder used by replay snapshots.
import Foundation
import Testing
import DanTermProtocol
import TerminalCoreRecording
@testable import DanTerm

struct PaneTapeFollowEncodingTests {
    @Test("stream event payloads equal neutral feed and resize encodings")
    func streamPayloadsUseNeutralEncoding() throws {
        // Intent: stream event objects are byte-semantically identical to neutral events.
        // Why it exists: a second hand-written event dialect could drift from replay tapes.
        // Scenario: one followed pane emits output bytes and then changes character geometry.
        for event in [
            NeutralTerminalRecordingEvent.feed(Array("Hi".utf8)),
            .write(Array("ls".utf8)),
            .resize(columns: 100, rows: 30, pinned: true),
        ] {
            let directData = try JSONEncoder().encode(event)
            let direct = try JSONDecoder().decode(JSONValue.self, from: directData)
            let adapted = try paneTapeFollowEventJSON(event)
            let batch = makePaneTapeBatch(from: .init(
                events: [.init(
                    sequence: 1,
                    elapsedNanoseconds: 2,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: 0, byteLength: 2),
                    event: adapted
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

            #expect(batch.records.first?["event"] == direct)
        }
    }
}
