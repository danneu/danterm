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
    func directReplyAndErrorWriteWireEnvelopes() async throws {
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

        let replyEnvelope = try await reply.readResponseAsync()
        let failureEnvelope = try await failure.readResponseAsync()
        #expect(replyEnvelope.id == .number(11))
        #expect(replyEnvelope.result == .object(["ok": .bool(true)]))
        #expect(failureEnvelope.id == .string("failure"))
        #expect(failureEnvelope.error == JsonRpcError(code: -32602, message: "invalid pane"))
        #expect(reply.hasReadableData() == false, "a retired reply must not close its socket")

        runtime.shutdown()
        reply.connection.close()

        #expect(
            try await reply.readByteAsync() == 0,
            "transport shutdown must be the first source of EOF"
        )
    }

    // Intent: the doctor reply names the config file this instance was launched
    //   against, beside the permissions only a running app can answer for.
    // Why it exists: a slot and the user's app read different files, so doctor can
    //   only report on the right one if the instance says which it read. Pins the
    //   path to the store's URL, so a re-resolution here could not pass.
    @Test("doctor and focus reads return runtime-owned facts")
    func doctorAndFocusReadsWriteFacts() async throws {
        let ports = RecordingAppRuntimePorts()
        ports.doctorPermissions = DoctorFacts.Permissions(
            notifications: .granted,
            fullDiskAccess: .denied,
            developerTools: .unknown
        )
        ports.doctorConfigFont = .notInstalled(requested: "Slot Mono")
        let configURL = URL(fileURLWithPath: "/fixture-slot/config/slot-3.json")
        let runtime = makeCommandTestRuntime(ports, configStore: DanTermConfigStore(url: configURL))
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

        runtime.perform(.readDoctorAppFacts(reqId: doctorId))
        runtime.perform(.readFocusInfo(reqId: focusId))

        let doctorEnvelope = try await doctor.readResponseAsync()
        let focusEnvelope = try await focus.readResponseAsync()
        #expect(doctorEnvelope.result == DoctorFacts.AppFacts(
            permissions: ports.doctorPermissions,
            configFilePath: configURL.path,
            configFont: ports.doctorConfigFont
        ).jsonValue)
        #expect(ports.doctorConfigFilePaths == [configURL.path])
        #expect(focusEnvelope.result == .object([
            "focus": .object(["type": .string("none")]),
        ]))
    }

    @Test("the surface census sums measured panes and names unmeasured ones")
    func surfaceCensusSeparatesUnmeasuredFromZero() async throws {
        // Intent: the census walks every installed pane, sums only the panes whose
        //   session answered, and lists the ones that could not be measured instead
        //   of counting them as panes holding nothing.
        // Why it exists: research/41 D1 admits an in-app attribution only when zero
        //   stays distinguishable from unmeasured; a walk that summed a nil as a
        //   zero would report a smaller footprint than the process holds.
        // Scenario: two installed panes, one reporting a hidden three-buffer
        //   rotation, one with no presentation to measure.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let measuredId = PaneId(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        let unmeasuredId = PaneId(rawValue: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!)
        let measured = RecordingTerminalSession()
        measured.surfaceCensus = TerminalSessionSurfaceCensus(
            isVisible: false,
            swapchain: TerminalSessionSurfaceCensus.Swapchain(
                storeCount: 3,
                bytes: 60_710_400,
                pixelWidth: 2720,
                pixelHeight: 1860
            ),
            displayedStoreOutsideSwapchainBytes: 20_250_624
        )
        let unmeasured = RecordingTerminalSession()
        runtime.installTerminalSession(measured, paneId: measuredId)
        runtime.installTerminalSession(unmeasured, paneId: unmeasuredId)
        let fixture = try CommandIpcConnectionFixture()
        defer {
            fixture.connection.close()
            fixture.closePeer()
        }
        let reqId = UUID()
        register(fixture, requestId: reqId, rpcId: .number(1), runtime: runtime)

        runtime.perform(.readDebugSurfaces(reqId: reqId))

        let envelope = try await fixture.readResponseAsync()
        let result = try #require(envelope.result)
        #expect(result["panes"] == .object([
            "total": .number(2),
            "visible": .number(0),
            "hidden": .number(1),
            "measured": .number(1),
            "unmeasured": .array([.string(unmeasuredId.rawValue.uuidString)]),
        ]))
        #expect(result["swapchains"] == .object([
            "count": .number(1),
            "stores": .number(3),
            "bytes": .number(60_710_400),
        ]))
        #expect(result["displayedOutsideSwapchain"] == .object([
            "count": .number(1),
            "bytes": .number(20_250_624),
        ]))
        #expect(result["surfaces"] == .object([
            "count": .number(4),
            "bytes": .number(80_961_024),
        ]))
        #expect(result["perPane"] == .array([
            .object([
                "paneId": .string(measuredId.rawValue.uuidString),
                "visible": .bool(false),
                "swapchain": .object([
                    "stores": .number(3),
                    "bytes": .number(60_710_400),
                    "pixelWidth": .number(2720),
                    "pixelHeight": .number(1860),
                ]),
                "displayedOutsideSwapchainBytes": .number(20_250_624),
            ]),
            .object([
                "paneId": .string(unmeasuredId.rawValue.uuidString),
                "swapchain": .string("unmeasured"),
            ]),
        ]))
    }

    @Test("pane text and row reads preserve terminal results")
    func paneReadsWriteSessionResults() async throws {
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        ports.session.viewportText = "visible"
        ports.session.fullHistoryText = "one\ntwo\nthree"
        ports.session.viewportCells = TerminalSessionViewportCells(
            columns: 12,
            rowCount: 1,
            paneRowsOrigin: 7,
            rows: [TerminalSessionViewportCellRow(index: 0, spans: [
                TerminalSessionViewportCellSpan(
                    kind: "wide",
                    column: 3,
                    cellWidth: 2,
                    text: "\u{754C}",
                    utf8Offsets: [0]
                ),
            ])]
        )
        ports.session.rowStructure = [TerminalSessionRowStructure(
            index: 7,
            isRetained: true,
            isSoftWrapped: false,
            contentEnd: 4,
            visibleEnd: 6,
            fill: TerminalSessionCellStyle(
                foreground: "default",
                background: "indexed:4",
                underlineColor: "default",
                attributes: ["bold"]
            ),
            width: 12,
            marginKind: "padding",
            staleWrapClaim: true
        )]
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let viewport = try CommandIpcConnectionFixture()
        let history = try CommandIpcConnectionFixture()
        let rows = try CommandIpcConnectionFixture()
        let cells = try CommandIpcConnectionFixture()
        defer {
            for fixture in [viewport, history, rows, cells] {
                fixture.connection.close()
                fixture.closePeer()
            }
        }
        let viewportId = UUID()
        let historyId = UUID()
        let rowsId = UUID()
        let cellsId = UUID()
        register(viewport, requestId: viewportId, rpcId: .number(1), runtime: runtime)
        register(history, requestId: historyId, rpcId: .number(2), runtime: runtime)
        register(rows, requestId: rowsId, rpcId: .number(3), runtime: runtime)
        register(cells, requestId: cellsId, rpcId: .number(4), runtime: runtime)

        runtime.perform(.readPaneText(reqId: viewportId, paneId: paneId, lineLimit: nil))
        runtime.perform(.readPaneText(reqId: historyId, paneId: paneId, lineLimit: 2))
        runtime.perform(.readPaneRowStructure(reqId: rowsId, paneId: paneId))
        runtime.perform(.readPaneCells(reqId: cellsId, paneId: paneId))

        #expect(try await viewport.readResponseAsync().result == .object(["text": .string("visible")]))
        #expect(try await history.readResponseAsync().result == .object(["text": .string("two\nthree")]))
        #expect(try await rows.readResponseAsync().result == .object([
            "rows": .array([.object([
                "index": .number(7),
                "retained": .bool(true),
                "softWrapped": .bool(false),
                "contentEnd": .number(4),
                "visibleEnd": .number(6),
                "fill": .object([
                    "foreground": .string("default"),
                    "background": .string("indexed:4"),
                    "underlineColor": .string("default"),
                    "attributes": .array([.string("bold")]),
                ]),
                "width": .number(12),
                "marginKind": .string("padding"),
                "staleWrapClaim": .bool(true),
            ])]),
        ]))
        #expect(try await cells.readResponseAsync().result == .object([
            "columns": .number(12),
            "rowCount": .number(1),
            "paneRowsOrigin": .number(7),
            "rows": .array([.object([
                "index": .number(0),
                "spans": .array([.object([
                    "kind": .string("wide"),
                    "column": .number(3),
                    "cellWidth": .number(2),
                    "text": .string("\u{754C}"),
                    "utf8Offsets": .array([.number(0)]),
                ])]),
            ])]),
        ]))
    }

    @Test("pane tape commands select dump and follow session entry points")
    func paneTapeCommandsWriteSessionErrors() async throws {
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

        #expect(try await dump.readResponseAsync().error?.message == "pane has no terminal to read a tape from")
        #expect(try await follow.readResponseAsync().error?.message == "pane has no terminal to read a tape from")
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
    func paneTapeDumpPutsDecodableRecordsOnTheWire() async throws {
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

        let result = try #require(try await wire.readResponseAsync().result)
        guard case .start(let start)? = decodePaneTapeRecord(result) else {
            Issue.record("the dump's reply must decode as a start record")
            return
        }
        #expect(start.version == paneTapeStreamVersion)
        #expect(start.capture == .dump)

        // One notification carries the whole delivery, so the dump's event and its
        // terminator arrive together rather than one notification each.
        let records = try #require(
            try await wire.readNotificationAsync().params?["records"]?.asArray
        )
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

    @Test("config save failure queues a notice and completes font resolution before return")
    func configFailureReentersBeforePerformReturns() {
        let ports = RecordingAppRuntimePorts()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-unwritable-config-\(UUID().uuidString)/config.json")
        let store = DanTermConfigStore(url: url, writeData: { _, _ in
            throw POSIXError(.EROFS)
        })
        var initialModel = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")]
        )
        initialModel.resolvedFontFamily = "stale family"
        let runtime = makeCommandTestRuntime(
            ports,
            configStore: store,
            initialModel: initialModel
        )
        defer { runtime.shutdown() }
        runtime.send(.preferencesOpened())
        runtime.send(.prefSet(.fontFamily("DanTerm Missing Font \(UUID().uuidString)")))
        runtime.send(.prefSave)

        #expect(runtime.model.noticeQueue.count == 1)
        #expect(desiredNotice(in: runtime.model)?.title == "DanTerm Config Error")
        #expect(desiredNotice(in: runtime.model)?.message.contains("could not save") == true)
        #expect(runtime.model.resolvedFontFamily == nil)
    }

    @Test("input rejection re-enters update and writes the pending reply")
    func inputRejectionWritesPendingErrorBeforeReturn() async throws {
        let ports = RecordingAppRuntimePorts()
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let requestId = UUID()
        let submissionId = InputSubmissionId(rawValue: UUID())
        var initialModel = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")]
        )
        initialModel.pendingInputSubmissions[submissionId] = PendingInputSubmission(
            requestId: requestId,
            paneId: PaneId(rawValue: UUID())
        )
        let runtime = makeCommandTestRuntime(ports, initialModel: initialModel)
        defer { runtime.shutdown() }
        wire.remember(reqId: requestId, rpcId: .number(9))
        runtime.registerIpcConnection(wire.connection, for: requestId)

        runtime.perform(.submitPaneInput(
            paneId: PaneId(rawValue: UUID()),
            input: .paste("unroutable"),
            submissionId: submissionId
        ))

        let response = try await wire.readResponseAsync()
        #expect(response.error?.code == -32603)
        #expect(response.error?.message ==
            "pane input was not delivered because the pane process ended")
        #expect(runtime.model.pendingInputSubmissions.isEmpty)
    }

    @Test("wheel completion re-enters update and writes the pending reply")
    func wheelCompletionWritesPendingReply() async throws {
        // Intent: a routed wheel event completes the same pending IPC request as keys and text.
        // Why it exists: wheel can finish as a local scroll or a PTY write, but neither path
        //   may leave the caller waiting after the pane owner handled it.
        // Scenario: an installed session accepts one wheel-up event at a viewport cell.
        let ports = RecordingAppRuntimePorts()
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let paneId = PaneId(rawValue: UUID())
        let requestId = UUID()
        let submissionId = InputSubmissionId(rawValue: UUID())
        var initialModel = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")]
        )
        initialModel.pendingInputSubmissions[submissionId] = PendingInputSubmission(
            requestId: requestId,
            paneId: paneId
        )
        let runtime = makeCommandTestRuntime(ports, initialModel: initialModel)
        defer { runtime.shutdown() }
        runtime.installTerminalSession(ports.session, paneId: paneId)
        wire.remember(reqId: requestId, rpcId: .number(10))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        runtime.perform(.submitPaneInput(
            paneId: paneId,
            input: .wheel(.up, column: 4, row: 2),
            submissionId: submissionId
        ))

        let response = try await wire.readResponseAsync()
        #expect(response.result == .object(["ok": .bool(true)]))
        #expect(ports.session.sentInputWheels.count == 1)
        #expect(runtime.model.pendingInputSubmissions.isEmpty)
    }

    @Test("a pane-resize reply is written before the resize reaches the pane")
    func paneResizeReplyPrecedesTheResizeItself() async throws {
        // Intent: within one send frame, the pane.resize response is on the wire before
        //   the runtime applies the override to the pane's session -- the earliest moment
        //   any tape record of that resize can exist.
        // Why it exists: the phone's claim protocol reads a tape record's pinnedness as
        //   post-claim truth exactly when the record follows the claim's success response
        //   on the frame stream. That reading is sound only while the server replies
        //   before it reconciles; this pins the ordering premise.
        let ports = RecordingAppRuntimePorts()
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let paneId = PaneId(rawValue: UUID())
        let tabId = TabId(rawValue: UUID())
        let initialModel = AppModel(
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
        let runtime = makeCommandTestRuntime(ports, initialModel: initialModel)
        defer { runtime.shutdown() }
        runtime.installTerminalSession(ports.session, paneId: paneId)
        let requestId = UUID()
        wire.remember(reqId: requestId, rpcId: .number(7))
        runtime.registerIpcConnection(wire.connection, for: requestId)
        // The reply and marker share the connection's serial write queue, so their wire
        // order observes whether the reply was enqueued before the grid override.
        ports.session.onGridOverride = { _ in
            wire.connection.writeNotification(
                method: "test.gridOverride",
                params: JSONValue.null
            )
        }

        runtime.send(.ipcRequest(
            reqId: requestId,
            caller: .local,
            request: .paneResize(pane: paneId, resize: .grid(columns: 100, rows: 30))
        ))

        let response = try await wire.readResponseAsync()
        let marker = try await wire.readNotificationAsync()
        #expect(response.id == .number(7))
        #expect(response.error == nil)
        #expect(marker.method == "test.gridOverride")
        #expect(ports.session.gridOverrides == [PaneGridOverride(columns: 100, rows: 30)])
    }

    @Test("one send orders a notification port before its IPC reply")
    func sendPreservesCommandOrderAcrossPortAndWire() async throws {
        let ports = RecordingAppRuntimePorts()
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        let requestId = UUID()
        wire.remember(reqId: requestId, rpcId: .number(42))
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let selectedPaneId = PaneId(rawValue: UUID())
        let targetPaneId = PaneId(rawValue: UUID())
        let selectedTabId = TabId(rawValue: UUID())
        let targetTabId = TabId(rawValue: UUID())
        var targetSession = SessionModel(id: SessionId(rawValue: UUID()))
        targetSession.agent = .attached(session: agent, activity: nil)
        let initialModel = AppModel(
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
        let runtime = makeCommandTestRuntime(ports, initialModel: initialModel)
        defer { runtime.shutdown() }
        runtime.registerIpcConnection(wire.connection, for: requestId)
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

        let first = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: try await wire.readLineAsync()
        )
        let second = try await wire.readResponseAsync()
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
