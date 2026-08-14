// The TCP conformance of the client transport seam. It owns address fallback,
// bounded socket waits, and stream-safe POSIX behavior; protocol policy stays above it.
import Darwin
import Foundation

/// Distinguishes TCP setup and stream failures so each client can phrase them for its UI.
public enum TCPSocketTransportError: Error, Equatable {
    /// No address could be resolved for the supplied hostname.
    case unresolvedHost(host: String)
    /// Every resolved address refused or failed the connection attempt.
    case connectFailed(reason: String, target: String)
    /// The shared connection deadline elapsed before any address connected.
    case connectTimedOut(target: String)
    /// The socket could not be configured for safe stream behavior.
    case configureFailed
    /// The socket could not be configured for bounded IO.
    case configureTimeoutFailed
    /// A configured send or receive wait elapsed.
    case timedOut
    /// Reading failed for a reason other than timeout or EOF.
    case readFailed
    /// Writing failed for a reason other than timeout or peer closure.
    case writeFailed
    /// The peer disconnected during a write.
    case peerClosed
}

/// A bounded TCP byte stream that tries every resolved address until one connects.
public final class TCPSocketTransport: DanTermClientTransport {
    private var descriptor: Int32
    private let readBufferSize = 64 * 1024

    /// Resolves `host`, connects within the shared deadline, and configures bounded IO.
    public init(
        host: String,
        port: UInt16,
        connectTimeout: TimeInterval,
        receiveTimeout: TimeInterval?,
        sendTimeout: TimeInterval
    ) throws {
        let target = "\(host):\(port)"
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0,
              let first = resolved
        else { throw TCPSocketTransportError.unresolvedHost(host: host) }
        defer { freeaddrinfo(first) }

        let deadline = ProcessInfo.processInfo.systemUptime + connectTimeout
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var lastReason = "no resolved address accepted the connection"
        var candidateTimedOut = false
        var connected: Int32?
        while let current = candidate {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw TCPSocketTransportError.connectTimedOut(target: target)
            }
            let fd = Darwin.socket(
                current.pointee.ai_family,
                current.pointee.ai_socktype,
                current.pointee.ai_protocol
            )
            if fd >= 0 {
                do {
                    try Self.disableSigPipe(fd)
                    try Self.connect(
                        fd,
                        address: current.pointee.ai_addr,
                        length: current.pointee.ai_addrlen,
                        timeout: min(remaining, 1),
                        target: target
                    )
                    try Self.disableNagle(fd)
                    if let receiveTimeout {
                        try Self.setTimeout(fd, option: SO_RCVTIMEO, seconds: receiveTimeout)
                    }
                    try Self.setTimeout(fd, option: SO_SNDTIMEO, seconds: sendTimeout)
                    connected = fd
                    break
                } catch let error as TCPSocketTransportError {
                    Darwin.close(fd)
                    switch error {
                    case .connectTimedOut:
                        candidateTimedOut = true
                    case let .connectFailed(reason, _):
                        lastReason = reason
                    default:
                        throw error
                    }
                } catch {
                    Darwin.close(fd)
                    throw error
                }
            } else {
                lastReason = String(cString: strerror(errno))
            }
            candidate = current.pointee.ai_next
        }
        guard let connected else {
            if candidateTimedOut {
                throw TCPSocketTransportError.connectTimedOut(target: target)
            }
            throw TCPSocketTransportError.connectFailed(reason: lastReason, target: target)
        }
        descriptor = connected
    }

    deinit { close() }

    public func send(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw TCPSocketTransportError.timedOut
                    }
                    throw TCPSocketTransportError.writeFailed
                }
                if count == 0 { throw TCPSocketTransportError.peerClosed }
                offset += count
            }
        }
    }

    public func receive() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return Data() }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw TCPSocketTransportError.timedOut
                }
                throw TCPSocketTransportError.readFailed
            }
            return Data(buffer[0..<count])
        }
    }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private static func connect(
        _ fd: Int32,
        address: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t,
        timeout: TimeInterval,
        target: String
    ) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TCPSocketTransportError.configureFailed
        }
        let result = Darwin.connect(fd, address, length)
        if result != 0 && errno != EINPROGRESS {
            throw TCPSocketTransportError.connectFailed(
                reason: String(cString: strerror(errno)),
                target: target
            )
        }
        if result != 0 {
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))
            let polled = Darwin.poll(&event, 1, milliseconds)
            guard polled > 0 else {
                if polled == 0 { throw TCPSocketTransportError.connectTimedOut(target: target) }
                throw TCPSocketTransportError.connectFailed(
                    reason: String(cString: strerror(errno)),
                    target: target
                )
            }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                throw TCPSocketTransportError.connectFailed(
                    reason: String(cString: strerror(errno)),
                    target: target
                )
            }
            guard socketError == 0 else {
                throw TCPSocketTransportError.connectFailed(
                    reason: String(cString: strerror(socketError)),
                    target: target
                )
            }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else {
            throw TCPSocketTransportError.configureFailed
        }
    }

    private static func disableSigPipe(_ fd: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw TCPSocketTransportError.configureFailed }
    }

    private static func disableNagle(_ fd: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(
            fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw TCPSocketTransportError.configureFailed }
    }

    private static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
        )
        guard setsockopt(
            fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw TCPSocketTransportError.configureTimeoutFailed }
    }
}
