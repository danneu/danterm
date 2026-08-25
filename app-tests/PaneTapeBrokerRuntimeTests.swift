// Runtime-path proofs for pane-tape stream lifecycle, delivery, and request completion.
import DanTermProtocol
import Foundation
import Testing
import TerminalCoreRecording
@testable import DanTerm

/// Pins the behavior that must survive moving pane-tape ownership out of AppRuntime.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PaneTapeBrokerRuntimeTests {
    @Test("a ninth follower receives an error before start and leaves eight streams live")
    func followerCapRefusesBeforeStart() async throws {
        let ports = RecordingAppRuntimePorts()
        ports.session.tapeOpening = makeEmptyPaneTapeOpening()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }

        for index in 0..<9 {
            let requestId = UUID()
            registerPaneTapeRequest(
                wire,
                requestId: requestId,
                rpcId: .number(Double(index)),
                runtime: runtime
            )
            runtime.perform(.streamPaneTape(
                reqId: requestId,
                paneId: paneId,
                capture: .follow,
                start: .now,
                policy: .raw
            ))
        }

        var starts = 0
        var errors: [String] = []
        for _ in 0..<9 {
            let response = try await wire.readResponseAsync()
            if response.error == nil {
                starts += 1
            } else if let message = response.error?.message {
                errors.append(message)
            }
        }
        #expect(starts == 8)
        #expect(errors == ["pane already has the maximum of 8 tape followers"])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 8)
    }

    // Intent: ending one follower retires only its own notice and lifecycle token, while a
    //   sibling on the same socket remains able to fetch and deliver appended records.
    // Why it exists: stream state and transports currently live in separate tables. A broad
    //   cleanup keyed by pane or socket can close the shared socket or retire both streams.
    // Scenario: two panes share one client socket; the first pane closes, then the second
    //   pane appends output before the client connection itself closes.
    @Test("one ended follow stream leaves its sibling live on the shared socket")
    func endingOneFollowerPreservesItsSibling() async throws {
        let firstSession = RecordingTerminalSession()
        let secondSession = RecordingTerminalSession()
        firstSession.tapeOpening = makeEmptyPaneTapeOpening()
        secondSession.tapeOpening = makeEmptyPaneTapeOpening()
        secondSession.tapeFollowContinuations = [makePaneTapeTestContinuation()]
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let firstPaneId = PaneId(rawValue: UUID())
        let secondPaneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(firstSession, paneId: firstPaneId)
        runtime.installTerminalSession(secondSession, paneId: secondPaneId)

        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let firstRequestId = UUID()
        let secondRequestId = UUID()
        registerPaneTapeRequest(
            wire,
            requestId: firstRequestId,
            rpcId: .number(1),
            runtime: runtime
        )
        registerPaneTapeRequest(
            wire,
            requestId: secondRequestId,
            rpcId: .number(2),
            runtime: runtime
        )

        runtime.perform(.streamPaneTape(
            reqId: firstRequestId,
            paneId: firstPaneId,
            capture: .follow,
            start: .now,
            policy: .raw
        ))
        runtime.perform(.streamPaneTape(
            reqId: secondRequestId,
            paneId: secondPaneId,
            capture: .follow,
            start: .now,
            policy: .raw
        ))

        _ = try await wire.readResponseAsync()
        _ = try await wire.readResponseAsync()
        try await waitForPaneTapeSubscriptions(in: runtime, count: 2)

        runtime.tearDownSession(firstPaneId)

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 1)
        #expect(firstSession.cancelledTapeNotices == 1)
        #expect(secondSession.cancelledTapeNotices == 0)
        let endedRecords = try paneTapeRecords(in: await wire.readNotificationAsync())
        #expect(endedRecords == [.end(reason: .paneClosed)])

        secondSession.notifyPaneTapeFollowers()

        let deliveredRecords = try paneTapeRecords(in: await wire.readNotificationAsync())
        guard case .event(let delivered)? = deliveredRecords.first else {
            Issue.record("the sibling follower must deliver its scripted event")
            return
        }
        #expect(delivered.sequence == 0)
        #expect(delivered.event == (try paneTapeTestEventJSON()))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 1)

        runtime.ipcConnectionClosed(wire.connection.id)

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == nil)
        #expect(secondSession.cancelledTapeNotices == 1)
    }

    // Intent: app shutdown closes a follower's socket without first writing a stream
    //   terminator, and retires the runtime-owned subscription.
    // Why it exists: orderly pane teardown writes `.paneClosed`, but app shutdown promises
    //   abrupt EOF and must run while the shared scheduling lifecycle can retire tokens.
    // Scenario: the application exits while one client is following a live pane.
    @Test("shutdown gives a pane-tape follower EOF without a terminator")
    func shutdownClosesFollowerWithEOF() async throws {
        let ports = RecordingAppRuntimePorts()
        ports.session.tapeOpening = makeEmptyPaneTapeOpening()
        let runtime = makeCommandTestRuntime(ports)
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let requestId = UUID()
        registerPaneTapeRequest(
            wire,
            requestId: requestId,
            rpcId: .number(1),
            runtime: runtime
        )

        runtime.perform(.streamPaneTape(
            reqId: requestId,
            paneId: paneId,
            capture: .follow,
            start: .now,
            policy: .raw
        ))

        _ = try await wire.readResponseAsync()
        try await waitForPaneTapeSubscriptions(in: runtime, count: 1)
        runtime.shutdown()

        #expect(try wire.readByte() == 0)
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == nil)
        #expect(ports.session.cancelledTapeNotices == 1)
    }

    // Intent: every capture mode reports an absent pane once and completes the request's
    //   audit exactly once at that error reply.
    // Why it exists: moving pane lookup into the broker moves both the error writer and the
    //   audited transport across an ownership boundary where a reply can be lost or doubled.
    // Scenario: a remote client asks for dump, snapshot, and follow captures after its pane
    //   has already disappeared.
    @Test(
        "an absent pane completes each capture request once",
        arguments: [PaneTapeCaptureMode.dump, .snapshot, .follow]
    )
    func absentPaneCompletesAuditOnce(capture: PaneTapeCaptureMode) throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let paneId = PaneId(rawValue: UUID())
        let requestId = UUID()
        wire.remember(reqId: requestId, rpcId: .number(1))
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-pane-tape-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: auditDirectory) }
        let auditWriter = IpcAuditLogWriter(directory: auditDirectory)
        let request = IpcRequest.paneTape(
            pane: paneId,
            follow: capture == .follow,
            start: .now,
            policy: .raw
        )
        runtime.registerIpcConnection(
            wire.connection,
            for: requestId,
            audit: IpcRequestAudit(
                writer: auditWriter,
                caller: .remote(nodeId: "node", user: "user", machineName: "phone"),
                request: request.auditDescriptor,
                isRemote: true
            )
        )

        runtime.perform(.streamPaneTape(
            reqId: requestId,
            paneId: paneId,
            capture: capture,
            start: .now,
            policy: .raw
        ))

        #expect(try wire.readResponse().error?.message == "pane no longer available")
        let entries = try readPaneTapeAuditEntries(from: auditWriter.logURL)
        #expect(entries.count == 1)
        #expect(entries.first?.event.kind == .requestCompleted)
        #expect(entries.first?.event.outcome == "error")
    }
}

@MainActor
private func registerPaneTapeRequest(
    _ fixture: CommandIpcConnectionFixture,
    requestId: UUID,
    rpcId: JSONValue,
    runtime: AppRuntime
) {
    fixture.remember(reqId: requestId, rpcId: rpcId)
    runtime.registerIpcConnection(fixture.connection, for: requestId)
}

@MainActor
private func waitForPaneTapeSubscriptions(in runtime: AppRuntime, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == count { return }
        await Task.yield()
    }
    throw POSIXError(.ETIMEDOUT)
}

private func paneTapeRecords(
    in notification: JsonRpcRequest
) throws -> [PaneTapeRecord<JSONValue>] {
    let values = try #require(notification.params?["records"]?.asArray)
    return try values.map { try #require(decodePaneTapeRecord($0)) }
}

private func makePaneTapeTestContinuation() -> PaneTapeContinuation<PaneTapeSessionEvent> {
    let opening = makeEmptyPaneTapeOpening()
    let nextCursor = PaneTapeCursor(
        recorderLifetimeId: opening.nextCursor.recorderLifetimeId,
        nextSequence: 1,
        feedBytesBeforeNextSequence: 2,
        writeBytesBeforeNextSequence: 0
    )
    return PaneTapeContinuation(
        batch: PaneTapeBatch(
            records: [makePaneTapeEventRecord(PaneTapeEvent(
                sequence: 0,
                elapsedNanoseconds: 3,
                originElapsedNanoseconds: nil,
                payload: .init(byteOffset: 0, byteLength: 2),
                event: .feed(Array("ok".utf8)),
                needsCompleteHistory: false
            ))],
            nextCursor: nextCursor
        ),
        replicaHistoryIsComplete: false
    )
}

private func paneTapeTestEventJSON() throws -> JSONValue {
    let data = try JSONEncoder().encode(NeutralTerminalRecordingEvent.feed(Array("ok".utf8)))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func readPaneTapeAuditEntries(from url: URL) throws -> [IpcAuditLogEntry] {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: 0x0A).map { try decoder.decode(IpcAuditLogEntry.self, from: $0) }
}
