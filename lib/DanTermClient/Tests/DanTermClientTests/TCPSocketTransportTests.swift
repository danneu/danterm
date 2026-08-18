// Behavioral coverage for the TCP client transport against an IPv4 loopback peer.
import Darwin
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

struct TCPSocketTransportTests {
    @Test("a dual-stack hostname reaches an IPv4-only listener and completes the handshake")
    func dualStackHostnameReachesIPv4Listener() throws {
        let listener = try TCPTestListener()
        defer { listener.close() }
        let server = Thread {
            guard let connection = listener.accept() else { return }
            defer { Darwin.close(connection) }
            writeLine(helloLine(), to: connection)
        }
        server.start()

        let transport = try TCPSocketTransport(
            host: "localhost",
            port: listener.port,
            connectTimeout: 1,
            receiveTimeout: 1,
            sendTimeout: 1
        )
        defer { transport.close() }

        let hello = try DanTermClientSession(transport: transport).handshake()
        #expect(hello.appVersion == "test")
    }

    @Test("every TCP connection rejection stays a typed session error")
    func connectionRejectionsStayTyped() throws {
        let advertised = try #require(IpcLivenessBound(seconds: 7))
        for reason in IpcConnectionRejectionReason.allCases {
            let listener = try TCPTestListener()
            let server = Thread {
                guard let connection = listener.accept() else { return }
                defer { Darwin.close(connection) }
                writeLine(encoded(reason.notification(livenessBound: advertised)), to: connection)
            }
            server.start()

            let transport = try TCPSocketTransport(
                host: "127.0.0.1",
                port: listener.port,
                connectTimeout: 1,
                receiveTimeout: 1,
                sendTimeout: 1
            )
            let session = DanTermClientSession(transport: transport)
            #expect(throws: clientError(for: reason, livenessBound: advertised)) {
                try session.handshake()
            }
            session.close()
            listener.close()
        }
    }

    @Test("concurrent session senders produce complete uninterleaved lines on loopback")
    func concurrentSendersProduceWholeLines() throws {
        // Intent: serialization protects real socket framing, not only a test double.
        // Why it exists: a split JSON line corrupts every request after the collision.
        // Scenario: 24 large requests race through one loopback session.
        let requestCount = 24
        let listener = try TCPTestListener()
        defer { listener.close() }
        let received = LockedResult<[JsonRpcRequest]>()
        let server = Thread {
            guard let connection = listener.accept() else {
                received.finish([])
                return
            }
            defer { Darwin.close(connection) }
            received.finish(readRequests(from: connection, count: requestCount))
        }
        server.start()

        let transport = try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 1,
            receiveTimeout: nil,
            sendTimeout: 2
        )
        let session = DanTermClientSession(transport: transport)
        let senders = DispatchGroup()
        for index in 0..<requestCount {
            senders.enter()
            Thread {
                defer { senders.leave() }
                let payload = String(repeating: String(index % 10), count: 16 * 1024)
                try? session.send(JsonRpcRequest(
                    id: .number(Double(index)),
                    method: "send-\(index)",
                    params: .object(["payload": .string(payload)])
                ))
            }.start()
        }
        senders.wait()
        session.cancel()

        let requests = received.wait()
        #expect(requests.count == requestCount)
        #expect(requests.compactMap { $0.id?.asNumber }.sorted()
            == (0..<requestCount).map(Double.init))
        #expect(requests.allSatisfy { request in
            guard let index = Int(request.method.split(separator: "-").last ?? "") else {
                return false
            }
            return request.params?["payload"]?.asString
                == String(repeating: String(index % 10), count: 16 * 1024)
        })
    }

    @Test("cancelling a loopback session wakes a blocked reader without a frame")
    func cancellationWakesLoopbackReader() throws {
        // Intent: socket shutdown wakes a real blocked read before cancellation returns.
        // Why it exists: backgrounding cannot wait for a quiet pane to emit another byte.
        // Scenario: a loopback peer accepts the connection and deliberately sends nothing.
        let listener = try TCPTestListener()
        defer { listener.close() }
        let accepted = LockedSignal()
        let serverFinished = LockedSignal()
        let server = Thread {
            guard let connection = listener.accept() else {
                serverFinished.signal()
                return
            }
            accepted.signal()
            var byte: UInt8 = 0
            _ = Darwin.read(connection, &byte, 1)
            Darwin.close(connection)
            serverFinished.signal()
        }
        server.start()

        let session = DanTermClientSession(transport: try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 1,
            receiveTimeout: nil,
            sendTimeout: 1
        ))
        accepted.wait()
        let readerStarted = LockedSignal()
        let readerResult = LockedResult<Result<DanTermClientFrame?, Error>>()
        Thread {
            readerStarted.signal()
            readerResult.finish(Result { try session.nextFrame() })
        }.start()
        readerStarted.wait()

        session.cancel()
        session.cancel()

        switch readerResult.wait() {
        case .success(let frame):
            #expect(frame == nil)
        case .failure(let error):
            Issue.record("Cancellation returned an error: \(error)")
        }
        serverFinished.wait()
    }
}

/// Moves a value from a server thread to its test without a timing delay.
private final class LockedResult<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    func finish(_ value: Value) {
        condition.lock()
        self.value = value
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Value {
        condition.lock()
        while value == nil { condition.wait() }
        let result = value!
        condition.unlock()
        return result
    }
}

/// Coordinates a test thread with a real socket operation without a timing delay.
private final class LockedSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var signalled = false

    func signal() {
        condition.lock()
        signalled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while signalled == false { condition.wait() }
        condition.unlock()
    }
}

private final class TCPTestListener: @unchecked Sendable {
    private var descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        var selected = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &selected) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        descriptor = fd
        port = UInt16(bigEndian: selected.sin_port)
    }

    func accept() -> Int32? {
        let accepted = Darwin.accept(descriptor, nil, nil)
        return accepted >= 0 ? accepted : nil
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

/// Mirrors the server's real hello, silence bound included: a TCP stream lives under the
/// liveness contract, and a hello that states no bound is not one this client can serve.
private func helloLine() -> String {
    encoded(JsonRpcRequest(
        method: Methods.hello,
        params: IpcHello.params(
            protocolVersion: danTermIpcProtocolVersion,
            appVersion: "test",
            livenessBound: .standard
        )
    ))
}

private func writeLine(_ line: String, to descriptor: Int32) {
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
}

private func readRequests(from descriptor: Int32, count: Int) -> [JsonRpcRequest] {
    var framer = IpcLineFramer()
    var requests: [JsonRpcRequest] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while requests.count < count {
        let readCount = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        guard readCount > 0 else { break }
        for event in framer.append(Data(buffer[0..<readCount])) {
            guard case .line(let line) = event,
                  let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: line)
            else { continue }
            requests.append(request)
        }
    }
    return requests
}

private func encoded<T: Encodable>(_ value: T) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func clientError(
    for reason: IpcConnectionRejectionReason,
    livenessBound: IpcLivenessBound
) -> DanTermClientError {
    switch reason {
    case .notAdmitted: .notAdmitted
    case .identityUnresolved: .identityUnresolved
    case .connectionLimit: .connectionLimit(livenessBound)
    case .auditUnavailable: .auditUnavailable
    }
}
