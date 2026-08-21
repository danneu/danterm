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
            bytes: Data("sta".utf8),
            transfer: PaneTapeSyncRecord.Transfer(
                columns: 80,
                rows: 24,
                pinned: true,
                droppedHistoryRows: 0,
                focused: false
            ),
            cursor: nil
        )) == nil)
        #expect(assembler.ingest(PaneTapeSyncRecord(
            part: 2,
            parts: 2,
            bytes: Data("te".utf8),
            transfer: nil,
            cursor: cursor
        )) == PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            columns: 80,
            rows: 24,
            pinned: true,
            droppedHistoryRows: 0,
            focused: false,
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
            bytes: Data("sta".utf8),
            transfer: PaneTapeSyncRecord.Transfer(
                columns: 80,
                rows: 24,
                pinned: false,
                droppedHistoryRows: 512,
                focused: false
            ),
            cursor: nil
        )) == nil)
        let assembled = assembler.ingest(PaneTapeSyncRecord(
            part: 2,
            parts: 2,
            bytes: Data("te".utf8),
            transfer: nil,
            cursor: cursor
        ))
        #expect(assembled?.droppedHistoryRows == 512)
    }

    // Intent: the effective focus a producer states on the first part survives multi-part
    //   assembly and arrives on the completed synchronization.
    // Why it exists: focus is the one whole-transfer fact the state bytes cannot restate, so
    //   an assembler that dropped it would hand a replica focus the pane never held, and the
    //   replica would answer a later `DECSET 1004` with the wrong report.
    // Scenario: spec-first contract for the sync a reader assembles for a focused pane.
    @Test("an assembled sync carries the effective focus from its first part")
    func assembledSyncCarriesFocus() throws {
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
            bytes: Data("sta".utf8),
            transfer: PaneTapeSyncRecord.Transfer(
                columns: 80,
                rows: 24,
                pinned: false,
                droppedHistoryRows: 0,
                focused: true
            ),
            cursor: nil
        )) == nil)
        let assembled = assembler.ingest(PaneTapeSyncRecord(
            part: 2,
            parts: 2,
            bytes: Data("te".utf8),
            transfer: nil,
            cursor: cursor
        ))
        #expect(assembled?.focused == true)
    }
}
