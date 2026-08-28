// The one POSIX stream body the client transports run on: descriptor ownership,
// cancellation, the read buffer, and the read and write loops.
//
// The loops live here rather than in each conformance because the descriptor's owner is
// the only object that can promise the buffer outlives every call and is untouched after
// close. This file names no transport error: it reports one outcome type, and each
// conformance translates it, so a third conformance over a descriptor adds a translation
// instead of another copy of the loops.
import Darwin
import Foundation

/// How a shared stream operation failed, stated in the loop's vocabulary rather than any
/// transport's.
///
/// Each transport maps every case onto its own public enum through an exhaustive switch,
/// so a case added here surfaces as a compile error at each conformance, not as a runtime
/// gap.
enum SocketStreamFailure: Error, Equatable {
    /// The socket's configured send or receive wait elapsed.
    case timedOut
    case readFailed
    case writeFailed
    /// A write reported zero bytes accepted, so the peer left mid-write.
    case peerClosed
}

/// Owns one connected descriptor, the buffer its reads land in, and the loops that drive
/// them, and keeps all three alive until every operation that borrowed them has returned.
final class SocketDescriptorLifetime: @unchecked Sendable {
    private enum State {
        case open
        case closing
        case closed
    }

    /// Large enough that a `pane snapshot` sync is not split into many syscalls, and paid
    /// once per stream rather than once per read.
    private static let readBufferByteCount = 64 * 1024

    private let condition = NSCondition()
    private var descriptor: Int32
    private var state = State.open
    private var activeOperations = 0

    /// The single destination of every read on this stream. It is shared between calls,
    /// so only one read may run at a time -- the seam in `ClientTransport.swift` promises
    /// exactly that, and every reader reaches `read` through
    /// `DanTermClientSession.nextLine()` under the session's read lock. Writes never touch
    /// it, so the seam's one concurrent write stays safe.
    private let readBuffer: UnsafeMutableRawBufferPointer

    /// Takes ownership of one connected descriptor.
    init(descriptor: Int32) {
        self.descriptor = descriptor
        readBuffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.readBufferByteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
    }

    /// Reads once and returns an independent copy of the bytes, or an empty value at end
    /// of stream. The copy is what lets the next read reuse the buffer.
    func read() throws -> Data {
        try withDescriptor { descriptor in
            while true {
                let count = Darwin.read(descriptor, readBuffer.baseAddress, readBuffer.count)
                if count == 0 { return Data() }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SocketStreamFailure.timedOut
                    }
                    throw SocketStreamFailure.readFailed
                }
                return Data(UnsafeRawBufferPointer(rebasing: readBuffer[0..<count]))
            }
        }
    }

    /// Writes every byte or throws. A throw can follow a partial write, so the caller
    /// treats the stream as unusable rather than appending to a truncated message.
    func write(_ bytes: Data) throws {
        try withDescriptor { descriptor in
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
                            throw SocketStreamFailure.timedOut
                        }
                        throw SocketStreamFailure.writeFailed
                    }
                    if written == 0 { throw SocketStreamFailure.peerClosed }
                    offset += written
                }
            }
        }
    }

    /// Borrows the live descriptor for one complete read or write operation.
    private func withDescriptor<T>(_ operation: (Int32) throws -> T) throws -> T {
        condition.lock()
        guard state == .open else {
            condition.unlock()
            throw DanTermClientTransportError.cancelled
        }
        let borrowed = descriptor
        activeOperations += 1
        condition.unlock()

        defer {
            condition.lock()
            activeOperations -= 1
            condition.broadcast()
            condition.unlock()
        }
        return try operation(borrowed)
    }

    /// Wakes blocking IO, waits for every borrower, and releases the descriptor once.
    func close() {
        condition.lock()
        switch state {
        case .closed:
            condition.unlock()
            return
        case .closing:
            while state != .closed { condition.wait() }
            condition.unlock()
            return
        case .open:
            state = .closing
            let closingDescriptor = descriptor
            condition.unlock()

            _ = Darwin.shutdown(closingDescriptor, SHUT_RDWR)

            condition.lock()
            while activeOperations > 0 { condition.wait() }
            descriptor = -1
            condition.unlock()

            Darwin.close(closingDescriptor)

            condition.lock()
            state = .closed
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Closing first is what makes freeing the buffer safe: it returns only once no
    /// operation can still be reading into it.
    deinit {
        close()
        readBuffer.deallocate()
    }
}
