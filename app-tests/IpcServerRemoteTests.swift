// App-level integration coverage for tailnet admission, capacity, and audit gates.
import Darwin
import DanTermProtocol
import Foundation
import Synchronization
import Testing
@testable import DanTerm

/// How long a waiter in this file sits before it declares the server hung.
///
/// This is a hang guard, not a threshold: no assertion here turns on how fast the server
/// answers, so the only requirement is that a passing run cannot approach it and that it
/// fires before the suite's time-limit backstop, so the failure names the waiter.
private let hangGuardSeconds = 30.0

/// How long a probe that expects silence waits before it calls the attempt a miss.
///
/// Unlike the hang guard, this one is meant to expire: `connectWhenSlotReleases` learns
/// that the slot is still held by not being greeted, and retries. Keep it short so the
/// retry loop turns over, and keep it far below the hang guard so the two never blur.
private let silenceProbeSeconds = 0.5

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct IpcServerRemoteTests {
    @Test("tailnet service is closed by default")
    func absentConfigOpensOnlyLocalSocket() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let server = try IpcServer(
            socketPath: fixture.socketURL,
            auditWriter: fixture.auditWriter,
            runtime: nil
        )
        defer { server.stop() }

        await server.start()
        #expect(server.tailnetPort == nil)
        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        #expect(try await local.readRequest().method == Methods.hello)
    }

    @Test("invalid bind config fails soft and records the listener failure")
    func invalidBindKeepsLocalSocketAlive() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let server = try IpcServer(
            socketPath: fixture.socketURL,
            tailnetConfig: DanTermTailnetConfig(
                listen: "0.0.0.0:24863",
                admittedNodeIds: ["node-phone"]
            ),
            auditWriter: fixture.auditWriter,
            runtime: nil
        )
        defer { server.stop() }

        await server.start()
        #expect(server.tailnetPort == nil)
        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        #expect(try await local.readRequest().method == Methods.hello)
        #expect(try fixture.auditEntries().contains { $0.event.kind == .listenerFailed })
    }

    @Test("a tailnet bind collision fails soft and records the listener failure")
    func occupiedPortKeepsLocalSocketAlive() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let occupied = try TailnetListener.open(on: TailnetBindAddress(
            address: "127.0.0.1",
            port: 0,
            interfaceName: "lo0"
        ))
        defer { occupied.close() }
        let server = try IpcServer(
            socketPath: fixture.socketURL,
            tailnetConfig: DanTermTailnetConfig(
                listen: "100.99.4.1:24863",
                admittedNodeIds: ["node-phone"]
            ),
            auditWriter: fixture.auditWriter,
            resolveTailnetBindAddress: { _ in
                TailnetBindAddress(
                    address: "127.0.0.1",
                    port: occupied.port,
                    interfaceName: "lo0"
                )
            },
            runtime: nil
        )
        defer { server.stop() }

        await server.start()
        #expect(server.tailnetPort == nil)
        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        #expect(try await local.readRequest().method == Methods.hello)
        #expect(try fixture.auditEntries().contains { $0.event.kind == .listenerFailed })
    }

    @Test("an unavailable audit sink prevents tailnet service but not local IPC")
    func unwritableAuditSinkFailsSoft() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        try fixture.breakAuditSink()
        let server = try fixture.makeServer(runtime: nil)
        defer { server.stop() }

        await server.start()
        #expect(server.tailnetPort == nil)
        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        #expect(try await local.readRequest().method == Methods.hello)
    }

    @Test("an admitted tailnet peer receives hello and can dispatch ls")
    func admittedPeerIsServiced() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(runtime: runtime)
        defer { server.stop() }

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }

        let hello = try await peer.readRequest()
        #expect(hello.method == Methods.hello)
        try peer.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(7))
        let response = try await peer.readResponse()
        #expect(response.id == .number(7))
        #expect(response.error == nil)
    }

    @Test("hello advertises the server's silence bound and ping is served through dispatch")
    func helloAdvertisesBoundAndPingIsServed() async throws {
        // Intent: the number both ends apply is stated once, by the server, in the
        //   hello it already sends first -- and a ping is answered by the same
        //   dispatch path that answers `ls`.
        // Why it exists: PO8 and I3. A client that derived the bound from its own
        //   constant could disagree with the server about one connection, and a ping
        //   answered below dispatch would report a starved Mac as alive.
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(
            runtime: runtime,
            livenessBound: try #require(IpcLivenessBound(seconds: 6))
        )
        defer { server.stop() }

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }

        let hello = try await peer.readRequest()
        #expect(hello.method == Methods.hello)
        #expect(IpcHello.livenessBound(from: hello.params) == IpcLivenessBound(seconds: 6))

        try peer.writeRequest(method: IpcRequestMethod.ping.rawValue, id: .number(11))
        let pong = try await peer.readResponse()
        #expect(pong.id == .number(11))
        #expect(pong.error == nil)

        // The pong proves dispatch ran, so any request record for it would already be
        // on disk. A ping every half-bound would evict the events the log exists for.
        let kinds = try fixture.auditEntries().map(\.event.kind)
        #expect(kinds.contains(.requestStarted) == false)
        #expect(kinds.contains(.requestCompleted) == false)
    }

    @Test("a silent remote peer is reclaimed at the bound and gives its slot back")
    func silentRemotePeerReleasesItsSlot() async throws {
        // Intent: a remote connection that stops sending is closed within the bound, the
        //   close names the liveness reason, and the freed slot admits the next peer.
        // Why it exists: measured on hardware, a phone in airplane mode holds the socket
        //   ESTABLISHED with no audit event and no slot returned. A phone that never
        //   comes back -- flat battery, out of range overnight -- leaked that slot for
        //   good, against a cap the app cannot raise its way out of.
        // Scenario: the connection cap is one, and its holder goes quiet forever.
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let server = try fixture.makeServer(
            runtime: nil,
            remoteConnectionLimit: 1,
            livenessBound: try #require(IpcLivenessBound(seconds: 0.5))
        )
        defer { server.stop() }

        await server.start()
        let port = try #require(server.tailnetPort)
        let silent = try RemotePeer(port: port)
        defer { silent.close() }
        #expect(try await silent.readRequest().method == Methods.hello)

        let excess = try RemotePeer(port: port)
        defer { excess.close() }
        #expect(try await excess.readRequest() == IpcConnectionRejectionReason.connectionLimit.notification)

        let entries = try await fixture.auditEntriesWhenConnectionCloses()
        let closed = try #require(entries.last { $0.event.kind == .connectionClosed })
        #expect(closed.event.reason == "peer-silent")
        #expect(closed.event.servedRequests == 0)

        let replacement = try await fixture.connectWhenSlotReleases(port: port)
        replacement.close()
    }

    @Test("a local connection idles past the remote bound and is still served")
    func localConnectionIsExemptFromTheBound() async throws {
        // Intent: the silence bound governs remote connections only.
        // Why it exists: a local caller cannot die without its socket closing, and a CLI
        //   pane follow legitimately waits hours for the next byte of output. Reclaiming
        //   it would break a working feature to solve a problem it does not have.
        // Scenario: an agent follows a quiet pane over the local control socket.
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(
            runtime: runtime,
            livenessBound: try #require(IpcLivenessBound(seconds: 0.4))
        )
        defer { server.stop() }

        await server.start()
        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        #expect(try await local.readRequest().method == Methods.hello)

        try await Task.sleep(for: .seconds(1.2))
        try local.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(3))
        let response = try await local.readResponse()
        #expect(response.id == .number(3))
        #expect(response.error == nil)
    }

    @Test("close records tell a served connection from one that only pinged or never talked")
    func closeAccountingSeparatesServedFromSilentConnections() async throws {
        // Intent: the audit log can reconstruct, for a connection that has ended, whether
        //   it was served real requests, only kept itself alive, or was admitted and then
        //   never read.
        // Why it exists: the log recorded an admitted connection and nothing more, so a
        //   Mac too starved to read a request looked exactly like one doing the work.
        //   Heartbeats deliberately earn no record of their own, so without close-time
        //   accounting the pinging connection would look starved too.
        // Scenario: three phones connect -- one works, one sits idle keeping its
        //   connection, one connects and leaves.
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(runtime: runtime)
        defer { server.stop() }

        await server.start()
        let port = try #require(server.tailnetPort)

        let working = try RemotePeer(port: port)
        _ = try await working.readRequest()
        try working.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(1))
        #expect(try await working.readResponse().error == nil)
        working.close()
        _ = try await fixture.auditEntriesWhenConnectionCloses(count: 1)

        let idle = try RemotePeer(port: port)
        _ = try await idle.readRequest()
        try idle.writeRequest(method: IpcRequestMethod.ping.rawValue, id: .number(2))
        #expect(try await idle.readResponse().error == nil)
        idle.close()
        _ = try await fixture.auditEntriesWhenConnectionCloses(count: 2)

        let mute = try RemotePeer(port: port)
        _ = try await mute.readRequest()
        mute.close()
        let entries = try await fixture.auditEntriesWhenConnectionCloses(count: 3)

        let closes = entries.filter { $0.event.kind == .connectionClosed }
        #expect(closes.map(\.event.servedRequests) == [1, 1, 0])
        #expect(closes.allSatisfy { $0.event.reason == "peer-closed" })
        // One durable request record in total: the worked connection's. So the first two
        // closes are told apart by the log, not by their accounting alone.
        #expect(entries.count(where: { $0.event.kind == .requestStarted }) == 1)
        #expect(entries.count(where: { $0.event.kind == .requestCompleted }) == 1)
    }

    @Test("remote identity resolution receives the accepted source address")
    func resolverReceivesPeerAddress() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let observedAddresses = Mutex<[String]>([])
        let resolver = TailnetWhoisResolver { address in
            observedAddresses.withLock { $0.append(address) }
            return TailnetPeerIdentity(
                nodeId: "node-phone",
                user: "dan@example.com",
                machineName: "iphone"
            )
        }
        let server = try fixture.makeServer(runtime: nil, whoisResolver: resolver)
        defer { server.stop() }

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }
        _ = try await peer.readRequest()

        let address = try #require(observedAddresses.withLock { $0.first })
        #expect(address.hasPrefix("127.0.0.1:"))
        #expect(UInt16(address.split(separator: ":").last ?? "") != nil)
    }

    @Test("remote admission distinguishes unknown and unresolved identities", arguments: [
        RemoteAdmissionCase.unknown,
        RemoteAdmissionCase.unresolved,
    ])
    func refusedPeerGetsReason(_ admissionCase: RemoteAdmissionCase) async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let resolver: TailnetWhoisResolver
        let expected: IpcConnectionRejectionReason
        switch admissionCase {
        case .unknown:
            resolver = TailnetWhoisResolver { _ in
                TailnetPeerIdentity(nodeId: "node-stranger", user: "other@example.com", machineName: "other")
            }
            expected = .notAdmitted
        case .unresolved:
            resolver = TailnetWhoisResolver { _ in throw TailnetWhoisResolver.Error.invalidOutput }
            expected = .identityUnresolved
        }
        let server = try fixture.makeServer(runtime: nil, whoisResolver: resolver)
        defer { server.stop() }

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }

        let rejection = try await peer.readRequest()
        #expect(rejection == expected.notification)
        #expect(try await peer.readByte() == 0)
    }

    @Test("the accept-boundary cap refuses excess peers and releases on close")
    func connectionCapBoundsRemotePeers() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let server = try fixture.makeServer(runtime: nil, remoteConnectionLimit: 1)
        defer { server.stop() }

        await server.start()
        let first = try RemotePeer(port: try #require(server.tailnetPort))
        _ = try await first.readRequest()
        let excess = try RemotePeer(port: try #require(server.tailnetPort))
        defer { excess.close() }
        #expect(try await excess.readRequest() == IpcConnectionRejectionReason.connectionLimit.notification)
        first.close()

        let replacement = try await fixture.connectWhenSlotReleases(port: try #require(server.tailnetPort))
        replacement.close()
    }

    @Test("the cap rejects a burst while admitted identity resolution is stalled")
    func connectionCapPrecedesAdmissionWork() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let resolverStarted = DispatchSemaphore(value: 0)
        let releaseResolver = DispatchSemaphore(value: 0)
        let resolver = TailnetWhoisResolver { _ in
            resolverStarted.signal()
            releaseResolver.wait()
            return TailnetPeerIdentity(
                nodeId: "node-phone",
                user: "dan@example.com",
                machineName: "iphone"
            )
        }
        let server = try fixture.makeServer(
            runtime: nil,
            whoisResolver: resolver,
            remoteConnectionLimit: 1
        )
        defer { server.stop() }

        await server.start()
        let first = try RemotePeer(port: try #require(server.tailnetPort))
        defer { first.close() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                resolverStarted.wait()
                continuation.resume()
            }
        }
        let excess = try RemotePeer(port: try #require(server.tailnetPort))
        defer { excess.close() }

        #expect(try await excess.readRequest() == IpcConnectionRejectionReason.connectionLimit.notification)
        releaseResolver.signal()
        #expect(try await first.readRequest().method == Methods.hello)
    }

    @Test("shutdown prevents stalled admission from starting service")
    func shutdownWinsAgainstPendingAdmission() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let resolverStarted = DispatchSemaphore(value: 0)
        let releaseResolver = DispatchSemaphore(value: 0)
        let resolver = TailnetWhoisResolver { _ in
            resolverStarted.signal()
            releaseResolver.wait()
            return TailnetPeerIdentity(
                nodeId: "node-phone",
                user: "dan@example.com",
                machineName: "iphone"
            )
        }
        let server = try fixture.makeServer(runtime: nil, whoisResolver: resolver)

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                resolverStarted.wait()
                continuation.resume()
            }
        }
        server.stop()
        releaseResolver.signal()

        #expect(try await peer.readByte() == 0)
    }

    @Test("server shutdown records serviced connection closure")
    func shutdownAuditsConnectionClose() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let server = try fixture.makeServer(runtime: nil)

        await server.start()
        let peer = try RemotePeer(port: try #require(server.tailnetPort))
        defer { peer.close() }
        _ = try await peer.readRequest()
        server.stop()

        #expect(try await peer.readByte() == 0)
        let entries = try await fixture.auditEntriesWhenConnectionCloses()
        #expect(entries.last?.event.kind == .connectionClosed)
        // The peer was there the whole time, so blaming it would misread the log.
        #expect(entries.last?.event.reason == "server-stopped")
    }

    @Test("remote request audit failure blocks only that connection and retries on the next request")
    func requestAuditGateFailsClosedAndRecovers() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(runtime: runtime)
        defer { server.stop() }

        await server.start()
        let first = try RemotePeer(port: try #require(server.tailnetPort))
        let second = try RemotePeer(port: try #require(server.tailnetPort))
        defer {
            first.close()
            second.close()
        }
        _ = try await first.readRequest()
        _ = try await second.readRequest()
        try fixture.breakAuditSink()

        try first.writeRequest(
            method: IpcRequestMethod.groupNew.rawValue,
            id: .number(1),
            params: .object(["name": .string("must-not-run")])
        )
        let failure = try await first.readResponse()
        #expect(failure.error == IpcRequestErrors.auditUnavailable)
        #expect(try await first.readByte() == 0)
        #expect(runtime.model.groups.count == 1)

        let local = try RemotePeer(socketPath: fixture.socketURL)
        defer { local.close() }
        _ = try await local.readRequest()
        try local.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(9))
        #expect(try await local.readResponse().error == nil)

        try fixture.restoreAuditSink()
        try second.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(2))
        let success = try await second.readResponse()
        #expect(success.id == .number(2))
        #expect(success.error == nil)

        let kinds = try fixture.auditEntries().map(\.event.kind)
        let startedIndex = try #require(kinds.lastIndex(of: .requestStarted))
        let completedIndex = try #require(kinds.lastIndex(of: .requestCompleted))
        #expect(startedIndex < completedIndex)
    }

    @Test("the app audit path records local, remote, malformed, dropped, and close events")
    func completeAuditSequence() async throws {
        let fixture = try RemoteIpcServerFixture()
        defer { fixture.remove() }
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts())
        defer { runtime.shutdown() }
        let server = try fixture.makeServer(runtime: runtime)
        defer { server.stop() }

        await server.start()
        let local = try RemotePeer(socketPath: fixture.socketURL)
        let remote = try RemotePeer(port: try #require(server.tailnetPort))
        defer {
            local.close()
            remote.close()
        }
        _ = try await local.readRequest()
        _ = try await remote.readRequest()

        try local.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(1))
        _ = try await local.readResponse()
        try remote.writeRequest(method: IpcRequestMethod.ls.rawValue, id: .number(2))
        _ = try await remote.readResponse()
        try remote.writeRequest(method: IpcRequestMethod.quit.rawValue, id: .number(3))
        #expect(try await remote.readResponse().error != nil)
        try remote.writeRequest(method: "unknown.method", id: .number(4))
        #expect(try await remote.readResponse().error != nil)
        try remote.writeRawLine(#"{"jsonrpc":2,"id":5,"method":"pane.read","params":{}}"#)
        #expect(try await remote.readResponse().error?.code == -32700)
        try remote.writeRequest(method: IpcRequestMethod.ls.rawValue, id: nil)
        remote.close()

        let entries = try await fixture.auditEntriesWhenConnectionCloses()
        let kinds = entries.map(\.event.kind)
        #expect(kinds == [
            .connectionOpened,
            .connectionOpened,
            .localRequest,
            .requestStarted,
            .requestCompleted,
            .requestStarted,
            .requestCompleted,
            .requestDecodeFailed,
            .requestDecodeFailed,
            .requestDropped,
            .connectionClosed,
        ])
        let remoteStarted = try #require(entries.firstIndex {
            $0.event.kind == .requestStarted && $0.event.caller?.kind == .remote
        })
        let remoteCompleted = try #require(entries.firstIndex {
            $0.event.kind == .requestCompleted && $0.event.caller?.kind == .remote
        })
        #expect(remoteStarted < remoteCompleted)
        let localEntry = try #require(entries.first { $0.event.kind == .localRequest })
        #expect(localEntry.event.caller?.kind == .local)
    }
}

enum RemoteAdmissionCase: Sendable {
    case unknown
    case unresolved
}

private struct RemoteIpcServerFixture {
    let directory: URL
    let socketURL: URL
    let auditDirectory: URL
    let auditWriter: IpcAuditLogWriter

    init() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("danterm-remote-ipc-\(UUID().uuidString)", isDirectory: true)
        socketURL = directory.appendingPathComponent("control.sock")
        auditDirectory = directory.appendingPathComponent("audit", isDirectory: true)
        auditWriter = IpcAuditLogWriter(directory: auditDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeServer(
        runtime: AppRuntime?,
        whoisResolver: TailnetWhoisResolver = TailnetWhoisResolver { _ in
            TailnetPeerIdentity(nodeId: "node-phone", user: "dan@example.com", machineName: "iphone")
        },
        remoteConnectionLimit: Int = 4,
        livenessBound: IpcLivenessBound = .standard
    ) throws -> IpcServer {
        try IpcServer(
            socketPath: socketURL,
            appVersion: "test",
            livenessBound: livenessBound,
            tailnetConfig: DanTermTailnetConfig(
                listen: "100.99.4.1:24863",
                admittedNodeIds: ["node-phone"]
            ),
            auditWriter: auditWriter,
            whoisResolver: whoisResolver,
            remoteConnectionLimit: remoteConnectionLimit,
            resolveTailnetBindAddress: { _ in
                TailnetBindAddress(address: "127.0.0.1", port: 0, interfaceName: "lo0")
            },
            runtime: runtime
        )
    }

    func breakAuditSink() throws {
        try? FileManager.default.removeItem(at: auditDirectory)
        try Data("blocked".utf8).write(to: auditDirectory)
    }

    func restoreAuditSink() throws {
        try FileManager.default.removeItem(at: auditDirectory)
        try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: true)
    }

    func auditEntries() throws -> [IpcAuditLogEntry] {
        let data = try Data(contentsOf: auditWriter.logURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map {
            try decoder.decode(IpcAuditLogEntry.self, from: Data($0))
        }
    }

    func auditEntriesWhenConnectionCloses(
        count: Int = 1
    ) async throws -> [IpcAuditLogEntry] {
        let deadline = ContinuousClock.now + .seconds(hangGuardSeconds)
        while ContinuousClock.now < deadline {
            if let entries = try? auditEntries(),
               entries.count(where: { $0.event.kind == .connectionClosed }) >= count
            {
                return entries
            }
            await Task.yield()
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func connectWhenSlotReleases(port: UInt16) async throws -> RemotePeer {
        let deadline = ContinuousClock.now + .seconds(hangGuardSeconds)
        while ContinuousClock.now < deadline {
            // A short receive timeout is the probe: an ungreeted peer is how this learns
            // the slot is still held, so this read is meant to expire and be retried.
            let peer = try RemotePeer(port: port, receiveTimeout: silenceProbeSeconds)
            if let first = try? await peer.readRequest(), first.method == Methods.hello {
                return peer
            }
            peer.close()
            await Task.yield()
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Arms the socket's receive deadline, so no read in this file can park a thread for good.
private func setReceiveTimeout(_ fileDescriptor: Int32, _ seconds: Double) {
    var timeout = timeval(
        tv_sec: Int(seconds),
        tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
    )
    setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
}

/// Turns the errno of a failed read into an error, naming a receive-deadline expiry as one.
///
/// `SO_RCVTIMEO` reports its expiry as `EAGAIN`, which reads as "try again on a
/// non-blocking socket" and hides that the peer simply never spoke.
private func readFailure(errno code: Int32) -> POSIXError {
    if code == EAGAIN || code == EWOULDBLOCK { return POSIXError(.ETIMEDOUT) }
    return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private final class RemotePeer: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let closeLock = NSLock()
    private var isClosed = false

    init(port: UInt16, receiveTimeout: Double = hangGuardSeconds) throws {
        fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.EIO) }
        setReceiveTimeout(fileDescriptor, receiveTimeout)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    init(socketPath: URL, receiveTimeout: Double = hangGuardSeconds) throws {
        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.EIO) }
        setReceiveTimeout(fileDescriptor, receiveTimeout)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.path.utf8.count < maximumLength else { throw CocoaError(.fileWriteInvalidFileName) }
        socketPath.path.withCString { source in
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
            Darwin.close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func writeRequest(
        method: String,
        id: JSONValue?,
        params: JSONValue = .object([:])
    ) throws {
        let data = try encodeIpcLine(JsonRpcRequest(id: id, method: method, params: params))
        try write(data)
    }

    func writeRawLine(_ source: String) throws {
        try write(Data((source + "\n").utf8))
    }

    private func write(_ data: Data) throws {
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        guard count == data.count else { throw POSIXError(.EIO) }
    }

    func readRequest() async throws -> JsonRpcRequest {
        try JSONDecoder().decode(JsonRpcRequest.self, from: await readLine())
    }

    func readResponse() async throws -> JsonRpcResponse {
        try JSONDecoder().decode(JsonRpcResponse.self, from: await readLine())
    }

    func readByte() async throws -> UInt8 {
        let fileDescriptor = fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var byte: UInt8 = 0
                let count = Darwin.read(fileDescriptor, &byte, 1)
                guard count >= 0 else {
                    continuation.resume(throwing: readFailure(errno: errno))
                    return
                }
                continuation.resume(returning: count == 0 ? 0 : byte)
            }
        }
    }

    func close() {
        closeLock.lock()
        guard isClosed == false else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }

    private func readLine() async throws -> Data {
        let fileDescriptor = fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                var byte: UInt8 = 0
                while true {
                    let count = Darwin.read(fileDescriptor, &byte, 1)
                    guard count > 0 else {
                        continuation.resume(
                            throwing: count == 0
                                ? POSIXError(.ECONNRESET)
                                : readFailure(errno: errno)
                        )
                        return
                    }
                    if byte == 0x0A {
                        continuation.resume(returning: data)
                        return
                    }
                    data.append(byte)
                }
            }
        }
    }
}
