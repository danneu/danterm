// Fixture and scripted LocalAPI coverage for turning a Tailscale peer address
// into stable caller facts without depending on a Tailscale installation.
import Darwin
import Foundation
import Testing

@testable import DanTermSupport

struct TailnetWhoisResolverTests {
    @Test("the recorded whois shape yields stable node, user, and machine facts")
    func recordedFixtureParses() throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "tailscale-whois",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: fixtureURL)

        let identity = try TailnetWhoisResolver.parse(data)

        #expect(identity == TailnetPeerIdentity(
            nodeId: "nYLVaWdKL811CNTRL",
            user: "owner@example.com",
            machineName: "iphone-13-mini.tail11347d.ts.net"
        ))
    }

    @Test("the resolver passes the accepted peer address to its injected query")
    func resolverUsesInjectedQuery() throws {
        let expected = TailnetPeerIdentity(nodeId: "node", user: "user", machineName: "machine")
        let resolver = TailnetWhoisResolver { address in
            #expect(address == "100.98.63.67:49152")
            return expected
        }

        #expect(try resolver.resolve(peerAddress: "100.98.63.67:49152") == expected)
    }

    @Test("missing stable identity fields fail closed")
    func missingFieldsAreRejected() {
        #expect(throws: TailnetWhoisResolver.Error.self) {
            try TailnetWhoisResolver.parse(Data("{\"Node\":{}}".utf8))
        }
    }

    @Test("LocalAPI whois sends the accepted address and resolves the response")
    func localAPISuccess() throws {
        let body = try recordedFixture()
        let server = try ScriptedLocalAPIServer(response: httpResponse(status: 200, body: body))
        defer { server.stop() }
        let resolver = TailnetWhoisResolver(socketPath: server.socketURL, timeout: 0.5)

        let identity = try resolver.resolve(peerAddress: "100.98.63.67:49152")

        #expect(identity == TailnetPeerIdentity(
            nodeId: "nYLVaWdKL811CNTRL",
            user: "owner@example.com",
            machineName: "iphone-13-mini.tail11347d.ts.net"
        ))
        let request = try #require(server.request)
        #expect(request.hasPrefix(
            "GET /localapi/v0/whois?addr=100.98.63.67:49152 HTTP/1.1\r\n"
        ))
        #expect(request.contains("\r\nHost: local-tailscaled.sock\r\n"))
    }

    @Test("a non-success LocalAPI status fails closed")
    func localAPINonSuccess() throws {
        let server = try ScriptedLocalAPIServer(response: httpResponse(status: 503, body: Data()))
        defer { server.stop() }
        let resolver = TailnetWhoisResolver(socketPath: server.socketURL, timeout: 0.5)

        #expect(throws: TailnetWhoisResolver.Error.httpStatus(503)) {
            try resolver.resolve(peerAddress: "100.98.63.67:49152")
        }
    }

    @Test("a missing LocalAPI socket fails closed")
    func localAPIMissingSocket() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-whois-missing-\(UUID().uuidString)")
        let resolver = TailnetWhoisResolver(
            socketPath: directory.appendingPathComponent("tailscaled.sock"),
            timeout: 0.05
        )

        #expect(throws: TailnetWhoisResolver.Error.connectionFailed(ENOENT)) {
            try resolver.resolve(peerAddress: "100.98.63.67:49152")
        }
    }

    @Test("an invalid LocalAPI body fails closed")
    func localAPIInvalidBody() throws {
        let server = try ScriptedLocalAPIServer(response: httpResponse(
            status: 200,
            body: Data("{\"Node\":{}}".utf8)
        ))
        defer { server.stop() }
        let resolver = TailnetWhoisResolver(socketPath: server.socketURL, timeout: 0.5)

        #expect(throws: TailnetWhoisResolver.Error.invalidOutput) {
            try resolver.resolve(peerAddress: "100.98.63.67:49152")
        }
    }

    @Test("an unresponsive LocalAPI server times out")
    func localAPITimeout() throws {
        let server = try ScriptedLocalAPIServer(response: nil)
        defer { server.stop() }
        let resolver = TailnetWhoisResolver(socketPath: server.socketURL, timeout: 0.05)

        #expect(throws: TailnetWhoisResolver.Error.timedOut) {
            try resolver.resolve(peerAddress: "100.98.63.67:49152")
        }
    }
}

private final class ScriptedLocalAPIServer: @unchecked Sendable {
    let socketURL: URL

    private let listener: ControlSocketListener
    private let response: Data?
    private let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRequest: String?

    var request: String? {
        lock.withLock { storedRequest }
    }

    init(response: Data?) throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-whois-\(UUID().uuidString)", isDirectory: true)
        socketURL = directory.appendingPathComponent("tailscaled.sock")
        listener = try ControlSocketListener.open(at: socketURL)
        self.response = response
        if response != nil {
            DispatchQueue(label: "danterm.tests.local-api-server").async { [self] in serve() }
            started.wait()
        }
    }

    func stop() {
        listener.close()
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    private func serve() {
        started.signal()
        let client = Darwin.accept(listener.fileDescriptor, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while bytes.suffix(4) != [13, 10, 13, 10] {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        lock.withLock { storedRequest = String(decoding: bytes, as: UTF8.self) }
        guard let response else { return }
        response.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    client,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

private func recordedFixture() throws -> Data {
    let fixtureURL = try #require(Bundle.module.url(
        forResource: "tailscale-whois",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: fixtureURL)
}

private func httpResponse(status: Int, body: Data) -> Data {
    var response = Data(
        "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.count)\r\n\r\n".utf8
    )
    response.append(body)
    return response
}
