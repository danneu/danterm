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
    private let lifetime: SocketDescriptorLifetime
    private let readBufferSize = 64 * 1024

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
        lifetime = SocketDescriptorLifetime(descriptor: fd)
    }

    deinit { close() }

    public func send(_ bytes: Data) throws {
        try lifetime.withDescriptor { descriptor in
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            throw UnixSocketTransportError.timedOut
                        }
                        throw UnixSocketTransportError.writeFailed
                    }
                    if written == 0 { throw UnixSocketTransportError.peerClosed }
                    offset += written
                }
            }
        }
    }

    public func receive() throws -> Data {
        try lifetime.withDescriptor { descriptor in
            var buffer = [UInt8](repeating: 0, count: readBufferSize)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress, raw.count)
                }
                if count == 0 { return Data() }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw UnixSocketTransportError.timedOut
                    }
                    throw UnixSocketTransportError.readFailed
                }
                return Data(buffer[0..<count])
            }
        }
    }

    public func close() { lifetime.close() }

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
