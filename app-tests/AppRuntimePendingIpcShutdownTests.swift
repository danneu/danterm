// Deterministic transport proof for pending pane effects at application shutdown.
import Darwin
import Foundation
import DanTermProtocol
import Testing
@testable import DanTerm

/// Proves shutdown writes terminal errors before it closes pending IPC transports.
@MainActor
struct AppRuntimePendingIpcShutdownTests {
    @Test("shutdown answers pending creation and input before transport close")
    func shutdownAnswersPendingPaneEffectsBeforeClose() throws {
        // Intent: both pending-identity paths receive an error before their sockets reach EOF.
        // Why it exists: runtime shutdown previously erased its connection census first and
        //   stranded callers, while creation and input travel through separate model tables.
        // Scenario: one creation and one input remain in flight when application teardown starts.
        let absentConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-no-config-\(UUID().uuidString)")
        let runtime = AppRuntime(
            ports: .live(terminalBackend: SwiftTerminalBackend()),
            configStore: DanTermConfigStore(url: absentConfig),
            startsApplicationServices: false
        )
        let creation = try ShutdownConnectionFixture()
        let input = try ShutdownConnectionFixture()
        defer {
            Darwin.close(creation.peer)
            Darwin.close(input.peer)
        }
        let creationRequestId = UUID()
        let inputRequestId = UUID()
        creation.connection.rememberRequest(reqId: creationRequestId, rpcId: .number(1))
        input.connection.rememberRequest(reqId: inputRequestId, rpcId: .number(2))
        runtime.registerIpcConnection(creation.connection, for: creationRequestId)
        runtime.registerIpcConnection(input.connection, for: inputRequestId)
        runtime.model.pendingSessionCreations[SessionId(rawValue: UUID())] = PendingSessionCreation(
            requestId: creationRequestId,
            result: .null
        )
        let submissionId = InputSubmissionId(rawValue: UUID())
        runtime.model.pendingInputRequests[inputRequestId] = PendingInputRequest(
            remaining: [submissionId]
        )
        runtime.model.pendingInputSubmissions[submissionId] = inputRequestId

        runtime.shutdown()
        creation.connection.close()
        input.connection.close()

        let creationReply = try readResponse(from: creation.peer)
        let inputReply = try readResponse(from: input.peer)
        #expect(creationReply.error?.code == -32603)
        #expect(inputReply.error?.code == -32603)
        #expect(readByte(from: creation.peer) == 0)
        #expect(readByte(from: input.peer) == 0)
    }
}

private struct ShutdownConnectionFixture {
    let connection: IpcConnection
    let peer: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.ENOTSOCK)
        }
        connection = IpcConnection(fileDescriptor: descriptors[0])
        peer = descriptors[1]
    }
}

private func readResponse(from descriptor: Int32) throws -> JsonRpcResponse {
    guard waitUntilReadable(descriptor) else { throw POSIXError(.ETIMEDOUT) }
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(descriptor, &byte, 1)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        if byte == 0x0A { break }
        bytes.append(byte)
    }
    return try JSONDecoder().decode(JsonRpcResponse.self, from: Data(bytes))
}

private func readByte(from descriptor: Int32) -> Int {
    guard waitUntilReadable(descriptor) else { return -1 }
    var byte: UInt8 = 0
    return Darwin.read(descriptor, &byte, 1)
}

private func waitUntilReadable(_ descriptor: Int32) -> Bool {
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
        let result = Darwin.poll(&readiness, 1, 2_000)
        if result < 0, errno == EINTR { continue }
        return result > 0
    }
}
