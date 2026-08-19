// Coverage for the reader's own side of the stream: assembling a multi-part state transfer.
// The record shape's decode and the notification envelope that carries it are covered beside
// their declarations in DanTermProtocol.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

struct PaneTapeRecordReaderTests {
    @Test("a state sync becomes visible only after its final ordered part")
    func stateSyncAssemblesAtomically() throws {
        let cursor = PaneTapeCursor(
            recorderLifetimeId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            nextSequence: 41,
            feedBytesBeforeNextSequence: 100,
            writeBytesBeforeNextSequence: 7
        )
        var assembler = PaneTapeSyncAssembler()

        #expect(assembler.ingest(PaneTapeSyncRecord(
            part: 1,
            parts: 2,
            bytes: Array("sta".utf8),
            transfer: PaneTapeSyncRecord.Transfer(
                columns: 80,
                rows: 24,
                pinned: true,
                droppedHistoryRows: 0
            ),
            cursor: nil
        )) == nil)
        #expect(assembler.ingest(PaneTapeSyncRecord(
            part: 2,
            parts: 2,
            bytes: Array("te".utf8),
            transfer: nil,
            cursor: cursor
        )) == PaneTapeStateSynchronization(
            bytes: Array("state".utf8),
            columns: 80,
            rows: 24,
            pinned: true,
            droppedHistoryRows: 0,
            cursor: cursor
        ))
    }

    // Intent: the dropped-history count a producer states on the first part survives
    //   multi-part assembly and arrives on the completed synchronization.
    // Why it exists: a replica decides whether its own history is complete from this one
    //   number. Losing it during assembly -- the only place a multi-part transfer can lose a
    //   first-part fact -- would silently promote a truncated replica to a complete one.
    // Scenario: spec-first contract for the bounded sync a reader assembles.
    @Test("an assembled sync carries the dropped history count from its first part")
    func assembledSyncCarriesDroppedHistoryRows() throws {
        let cursor = PaneTapeCursor(
            recorderLifetimeId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            nextSequence: 41,
            feedBytesBeforeNextSequence: 100,
            writeBytesBeforeNextSequence: 7
        )
        var assembler = PaneTapeSyncAssembler()

        #expect(assembler.ingest(PaneTapeSyncRecord(
            part: 1,
            parts: 2,
            bytes: Array("sta".utf8),
            transfer: PaneTapeSyncRecord.Transfer(
                columns: 80,
                rows: 24,
                pinned: false,
                droppedHistoryRows: 512
            ),
            cursor: nil
        )) == nil)
        let assembled = assembler.ingest(PaneTapeSyncRecord(
            part: 2,
            parts: 2,
            bytes: Array("te".utf8),
            transfer: nil,
            cursor: cursor
        ))
        #expect(assembled?.droppedHistoryRows == 512)
    }
}
