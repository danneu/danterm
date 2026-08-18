// Behavioral coverage for choosing raw events or an atomic terminal-state synchronization.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermSupport

struct PaneTapeStreamStateTests {
    private static let lifetimeId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("reconstructible beginning replays a complete retained tape without a sync")
    func completeBeginningNeedsNoSync() {
        let opening = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .beginning),
            fence: fence(retainedSequences: [0, 1])
        )

        #expect(opening.start.record["reconstructible"] == .bool(true))
        #expect(opening.start.record["cursor"] != nil)
        #expect(opening.records.compactMap(sequence) == [0, 1])
        #expect(opening.records.contains { $0["kind"] == .string("sync") } == false)
        #expect(opening.nextCursor.nextSequence == 2)
    }

    @Test("reconstructible eviction states exact loss and replaces the suffix with a sync")
    func evictedBeginningUsesSync() throws {
        let opening = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .beginning),
            fence: fence(retainedSequences: [4, 5], droppedEventCount: 4)
        )

        #expect(opening.start.record["cursor"] == nil)
        #expect(opening.records.first == .object([
            "kind": .string("gap"),
            "droppedEventCount": .number(4),
            "droppedFeedBytes": .number(4),
            "droppedWriteBytes": .number(0),
        ]))
        #expect(opening.records.compactMap(sequence).isEmpty)
        let sync = opening.records.filter { $0["kind"] == .string("sync") }
        #expect(sync.isEmpty == false)
        #expect(try synchronizationBytes(sync) == Array("state".utf8))
        #expect(sync.dropLast().allSatisfy { $0["cursor"] == nil })
        #expect(sync.last?["cursor"] == cursorJSON(sequence: 6, feed: 6))
        #expect(opening.nextCursor.nextSequence == 6)
    }

    @Test("from-now reconstructible starts with state while raw starts at the live cursor")
    func fromNowDependsOnMode() {
        let streamFence = fence(retainedSequences: [0, 1])
        let reconstructible = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            fence: streamFence
        )
        let raw = makePaneTapeOpening(
            request: .init(capture: .follow, policy: .raw, position: .now),
            fence: streamFence
        )

        #expect(reconstructible.start.record["cursor"] == nil)
        #expect(reconstructible.records.map { $0["kind"] } == [.string("sync")])
        #expect(raw.start.record["reconstructible"] == .bool(false))
        #expect(raw.start.record["cursor"] == cursorJSON(sequence: 2, feed: 2))
        #expect(raw.records.isEmpty)
    }

    @Test("a placeable resume continues directly or synchronizes after exact loss")
    func placeableResumeDependsOnLoss() {
        let requested = cursor(sequence: 1, feed: 1)
        let contiguous = makePaneTapeOpening(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(requested)
            ),
            fence: fence(
                retainedSequences: [0, 1, 2],
                requested: .placed(snapshot(sequences: [1, 2], nextSequence: 3))
            )
        )
        let evicted = makePaneTapeOpening(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(requested)
            ),
            fence: fence(
                retainedSequences: [2, 3],
                requested: .placed(snapshot(
                    sequences: [2, 3],
                    nextSequence: 4,
                    droppedEventCount: 1
                ))
            )
        )
        let rawEvicted = makePaneTapeOpening(
            request: .init(capture: .follow, policy: .raw, position: .cursor(requested)),
            fence: fence(
                retainedSequences: [2, 3],
                requested: .placed(snapshot(
                    sequences: [2, 3],
                    nextSequence: 4,
                    droppedEventCount: 1
                ))
            )
        )

        #expect(contiguous.start.record["cursor"] == cursorJSON(sequence: 1, feed: 1))
        #expect(contiguous.records.compactMap(sequence) == [1, 2])
        #expect(evicted.records.first?["kind"] == .string("gap"))
        #expect(evicted.records.compactMap(sequence).isEmpty)
        #expect(evicted.records.last?["kind"] == .string("sync"))
        #expect(rawEvicted.records.first?["droppedEventCount"] == .number(1))
        #expect(rawEvicted.records.dropFirst().compactMap(sequence) == [2, 3])
    }

    @Test("an unplaceable cursor reports total loss in both modes")
    func unplaceableCursorUsesTotalLoss() {
        let foreign = PaneTapeCursor(
            recorderLifetimeId: UUID(),
            nextSequence: 40,
            feedBytesBeforeNextSequence: 100,
            writeBytesBeforeNextSequence: 20
        )
        let streamFence = fence(retainedSequences: [4, 5], droppedEventCount: 4, requested: .unplaceable)
        let reconstructible = makePaneTapeOpening(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(foreign)
            ),
            fence: streamFence
        )
        let raw = makePaneTapeOpening(
            request: .init(capture: .follow, policy: .raw, position: .cursor(foreign)),
            fence: streamFence
        )

        let totalGap: JSONValue = .object(["kind": .string("gap"), "loss": .string("total")])
        #expect(reconstructible.records.first == totalGap)
        #expect(reconstructible.records.compactMap(sequence).isEmpty)
        #expect(reconstructible.records.last?["kind"] == .string("sync"))
        #expect(raw.records.first == totalGap)
        #expect(raw.records.dropFirst().compactMap(sequence) == [4, 5])
        #expect(raw.start.record["cursor"] == cursorJSON(sequence: 4, feed: 4))
    }

    @Test("sync chunks fit the IPC line bound and publish the cursor only on completion")
    func syncChunksAreAtomicAndBounded() throws {
        let bytes = [UInt8](repeating: 0x41, count: IpcLineFramer.maxLineBytes + 1)
        var streamFence = fence(retainedSequences: [])
        streamFence = PaneTapeStreamFence(
            origin: streamFence.origin,
            retained: streamFence.retained,
            requested: streamFence.requested,
            synchronization: .init(
                bytes: bytes,
                dimensions: .init(columns: 179, rows: 66, pinned: false),
                droppedHistoryRows: 0,
                cursor: streamFence.synchronization.cursor
            )
        )

        let opening = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            fence: streamFence
        )
        let records = opening.records

        #expect(records.count > 1)
        #expect(records.dropLast().allSatisfy { $0["cursor"] == nil })
        #expect(records.last?["cursor"] != nil)
        #expect(records.first?["initial"] == .object([
            "columns": .number(179),
            "rows": .number(66),
            "pinned": .bool(false),
        ]))
        #expect(try synchronizationBytes(records) == bytes)
        for record in records {
            var encoded = try JSONEncoder().encode(JsonRpcRequest(
                method: Methods.paneTapeEvent,
                params: .object([
                    "subscription": .string(UUID().uuidString),
                    "record": record,
                ])
            ))
            encoded.append(0x0A)
            var framer = IpcLineFramer()
            #expect(framer.append(encoded) == [.line(encoded.dropLast())])
        }
    }

    @Test("both geometry-bearing opening shapes state the pane's pinnedness")
    func openingShapesStatePinnedness() {
        // Intent: whichever opening a request selects -- retained events behind a start
        //   record, or an injected state sync -- the geometry it publishes carries the
        //   pinned bit beside its columns and rows.
        // Why it exists: a replica learns pinnedness from the stream and nowhere else. An
        //   opening that stated a grid without it would leave the replica guessing until
        //   the pane's next resize, which may never come.
        // Scenario: one pane running at a claimed grid, opened from the beginning and
        //   from now.
        var pinnedFence = fence(retainedSequences: [0, 1])
        pinnedFence = PaneTapeStreamFence(
            origin: .init(
                initial: .init(columns: 80, rows: 24, pinned: true),
                cursor: pinnedFence.origin.cursor
            ),
            retained: pinnedFence.retained,
            requested: pinnedFence.requested,
            synchronization: .init(
                bytes: Array("state".utf8),
                dimensions: .init(columns: 100, rows: 30, pinned: true),
                droppedHistoryRows: 0,
                cursor: pinnedFence.synchronization.cursor
            )
        )

        let fromBeginning = makePaneTapeOpening(
            request: .init(capture: .dump, policy: .raw, position: .beginning),
            fence: pinnedFence
        )
        #expect(fromBeginning.start.record["initial"] == .object([
            "columns": .number(80),
            "rows": .number(24),
            "pinned": .bool(true),
        ]))

        let fromNow = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            fence: pinnedFence
        )
        #expect(fromNow.start.record["initial"] == .object([
            "columns": .number(100),
            "rows": .number(30),
            "pinned": .bool(true),
        ]))
        #expect(fromNow.records.first?["initial"] == .object([
            "columns": .number(100),
            "rows": .number(30),
            "pinned": .bool(true),
        ]))
    }

    @Test("a reconstructible continuation repairs eviction while a raw continuation reports it")
    func continuationDependsOnMode() {
        let evicted = snapshot(sequences: [4, 5], nextSequence: 6, droppedEventCount: 4)
        let synchronization = PaneTapeStateSynchronization(
            bytes: Array("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 0,
            cursor: evicted.nextCursor
        )

        let reconstructible = makePaneTapeContinuation(
            policy: reconstructiblePolicy,
            fence: .init(snapshot: evicted, synchronization: synchronization)
        )
        let raw = makePaneTapeContinuation(
            policy: .raw,
            fence: .init(snapshot: evicted, synchronization: synchronization)
        )

        #expect(reconstructible.records.first?["kind"] == .string("gap"))
        #expect(reconstructible.records.dropFirst().compactMap(sequence).isEmpty)
        #expect(reconstructible.records.last?["kind"] == .string("sync"))
        #expect(reconstructible.nextCursor == synchronization.cursor)
        #expect(raw.records.first?["kind"] == .string("gap"))
        #expect(raw.records.dropFirst().compactMap(sequence) == [4, 5])
    }

    // Intent: a sync transfer states its dropped-history count once, on the same first part
    //   that carries geometry, and never on a later part.
    // Why it exists: a replica cannot derive the count from the bytes -- a truncated sync and
    //   a whole one look identical -- so a transfer that omitted it would leave the replica
    //   believing its history is complete when it is not.
    // Scenario: spec-first contract for a bounded sync on the wire.
    @Test("a sync transfer states its dropped history rows once, beside its geometry")
    func syncStatesDroppedHistoryRowsOnItsFirstPart() {
        var streamFence = fence(retainedSequences: [])
        streamFence = PaneTapeStreamFence(
            origin: streamFence.origin,
            retained: streamFence.retained,
            requested: streamFence.requested,
            synchronization: .init(
                bytes: [UInt8](repeating: 0x41, count: IpcLineFramer.maxLineBytes + 1),
                dimensions: .init(columns: 100, rows: 30, pinned: false),
                droppedHistoryRows: 512,
                cursor: streamFence.synchronization.cursor
            )
        )

        let records = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            fence: streamFence
        ).records

        #expect(records.count > 1)
        #expect(records.first?["droppedHistoryRows"] == .number(512))
        #expect(records.dropFirst().allSatisfy { $0["droppedHistoryRows"] == nil })

        let whole = makePaneTapeOpening(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            fence: fence(retainedSequences: [])
        ).records
        #expect(whole.first?["droppedHistoryRows"] == .number(0))
    }

    // Intent: a budget changes what a sync carries, never whether one is sent -- a request
    //   the retained events can serve is still served from events.
    // Why it exists: making a sync cheap invites sending one where events would do, which
    //   would replace a replica's exact incremental state with a truncated replacement.
    // Scenario: spec-first contract for the bounded stream's send rule.
    @Test("a budget does not make a servable request take a sync instead of events")
    func budgetDoesNotChangeWhenASyncIsSent() {
        for budget in [0, 4096, PaneTapeSyncPolicy.defaultHistoryBudgetBytes] {
            let opening = makePaneTapeOpening(
                request: .init(
                    capture: .follow,
                    policy: .reconstructible(historyBudgetBytes: budget),
                    position: .beginning
                ),
                fence: fence(retainedSequences: [0, 1])
            )

            #expect(opening.records.compactMap(sequence) == [0, 1])
            #expect(opening.records.contains { $0["kind"] == .string("sync") } == false)
        }
    }

    private func fence(
        retainedSequences: [UInt64],
        droppedEventCount: UInt64 = 0,
        requested: PaneTapeCursorPlacement? = nil
    ) -> PaneTapeStreamFence {
        let nextSequence = retainedSequences.last.map { $0 + 1 } ?? 0
        let retained = snapshot(
            sequences: retainedSequences,
            nextSequence: nextSequence,
            droppedEventCount: droppedEventCount
        )
        return PaneTapeStreamFence(
            origin: .init(
                initial: .init(columns: 80, rows: 24, pinned: false),
                cursor: cursor(sequence: 0, feed: 0)
            ),
            retained: retained,
            requested: requested ?? .placed(retained),
            synchronization: .init(
                bytes: Array("state".utf8),
                dimensions: .init(columns: 100, rows: 30, pinned: false),
                droppedHistoryRows: 0,
                cursor: retained.nextCursor
            )
        )
    }

    private func snapshot(
        sequences: [UInt64],
        nextSequence: UInt64,
        droppedEventCount: UInt64 = 0
    ) -> PaneTapeSnapshot {
        PaneTapeSnapshot(
            events: sequences.map { sequence in
                .init(
                    sequence: sequence,
                    elapsedNanoseconds: sequence,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: Int(sequence), byteLength: 1),
                    event: .object(["type": .string("feed"), "base64": .string("QQ==")])
                )
            },
            droppedEventCount: droppedEventCount,
            droppedFeedBytes: Int(droppedEventCount),
            droppedWriteBytes: 0,
            nextCursor: cursor(sequence: nextSequence, feed: Int(nextSequence))
        )
    }

    private func cursor(sequence: UInt64, feed: Int) -> PaneTapeCursor {
        .init(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: sequence,
            feedBytesBeforeNextSequence: feed,
            writeBytesBeforeNextSequence: 0
        )
    }

    /// The policy every reconstructible case here runs under. The budget bounds what a sync
    /// carries; these tests are about which records an opening selects, so any budget serves.
    private let reconstructiblePolicy = PaneTapeSyncPolicy.reconstructible(
        historyBudgetBytes: PaneTapeSyncPolicy.defaultHistoryBudgetBytes
    )

    private func cursorJSON(sequence: UInt64, feed: Int) -> JSONValue {
        .object([
            "recorderLifetimeId": .string(Self.lifetimeId.uuidString),
            "sequence": .number(Double(sequence)),
            "feedByteOffset": .number(Double(feed)),
            "writeByteOffset": .number(0),
        ])
    }

    private func sequence(_ record: JSONValue) -> UInt64? {
        record["sequence"]?.asNumber.map(UInt64.init)
    }

    private func synchronizationBytes(_ records: [JSONValue]) throws -> [UInt8] {
        try records.flatMap { record in
            let encoded = try #require(record["base64"]?.asString)
            return try #require(Data(base64Encoded: encoded)).map { $0 }
        }
    }
}
