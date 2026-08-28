// Regression coverage for app-level IPC server ownership and synchronous teardown.
import Darwin
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct IpcServerOwnershipTests {
    @Test("failed server construction and shutdown preserve the live owner")
    func failedConstructionShutdownPreservesOwner() throws {
        // Intent: only a successfully constructed server can expose or remove a
        //   control socket, and its stop returns after that socket is gone.
        // Why it exists: a losing same-identity app retained a path it did not
        //   own, then deleted the winning app's live socket during shutdown.
        // Scenario: instance A owns the slot socket while instance B starts,
        //   loses the bind race, and quits before A later quits normally.
        let fixture = TemporaryInstancePaths()
        defer { fixture.remove() }
        let owner = try makeOwnershipServer(fixture)

        let contender = try? makeOwnershipServer(fixture)
        #expect(contender == nil)
        contender?.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        #expect(canConnectToIpcServer(at: fixture.socketURL))

        owner.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path) == false)
        #expect(canConnectToIpcServer(at: fixture.socketURL) == false)
    }

    @Test("application services arm one census entry each and retire on the calls that end them")
    func applicationServicesCensus() throws {
        // Intent: the switcher monitor and the IPC server are each one census entry, and
        //   the calls that end them -- stopIpcServer, shutdown -- take those entries away
        //   along with the native registration behind them.
        // Why it exists: the census is the only window a test has onto runtime ownership,
        //   so a handle that outlived its entry would otherwise be invisible.
        // Scenario: a runtime starts application services, the caller stops IPC while the
        //   runtime keeps running, and later shuts the whole runtime down.
        let fixture = TemporaryInstancePaths()
        defer { fixture.remove() }
        let runtime = AppRuntime(
            ports: RecordingAppRuntimePorts().value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: fixture.paths,
            configStore: DanTermConfigStore(url: fixture.absentConfigURL),
            startsApplicationServices: true,
            applicationActive: true
        )
        defer { runtime.shutdown() }

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.ipcServer] == 1)
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.eventMonitor] == 1)
        #expect(canConnectToIpcServer(at: fixture.socketURL))

        runtime.stopIpcServer()

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.ipcServer] == nil)
        #expect(runtime.ipcSocketPath == nil)
        #expect(canConnectToIpcServer(at: fixture.socketURL) == false)
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.eventMonitor] == 1)

        runtime.shutdown()

        #expect(runtime.schedulingLifecycle.captureOwnerCensus().isEmpty)
    }

    @Test("runtime accepts IPC only after launch bootstrap completes")
    func runtimeDefersAcceptanceUntilExplicitStart() async throws {
        // Intent: runtime construction claims the socket, but request handling starts only
        //   after the launch bootstrap decision has resolved.
        // Why it exists: accepting during the recovery prompt let an IPC request mutate a
        //   model that the later restore then replaced wholesale.
        // Scenario: a client connects and sends ping before bootstrap finishes, then the
        //   delegate-equivalent start call releases that same queued request.
        let fixture = TemporaryInstancePaths()
        defer { fixture.remove() }
        let runtime = AppRuntime(
            ports: RecordingAppRuntimePorts().value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: fixture.paths,
            configStore: DanTermConfigStore(url: fixture.absentConfigURL),
            startsApplicationServices: true,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        let peer = try connectToIpcServer(at: fixture.socketURL)
        defer { Darwin.close(peer) }
        let request = try encodeIpcLine(JsonRpcRequest(
            id: .number(7),
            method: IpcRequestMethod.ping.rawValue,
            params: .object([:])
        ))
        try writeAll(request, to: peer)

        // This expiry is the observation: the bound listener must not answer yet.
        #expect(pollForReadableData(peer, timeoutMilliseconds: 50) == false)

        runtime.startIpcServer()

        let response = try await Task.detached {
            try readResponse(id: .number(7), from: peer)
        }.value
        #expect(response.error == nil)
        // The runtime derives its audit sink from the same paths value it was given,
        // so a test runtime never appends to the user's real recovery directory.
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.ipcAuditDirectory
                .appendingPathComponent("ipc-audit.jsonl").path
        ))
        #expect(fixture.paths.ipcAuditDirectory.path.hasPrefix(fixture.rootURL.path))
    }

    @Test("recovery prompt starts IPC before its answer commits the restore")
    func restorePromptStartsIpcBeforeAnswer() async throws {
        // Intent: showing the recovery prompt starts IPC while the recovered panes remain
        //   inert until the user answers Restore.
        // Why it exists: the server used to stay closed for the whole prompt because restore
        //   replaced the model outside the reducer. The reducer store removed that constraint.
        // Scenario: a client pings while the launch recovery prompt is still unanswered, then
        //   the user restores the saved pane.
        let socket = TemporaryInstancePaths()
        defer { socket.remove() }
        let ports = RecordingAppRuntimePorts()
        let runtime = AppRuntime(
            ports: ports.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: socket.paths,
            configStore: DanTermConfigStore(url: socket.absentConfigURL),
            startsApplicationServices: true,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let restore = try ownershipValidatedRestore(makeCommandSnapshot(paneId: paneId))
        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let peer = try connectToIpcServer(at: socket.socketURL)
        defer { Darwin.close(peer) }
        try writeAll(try encodeIpcLine(JsonRpcRequest(
            id: .number(8),
            method: IpcRequestMethod.ping.rawValue,
            params: .object([:])
        )), to: peer)

        let becameReadable = await Task.detached {
            pollForReadableData(peer, timeoutMilliseconds: 30_000)
        }.value
        guard becameReadable else {
            throw POSIXError(.ETIMEDOUT)
        }
        let response = try await Task.detached {
            try readResponse(id: .number(8), from: peer)
        }.value
        #expect(response.error == nil)
        #expect(runtime.paneHosts.keys.contains(paneId) == false)

        let noticeId = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: noticeId, answer: .restore))
        await Task.yield()

        #expect(runtime.paneHosts.keys.contains(paneId))
    }

    @Test("Start Fresh creates a fresh tab while IPC is already accepting")
    func startFreshKeepsActiveIpc() async throws {
        let socket = TemporaryInstancePaths()
        defer { socket.remove() }
        let ports = RecordingAppRuntimePorts()
        let runtime = AppRuntime(
            ports: ports.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: socket.paths,
            configStore: DanTermConfigStore(url: socket.absentConfigURL),
            startsApplicationServices: true,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        let recoveredPaneId = PaneId(rawValue: UUID())
        let restore = try ownershipValidatedRestore(makeCommandSnapshot(paneId: recoveredPaneId))
        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let peer = try connectToIpcServer(at: socket.socketURL)
        defer { Darwin.close(peer) }
        try writeAll(try encodeIpcLine(JsonRpcRequest(
            id: .number(9),
            method: IpcRequestMethod.ping.rawValue,
            params: .object([:])
        )), to: peer)

        let becameReadable = await Task.detached {
            pollForReadableData(peer, timeoutMilliseconds: 30_000)
        }.value
        guard becameReadable else {
            throw POSIXError(.ETIMEDOUT)
        }
        let response = try await Task.detached {
            try readResponse(id: .number(9), from: peer)
        }.value
        #expect(response.error == nil)

        let noticeId = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: noticeId, answer: .startFresh))
        await Task.yield()

        #expect(ports.sessionRequests.count == 1)
        #expect(runtime.paneHosts.keys.contains(recoveredPaneId) == false)
        #expect(runtime.model.allPaneIds.count == 1)
    }

    @Test("failed recovery build falls back to fresh while IPC stays available")
    func failedRestoreKeepsActiveIpc() async throws {
        let socket = TemporaryInstancePaths()
        defer { socket.remove() }
        let ports = RecordingAppRuntimePorts()
        ports.failedSessionRequestNumbers = [1]
        let runtime = AppRuntime(
            ports: ports.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: socket.paths,
            configStore: DanTermConfigStore(url: socket.absentConfigURL),
            startsApplicationServices: true,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        let restore = try ownershipValidatedRestore(
            makeCommandSnapshot(paneId: PaneId(rawValue: UUID()))
        )
        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let peer = try connectToIpcServer(at: socket.socketURL)
        defer { Darwin.close(peer) }
        try writeAll(try encodeIpcLine(JsonRpcRequest(
            id: .number(10),
            method: IpcRequestMethod.ping.rawValue,
            params: .object([:])
        )), to: peer)

        let becameReadable = await Task.detached {
            pollForReadableData(peer, timeoutMilliseconds: 30_000)
        }.value
        guard becameReadable else {
            throw POSIXError(.ETIMEDOUT)
        }
        let response = try await Task.detached {
            try readResponse(id: .number(10), from: peer)
        }.value
        #expect(response.error == nil)

        let noticeId = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: noticeId, answer: .restore))
        await Task.yield()

        #expect(ports.sessionRequests.count == 2)
        #expect(runtime.model.allPaneIds.count == 1)
    }
}

private func ownershipValidatedRestore(_ snapshot: AppModelSnapshot) throws -> ValidatedAppRestore {
    let built = try #require(validateAndBuildDetailed(snapshot))
    return ValidatedAppRestore(
        model: built.model,
        paneSnapshots: built.paneSnapshots
    )
}

/// Builds a server on the fixture's own paths, so the socket it claims and the audit
/// log it writes both stay inside the fixture directory.
private func makeOwnershipServer(_ fixture: TemporaryInstancePaths) throws -> IpcServer {
    try IpcServer(
        socketPath: fixture.socketURL,
        identity: fixture.paths.identity,
        auditWriter: IpcAuditLogWriter(directory: fixture.paths.ipcAuditDirectory),
        runtimeDispatch: nil
    )
}

private func canConnectToIpcServer(at url: URL) -> Bool {
    guard let fileDescriptor = try? connectToIpcServer(at: url) else { return false }
    defer { Darwin.close(fileDescriptor) }
    return true
}

private func connectToIpcServer(at url: URL) throws -> Int32 {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard url.path.utf8.count < maximumLength else {
        Darwin.close(fileDescriptor)
        throw CocoaError(.fileWriteInvalidFileName)
    }
    url.path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            let destination = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
            strncpy(destination, source, maximumLength - 1)
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(fileDescriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return fileDescriptor
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fileDescriptor,
                rawBuffer.baseAddress!.advanced(by: offset),
                rawBuffer.count - offset
            )
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
    }
}

private func pollForReadableData(_ fileDescriptor: Int32, timeoutMilliseconds: Int32) -> Bool {
    var readiness = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
    return Darwin.poll(&readiness, 1, timeoutMilliseconds) > 0
}

private func readResponse(id: JSONValue, from fileDescriptor: Int32) throws -> JsonRpcResponse {
    while true {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            guard pollForReadableData(fileDescriptor, timeoutMilliseconds: 30_000) else {
                throw POSIXError(.ETIMEDOUT)
            }
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw POSIXError(count == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        if let response = try? JSONDecoder().decode(JsonRpcResponse.self, from: Data(bytes)),
           response.id == id {
            return response
        }
    }
}
