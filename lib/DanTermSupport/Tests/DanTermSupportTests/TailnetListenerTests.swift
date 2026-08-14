// Integration coverage for the tailnet TCP listener and accepted peer capture.
import Darwin
import Testing

@testable import DanTermSupport

struct TailnetListenerTests {
    @Test("a listener accepts a connection and reports its peer address")
    func listenerAcceptsAndCapturesPeer() throws {
        let bind = TailnetBindAddress(
            address: "127.0.0.1",
            port: 0,
            interfaceName: "lo0"
        )
        let listener = try TailnetListener.open(on: bind)
        defer { listener.close() }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { Darwin.close(client) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = listener.port.bigEndian
        try #require(inet_pton(AF_INET, "127.0.0.1", &destination.sin_addr) == 1)
        let connected = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0)

        let accepted = try acceptTailnetPeer(on: listener.fileDescriptor)
        defer { Darwin.close(accepted.fileDescriptor) }

        #expect(accepted.peer.host == "127.0.0.1")
        #expect(accepted.peer.port > 0)
    }

    @Test("closing the listener is idempotent")
    func repeatedCloseIsSafe() throws {
        let listener = try TailnetListener.open(on: TailnetBindAddress(
            address: "127.0.0.1",
            port: 0,
            interfaceName: "lo0"
        ))

        listener.close()
        listener.close()
    }
}
