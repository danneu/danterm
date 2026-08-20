// Behavioral coverage for choosing raw events or an atomic terminal-state synchronization,
// and for the record building that follows whichever was chosen.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermCore

struct PaneTapeStreamStateTests {
    private static let lifetimeId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("reconstructible beginning replays a complete retained tape without a sync")
    func completeBeginningNeedsNoSync() {
        let opening = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .beginning),
            pane: pane(retainedSequences: [0, 1])
        )

        #expect(opening.start.record.reconstructible)
        #expect(opening.start.record.cursor != nil)
        #expect(opening.records.compactMap(sequence) == [0, 1])
        #expect(opening.records.contains { kind($0) == .sync } == false)
        #expect(opening.nextCursor.nextSequence == 2)
    }

    @Test("reconstructible eviction states exact loss and replaces the suffix with a sync")
    func evictedBeginningUsesSync() {
        let opening = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .beginning),
            pane: pane(retainedSequences: [4, 5], droppedEventCount: 4)
        )

        #expect(opening.start.record.cursor == nil)
        #expect(opening.records.first == .gap(PaneTapeGapRecord(
            droppedEventCount: 4,
            droppedFeedBytes: 4,
            droppedWriteBytes: 0
        )))
        #expect(opening.records.compactMap(sequence).isEmpty)
        let sync = opening.records.filter { kind($0) == .sync }
        // Whole-record value, not a shape: this assembly now crosses the decide/materialize
        // boundary, so every field the record carries is stated here rather than sampled.
        #expect(sync == [.sync(PaneTapeSyncRecord(
            part: 1,
            parts: 1,
            bytes: Data("state".utf8),
            transfer: .init(columns: 100, rows: 30, pinned: false, droppedHistoryRows: 0),
            cursor: cursor(sequence: 6, feed: 6)
        ))])
        #expect(opening.nextCursor.nextSequence == 6)
    }

    @Test("from-now reconstructible starts with state while raw starts at the live cursor")
    func fromNowDependsOnMode() {
        let fenced = pane(retainedSequences: [0, 1])
        let reconstructible = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: fenced
        )
        let raw = openStream(
            request: .init(capture: .follow, policy: .raw, position: .now),
            pane: fenced
        )

        #expect(reconstructible.start.record.cursor == nil)
        #expect(reconstructible.records.map(kind) == [.sync])
        // Whole start record: a raw from-now opening is the one path that reports live
        // geometry and the live cursor without any state being serialized to read them off.
        #expect(raw.start.record == PaneTapeStartRecord(
            version: paneTapeStreamVersion,
            capture: .follow,
            format: .replay,
            provenance: defaultPaneTapeProvenance,
            columns: 100,
            rows: 30,
            pinned: false,
            cursor: cursor(sequence: 2, feed: 2),
            reconstructible: false
        ))
        #expect(raw.records.isEmpty)
    }

    @Test("a placeable resume continues directly or synchronizes after exact loss")
    func placeableResumeDependsOnLoss() {
        let requested = cursor(sequence: 1, feed: 1)
        let contiguous = openStream(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(requested)
            ),
            pane: pane(
                retainedSequences: [0, 1, 2],
                requested: .placed(snapshot(sequences: [1, 2], nextSequence: 3))
            )
        )
        let evicted = openStream(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(requested)
            ),
            pane: pane(
                retainedSequences: [2, 3],
                requested: .placed(snapshot(
                    sequences: [2, 3],
                    nextSequence: 4,
                    droppedEventCount: 1
                ))
            )
        )
        let rawEvicted = openStream(
            request: .init(capture: .follow, policy: .raw, position: .cursor(requested)),
            pane: pane(
                retainedSequences: [2, 3],
                requested: .placed(snapshot(
                    sequences: [2, 3],
                    nextSequence: 4,
                    droppedEventCount: 1
                ))
            )
        )

        #expect(contiguous.start.record.cursor == cursor(sequence: 1, feed: 1))
        #expect(contiguous.records.compactMap(sequence) == [1, 2])
        #expect(evicted.records.first.map(kind) == .gap)
        #expect(evicted.records.compactMap(sequence).isEmpty)
        #expect(evicted.records.last.map(kind) == .sync)
        #expect(gap(rawEvicted.records.first)?.droppedEventCount == 1)
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
        let fenced = pane(retainedSequences: [4, 5], droppedEventCount: 4, requested: .unplaceable)
        let reconstructible = openStream(
            request: .init(
                capture: .follow,
                policy: reconstructiblePolicy,
                position: .cursor(foreign)
            ),
            pane: fenced
        )
        let raw = openStream(
            request: .init(capture: .follow, policy: .raw, position: .cursor(foreign)),
            pane: fenced
        )

        #expect(reconstructible.records.first == .gap(.total))
        #expect(reconstructible.records.compactMap(sequence).isEmpty)
        #expect(reconstructible.records.last.map(kind) == .sync)
        #expect(raw.records.first == .gap(.total))
        #expect(raw.records.dropFirst().compactMap(sequence) == [4, 5])
        #expect(raw.start.record.cursor == cursor(sequence: 4, feed: 4))
    }

    @Test("sync chunks fit the IPC line bound and publish the cursor only on completion")
    func syncChunksAreAtomicAndBounded() throws {
        let bytes = Data(repeating: 0x41, count: IpcLineFramer.maxLineBytes + 1)
        let opening = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: pane(
                retainedSequences: [],
                syncBytes: bytes,
                syncDimensions: .init(columns: 179, rows: 66, pinned: false)
            )
        )
        let records = opening.records

        #expect(records.count > 1)
        #expect(records.dropLast().allSatisfy { part($0)?.cursor == nil })
        #expect(records.last.flatMap(part)?.cursor != nil)
        #expect(part(records.first)?.transfer?.columns == 179)
        #expect(part(records.first)?.transfer?.rows == 66)
        #expect(part(records.first)?.transfer?.pinned == false)
        #expect(synchronizationBytes(records) == bytes)
        for record in records {
            // The real notification line, so the bound is measured on the bytes the socket
            // carries rather than on the record alone.
            let encoded = try encodeIpcLine(JsonRpcRequestEnvelope(
                method: Methods.paneTapeEvent,
                params: PaneTapeEventNotification(
                    subscription: UUID().uuidString,
                    records: [record]
                )
            ))
            var framer = IpcLineFramer()
            #expect(framer.append(encoded) == [.line(encoded.dropLast())])
        }
    }

    // Intent: the payload splits at the chunk bound, and each part publishes its own chunk
    //   on the wire as standard padded base64.
    // Why it exists: how the producer holds the payload is an implementation choice, but the
    //   bytes it puts on the wire are the contract. Every other assertion here reads records
    //   in memory, so a change to the payload's carrier could move a chunk boundary or change
    //   the base64 spelling with nothing to catch it.
    // Scenario: three payload shapes around the chunk bound -- empty, exactly one chunk, and
    //   one that spans three chunk boundaries.
    @Test("sync parts split at the chunk bound and carry each chunk as standard base64")
    func syncPartsCarryTheirChunkAsBase64() throws {
        let bound = IpcLineFramer.maxLineBytes / 4
        for payloadCount in [0, bound, 3 * bound + 7] {
            // A period that does not divide the chunk bound, so two chunks of one payload
            // never hold the same bytes and a misplaced boundary cannot go unnoticed.
            let payload = (0..<payloadCount).map { UInt8($0 % 251) }
            let expectedChunks = payload.isEmpty
                ? [[UInt8]()]
                : stride(from: 0, to: payload.count, by: bound).map { start in
                    Array(payload[start..<min(start + bound, payload.count)])
                }
            let records = openStream(
                request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
                pane: pane(retainedSequences: [], syncBytes: Data(payload))
            ).records

            #expect(records.allSatisfy { kind($0) == .sync })
            #expect(records.compactMap { part($0)?.part } == Array(1...expectedChunks.count))
            #expect(records.allSatisfy { part($0)?.parts == expectedChunks.count })
            let carried = try #require(PaneTapeEventNotification<JSONValue>(
                method: Methods.paneTapeEvent,
                params: JSONDecoder().decode(
                    JSONValue.self,
                    from: JSONEncoder().encode(
                        PaneTapeEventNotification(subscription: "s", records: records)
                    )
                )
            ))
            #expect(
                carried.records.compactMap { $0.asObject?[PaneTapeRecordKey.base64]?.asString }
                    == expectedChunks.map { Data($0).base64EncodedString() }
            )
        }
    }

    // Intent: a synchronization that serialized to no bytes still ships exactly one part,
    //   carrying the transfer's facts and its continuation cursor.
    // Why it exists: a reader assembles a transfer by counting parts, so an empty state that
    //   shipped none would leave the reader waiting for a transfer that never arrives, and
    //   the geometry and cursor that ride the first and last part would never be published.
    // Scenario: a pane synchronized before its terminal has written anything.
    @Test("a synchronization with no bytes still ships one part")
    func emptySynchronizationShipsOnePart() {
        let opening = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: pane(retainedSequences: [], syncBytes: Data())
        )

        #expect(opening.records.count == 1)
        #expect(part(opening.records.first)?.part == 1)
        #expect(part(opening.records.first)?.parts == 1)
        #expect(part(opening.records.first)?.bytes.isEmpty == true)
        #expect(part(opening.records.first)?.transfer != nil)
        #expect(part(opening.records.first)?.cursor != nil)
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
        let pinned = pane(
            retainedSequences: [0, 1],
            initial: .init(columns: 80, rows: 24, pinned: true),
            syncDimensions: .init(columns: 100, rows: 30, pinned: true)
        )

        let fromBeginning = openStream(
            request: .init(capture: .dump, policy: .raw, position: .beginning),
            pane: pinned
        )
        #expect(fromBeginning.start.record.columns == 80)
        #expect(fromBeginning.start.record.rows == 24)
        #expect(fromBeginning.start.record.pinned)

        let fromNow = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: pinned
        )
        #expect(fromNow.start.record.columns == 100)
        #expect(fromNow.start.record.rows == 30)
        #expect(fromNow.start.record.pinned)
        #expect(part(fromNow.records.first)?.transfer
                == .init(columns: 100, rows: 30, pinned: true, droppedHistoryRows: 0))
    }

    @Test("a placed resume opens with birth geometry and replays the later transition")
    func placedResumePublishesBirthGeometry() {
        // Intent: on a `--from-cursor` resume the start record states the recorder's birth
        //   grid, and the geometry change after that grid reaches the reader as a replayed
        //   event rather than only through the start record.
        // Why it exists: readers have twice read the start record as the pane's geometry at
        //   the cursor it publishes. It is not, and a reader that adopted it would hold the
        //   birth grid's pinnedness until the pane's next resize, which may never come.
        // Scenario: a pane born pinned at 80x24, resized to an unpinned 100x30 while the
        //   client was away, resumed from a cursor before that resize.
        let resumed = openStream(
            request: .init(
                capture: .follow,
                policy: .raw,
                position: .cursor(cursor(sequence: 1, feed: 1))
            ),
            pane: pane(
                retainedSequences: [1, 2],
                requested: .placed(snapshot(
                    sequences: [1, 2],
                    nextSequence: 3,
                    resizeSequences: [2]
                )),
                initial: .init(columns: 80, rows: 24, pinned: true),
                syncDimensions: .init(columns: 100, rows: 30, pinned: false)
            )
        )

        #expect(resumed.start.record.columns == 80)
        #expect(resumed.start.record.rows == 24)
        #expect(resumed.start.record.pinned)
        #expect(resumed.start.record.cursor == cursor(sequence: 1, feed: 1))
        #expect(resumed.records.compactMap(sequence) == [1, 2])
        #expect(resumed.records.compactMap(event).contains(.object([
            "type": .string("resize"),
            "columns": .number(100),
            "rows": .number(30),
            "pinned": .bool(false),
        ])))
    }

    @Test("a reconstructible continuation repairs eviction while a raw continuation reports it")
    func continuationDependsOnMode() {
        let evicted = snapshot(sequences: [4, 5], nextSequence: 6, droppedEventCount: 4)
        let synchronization = PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 0,
            cursor: evicted.nextCursor
        )

        let reconstructible = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: true,
            snapshot: evicted,
            synchronization: synchronization
        ).batch
        let raw = continueStream(
            policy: .raw,
            replicaHistoryIsComplete: true,
            snapshot: evicted,
            synchronization: synchronization
        ).batch

        #expect(reconstructible.records.first.map(kind) == .gap)
        #expect(reconstructible.records.dropFirst().compactMap(sequence).isEmpty)
        // Whole-record value: this assembly crosses the decide/materialize boundary too.
        #expect(Array(reconstructible.records.dropFirst()) == [.sync(PaneTapeSyncRecord(
            part: 1,
            parts: 1,
            bytes: Data("state".utf8),
            transfer: .init(columns: 100, rows: 30, pinned: false, droppedHistoryRows: 0),
            cursor: cursor(sequence: 6, feed: 6)
        ))])
        #expect(reconstructible.nextCursor == synchronization.cursor)
        #expect(raw.records.first.map(kind) == .gap)
        #expect(raw.records.dropFirst().compactMap(sequence) == [4, 5])
    }

    // Intent: no stream that ships recorder events asks for the fenced terminal to be
    //   serialized -- not a raw opening at any start position, not a raw follow suffix, and
    //   not a reconstructible suffix the retained events already serve.
    // Why it exists: serializing state costs the whole retained scrollback, and every one of
    //   these paths used to pay it and throw the bytes away. Nothing in the delivered records
    //   would show the waste, so the decision itself is what gets asserted.
    // Scenario: spec-first contract for the stream's one serialization seam.
    @Test("only a stream that ships a sync asks for state to be serialized")
    func eventServedStreamsNeverSerializeState() {
        let placed = pane(
            retainedSequences: [0, 1, 2],
            requested: .placed(snapshot(sequences: [1, 2], nextSequence: 3))
        )
        let rawOpenings: [(String, PaneTapeStreamRequest, FencedPane)] = [
            ("dump from the beginning", .init(capture: .dump, policy: .raw, position: .beginning), placed),
            ("follow from now", .init(capture: .follow, policy: .raw, position: .now), placed),
            (
                "resume from a placed cursor",
                .init(capture: .follow, policy: .raw, position: .cursor(cursor(sequence: 1, feed: 1))),
                placed
            ),
            (
                "resume from an unplaceable cursor",
                .init(capture: .follow, policy: .raw, position: .cursor(cursor(sequence: 1, feed: 1))),
                pane(retainedSequences: [4, 5], droppedEventCount: 4, requested: .unplaceable)
            ),
        ]
        for (name, request, fenced) in rawOpenings {
            let decision = decidePaneTapeOpening(request: request, fence: fenced.facts)
            #expect(isEventDecision(decision.payload), "raw opening: \(name)")
        }

        // The raw follow stream's second entry point: rearming through the follow decision.
        #expect(isEventDecision(decidePaneTapeContinuation(
            policy: .raw,
            replicaHistoryIsComplete: false,
            snapshot: snapshot(sequences: [4, 5], nextSequence: 6, droppedEventCount: 4)
        )))
        // A reconstructible suffix the retained events serve -- the steady state.
        #expect(isEventDecision(decidePaneTapeContinuation(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: false,
            snapshot: snapshot(sequences: [4, 5], nextSequence: 6)
        )))
    }

    // Intent: an opening reports whether it left the replica holding the source's whole
    //   history, and only the three grounds that establish it count.
    // Why it exists: this flag is what later decides whether a resize may be replayed. A
    //   stream that overstated it would forward a resize the replica cannot reflow, and one
    //   that understated it would resync a replica that was already exact.
    // Scenario: spec-first contract for the completeness a bounded stream tracks.
    @Test("an opening states whether it left the replica holding the whole history")
    func openingStatesReplicaHistoryCompleteness() {
        func standing(position: PaneTapeStartPosition, pane fenced: FencedPane) -> Bool {
            openStream(
                request: .init(capture: .follow, policy: reconstructiblePolicy, position: position),
                pane: fenced
            ).replicaHistoryIsComplete
        }

        // Replayed from the recorder's own beginning with nothing evicted: the replica built
        // the whole history itself.
        #expect(standing(position: .beginning, pane: pane(retainedSequences: [0, 1])))
        // A sync that omitted nothing states completeness; one that omitted rows denies it.
        #expect(standing(position: .now, pane: pane(retainedSequences: [0, 1])))
        #expect(standing(
            position: .now,
            pane: pane(retainedSequences: [0, 1], droppedHistoryRows: 12)
        ) == false)
        #expect(standing(
            position: .beginning,
            pane: pane(retainedSequences: [4, 5], droppedEventCount: 4, droppedHistoryRows: 12)
        ) == false)
        // A cursor is a recorder coordinate and carries no evidence about the replica's
        // history, so a resumed stream stays unknown until a sync says otherwise.
        #expect(standing(
            position: .cursor(cursor(sequence: 1, feed: 1)),
            pane: pane(
                retainedSequences: [0, 1, 2],
                requested: .placed(snapshot(sequences: [1, 2], nextSequence: 3))
            )
        ) == false)
    }

    // Intent: a suffix that resizes reaches a history-incomplete replica as a fresh bounded
    //   sync instead, and reaches an exact replica as the resize event it is.
    // Why it exists: a primary-screen resize reflows retained history and the live rows as one
    //   stream, so a replica missing the oldest history computes a different grid from the
    //   same event. Replacing the suffix with state keeps grid exactness structural rather
    //   than an argument about how far reflow can reach.
    // Scenario: a bounded stream whose opening sync dropped history sees output, a resize,
    //   then more output.
    @Test("a resize in a suffix resyncs a truncated replica and passes through to an exact one")
    func resizeResyncsOnlyATruncatedReplica() {
        let resizing = snapshot(sequences: [4, 5, 6], nextSequence: 7, resizeSequences: [5])
        let synchronization = PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 9,
            cursor: cursor(sequence: 7, feed: 7)
        )

        let truncated = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: false,
            snapshot: resizing,
            synchronization: synchronization
        )
        let exact = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: true,
            snapshot: resizing,
            synchronization: synchronization
        )

        #expect(truncated.batch.records.allSatisfy { kind($0) == .sync })
        #expect(truncated.batch.records.compactMap(sequence).isEmpty)
        #expect(truncated.batch.nextCursor == synchronization.cursor)
        #expect(truncated.replicaHistoryIsComplete == false)
        #expect(exact.batch.records.compactMap(sequence) == [4, 5, 6])
        #expect(exact.batch.nextCursor == resizing.nextCursor)
        #expect(exact.replicaHistoryIsComplete)
    }

    // Intent: the resize rule fires on a resize and on nothing else, and a replacement sync
    //   that omits nothing hands the replica back its exact standing.
    // Why it exists: resyncing a truncated replica on every batch would throw away the cheap
    //   incremental path the stream exists for, and never restoring completeness would keep a
    //   replica resyncing on resizes long after it held the whole history again.
    // Scenario: a truncated replica takes a plain output suffix, then one whose replacement
    //   sync fits the whole history, then a resize.
    @Test("only a resize resyncs, and a sync that omits nothing restores exact standing")
    func plainSuffixesPassThroughAndAWholeSyncRestoresCompleteness() {
        let truncatedSync = PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 9,
            cursor: cursor(sequence: 6, feed: 6)
        )

        let passedThrough = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: false,
            snapshot: snapshot(sequences: [4, 5], nextSequence: 6),
            synchronization: truncatedSync
        )
        #expect(passedThrough.batch.records.compactMap(sequence) == [4, 5])
        #expect(passedThrough.replicaHistoryIsComplete == false)

        let wholeSync = PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 0,
            cursor: cursor(sequence: 7, feed: 7)
        )
        let restored = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: false,
            snapshot: snapshot(sequences: [6], nextSequence: 7, resizeSequences: [6]),
            synchronization: wholeSync
        )
        #expect(restored.batch.records.allSatisfy { kind($0) == .sync })
        #expect(restored.replicaHistoryIsComplete)

        let afterRestore = continueStream(
            policy: reconstructiblePolicy,
            replicaHistoryIsComplete: restored.replicaHistoryIsComplete,
            snapshot: snapshot(sequences: [7], nextSequence: 8, resizeSequences: [7]),
            synchronization: wholeSync
        )
        #expect(afterRestore.batch.records.compactMap(sequence) == [7])
    }

    // Intent: a sync transfer states its dropped-history count once, on the same first part
    //   that carries geometry, and never on a later part.
    // Why it exists: a replica cannot derive the count from the bytes -- a truncated sync and
    //   a whole one look identical -- so a transfer that omitted it would leave the replica
    //   believing its history is complete when it is not.
    // Scenario: spec-first contract for a bounded sync on the wire.
    @Test("a sync transfer states its dropped history rows once, beside its geometry")
    func syncStatesDroppedHistoryRowsOnItsFirstPart() {
        let records = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: pane(
                retainedSequences: [],
                droppedHistoryRows: 512,
                syncBytes: Data(repeating: 0x41, count: IpcLineFramer.maxLineBytes + 1)
            )
        ).records

        #expect(records.count > 1)
        #expect(part(records.first)?.transfer?.droppedHistoryRows == 512)
        #expect(records.dropFirst().allSatisfy { part($0)?.transfer == nil })

        let whole = openStream(
            request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
            pane: pane(retainedSequences: [])
        ).records
        #expect(part(whole.first)?.transfer?.droppedHistoryRows == 0)
    }

    // Intent: a budget changes what a sync carries, never whether one is sent -- a request
    //   the retained events can serve is still served from events.
    // Why it exists: making a sync cheap invites sending one where events would do, which
    //   would replace a replica's exact incremental state with a truncated replacement.
    // Scenario: spec-first contract for the bounded stream's send rule.
    @Test("a budget does not make a servable request take a sync instead of events")
    func budgetDoesNotChangeWhenASyncIsSent() {
        for budget in [0, 4096, PaneTapeSyncPolicy.defaultHistoryBudgetBytes] {
            let opening = openStream(
                request: .init(
                    capture: .follow,
                    policy: .reconstructible(historyBudgetBytes: budget),
                    position: .beginning
                ),
                pane: pane(retainedSequences: [0, 1])
            )

            #expect(opening.records.compactMap(sequence) == [0, 1])
            #expect(opening.records.contains { kind($0) == .sync } == false)
        }
    }

    // Intent: the budget a reconstructible stream runs under is the budget the selected sync
    //   asks the fenced state for, and no other path carries one.
    // Why it exists: the budget is the only thing standing between a join and a payload
    //   proportional to the whole scrollback, and it now travels inside the requirement rather
    //   than beside the request. A decision that dropped it would still deliver a correct
    //   sync, just an unbounded one.
    // Scenario: spec-first contract for what the one serialization seam is handed.
    @Test("a selected sync asks for exactly the budget the stream's policy states")
    func selectedSyncCarriesThePolicyBudget() {
        for budget in [nil, 0, 4096, PaneTapeSyncPolicy.defaultHistoryBudgetBytes] {
            let decision = decidePaneTapeOpening(
                request: .init(
                    capture: .follow,
                    policy: .reconstructible(historyBudgetBytes: budget),
                    position: .now
                ),
                fence: pane(retainedSequences: [0, 1]).facts
            )
            guard case .synchronize(let requirement) = decision.payload else {
                Issue.record("a reconstructible from-now opening must select a sync")
                continue
            }
            #expect(requirement.historyBudgetBytes == budget)

            let continuation = decidePaneTapeContinuation(
                policy: .reconstructible(historyBudgetBytes: budget),
                replicaHistoryIsComplete: true,
                snapshot: snapshot(sequences: [4, 5], nextSequence: 6, droppedEventCount: 4)
            )
            guard case .synchronize(let followRequirement) = continuation else {
                Issue.record("an evicted reconstructible suffix must select a sync")
                continue
            }
            #expect(followRequirement.historyBudgetBytes == budget)
        }
    }

    // Intent: the standing an opening reports is the one the next continuation acts on, for a
    //   stream that opened on a truncated sync and for one that resumed from a client cursor.
    // Why it exists: the two halves are decided in different functions, so each can be right
    //   on its own while the stream still forwards a resize to a replica that cannot reflow it.
    // Scenario: a phone joins a deep pane under a budget, and later reconnects from the cursor
    //   its last sync published; a resize arrives on each stream.
    @Test("an opening's standing carries into the next suffix, on a fresh join and on a resume")
    func openingStandingDecidesTheNextSuffix() {
        let resizing = snapshot(sequences: [8], nextSequence: 9, resizeSequences: [8])
        let resizeSync = PaneTapeStateSynchronization(
            bytes: Data("state".utf8),
            dimensions: .init(columns: 100, rows: 30, pinned: false),
            droppedHistoryRows: 9,
            cursor: cursor(sequence: 9, feed: 9)
        )

        for opening in [
            openStream(
                request: .init(capture: .follow, policy: reconstructiblePolicy, position: .now),
                pane: pane(retainedSequences: [0, 1], droppedHistoryRows: 12)
            ),
            openStream(
                request: .init(
                    capture: .follow,
                    policy: reconstructiblePolicy,
                    position: .cursor(cursor(sequence: 1, feed: 1))
                ),
                pane: pane(
                    retainedSequences: [0, 1, 2],
                    requested: .placed(snapshot(sequences: [1, 2], nextSequence: 3))
                )
            ),
        ] {
            let continuation = continueStream(
                policy: reconstructiblePolicy,
                replicaHistoryIsComplete: opening.replicaHistoryIsComplete,
                snapshot: resizing,
                synchronization: resizeSync
            )

            #expect(continuation.batch.records.allSatisfy { kind($0) == .sync })
            #expect(continuation.batch.nextCursor == resizeSync.cursor)
        }
    }

    /// One fenced moment: the cheap facts stream policy decides from, beside the state the
    /// fenced terminal would serialize into if -- and only if -- the decision asks for one.
    private struct FencedPane {
        let facts: PaneTapeStreamFence<JSONValue>
        let synchronization: PaneTapeStateSynchronization
    }

    /// Runs one opening through both phases, serializing state only when the decision asked
    /// for it, exactly as the app does.
    private func openStream(
        request: PaneTapeStreamRequest,
        pane fenced: FencedPane
    ) -> PaneTapeOpening<JSONValue> {
        let decision = decidePaneTapeOpening(request: request, fence: fenced.facts)
        switch decision.payload {
        case .events(let events):
            return makePaneTapeOpening(decision, events: events)
        case .synchronize(let requirement):
            return makePaneTapeOpening(
                decision,
                requirement: requirement,
                synchronization: fenced.synchronization
            )
        }
    }

    /// Runs one followed suffix through both phases, the same way.
    private func continueStream(
        policy: PaneTapeSyncPolicy,
        replicaHistoryIsComplete: Bool,
        snapshot: PaneTapeSnapshot<JSONValue>,
        synchronization: PaneTapeStateSynchronization
    ) -> PaneTapeContinuation<JSONValue> {
        let decision = decidePaneTapeContinuation(
            policy: policy,
            replicaHistoryIsComplete: replicaHistoryIsComplete,
            snapshot: snapshot
        )
        switch decision {
        case .events(let events):
            return makePaneTapeContinuation(events: events)
        case .synchronize(let requirement):
            return makePaneTapeContinuation(
                requirement: requirement,
                synchronization: synchronization
            )
        }
    }

    private func isEventDecision<Events>(_ decision: PaneTapePayloadDecision<Events>) -> Bool {
        if case .events = decision { true } else { false }
    }

    private func pane(
        retainedSequences: [UInt64],
        droppedEventCount: UInt64 = 0,
        droppedHistoryRows: Int = 0,
        requested: PaneTapeCursorPlacement<JSONValue>? = nil,
        initial: PaneTapeDimensions = .init(columns: 80, rows: 24, pinned: false),
        syncBytes: Data = Data("state".utf8),
        syncDimensions: PaneTapeDimensions = .init(columns: 100, rows: 30, pinned: false)
    ) -> FencedPane {
        let nextSequence = retainedSequences.last.map { $0 + 1 } ?? 0
        let retained = snapshot(
            sequences: retainedSequences,
            nextSequence: nextSequence,
            droppedEventCount: droppedEventCount
        )
        return FencedPane(
            facts: PaneTapeStreamFence(
                origin: .init(initial: initial, cursor: cursor(sequence: 0, feed: 0)),
                // The live pane runs at the geometry a sync would report, and the recorder's
                // live cursor is the one past every event the fence retained.
                live: .init(initial: syncDimensions, cursor: retained.nextCursor),
                retained: retained,
                requested: requested ?? .placed(retained)
            ),
            synchronization: .init(
                bytes: syncBytes,
                dimensions: syncDimensions,
                droppedHistoryRows: droppedHistoryRows,
                cursor: retained.nextCursor
            )
        )
    }

    private func snapshot(
        sequences: [UInt64],
        nextSequence: UInt64,
        droppedEventCount: UInt64 = 0,
        resizeSequences: Set<UInt64> = []
    ) -> PaneTapeSnapshot<JSONValue> {
        PaneTapeSnapshot(
            events: sequences.map { sequence in
                let isResize = resizeSequences.contains(sequence)
                return .init(
                    sequence: sequence,
                    elapsedNanoseconds: sequence,
                    originElapsedNanoseconds: nil,
                    payload: isResize ? nil : .init(byteOffset: Int(sequence), byteLength: 1),
                    event: isResize
                        ? .object([
                            "type": .string("resize"),
                            "columns": .number(100),
                            "rows": .number(30),
                            "pinned": .bool(false),
                        ])
                        : .object(["type": .string("feed"), "base64": .string("QQ==")]),
                    needsCompleteHistory: isResize
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

    private func kind(_ record: PaneTapeOutgoingRecord<JSONValue>) -> PaneTapeRecordKind {
        switch record {
        case .start: .start
        case .gap: .gap
        case .event: .event
        case .sync: .sync
        case .end: .end
        }
    }

    private func gap(_ record: PaneTapeOutgoingRecord<JSONValue>?) -> PaneTapeGapRecord? {
        guard case .gap(let gap)? = record else { return nil }
        return gap
    }

    private func part(_ record: PaneTapeOutgoingRecord<JSONValue>?) -> PaneTapeSyncRecord? {
        guard case .sync(let part)? = record else { return nil }
        return part
    }

    private func event(_ record: PaneTapeOutgoingRecord<JSONValue>) -> JSONValue? {
        guard case .event(let event) = record else { return nil }
        return event.event
    }

    private func sequence(_ record: PaneTapeOutgoingRecord<JSONValue>) -> UInt64? {
        guard case .event(let event) = record else { return nil }
        return event.sequence
    }

    private func synchronizationBytes(_ records: [PaneTapeOutgoingRecord<JSONValue>]) -> Data {
        records.reduce(into: Data()) { joined, record in
            if let bytes = part(record)?.bytes { joined.append(bytes) }
        }
    }
}
