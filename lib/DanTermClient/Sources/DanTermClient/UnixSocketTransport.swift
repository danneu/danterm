// The AF_UNIX conformance of the client transport seam: the only file in this module
// that knows what a socket is.
//
// It stays a conformance rather than the transport, so a network transport can be added
// beside it without touching the conversation above. Its error cases are deliberately
// specific -- a caller renders the difference between "nothing is listening" and "the
// sandbox refused the path", and cannot recover that from a collapsed failure.
import Foundation
import Darwin

/// Every way opening or using a local control socket can fail. Distinct cases exist where
/// a caller phrases the outcome differently, not for every errno the kernel can return.
public enum UnixSocketTransportError: Error, Equatable {
    /// Nothing is listening: no socket file, or a stale one left behind.
    case unreachable
    /// The path exists but this process may not reach it.
    case accessDenied(path: String)
    case connectFailed(reason: String, path: String)
    case pathTooLong
    case createFailed
    case configureFailed
    case configureTimeoutFailed
    /// A read or write hit the configured timeout, so the peer is present but silent.
    case timedOut
    case readFailed
    case writeFailed
    /// The peer closed the stream mid-write.
    case peerClosed
}

/// A client transport over a local AF_UNIX stream socket.
///
/// The receive timeout is optional because the two conversations need different ones: a
/// request expects an answer within seconds, while a followed stream is idle exactly as
/// long as its subject is quiet, and a timeout there would cut a healthy capture short.
public final class UnixSocketTransport: DanTermClientTransport {
    /// A local peer cannot die without its socket closing, and a local follow is idle for
    /// exactly as long as its pane is quiet, so no silence bound applies to these streams.
    public static let livenessPolicy = DanTermClientLivenessPolicy.exempt

    private let stream: SocketDescriptorLifetime

    /// Connects to `path`, applying a send timeout always and a receive timeout only when
    /// one is asked for.
    public init(path: String, receiveTimeout: TimeInterval?, sendTimeout: TimeInterval) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketTransportError.createFailed }
        do {
            try Self.disableSigPipe(fd)
            if let receiveTimeout {
                try Self.setTimeout(fd, option: SO_RCVTIMEO, seconds: receiveTimeout)
            }
            try Self.setTimeout(fd, option: SO_SNDTIMEO, seconds: sendTimeout)
            try Self.connect(fd, to: path)
        } catch {
            Darwin.close(fd)
            throw error
        }
        stream = SocketDescriptorLifetime(descriptor: fd)
    }

    /// Takes ownership of an already-connected socket so the real write path can be
    /// exercised against a socketpair without creating a filesystem endpoint.
    init(connectedDescriptor fd: Int32, sendTimeout: TimeInterval) throws {
        do {
            try Self.disableSigPipe(fd)
            try Self.setTimeout(fd, option: SO_SNDTIMEO, seconds: sendTimeout)
        } catch {
            Darwin.close(fd)
            throw error
        }
        stream = SocketDescriptorLifetime(descriptor: fd)
    }

    deinit { close() }

    public func send(_ bytes: Data) throws {
        do {
            try stream.write(bytes)
        } catch let failure as SocketStreamFailure {
            throw Self.error(for: failure)
        }
    }

    public func receive() throws -> Data {
        do {
            return try stream.read()
        } catch let failure as SocketStreamFailure {
            throw Self.error(for: failure)
        }
    }

    public func close() { stream.close() }

    /// Says the shared stream body's outcome in this transport's own vocabulary. It is
    /// exhaustive, so a new stream outcome cannot reach a caller unnamed.
    private static func error(for failure: SocketStreamFailure) -> UnixSocketTransportError {
        switch failure {
        case .timedOut: .timedOut
        case .readFailed: .readFailed
        case .writeFailed: .writeFailed
        case .peerClosed: .peerClosed
        }
    }

    private static func connect(_ fd: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw UnixSocketTransportError.pathTooLong }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let bytes = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(bytes, source, capacity - 1)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0 else { return }
        switch errno {
        case ENOENT, ECONNREFUSED:
            throw UnixSocketTransportError.unreachable
        case EACCES, EPERM:
            throw UnixSocketTransportError.accessDenied(path: path)
        default:
            throw UnixSocketTransportError.connectFailed(
                reason: String(cString: strerror(errno)),
                path: path
            )
        }
    }

    private static func disableSigPipe(_ fd: Int32) throws {
        var value: Int32 = 1
        let result = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else { throw UnixSocketTransportError.configureFailed }
    }

    private static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
        )
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, option, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else { throw UnixSocketTransportError.configureTimeoutFailed }
    }
}
