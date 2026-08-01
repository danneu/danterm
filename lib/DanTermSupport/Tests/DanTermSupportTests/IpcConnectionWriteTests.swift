// Socket-level coverage for ordered notification writes and their completion signal.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

struct IpcConnectionWriteTests {
    @Test("real socket stream orders start, notifications, end, and close")
    func realSocketStreamOrdersEveryFrame() throws {
        // Intent: production framing flushes the start reply before ordered stream records,
        //   then flushes the end record before closing the socket.
        // Why it exists: unit tests of record construction and socket writes cannot catch a
        //   missing or reordered handoff between those seams.
        // Scenario: a local client follows one pane through an event, a gap, and pane close.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let requestId = UUID()
        let closed = ConnectionCloseProbe()
        defer { Darwin.close(descriptors.peer) }

        connection.writeHello(appVersion: "test")
        connection.startReading(
            onRequest: { request, connection in
                connection.rememberRequest(reqId: requestId, rpcId: request.id)
                connection.writeSuccess(
                    reqId: requestId,
                    result: .object(["kind": .string("start")])
                ) { succeeded in
                    guard succeeded else { return }
                    for record in [
                        JSONValue.object(["kind": .string("event"), "sequence": .number(1)]),
                        .object(["kind": .string("gap"), "droppedEventCount": .number(2)]),
                    ] {
                        connection.writeNotification(
                            method: Methods.paneTapeEvent,
                            params: .object([
                                "subscription": .string("S1"),
                                "record": record,
                            ])
                        )
                    }
                    connection.writeNotification(
                        method: Methods.paneTapeEvent,
                        params: .object([
                            "subscription": .string("S1"),
                            "record": .object([
                                "kind": .string("end"),
                                "reason": .string("pane-closed"),
                            ]),
                        ]),
                        closeAfterWrite: true
                    )
                }
            },
            onClose: { connection in closed.record(connection.id) }
        )

        let hello = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(hello.method == Methods.hello)
        try writeIpcLine(
            JsonRpcRequest(id: .string("R1"), method: Methods.paneTape),
            to: descriptors.peer
        )

        let start = try JSONDecoder().decode(
            JsonRpcResponse.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(start.id == .string("R1"))
        #expect(start.result?["kind"] == .string("start"))

        var kinds: [String] = []
        for _ in 0..<3 {
            let notification = try JSONDecoder().decode(
                JsonRpcRequest.self,
                from: readIpcLine(from: descriptors.peer)
            )
            #expect(notification.id == nil)
            #expect(notification.method == Methods.paneTapeEvent)
            kinds.append(notification.params?["record"]?["kind"]?.asString ?? "")
        }
        #expect(kinds == ["event", "gap", "end"])
        #expect(readByte(from: descriptors.peer) == 0)
        #expect(closed.wait() == connection.id)
    }

    @Test("client disconnect reaches the production close callback")
    func clientDisconnectReportsConnectionClose() throws {
        // Intent: EOF from a client reaches the callback that removes owned subscriptions.
        // Why it exists: without the callback, every disconnected follow leaks polling work.
        // Scenario: an agent interrupts a live follow while the app keeps running.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = ConnectionCloseProbe()
        connection.startReading(
            onRequest: { _, _ in },
            onClose: { connection in closed.record(connection.id) }
        )

        Darwin.close(descriptors.peer)
        #expect(closed.wait() == connection.id)
    }

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

    private func writeIpcLine<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let line = try encodeIpcLine(value)
        let succeeded = line.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var written = 0
            while written < line.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    line.count - written
                )
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
        guard succeeded else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readByte(from descriptor: Int32) -> Int {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1)
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

private final class ConnectionCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var connectionId: UUID?

    func record(_ connectionId: UUID) {
        lock.lock()
        self.connectionId = connectionId
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> UUID? {
        guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return connectionId
    }
}
