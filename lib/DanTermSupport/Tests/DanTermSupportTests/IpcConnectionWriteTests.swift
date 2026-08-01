// Socket-level coverage for ordered notification writes and their completion signal.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

struct IpcConnectionWriteTests {
    @Test("notification completion reports a fully flushed JSON-RPC line")
    func notificationCompletionReportsFlush() throws {
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let completion = WriteCompletionProbe()
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: .object(["subscription": .string("S1")]),
            completion: { succeeded in completion.record(succeeded) }
        )

        let line = try readIpcLine(from: descriptors.peer)
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.id == nil)
        #expect(request.method == Methods.paneTapeEvent)
        #expect(request.params?["subscription"] == .string("S1"))
        #expect(completion.wait() == true)
    }

    @Test("notification completion reports a failed socket write")
    func notificationCompletionReportsFailure() throws {
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let completion = WriteCompletionProbe()
        Darwin.close(descriptors.peer)
        defer { connection.close() }

        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: .object([:]),
            completion: { succeeded in completion.record(succeeded) }
        )

        #expect(completion.wait() == false)
    }

    private func socketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func readIpcLine(from descriptor: Int32) throws -> Data {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if byte == 0x0A { return Data(bytes) }
            bytes.append(byte)
        }
    }
}

private final class WriteCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var succeeded: Bool?

    func record(_ succeeded: Bool) {
        lock.lock()
        self.succeeded = succeeded
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Bool? {
        guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}
