// Regression coverage for app-level IPC server ownership and synchronous teardown.
import Darwin
import Foundation
import Testing
@testable import DanTerm

struct IpcServerOwnershipTests {
    @Test("failed server construction and shutdown preserve the live owner")
    func failedConstructionShutdownPreservesOwner() throws {
        // Intent: only a successfully constructed server can expose or remove a
        //   control socket, and its stop returns after that socket is gone.
        // Why it exists: a losing same-identity app retained a path it did not
        //   own, then deleted the winning app's live socket during shutdown.
        // Scenario: instance A owns the slot socket while instance B starts,
        //   loses the bind race, and quits before A later quits normally.
        let fixture = try IpcServerSocketFixture()
        defer { fixture.remove() }
        let owner = try IpcServer(socketPath: fixture.socketURL, runtimeDispatch: nil)

        let contender = try? IpcServer(socketPath: fixture.socketURL, runtimeDispatch: nil)
        #expect(contender == nil)
        contender?.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        #expect(canConnectToIpcServer(at: fixture.socketURL))

        owner.stop()

        #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path) == false)
        #expect(canConnectToIpcServer(at: fixture.socketURL) == false)
    }
}

private struct IpcServerSocketFixture {
    let directoryURL: URL
    let socketURL: URL

    init() throws {
        directoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-ipc-server-\(UUID().uuidString)", isDirectory: true)
        socketURL = directoryURL.appendingPathComponent("control.sock")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func canConnectToIpcServer(at url: URL) -> Bool {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { return false }
    defer { Darwin.close(fileDescriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard url.path.utf8.count < maximumLength else { return false }
    url.path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            let destination = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
            strncpy(destination, source, maximumLength - 1)
        }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    } == 0
}
