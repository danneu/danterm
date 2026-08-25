// Race-safe ownership of DanTerm's Unix control socket. The listener serializes
// stale-path reclamation per identity and records the bound path's filesystem
// identity so teardown cannot unlink a newer listener. The AppKit-free support
// layer owns this mechanism; app/IpcServer owns request acceptance and dispatch.
import Darwin
import Foundation
import Synchronization

/// Owns one listening Unix socket and removes its path only while that path still
/// names the socket created by this owner.
final class ControlSocketListener: Sendable {
    let fileDescriptor: Int32

    private let socketURL: URL
    private let boundPathIdentity: BoundPathIdentity
    /// Guards the whole teardown, not just the flag: every caller of `close()` has to
    /// return with the path unlinked and the descriptor closed, so the one that finds
    /// the work already done must have waited for it rather than raced past it.
    private let isClosed = Mutex(false)

    private init(
        fileDescriptor: Int32,
        socketURL: URL,
        boundPathIdentity: BoundPathIdentity
    ) {
        self.fileDescriptor = fileDescriptor
        self.socketURL = socketURL
        self.boundPathIdentity = boundPathIdentity
    }

    deinit {
        close()
    }

    /// Claims `url`, reclaiming an abandoned socket only while holding the
    /// identity-specific replacement lock.
    static func open(at url: URL) throws -> ControlSocketListener {
        try PrivateFile.createDirectory(at: url.deletingLastPathComponent())

        return try withReplacementLock(for: url) {
            if let existing = try pathIdentity(at: url) {
                guard existing.isSocket else { throw POSIXError(.EADDRINUSE) }
                if try socketAcceptsConnections(at: url) {
                    throw POSIXError(.EADDRINUSE)
                }
                guard unlink(url.path) == 0 else { throw currentPOSIXError() }
            }

            // The node is already 0600 when the seam returns it, and it has not listened
            // yet, so there is no moment at which this path accepts a connection at a
            // broader mode.
            let fileDescriptor = try PrivateFile.bindSocket(at: url)

            do {
                guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                    throw currentPOSIXError()
                }
                guard let identity = try pathIdentity(at: url), identity.isSocket else {
                    throw POSIXError(.EIO)
                }
                return ControlSocketListener(
                    fileDescriptor: fileDescriptor,
                    socketURL: url,
                    boundPathIdentity: identity
                )
            } catch {
                Darwin.close(fileDescriptor)
                throw error
            }
        }
    }

    /// Stops accepting connections and unlinks only this listener's still-owned path.
    func close() {
        isClosed.withLock { closed in
            guard closed == false else { return }
            closed = true

            try? withReplacementLock(for: socketURL) {
                if try pathIdentity(at: socketURL) == boundPathIdentity {
                    guard unlink(socketURL.path) == 0 else { throw currentPOSIXError() }
                }
            }
            Darwin.close(fileDescriptor)
        }
    }
}

private struct BoundPathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t

    static func == (lhs: BoundPathIdentity, rhs: BoundPathIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    var isSocket: Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }
}

/// Runs a socket-path mutation while holding the persistent per-path advisory lock.
private func withReplacementLock<T>(for socketURL: URL, body: () throws -> T) throws -> T {
    let lockURL = URL(fileURLWithPath: socketURL.path + ".lock")
    let fileDescriptor = try PrivateFile.openForLocking(at: lockURL)
    defer { Darwin.close(fileDescriptor) }
    guard flock(fileDescriptor, LOCK_EX) == 0 else { throw currentPOSIXError() }
    defer { flock(fileDescriptor, LOCK_UN) }
    return try body()
}

/// Returns the filesystem identity recorded at bind time, or nil for no path.
private func pathIdentity(at url: URL) throws -> BoundPathIdentity? {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        if errno == ENOENT { return nil }
        throw currentPOSIXError()
    }
    return BoundPathIdentity(device: status.st_dev, inode: status.st_ino, mode: status.st_mode)
}

/// Distinguishes a serving socket from an abandoned socket pathname.
private func socketAcceptsConnections(at url: URL) throws -> Bool {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw currentPOSIXError() }
    defer { Darwin.close(fileDescriptor) }
    var address = try unixSocketAddress(for: url)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                fileDescriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    if result == 0 { return true }
    if errno == ECONNREFUSED || errno == ENOENT { return false }
    throw currentPOSIXError()
}

/// Captures `errno` before subsequent cleanup syscalls can overwrite it.
private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
