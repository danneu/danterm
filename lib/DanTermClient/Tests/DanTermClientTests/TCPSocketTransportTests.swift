// Behavioral coverage for the TCP client transport against an IPv4 loopback peer.
import Darwin
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

struct TCPSocketTransportTests {
    // Intent: a connect attempt can use the caller's full deadline.
    // Why it exists: a per-address cap silently shortened every literal-IP deadline.
    // Scenario: unaccepted clients fill a loopback listener's accept queue, so the next
    // connection remains pending until the transport's three-second deadline.
    @Test("a pending TCP connect honors the caller's full deadline", .timeLimit(.minutes(1)))
    func pendingConnectHonorsFullDeadline() throws {
        let listener = try TCPTestListener(backlog: 0)
        defer { listener.close() }
        let queuedClients = try listener.fillAcceptQueue()
        defer { queuedClients.forEach { Darwin.close($0) } }

        let connectTimeout: TimeInterval = 3
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try TCPSocketTransport(
                host: "127.0.0.1",
                port: listener.port,
                connectTimeout: connectTimeout,
                receiveTimeout: 1,
                sendTimeout: 1
            )
            Issue.record("Expected the full accept queue to keep the connection pending")
        } catch TCPSocketTransportError.connectTimedOut {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            #expect(elapsed >= connectTimeout)
        } catch {
            Issue.record("Expected connectTimedOut, got \(error)")
        }
    }

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

    // Intent: an address literal resolves with name resolution disabled, while a
    // hostname resolves with it enabled.
    // Why it exists: on an IPv6-only NAT64 network Darwin's resolver replaces an IPv4
    // literal with a carrier NAT64 IPv6 address and returns only that, dropping the
    // address the caller asked for (libinfo `si_getaddrinfo.c`, `_gai_nat64_synthesis`).
    // A tailnet address rewritten that way leaves over the carrier instead of the
    // tunnel and reaches nothing. AI_NUMERICHOST is that path's first guard.
    // Scenario: the iOS client connecting to 100.106.152.106:7420 over 5G on
    // 2026-08-24. Every attempt reported "Server unreachable" and no SYN ever arrived
    // on the Mac's tunnel interface, while the same host reached by its MagicDNS name
    // connected at once.
    @Test("an address literal resolves without name resolution, a hostname with it")
    func addressLiteralsBypassNameResolution() {
        #expect(TCPSocketTransport.resolutionFlags(for: "100.106.152.106") == AI_NUMERICHOST)
        #expect(TCPSocketTransport.resolutionFlags(for: "fd7a:115c:a1e0::1401:98ad") == AI_NUMERICHOST)
        #expect(TCPSocketTransport.resolutionFlags(for: "macbook.tail11347d.ts.net") == 0)
        #expect(TCPSocketTransport.resolutionFlags(for: "localhost") == 0)
        // Darwin treats "10.1" as numeric via inet_aton, but the NAT64 synthesis path
        // gates on strict inet_pton, so the shorthand never needs the flag.
        #expect(TCPSocketTransport.resolutionFlags(for: "10.1") == 0)
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

/// A loopback listener the transport suites share: `SharedStreamBodyTests` needs the same
/// accepted peer descriptor to drive the shared stream body over TCP.
final class TCPTestListener: @unchecked Sendable {
    private var descriptor: Int32
    let port: UInt16

    init(backlog: Int32 = 1) throws {
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
        guard bound == 0, Darwin.listen(fd, backlog) == 0 else {
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

    func fillAcceptQueue() throws -> [Int32] {
        var clients: [Int32] = []
        do {
            for _ in 0...(Int(SOMAXCONN) + 1) {
                let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
                clients.append(fd)
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(.EINVAL)
                }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 || errno == EINPROGRESS else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                }
                if connected == 0 { continue }

                var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // This one-second probe is meant to expire when the accept queue is full.
                let polled = Darwin.poll(&event, 1, 1_000)
                if polled == 0 { return clients }
                guard polled > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                }
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                      socketError == 0
                else {
                    throw POSIXError(POSIXErrorCode(rawValue: socketError) ?? .EINVAL)
                }
            }
            throw POSIXError(.ENOBUFS)
        } catch {
            clients.forEach { Darwin.close($0) }
            throw error
        }
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
