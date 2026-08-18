// Behavioral tests for exact pane-tape replication and explicit loss handling.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import TerminalCoreRecording
import Testing

@Test("A complete sync replaces state atomically and advances its cursor")
func completeSyncIsAtomic() throws {
    var replica = PaneReplica()
    let cursor = testCursor(sequence: 7, feed: 12)
    try replica.apply(.start(PaneTapeStartRecord(
        version: 1,
        capture: .follow,
        format: .replay,
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: nil,
        reconstructible: true
    )))

    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 2,
        bytes: Array("first".utf8),
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: nil
    )))
    #expect(replica.terminal == nil)
    #expect(replica.state == .awaitingSynchronization)

    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 2,
        parts: 2,
        bytes: Array(" second".utf8),
        columns: nil,
        rows: nil,
        pinned: nil,
        cursor: cursor
    )))
    #expect(replica.terminal?.viewportText == "first second")
    #expect(replica.cursor == cursor)
    #expect(replica.state == .exact)
}

@Test("A gap freezes presented state until a complete replacement sync")
func gapFreezesReplicaUntilRepair() throws {
    var replica = try synchronizedReplica(bytes: Array("old".utf8), cursor: testCursor(sequence: 1))
    try replica.apply(.gap(PaneTapeGapRecord(
        droppedEventCount: 2,
        droppedFeedBytes: 4,
        droppedWriteBytes: 0
    )))
    let frozen = replica.terminal

    try replica.apply(eventRecord(sequence: 1, event: .feed(Array(" ignored".utf8))))
    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 2,
        bytes: Array("new".utf8),
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: nil
    )))
    #expect(replica.terminal == frozen)
    #expect(replica.state == .gap(.declared(.exact(
        droppedEventCount: 2,
        droppedFeedBytes: 4,
        droppedWriteBytes: 0
    ))))

    let repairCursor = testCursor(sequence: 9, feed: 3)
    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 2,
        parts: 2,
        bytes: [],
        columns: nil,
        rows: nil,
        pinned: nil,
        cursor: repairCursor
    )))
    #expect(replica.terminal?.viewportText == "new")
    #expect(replica.cursor == repairCursor)
    #expect(replica.state == .exact)
}

@Test("Applied events advance the cursor and preserve observe-only behavior")
func eventsAdvanceCursorWithoutOriginatingBytes() throws {
    let initial = testCursor(sequence: 3, feed: 5, write: 2)
    var replica = try synchronizedReplica(bytes: [], cursor: initial)
    let queryAndText = Array("\u{1B}[6nhi".utf8)

    try replica.apply(eventRecord(
        sequence: 3,
        byteOffset: 5,
        byteLength: queryAndText.count,
        event: .feed(queryAndText)
    ))
    #expect(replica.terminal?.viewportText == "hi")
    #expect(replica.cursor == testCursor(sequence: 4, feed: 11, write: 2))
    #expect(replica.terminal?.pendingReplyBytes.isEmpty == true)

    let clipboardWrite = Array("\u{1B}]52;c;aGk=\u{7}".utf8)
    try replica.apply(eventRecord(
        sequence: 4,
        byteOffset: 11,
        byteLength: clipboardWrite.count,
        event: .feed(clipboardWrite)
    ))
    var authorityProbe = replica.terminal
    #expect(authorityProbe?.drainPendingClipboardWrite() == nil)

    let unchanged = replica.terminal
    let writeSequence = replica.cursor!.nextSequence
    try replica.apply(eventRecord(
        sequence: writeSequence,
        byteOffset: 2,
        byteLength: 1,
        event: .write([1])
    ))
    #expect(replica.terminal == unchanged)
    for event in [
        NeutralTerminalRecordingEvent.input(key: .returnKey, modifiers: []),
        .paste("paste"),
        .focus(true),
        .checkpoint,
    ] {
        let sequence = replica.cursor!.nextSequence
        try replica.apply(eventRecord(sequence: sequence, event: event))
        #expect(replica.terminal == unchanged)
    }
}

@Test("Malformed byte coordinates freeze the replica behind an explicit gap")
func malformedByteCoordinatesCannotAdvanceExactState() throws {
    var replica = try synchronizedReplica(
        bytes: Array("old".utf8),
        cursor: testCursor(sequence: 1, feed: 4)
    )
    try replica.apply(eventRecord(sequence: 1, event: .feed(Array("bad".utf8))))
    #expect(replica.state == .gap(.detected))
    #expect(replica.terminal?.viewportText == "old")
    #expect(replica.cursor == testCursor(sequence: 1, feed: 4))
}

@Test("A sync restores state that visible text alone cannot prove")
func syncRestoresModesAndHistory() throws {
    let bytes = Array("1\r\n2\r\n3\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1049hALT".utf8)
    let replica = try synchronizedReplica(
        bytes: bytes,
        cursor: testCursor(sequence: 1),
        columns: 8,
        rows: 2
    )
    #expect(replica.terminal?.isAlternateScreenActive == true)
    #expect(replica.terminal?.inputModes.applicationCursorKeys == true)
    #expect(replica.terminal?.inputModes.bracketedPaste == true)
    #expect((replica.terminal?.scrollbackRowCount ?? 0) > 0)
}

@Test("Recorded mouse events mutate local replica interaction without emitting bytes")
func mouseEventsApplyLocally() throws {
    var replica = try synchronizedReplica(
        bytes: Array("abcd".utf8),
        cursor: testCursor(sequence: 1),
        columns: 8,
        rows: 2
    )
    try replica.apply(eventRecord(sequence: 1, event: .mouse(NeutralTerminalMouseEvent(
        action: .down,
        button: 1,
        column: 0,
        row: 0
    ))))
    try replica.apply(eventRecord(sequence: 2, event: .mouse(NeutralTerminalMouseEvent(
        action: .move,
        column: 2,
        row: 0
    ))))
    try replica.apply(eventRecord(sequence: 3, event: .mouse(NeutralTerminalMouseEvent(
        action: .up,
        button: 1,
        column: 2,
        row: 0
    ))))
    #expect(replica.terminal?.selectedText == "ab")
    #expect(replica.terminal?.pendingReplyBytes.isEmpty == true)
}

@Test("Resize and viewport events apply, while stream geometry stays authoritative")
func geometryAndViewportEventsApply() throws {
    var replica = try synchronizedReplica(
        bytes: Array("1\r\n2\r\n3\r\n4".utf8),
        cursor: testCursor(sequence: 1),
        columns: 6,
        rows: 2
    )
    try replica.apply(eventRecord(sequence: 1, event: .viewport(.byRows(-1))))
    #expect(replica.terminal?.scrollProjection.isFollowing == false)
    try replica.apply(eventRecord(sequence: 2, event: .resize(columns: 10, rows: 3, pinned: false)))
    #expect(replica.terminal?.geometry.columns == 10)
    #expect(replica.terminal?.geometry.rows.count == 3)
}

@Test("Pinnedness follows the stream's geometry and is withheld off exact state")
func pinnednessTracksStreamGeometry() throws {
    // Intent: hold the authoritative pinnedness at the cursor, and hold none when not exact.
    // Why it exists: a Release control offered from stale or guessed pinnedness lies.
    // Scenario: a pinned pane is synchronized, unpinned at the same grid, then loses records.
    var replica = PaneReplica()
    #expect(replica.pinned == nil)

    replica = try synchronizedReplica(
        bytes: Array("live".utf8),
        cursor: testCursor(sequence: 1),
        columns: 6,
        rows: 2,
        pinned: true
    )
    #expect(replica.pinned == true)

    try replica.apply(eventRecord(sequence: 1, event: .resize(columns: 6, rows: 2, pinned: false)))
    #expect(replica.pinned == false)
    #expect(replica.terminal?.geometry.columns == 6)

    try replica.apply(eventRecord(sequence: 2, event: .resize(columns: 10, rows: 3, pinned: true)))
    #expect(replica.pinned == true)

    try replica.apply(.gap(.total))
    #expect(replica.pinned == nil)

    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 1,
        bytes: Array("repaired".utf8),
        columns: 10,
        rows: 3,
        pinned: false,
        cursor: testCursor(sequence: 9)
    )))
    #expect(replica.pinned == false)
}

@Test("A detected gap withholds pinnedness until a replacement sync")
func detectedGapWithholdsPinnedness() throws {
    // Intent: treat a replica-detected discontinuity like a declared one for pinnedness.
    // Why it exists: the pinned bit the replica holds is only as trustworthy as its cursor.
    // Scenario: an out-of-order event arrives on a pinned pane.
    var replica = try synchronizedReplica(
        bytes: Array("live".utf8),
        cursor: testCursor(sequence: 1),
        pinned: true
    )
    try replica.apply(eventRecord(sequence: 4, event: .viewport(.toBottom)))

    #expect(replica.state == .gap(.detected))
    #expect(replica.pinned == nil)
}

@Test("Local primary-screen scrolling moves an exact replica viewport")
func localViewportScrollMovesReplica() throws {
    var replica = try synchronizedReplica(
        bytes: Array("one\r\ntwo\r\nthree\r\nfour".utf8),
        cursor: testCursor(sequence: 1),
        columns: 8,
        rows: 2
    )

    replica.scrollViewport(byRows: -1)

    #expect(replica.terminal?.scrollProjection.isFollowing == false)
}

@Test("Invalid authoritative geometry cannot advance exact replica state")
func invalidResizeBecomesGap() throws {
    var replica = try synchronizedReplica(
        bytes: Array("stable".utf8),
        cursor: testCursor(sequence: 1),
        columns: 6,
        rows: 2
    )
    try replica.apply(eventRecord(sequence: 1, event: .resize(columns: 1, rows: 0, pinned: false)))
    #expect(replica.state == .gap(.detected))
    #expect(replica.cursor == testCursor(sequence: 1))
    #expect(replica.terminal?.viewportText == "stable")
}

@Test("A reconnect resumes from a stored cursor or repairs a foreign lifetime with a total gap")
func reconnectResumeAndTotalLoss() throws {
    var replica = try synchronizedReplica(
        bytes: Array("base".utf8),
        cursor: testCursor(sequence: 4)
    )
    let stored = replica.cursor
    try replica.apply(.start(PaneTapeStartRecord(
        version: 1,
        capture: .follow,
        format: .replay,
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: stored,
        reconstructible: true
    )))
    try replica.apply(eventRecord(
        sequence: 4,
        byteOffset: 0,
        byteLength: 1,
        event: .feed(Array("+".utf8))
    ))
    #expect(replica.terminal?.viewportText == "base+")

    try replica.apply(.gap(.total))
    try replica.apply(eventRecord(sequence: 5, event: .feed(Array("bad".utf8))))
    #expect(replica.terminal?.viewportText == "base+")
    let replacement = testCursor(sequence: 40, lifetime: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 1,
        bytes: Array("fresh".utf8),
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: replacement
    )))
    #expect(replica.terminal?.viewportText == "fresh")
    #expect(replica.cursor == replacement)
}

@Test("A reconnect start from a different recorder lifetime cannot bless stale state")
func reconnectRejectsForeignStartCursor() throws {
    var replica = try synchronizedReplica(
        bytes: Array("old".utf8),
        cursor: testCursor(sequence: 4)
    )
    let foreign = testCursor(
        sequence: 4,
        lifetime: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )
    try replica.apply(.start(PaneTapeStartRecord(
        version: 1,
        capture: .follow,
        format: .replay,
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: foreign,
        reconstructible: true
    )))
    #expect(replica.state == .gap(.detected))
    #expect(replica.terminal?.viewportText == "old")
}

// Intent: every gap the replica reaches on its own finding is marked detected, and only a
// producer gap record is marked declared.
//
// Why it exists: provenance is what decides the remedy. A site left spelled as a declared
// gap waits for a replacement sync the producer will never send, which is the freeze this
// enumeration guards. The cases are the complete list of assignments to the gap state in
// `PaneReplica`, so a new one added without a provenance decision shows up as a case this
// test does not cover.
//
// Scenario: each disagreement a healthy-looking stream can present to a replica, plus the
// producer's own loss report for contrast.
@Test("Each way the replica finds a gap for itself is marked detected")
func replicaMarksItsOwnFindingsAsDetected() throws {
    let base = testCursor(sequence: 4, feed: 3)

    var foreignStart = try synchronizedReplica(bytes: Array("old".utf8), cursor: base)
    try foreignStart.apply(startRecord(cursor: testCursor(
        sequence: 4,
        feed: 3,
        lifetime: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )))
    #expect(foreignStart.state == .gap(.detected))

    var statelessStart = PaneReplica()
    try statelessStart.apply(startRecord(cursor: base))
    #expect(statelessStart.state == .gap(.detected))

    var skippedSequence = try synchronizedReplica(bytes: [], cursor: base)
    try skippedSequence.apply(eventRecord(sequence: 9, event: .checkpoint))
    #expect(skippedSequence.state == .gap(.detected))

    var degenerateResize = try synchronizedReplica(bytes: [], cursor: base)
    try degenerateResize.apply(eventRecord(sequence: 4, event: .resize(columns: 1, rows: 0, pinned: false)))
    #expect(degenerateResize.state == .gap(.detected))

    var unplaceableBytes = try synchronizedReplica(bytes: [], cursor: base)
    try unplaceableBytes.apply(eventRecord(sequence: 4, event: .feed(Array("x".utf8))))
    #expect(unplaceableBytes.state == .gap(.detected))

    var producerReported = try synchronizedReplica(bytes: [], cursor: base)
    try producerReported.apply(.gap(.total))
    #expect(producerReported.state == .gap(.declared(.total)))
}

private func startRecord(cursor: PaneTapeCursor) -> PaneTapeRecord {
    .start(PaneTapeStartRecord(
        version: 1,
        capture: .follow,
        format: .replay,
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: cursor,
        reconstructible: true
    ))
}

private func synchronizedReplica(
    bytes: [UInt8],
    cursor: PaneTapeCursor,
    columns: Int = 8,
    rows: Int = 2,
    pinned: Bool = false
) throws -> PaneReplica {
    var replica = PaneReplica()
    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 1,
        bytes: bytes,
        columns: columns,
        rows: rows,
        pinned: pinned,
        cursor: cursor
    )))
    return replica
}

private func eventRecord(
    sequence: UInt64,
    byteOffset: Int? = nil,
    byteLength: Int? = nil,
    event: NeutralTerminalRecordingEvent
) throws -> PaneTapeRecord {
    let data = try JSONEncoder().encode(event)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    return .event(PaneTapeEventRecord(
        sequence: sequence,
        elapsedNanoseconds: sequence,
        originElapsedNanoseconds: nil,
        byteOffset: byteOffset,
        byteLength: byteLength,
        event: json
    ))
}

private func testCursor(
    sequence: UInt64,
    feed: Int = 0,
    write: Int = 0,
    lifetime: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
) -> PaneTapeCursor {
    PaneTapeCursor(
        recorderLifetimeId: lifetime,
        nextSequence: sequence,
        feedBytesBeforeNextSequence: feed,
        writeBytesBeforeNextSequence: write
    )
}
