// Coordinates socket cancellation with active POSIX operations.
import Darwin
import Foundation

/// Keeps a descriptor open until every operation that borrowed it has returned.
final class SocketDescriptorLifetime: @unchecked Sendable {
    private enum State {
        case open
        case closing
        case closed
    }

    private let condition = NSCondition()
    private var descriptor: Int32
    private var state = State.open
    private var activeOperations = 0

    /// Takes ownership of one connected descriptor.
    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Borrows the live descriptor for one complete read or write operation.
    func withDescriptor<T>(_ operation: (Int32) throws -> T) throws -> T {
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

    deinit { close() }
}
