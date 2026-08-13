// A file-descriptor transport: the read/write/close loops the CLI, the T4 spike, and
// the tape streamer each hand-rolled. It takes a connected descriptor rather than
// connecting itself, so the same code serves an AF_UNIX socket on the Mac and a TCP
// socket to the bridge from the phone.
import Foundation
import Darwin

/// Owns a connected descriptor and the partial-write loop every writer needs.
public final class FileDescriptorTransport: DanTermClientTransport {
    private let fd: Int32
    private var buffer = [UInt8](repeating: 0, count: 4096)

    /// Takes ownership of an already-connected descriptor; `close()` is the only closer.
    public init(fileDescriptor: Int32) {
        self.fd = fileDescriptor
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    throw DanTermClientError.transportFailed(String(cString: strerror(errno)))
                }
                written += n
            }
        }
    }

    public func receive() throws -> Data {
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 {
                throw DanTermClientError.transportFailed(String(cString: strerror(errno)))
            }
            return Data(buffer.prefix(n))
        }
    }

    public func close() { Darwin.close(fd) }
}
