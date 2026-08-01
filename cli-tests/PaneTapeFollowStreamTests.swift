// Socket-and-pipe coverage for the CLI's unbuffered pane-tape JSON Lines renderer.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermCLI

struct PaneTapeFollowStreamTests {
    @Test("follow renderer flushes each record and stops after end")
    func rendererWritesImmediateLinesThroughProductionDescriptors() throws {
        // Intent: every start, event, and end record is visible before a later frame arrives.
        // Why it exists: print or FileHandle buffering would defeat live pane observation.
        // Scenario: an agent tails a quiet pane, sees isolated output, then the pane closes.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        let completion = FollowCompletionProbe()
        defer {
            Darwin.close(socket.peer)
            Darwin.close(output.read)
        }

        DispatchQueue.global().async {
            do {
                completion.finish(try renderPaneTapeFollowStream(
                    socket: socket.connection,
                    output: output.write,
                    requestId: "R1"
                ))
            } catch {
                completion.fail(error)
            }
            Darwin.close(socket.connection)
            Darwin.close(output.write)
        }

        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: record("start")),
            to: socket.peer
        )
        let startLine = try encodedRecordLine(record("start"))
        #expect(try readDescriptorLine(output.read) == startLine)

        try writeFrame(notification(record("event")), to: socket.peer)
        let eventLine = try encodedRecordLine(record("event"))
        #expect(try readDescriptorLine(output.read) == eventLine)

        try writeFrame(notification(record("end")), to: socket.peer)
        let endLine = try encodedRecordLine(record("end"))
        #expect(try readDescriptorLine(output.read) == endLine)
        #expect(try completion.wait() == .end)
    }

    @Test("follow renderer treats EOF after start as clean termination")
    func rendererStopsCleanlyOnEOF() throws {
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: record("start")),
            to: socket.peer
        )
        Darwin.close(socket.peer)

        #expect(try renderPaneTapeFollowStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .eof)
        let startLine = try encodedRecordLine(record("start"))
        #expect(try readDescriptorLine(output.read) == startLine)
    }

    @Test("follow renderer treats a closed stdout pipe as clean termination")
    func rendererStopsCleanlyOnBrokenPipe() throws {
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(socket.peer)
            Darwin.close(output.write)
        }
        signal(SIGPIPE, SIG_IGN)
        Darwin.close(output.read)
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: record("start")),
            to: socket.peer
        )

        #expect(try renderPaneTapeFollowStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .brokenPipe)
    }

    private func record(_ kind: String) -> JSONValue {
        .object(["kind": .string(kind)])
    }

    private func notification(_ record: JSONValue) -> JsonRpcRequest {
        JsonRpcRequest(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("S1"),
                "record": record,
            ])
        )
    }
}

private struct DescriptorPair: @unchecked Sendable {
    let connection: Int32
    let peer: Int32
}

private struct DescriptorPipe: @unchecked Sendable {
    let read: Int32
    let write: Int32
}

private final class FollowCompletionProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<PaneTapeFollowTermination, Error>?

    func finish(_ termination: PaneTapeFollowTermination) {
        store(.success(termination))
    }

    func fail(_ error: Error) {
        store(.failure(error))
    }

    func wait() throws -> PaneTapeFollowTermination {
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            throw CocoaError(.coderReadCorrupt)
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }

    private func store(_ result: Result<PaneTapeFollowTermination, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }
}

private func descriptorPair() throws -> DescriptorPair {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPair(connection: descriptors[0], peer: descriptors[1])
}

private func descriptorPipe() throws -> DescriptorPipe {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPipe(read: descriptors[0], write: descriptors[1])
}

private func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    let data = try encodeIpcLine(value)
    try writeDescriptorData(data, to: descriptor)
}

private func encodedRecordLine(_ record: JSONValue) throws -> String {
    String(decoding: try encodeIpcLine(record).dropLast(), as: UTF8.self)
}

private func writeDescriptorData(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw POSIXError(.EIO) }
        offset += written
    }
}

private func readDescriptorLine(_ descriptor: Int32) throws -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&readiness, 1, 2_000)
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw CocoaError(.coderReadCorrupt) }
        let count = Darwin.read(descriptor, &byte, 1)
        if count < 0 && errno == EINTR { continue }
        if count == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
        guard count > 0 else { throw POSIXError(.EIO) }
        if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
}
