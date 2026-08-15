// TCP listener ownership for the remote IPC surface. Admission and request
// dispatch remain in the app; this file owns bind/listen/close and peer capture.
import Darwin
import Foundation
import Synchronization

/// Owns one TCP listener that can be opened only from a validated bind address.
final class TailnetListener: Sendable {
    let fileDescriptor: Int32
    let port: UInt16
    private let isClosed = Mutex(false)

    private init(fileDescriptor: Int32, port: UInt16) {
        self.fileDescriptor = fileDescriptor
        self.port = port
    }

    deinit {
        close()
    }

    /// Binds exactly the validated address and never retries on a broader interface.
    static func open(on bindAddress: TailnetBindAddress) throws -> TailnetListener {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw tailnetPOSIXError() }
        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw tailnetPOSIXError() }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = bindAddress.port.bigEndian
            guard inet_pton(AF_INET, bindAddress.address, &address.sin_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        fileDescriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard result == 0 else { throw tailnetPOSIXError() }
            guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw tailnetPOSIXError()
            }
            return TailnetListener(
                fileDescriptor: fileDescriptor,
                port: try boundPort(of: fileDescriptor)
            )
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    /// Stops accepting connections once, including when explicit shutdown races deinit.
    func close() {
        isClosed.withLock { closed in
            guard closed == false else { return }
            closed = true
            Darwin.close(fileDescriptor)
        }
    }
}

/// Carries the source address authenticated by the tailnet interface into admission.
struct TailnetPeerAddress: Equatable, Sendable, CustomStringConvertible {
    let host: String
    let port: UInt16

    var description: String { "\(host):\(port)" }
}

/// Couples an accepted descriptor to the peer address captured by the same syscall.
struct TailnetAcceptedPeer: Sendable {
    let fileDescriptor: Int32
    let peer: TailnetPeerAddress
}

/// Accepts one peer while preserving the source address needed for identity resolution.
func acceptTailnetPeer(on listenerFileDescriptor: Int32) throws -> TailnetAcceptedPeer {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let fileDescriptor = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.accept(listenerFileDescriptor, $0, &length)
        }
    }
    guard fileDescriptor >= 0 else { throw tailnetPOSIXError() }
    do {
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(
            AF_INET,
            &address.sin_addr,
            &hostBuffer,
            socklen_t(hostBuffer.count)
        ) != nil else { throw tailnetPOSIXError() }
        var noDelay: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw tailnetPOSIXError() }
        var noSignal: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw tailnetPOSIXError() }
        return TailnetAcceptedPeer(
            fileDescriptor: fileDescriptor,
            peer: TailnetPeerAddress(
                host: String(
                    decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                ),
                port: UInt16(bigEndian: address.sin_port)
            )
        )
    } catch {
        Darwin.close(fileDescriptor)
        throw error
    }
}

/// Reads the kernel-selected port used by test-only port-zero listeners.
private func boundPort(of fileDescriptor: Int32) throws -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fileDescriptor, $0, &length)
        }
    }
    guard result == 0 else { throw tailnetPOSIXError() }
    return UInt16(bigEndian: address.sin_port)
}

/// Captures errno before cleanup can replace it.
private func tailnetPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
