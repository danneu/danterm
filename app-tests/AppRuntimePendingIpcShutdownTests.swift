// Deterministic transport proof for pending pane effects at application shutdown.
import Darwin
import Foundation
import DanTermProtocol
import Testing
@testable import DanTerm

/// How long a read in this file waits before it declares shutdown hung.
///
/// This is a hang guard, not a threshold: nothing here measures how fast shutdown answers,
/// so the only requirement is that a passing run cannot approach it and that it fires
/// before the suite's time-limit backstop, so the failure names the read.
private let hangGuardMilliseconds: Int32 = 30_000

/// Proves shutdown writes terminal errors before it closes pending IPC transports.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppRuntimePendingIpcShutdownTests {
    @Test("shutdown answers pending creation and input before transport close")
    func shutdownAnswersPendingPaneEffectsBeforeClose() throws {
        // Intent: both pending-identity paths' error replies are in the kernel -- readable
        //   by their peers with no further waiting and no manual close -- when shutdown()
        //   returns, and each socket still reaches EOF once its transport closes.
        // Why it exists: runtime shutdown previously erased its connection census first and
        //   stranded callers, and later enqueued the replies without flushing them, so a
        //   caller nondeterministically lost the reply to process exit.
        // Scenario: one creation and one input remain in flight when application teardown starts.
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let creation = try ShutdownConnectionFixture()
        let input = try ShutdownConnectionFixture()
        defer {
            Darwin.close(creation.peer)
            Darwin.close(input.peer)
        }
        let creationRequestId = UUID()
        let inputRequestId = UUID()
        var initialModel = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")]
        )
        initialModel.pendingSessionCreations[SessionId(rawValue: UUID())] = PendingSessionCreation(
            requestId: creationRequestId,
            result: .null
        )
        let submissionId = InputSubmissionId(rawValue: UUID())
        initialModel.pendingInputSubmissions[submissionId] = PendingInputSubmission(
            requestId: inputRequestId,
            paneId: PaneId(rawValue: UUID())
        )
        let runtime = AppRuntime(
            ports: .live(terminalBackend: SwiftTerminalBackend()),
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            initialModel: initialModel,
            startsApplicationServices: false,
            applicationActive: true
        )
        creation.connection.rememberRequest(reqId: creationRequestId, rpcId: .number(1))
        input.connection.rememberRequest(reqId: inputRequestId, rpcId: .number(2))
        runtime.registerIpcConnection(creation.connection, for: creationRequestId)
        runtime.registerIpcConnection(input.connection, for: inputRequestId)
        runtime.shutdown()

        let creationReply = try readDeliveredResponse(from: creation.peer)
        let inputReply = try readDeliveredResponse(from: input.peer)
        #expect(creationReply.error?.code == -32603)
        #expect(inputReply.error?.code == -32603)
        creation.connection.close()
        input.connection.close()
        #expect(try readByte(from: creation.peer) == 0)
        #expect(try readByte(from: input.peer) == 0)
    }

    @Test("shutdown pays one total flush bound across several wedged peers")
    func shutdownFlushBoundIsTotalAcrossWedgedPeers() throws {
        // Intent: with several pending connections whose peers have stopped reading a
        //   full socket backlog, shutdown() returns within one total flush bound, not
        //   one bound per connection.
        // Why it exists: the flush sits on the quit path; a per-connection wait would
        //   scale quit latency with the number of stuck clients.
        // Scenario: spec-first -- several clients hang without reading while quit
        //   drains their pending input requests.
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let wedgedPeerCount = 8
        let fixtures = try (0..<wedgedPeerCount).map { _ in try ShutdownConnectionFixture() }
        defer {
            for fixture in fixtures {
                fixture.connection.forceClose()
                Darwin.close(fixture.peer)
            }
        }
        var initialModel = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")]
        )
        var requestIds: [UUID] = []
        for fixture in fixtures {
            var sendBufferBytes: Int32 = 4_096
            setsockopt(
                fixture.connectionDescriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            )
            fixture.connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: JSONValue.object([
                    "record": .string(String(repeating: "x", count: 4_000_000)),
                ])
            )
            let requestId = UUID()
            requestIds.append(requestId)
            initialModel.pendingInputSubmissions[InputSubmissionId(rawValue: UUID())] =
                PendingInputSubmission(requestId: requestId, paneId: PaneId(rawValue: UUID()))
        }
        // The parked writes announce themselves by the bytes that did fit; only then is
        // the flush provably waiting on wedged peers rather than on empty queues.
        for fixture in fixtures {
            guard waitUntilReadable(fixture.peer) else { throw POSIXError(.ETIMEDOUT) }
        }
        // Meant to expire: no wedged peer ever reads, so the flush runs out its bound.
        let flushBound = 0.25
        let runtime = AppRuntime(
            ports: .live(terminalBackend: SwiftTerminalBackend()),
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            initialModel: initialModel,
            startsApplicationServices: false,
            ipcShutdownFlushBound: flushBound,
            applicationActive: true
        )
        for (fixture, requestId) in zip(fixtures, requestIds) {
            fixture.connection.rememberRequest(reqId: requestId, rpcId: .number(1))
            runtime.registerIpcConnection(fixture.connection, for: requestId)
        }

        let elapsed = ContinuousClock().measure { runtime.shutdown() }

        // Not a speed threshold: both durations are defined by the bound this test
        // injects. A per-connection implementation waits the bound once per wedged
        // peer, so it cannot return before wedgedPeerCount * flushBound; a total-bound
        // one returns after ~one flushBound.
        #expect(elapsed < .seconds(flushBound * Double(wedgedPeerCount)))
    }
}

private struct ShutdownConnectionFixture {
    let connection: IpcConnection
    let connectionDescriptor: Int32
    let peer: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.ENOTSOCK)
        }
        connection = IpcConnection(fileDescriptor: descriptors[0])
        connectionDescriptor = descriptors[0]
        peer = descriptors[1]
    }
}

/// Reads one reply line the kernel already holds for the peer, without waiting.
///
/// Not waiting is the point: the claim under test is that a returned shutdown() has
/// already handed the reply bytes to the kernel, so any blocking here would mask exactly
/// the flush omission the caller asserts against.
private func readDeliveredResponse(from descriptor: Int32) throws -> JsonRpcResponse {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var line = Data(buffer.prefix(count))
    guard line.last == 0x0A else { throw POSIXError(.EBADMSG) }
    line.removeLast()
    return try JSONDecoder().decode(JsonRpcResponse.self, from: line)
}

private func readByte(from descriptor: Int32) throws -> Int {
    guard waitUntilReadable(descriptor) else { throw POSIXError(.ETIMEDOUT) }
    var byte: UInt8 = 0
    return Darwin.read(descriptor, &byte, 1)
}

private func waitUntilReadable(_ descriptor: Int32) -> Bool {
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
        let result = Darwin.poll(&readiness, 1, hangGuardMilliseconds)
        if result < 0, errno == EINTR { continue }
        return result > 0
    }
}
