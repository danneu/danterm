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
        for reason in IpcConnectionRejectionReason.allCases {
            let listener = try TCPTestListener()
            let server = Thread {
                guard let connection = listener.accept() else { return }
                defer { Darwin.close(connection) }
                writeLine(encoded(reason.notification), to: connection)
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
            #expect(throws: clientError(for: reason)) {
                try session.handshake()
            }
            session.close()
            listener.close()
        }
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

private func helloLine() -> String {
    encoded(JsonRpcRequest(
        method: Methods.hello,
        params: .object([
            "protocol": .number(1),
            "app": .string("test"),
        ])
    ))
}

private func writeLine(_ line: String, to descriptor: Int32) {
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
}

private func encoded<T: Encodable>(_ value: T) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func clientError(for reason: IpcConnectionRejectionReason) -> DanTermClientError {
    switch reason {
    case .notAdmitted: .notAdmitted
    case .identityUnresolved: .identityUnresolved
    case .connectionLimit: .connectionLimit
    case .auditUnavailable: .auditUnavailable
    }
}
