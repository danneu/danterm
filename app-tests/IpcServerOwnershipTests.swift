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
        let fixture = try IpcServerSocketFixture()
        defer { fixture.remove() }
        let owner = try IpcServer(socketPath: fixture.socketURL, runtimeDispatch: nil)

        let contender = try? IpcServer(socketPath: fixture.socketURL, runtimeDispatch: nil)
        #expect(contender == nil)
        contender?.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        #expect(canConnectToIpcServer(at: fixture.socketURL))

        owner.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path) == false)
        #expect(canConnectToIpcServer(at: fixture.socketURL) == false)
    }

    @Test("runtime accepts IPC only after launch bootstrap completes")
    func runtimeDefersAcceptanceUntilExplicitStart() async throws {
        // Intent: runtime construction claims the socket, but request handling starts only
        //   after the launch bootstrap decision has resolved.
        // Why it exists: accepting during the recovery prompt let an IPC request mutate a
        //   model that the later restore then replaced wholesale.
        // Scenario: a client connects and sends ping before bootstrap finishes, then the
        //   delegate-equivalent start call releases that same queued request.
        let fixture = try IpcServerSocketFixture()
        defer { fixture.remove() }
        let configURL = fixture.directoryURL.appendingPathComponent("absent-config.json")
        let runtime = AppRuntime(
            ports: RecordingAppRuntimePorts().value,
            configStore: DanTermConfigStore(url: configURL),
            startsApplicationServices: true,
            socketPath: fixture.socketURL
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
    }
}

private struct IpcServerSocketFixture {
    let directoryURL: URL
    let socketURL: URL

    init() throws {
        directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-ipc-server-\(UUID().uuidString)", isDirectory: true)
        socketURL = directoryURL.appendingPathComponent("control.sock")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
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
