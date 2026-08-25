// Swift Testing integration coverage for race-safe Unix control-socket ownership.
import Darwin
import Foundation
import Testing
@testable import DanTermSupport

struct ControlSocketListenerTests {
    @Test("a live listener rejects a second owner and remains reachable")
    func liveListenerRejectsSecondOwner() throws {
        // Intent: opening an already-served control socket refuses without disturbing
        //   the original listener.
        // Why it exists: unlink-before-bind let a second app steal a live instance's
        //   path while its now-anonymous listener kept running.
        // Scenario: two DanTerm processes with the same identity start concurrently.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let first = try ControlSocketListener.open(at: fixture.socketURL)
        defer { first.close() }

        do {
            _ = try ControlSocketListener.open(at: fixture.socketURL)
            Issue.record("expected the live socket owner to reject a replacement")
        } catch let error as POSIXError {
            #expect(error.code == .EADDRINUSE)
        }

        #expect(canConnect(to: fixture.socketURL))
    }

    @Test("an abandoned socket path is reclaimed")
    func abandonedSocketIsReclaimed() throws {
        // Intent: a socket pathname left behind after process death can be rebound.
        // Why it exists: refusing every existing pathname would make a crash prevent
        //   that identity from serving IPC until manual cleanup.
        // Scenario: DanTerm is SIGKILLed, then the same identity launches again.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        try leaveAbandonedSocket(at: fixture.socketURL)

        let listener = try ControlSocketListener.open(at: fixture.socketURL)
        defer { listener.close() }

        #expect(canConnect(to: fixture.socketURL))
    }

    @Test("concurrent reclaimers leave exactly one reachable listener")
    func concurrentReclaimHasOneWinner() throws {
        // Intent: abandoned-path detection and replacement form one serialized critical
        //   section, so only one contender becomes the listener.
        // Why it exists: independent probe-unlink-bind sequences can both decide a path
        //   is stale and let the loser unlink the winner's newly bound socket.
        // Scenario: two same-identity launches race immediately after an unclean exit.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        try leaveAbandonedSocket(at: fixture.socketURL)
        let results = LockedResults<Result<ControlSocketListener, Error>>()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            results.append(Result { try ControlSocketListener.open(at: fixture.socketURL) })
        }

        let listeners = results.values.compactMap { try? $0.get() }
        defer { listeners.forEach { $0.close() } }
        #expect(listeners.count == 1)
        #expect(results.values.count(where: { if case .failure = $0 { true } else { false } }) == 1)
        #expect(canConnect(to: fixture.socketURL))
    }

    @Test("every concurrent close returns only after the path is gone")
    func concurrentCloseUnlinksBeforeAnyCallerReturns() throws {
        // Intent: a close that did not perform the teardown still returns only once the
        //   socket path is unlinked.
        // Why it exists: guarding close with a bare flag lets the loser return while the
        //   winner is still inside the replacement lock, so IpcServer.stop() could hand
        //   control back to the app exit path with the socket still on disk and still
        //   connectable.
        // Scenario: quit and an explicit shutdown request race on the same listener.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let listener = try ControlSocketListener.open(at: fixture.socketURL)
        let pathStillPresent = LockedResults<Bool>()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            listener.close()
            pathStillPresent.append(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        }

        #expect(pathStillPresent.values.count == 8)
        #expect(pathStillPresent.values.allSatisfy { $0 == false })
    }

    @Test("a repeated close leaves the reused descriptor number open")
    func repeatedCloseDoesNotCloseAReusedDescriptor() throws {
        // Intent: only the first close closes the listening descriptor.
        // Why it exists: a second Darwin.close on the same number hits whatever the
        //   process opened next, since the kernel hands out the lowest free number.
        // Scenario: IpcServer.stop() runs on quit and the listener then deinitializes.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let listener = try ControlSocketListener.open(at: fixture.socketURL)
        let freedNumber = listener.fileDescriptor
        listener.close()

        // The kernel hands out the lowest free number, so a probe should land on the one
        // the listener just freed. A test running in parallel can take it first, which
        // leaves nothing to observe -- stand down rather than assert on someone else's
        // descriptor.
        var probes: [Int32] = []
        defer { probes.forEach { Darwin.close($0) } }
        while probes.contains(freedNumber) == false && probes.count < 64 {
            let probe = Darwin.open("/dev/null", O_RDONLY)
            try #require(probe >= 0)
            probes.append(probe)
        }
        guard probes.contains(freedNumber) else { return }

        listener.close()

        #expect(fcntl(freedNumber, F_GETFD) != -1)
    }

    @Test("closing an old listener preserves a replacement path")
    func oldListenerClosePreservesReplacement() throws {
        // Intent: close removes the pathname only when it still names the socket this
        //   listener bound.
        // Why it exists: unconditional cleanup lets an older process erase a newer
        //   listener's path after an external replacement or ownership bug.
        // Scenario: an old instance stops after another instance has rebound its path.
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let first = try ControlSocketListener.open(at: fixture.socketURL)
        try FileManager.default.removeItem(at: fixture.socketURL)
        let replacement = try ControlSocketListener.open(at: fixture.socketURL)
        defer { replacement.close() }

        first.close()

        #expect(canConnect(to: fixture.socketURL))
    }

    @Test("the socket, its replacement lock, and the directory holding them are owner-only")
    func openLeavesEveryArtifactOwnerOnly() throws {
        // Intent: opening a listener leaves a 0600 socket and a 0600 replacement lock inside a
        //   0700 directory, narrowing a directory that already existed at a broader mode.
        // Why it exists: the socket is the whole remote-control surface of a running instance,
        //   and the fixture creates its directory at the umask default first, so the mode
        //   asserted here can only come from the listener narrowing what it found (I1, I3, I5).
        // Scenario: spec-first -- one instance claiming its control socket at launch.
        let fixture = try SocketFixture()
        defer { fixture.remove() }

        let listener = try ControlSocketListener.open(at: fixture.socketURL)
        defer { listener.close() }

        let lockURL = URL(fileURLWithPath: fixture.socketURL.path + ".lock")
        #expect(try posixMode(of: fixture.socketURL) == 0o600)
        #expect(try posixMode(of: lockURL) == 0o600)
        #expect(try posixMode(of: fixture.directoryURL) == 0o700)
    }
}

private final class LockedResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private struct SocketFixture: Sendable {
    let directoryURL: URL
    let socketURL: URL

    init() throws {
        directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-sock-\(UUID().uuidString)", isDirectory: true)
        socketURL = directoryURL.appendingPathComponent("control.sock")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func leaveAbandonedSocket(at url: URL) throws {
    let fileDescriptor = try bindSocket(at: url)
    guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
        let error = posixError()
        Darwin.close(fileDescriptor)
        throw error
    }
    Darwin.close(fileDescriptor)
}

private func canConnect(to url: URL) -> Bool {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { return false }
    defer { Darwin.close(fileDescriptor) }
    do {
        var address = try socketAddress(for: url)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        } == 0
    } catch {
        return false
    }
}

private func bindSocket(at url: URL) throws -> Int32 {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw posixError() }
    do {
        var address = try socketAddress(for: url)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else { throw posixError() }
        return fileDescriptor
    } catch {
        Darwin.close(fileDescriptor)
        throw error
    }
}

private func socketAddress(for url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard url.path.utf8.count < maximumLength else {
        throw CocoaError(.fileWriteInvalidFileName)
    }
    url.path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            let destination = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
            strncpy(destination, source, maximumLength - 1)
        }
    }
    return address
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
