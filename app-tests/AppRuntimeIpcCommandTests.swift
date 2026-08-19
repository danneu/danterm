// Command-interpreter coverage for IPC wires, synchronous re-entry, and command order.
import Darwin
import DanTermProtocol
import Foundation
import Testing
import TerminalCoreRecording
@testable import DanTerm

/// Proves every IPC Command arm against a real socketpair and locks down re-entry order.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppRuntimeIpcCommandTests {
    @Test("IPC reply and error commands write their JSON-RPC envelopes")
    func directReplyAndErrorWriteWireEnvelopes() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        let reply = try CommandIpcConnectionFixture()
        let failure = try CommandIpcConnectionFixture()
        defer {
            reply.closePeer()
            failure.connection.close()
            failure.closePeer()
        }
        let replyId = UUID()
        let failureId = UUID()
        reply.remember(reqId: replyId, rpcId: .number(11))
        failure.remember(reqId: failureId, rpcId: .string("failure"))
        runtime.registerIpcConnection(reply.connection, for: replyId)
        runtime.registerIpcConnection(failure.connection, for: failureId)

        runtime.perform(.ipcReply(reqId: replyId, result: .object(["ok": .bool(true)])))
        runtime.perform(.ipcError(reqId: failureId, code: -32602, message: "invalid pane"))

        let replyEnvelope = try reply.readResponse()
        let failureEnvelope = try failure.readResponse()
        #expect(replyEnvelope.id == .number(11))
        #expect(replyEnvelope.result == .object(["ok": .bool(true)]))
        #expect(failureEnvelope.id == .string("failure"))
        #expect(failureEnvelope.error == JsonRpcError(code: -32602, message: "invalid pane"))
        #expect(reply.hasReadableData() == false, "a retired reply must not close its socket")

        runtime.shutdown()
        reply.connection.close()

        #expect(try reply.readByte() == 0, "transport shutdown must be the first source of EOF")
    }

    @Test("doctor and focus reads return runtime-owned facts")
    func doctorAndFocusReadsWriteFacts() async throws {
        let ports = RecordingAppRuntimePorts()
        ports.doctorPermissions = DoctorFacts.Permissions(
            notifications: .granted,
            fullDiskAccess: .denied,
            developerTools: .unknown
        )
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let doctor = try CommandIpcConnectionFixture()
        let focus = try CommandIpcConnectionFixture()
        defer {
            doctor.connection.close()
            doctor.closePeer()
            focus.connection.close()
            focus.closePeer()
        }
        let doctorId = UUID()
        let focusId = UUID()
        doctor.remember(reqId: doctorId, rpcId: .number(1))
        focus.remember(reqId: focusId, rpcId: .number(2))
        runtime.registerIpcConnection(doctor.connection, for: doctorId)
        runtime.registerIpcConnection(focus.connection, for: focusId)

        runtime.perform(.readDoctorPermissions(reqId: doctorId))
        runtime.perform(.readFocusInfo(reqId: focusId))

        let doctorEnvelope = try await doctor.readResponseAsync()
        let focusEnvelope = try focus.readResponse()
        #expect(doctorEnvelope.result == ports.doctorPermissions.jsonValue)
        #expect(focusEnvelope.result == .object([
            "focus": .object(["type": .string("none")]),
        ]))
    }

    @Test("pane text and row reads preserve terminal results")
    func paneReadsWriteSessionResults() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        ports.session.viewportText = "visible"
        ports.session.fullHistoryText = "one\ntwo\nthree"
        ports.session.rowStructure = [TerminalSessionRowStructure(
            index: 7,
            isRetained: true,
            isSoftWrapped: false,
            contentEnd: 4,
            width: 12,
            marginKind: "padding",
            staleWrapClaim: true
        )]
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let viewport = try CommandIpcConnectionFixture()
        let history = try CommandIpcConnectionFixture()
        let rows = try CommandIpcConnectionFixture()
        defer {
            for fixture in [viewport, history, rows] {
                fixture.connection.close()
                fixture.closePeer()
            }
        }
        let viewportId = UUID()
        let historyId = UUID()
        let rowsId = UUID()
        register(viewport, requestId: viewportId, rpcId: .number(1), runtime: runtime)
        register(history, requestId: historyId, rpcId: .number(2), runtime: runtime)
        register(rows, requestId: rowsId, rpcId: .number(3), runtime: runtime)

        runtime.perform(.readPaneText(reqId: viewportId, paneId: paneId, lineLimit: nil))
        runtime.perform(.readPaneText(reqId: historyId, paneId: paneId, lineLimit: 2))
        runtime.perform(.readPaneRowStructure(reqId: rowsId, paneId: paneId))

        #expect(try viewport.readResponse().result == .object(["text": .string("visible")]))
        #expect(try history.readResponse().result == .object(["text": .string("two\nthree")]))
        #expect(try rows.readResponse().result == .object([
            "rows": .array([.object([
                "index": .number(7),
                "retained": .bool(true),
                "softWrapped": .bool(false),
                "contentEnd": .number(4),
                "width": .number(12),
                "marginKind": .string("padding"),
                "staleWrapClaim": .bool(true),
            ])]),
        ]))
    }

    @Test("pane tape commands select dump and follow session entry points")
    func paneTapeCommandsWriteSessionErrors() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let dump = try CommandIpcConnectionFixture()
        let follow = try CommandIpcConnectionFixture()
        defer {
            dump.connection.close()
            dump.closePeer()
            follow.connection.close()
            follow.closePeer()
        }
        let dumpId = UUID()
        let followId = UUID()
        register(dump, requestId: dumpId, rpcId: .number(1), runtime: runtime)
        register(follow, requestId: followId, rpcId: .number(2), runtime: runtime)

        runtime.perform(.streamPaneTape(
            reqId: dumpId,
            paneId: paneId,
            capture: .dump,
            start: .beginning,
            policy: .raw
        ))
        runtime.perform(.streamPaneTape(
            reqId: followId,
            paneId: paneId,
            capture: .follow,
            start: .now,
            policy: .reconstructible(historyBudgetBytes: 4096)
        ))

        #expect(try dump.readResponse().error?.message == "pane has no terminal to read a tape from")
        #expect(try follow.readResponse().error?.message == "pane has no terminal to read a tape from")
        #expect(ports.session.paneTapeOpenings.count == 2)
        #expect(ports.session.paneTapeOpenings[0].0 == .dump)
        #expect(ports.session.paneTapeOpenings[0].1 == .beginning)
        #expect(ports.session.paneTapeOpenings[0].2 == .raw)
        #expect(ports.session.paneTapeOpenings[1].0 == .follow)
        #expect(ports.session.paneTapeOpenings[1].1 == .now)
        #expect(ports.session.paneTapeOpenings[1].2 == .reconstructible(historyBudgetBytes: 4096))
    }

    // Intent: a real dump over the runtime's socket puts a decodable start record at the
    //   response's `result` and each following record at its notification's `params.record`,
    //   with the recorded event carried as the engine wrote it.
    // Why it exists: the producer hands typed records to the wire encoder now, and the start
    //   record leaves by a different door from every other record -- an RPC result rather than
    //   a notification. Nothing below this seam would notice one of the two doors encoding a
    //   record differently, or double-encoding it into a string.
    // Scenario: an agent runs `danterm pane tape` against a pane with one retained event.
    @Test("a dump answers with a start record and streams its events as records")
    func paneTapeDumpPutsDecodableRecordsOnTheWire() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let event = NeutralTerminalRecordingEvent.feed(Array("Hi \u{1F602}".utf8))
        ports.session.tapeOpening = makeSingleEventPaneTapeDump(of: event)
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let reqId = UUID()
        register(wire, requestId: reqId, rpcId: .number(1), runtime: runtime)

        runtime.perform(.streamPaneTape(
            reqId: reqId,
            paneId: paneId,
            capture: .dump,
            start: .beginning,
            policy: .raw
        ))

        let result = try #require(try wire.readResponse().result)
        guard case .start(let start)? = decodePaneTapeRecord(result) else {
            Issue.record("the dump's reply must decode as a start record")
            return
        }
        #expect(start.version == paneTapeStreamVersion)
        #expect(start.capture == .dump)

        // One notification carries the whole delivery, so the dump's event and its
        // terminator arrive together rather than one notification each.
        let records = try #require(wire.readNotification().params?["records"]?.asArray)
        guard records.count == 2 else {
            Issue.record("the dump owes one notification carrying its event and its end")
            return
        }
        guard case .event(let delivered)? = decodePaneTapeRecord(records[0]) else {
            Issue.record("the dump's first notification must carry an event record")
            return
        }
        let alone = try JSONDecoder().decode(
            JSONValue.self,
            from: try JSONEncoder().encode(event)
        )
        #expect(delivered.sequence == 4)
        #expect(delivered.event == alone)
        #expect(decodePaneTapeRecord(records[1]) == .end(reason: .dumpComplete))
    }

    @Test("config save failure alerts and completes font resolution before return")
    func configFailureReentersBeforePerformReturns() {
        let ports = RecordingAppRuntimePorts()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-unwritable-config-\(UUID().uuidString)/config.json")
        let store = DanTermConfigStore(url: url, writeData: { _, _ in
            throw POSIXError(.EROFS)
        })
        let runtime = makeCommandTestRuntime(ports, configStore: store)
        defer { runtime.shutdown() }
        runtime.model.resolvedFontFamily = "stale family"
        var config = DanTermConfig.default
        config.fontFamily = "DanTerm Missing Font \(UUID().uuidString)"

        runtime.perform(.saveDanTermConfig(config))

        #expect(ports.alerts.count == 1)
        #expect(ports.alerts.first?.title == "DanTerm Config Error")
        #expect(ports.alerts.first?.message.contains("could not save") == true)
        #expect(runtime.model.resolvedFontFamily == nil)
    }

    @Test("input rejection re-enters update and writes the pending reply")
    func inputRejectionWritesPendingErrorBeforeReturn() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let requestId = UUID()
        let submissionId = InputSubmissionId(rawValue: UUID())
        wire.remember(reqId: requestId, rpcId: .number(9))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        runtime.model.pendingInputRequests[requestId] = PendingInputRequest(
            remaining: [submissionId]
        )
        runtime.model.pendingInputSubmissions[submissionId] = requestId

        runtime.perform(.sendText(
            paneId: PaneId(rawValue: UUID()),
            text: "unroutable",
            submissionId: submissionId
        ))

        let response = try wire.readResponse()
        #expect(response.error?.code == -32603)
        #expect(response.error?.message == "pane input was not delivered")
        #expect(runtime.model.pendingInputRequests.isEmpty)
        #expect(runtime.model.pendingInputSubmissions.isEmpty)
    }

    @Test("wheel completion re-enters update and writes the pending reply")
    func wheelCompletionWritesPendingReply() async throws {
        // Intent: a routed wheel event completes the same pending IPC request as keys and text.
        // Why it exists: wheel can finish as a local scroll or a PTY write, but neither path
        //   may leave the caller waiting after the pane owner handled it.
        // Scenario: an installed session accepts one wheel-up event at a viewport cell.
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
        let submissionId = InputSubmissionId(rawValue: UUID())
        runtime.installTerminalSession(ports.session, paneId: paneId)
        wire.remember(reqId: requestId, rpcId: .number(10))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        runtime.model.pendingInputRequests[requestId] = PendingInputRequest(
            remaining: [submissionId]
        )
        runtime.model.pendingInputSubmissions[submissionId] = requestId

        runtime.perform(.sendInputWheel(
            paneId: paneId,
            direction: .up,
            column: 4,
            row: 2,
            submissionId: submissionId
        ))

        let response = try await wire.readResponseAsync()
        #expect(response.result == .object(["ok": .bool(true)]))
        #expect(ports.session.sentInputWheels.count == 1)
        #expect(runtime.model.pendingInputRequests.isEmpty)
        #expect(runtime.model.pendingInputSubmissions.isEmpty)
    }

    @Test("a pane-resize reply is written before the resize reaches the pane")
    func paneResizeReplyPrecedesTheResizeItself() throws {
        // Intent: within one send frame, the pane.resize response is on the wire before
        //   the runtime applies the override to the pane's session -- the earliest moment
        //   any tape record of that resize can exist.
        // Why it exists: the phone's claim protocol reads a tape record's pinnedness as
        //   post-claim truth exactly when the record follows the claim's success response
        //   on the frame stream. That reading is sound only while the server replies
        //   before it reconciles; this pins the ordering premise.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let paneId = PaneId(rawValue: UUID())
        let tabId = TabId(rawValue: UUID())
        runtime.model = AppModel(
            groups: [GroupModel(
                id: GroupId(rawValue: UUID()),
                name: "General",
                tabs: [TabModel(
                    id: tabId,
                    paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)))
                )]
            )],
            selectedTabId: tabId
        )
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let requestId = UUID()
        wire.remember(reqId: requestId, rpcId: .number(7))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        // The reply rides the connection's serial write queue, so enqueue order is wire
        // order. This hook runs on the main thread, mid-send: a reply enqueued only
        // after the override would have to be enqueued by this same blocked thread, so
        // it could never become readable during the wait -- which makes the bounded
        // wait a true ordering observation, not a timing one. The bound is a hang
        // guard: a passing run flushes in microseconds and cannot approach it.
        var replyPrecededOverride: [Bool] = []
        ports.session.onGridOverride = { _ in
            let deadline = Date().addingTimeInterval(30)
            while wire.hasReadableData() == false, Date() < deadline {
                usleep(1_000)
            }
            replyPrecededOverride.append(wire.hasReadableData())
        }

        runtime.send(.ipcRequest(
            reqId: requestId,
            caller: .local,
            request: .paneResize(pane: paneId, resize: .grid(columns: 100, rows: 30))
        ))

        let response = try wire.readResponse()
        #expect(response.id == .number(7))
        #expect(response.error == nil)
        #expect(ports.session.gridOverrides == [PaneGridOverride(columns: 100, rows: 30)])
        #expect(replyPrecededOverride == [true])
    }

    @Test("one send orders a notification port before its IPC reply")
    func sendPreservesCommandOrderAcrossPortAndWire() throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let requestId = UUID()
        wire.remember(reqId: requestId, rpcId: .number(42))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let selectedPaneId = PaneId(rawValue: UUID())
        let targetPaneId = PaneId(rawValue: UUID())
        let selectedTabId = TabId(rawValue: UUID())
        let targetTabId = TabId(rawValue: UUID())
        var targetSession = SessionModel(id: SessionId(rawValue: UUID()))
        targetSession.agent = .attached(session: agent, activity: nil)
        runtime.model = AppModel(
            groups: [GroupModel(
                id: GroupId(rawValue: UUID()),
                name: "General",
                tabs: [
                    TabModel(
                        id: selectedTabId,
                        paneTree: PaneTree(root: .leaf(PaneModel(id: selectedPaneId)))
                    ),
                    TabModel(
                        id: targetTabId,
                        paneTree: PaneTree(root: .leaf(PaneModel(
                            id: targetPaneId,
                            session: targetSession
                        )))
                    ),
                ]
            )],
            selectedTabId: selectedTabId
        )
        ports.onNotification = {
            wire.connection.writeNotification(method: "test.notification", params: JSONValue.null)
        }

        runtime.send(.ipcRequest(
            reqId: requestId,
            caller: .local,
            request: .agentActivity(
                pane: targetPaneId,
                session: IpcAgentSession(kind: "codex", id: "thread-1"),
                activity: .waiting
            )
        ))

        let first = try JSONDecoder().decode(JsonRpcRequest.self, from: wire.readLine())
        let second = try wire.readResponse()
        #expect(ports.notifications.count == 1)
        #expect(first.method == "test.notification")
        #expect(second.id == .number(42))
        #expect(second.result == .object(["ok": .bool(true)]))
    }
}

@MainActor
private func register(
    _ fixture: CommandIpcConnectionFixture,
    requestId: UUID,
    rpcId: JSONValue,
    runtime: AppRuntime
) {
    fixture.remember(reqId: requestId, rpcId: rpcId)
    runtime.registerIpcConnection(fixture.connection, for: requestId)
}
