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
            .resize(columns: 100, rows: 30),
        ] {
            let directData = try JSONEncoder().encode(event)
            let direct = try JSONDecoder().decode(JSONValue.self, from: directData)
            let adapted = try paneTapeFollowEventJSON(event)
            let batch = makePaneTapeFollowBatch(from: .init(
                events: [.init(
                    sequence: 1,
                    elapsedNanoseconds: 2,
                    originElapsedNanoseconds: nil,
                    event: adapted
                )],
                droppedEventCount: 0,
                droppedPayloadBytes: 0,
                nextCursor: .init(nextSequence: 2, payloadBytesBeforeNextSequence: 2)
            ))

            #expect(batch.records.first?["event"] == direct)
        }
    }
}
