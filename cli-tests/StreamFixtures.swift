// Socket-and-pipe fixtures shared by the CLI's stream renderer suites.
//
// Every streaming command renders a real DanTermClient session over a real descriptor and
// writes to a real pipe, because what these suites assert is that each line reaches the
// consumer before the next frame arrives -- which no in-memory double can show. The
// fixtures live here rather than in one suite so a second renderer does not copy them.
//
// Not here: any one stream's records or its endings. Those stay with the suite that owns
// the stream.
import Foundation
import Testing
import DanTermClient
import DanTermProtocol
import Darwin
@testable import DanTermCLI

/// How long any waiter in these suites will sit before it declares a renderer hung.
///
/// This is a hang guard, not a threshold: nothing here measures how fast a renderer is, so
/// the only requirement is that a passing run cannot approach it and that it fires before the
/// suite's time-limit backstop, so the failure names the waiter instead of the whole test.
let streamHangGuardSeconds = 30.0

/// Feeds a client session from a raw descriptor, so these fixtures can keep writing frames
/// one at a time into a real socket and still exercise the renderer's actual input path.
final class DescriptorTransport: DanTermClientTransport {
    static let livenessPolicy = DanTermClientLivenessPolicy.exempt

    private let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ bytes: Data) throws {
        try writeDescriptorData(bytes, to: descriptor)
    }

    func receive() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { return Data() }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Data(buffer[0..<count])
        }
    }

    func close() {}
}

/// Wraps a raw descriptor in the session type every renderer reads through.
func streamSession(_ descriptor: Int32) -> DanTermClientSession {
    DanTermClientSession(transport: DescriptorTransport(descriptor))
}

struct DescriptorPair: @unchecked Sendable {
    let connection: Int32
    let peer: Int32
}

struct DescriptorPipe: @unchecked Sendable {
    let read: Int32
    let write: Int32
}

/// Carries a renderer's outcome off the thread it ran on, or the error it threw.
final class StreamCompletionProbe<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ outcome: Value) {
        store(.success(outcome))
    }

    func fail(_ error: Error) {
        store(.failure(error))
    }

    func wait() throws -> Value {
        guard semaphore.wait(timeout: .now() + streamHangGuardSeconds) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }

    private func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }
}

/// Runs `body` on a thread of its own, so the renderer never queues behind a sibling test.
///
/// The obvious `DispatchQueue.global().async` cannot be used here. Eleven tests in this same
/// binary park a global-queue worker inside a blocking `accept()`, and a non-overcommit root
/// queue does not grow on demand: it asks the kernel workqueue for a worker and collapses
/// further requests while one is already outstanding. Under the gate's deprioritized,
/// oversubscribed pool that delay is measurable and grows with load, and the renderer must
/// already be running before the first frame is written.
func runOnItsOwnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.start()
}

func descriptorPair() throws -> DescriptorPair {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPair(connection: descriptors[0], peer: descriptors[1])
}

func descriptorPipe() throws -> DescriptorPipe {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPipe(read: descriptors[0], write: descriptors[1])
}

func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    let data = try encodeIpcLine(value)
    try writeDescriptorData(data, to: descriptor)
}

/// Reads one whole output line and decodes it back into a record.
///
/// The comparison is on the decoded record, not on the line's text: a record's keys are not
/// serialized in a fixed order, so two encodings of the same record can differ byte for byte.
/// Reading a whole line still proves the flushing this suite is about, because a line arrives
/// only once its terminator does.
func readDescriptorRecord(_ descriptor: Int32) throws -> JSONValue? {
    guard let line = try readDescriptorLine(descriptor) else { return nil }
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

func writeDescriptorData(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw POSIXError(.EIO) }
        offset += written
    }
}

func readDescriptorLine(_ descriptor: Int32) throws -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&readiness, 1, Int32(streamHangGuardSeconds * 1000))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
        let count = Darwin.read(descriptor, &byte, 1)
        if count < 0 && errno == EINTR { continue }
        if count == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
        guard count > 0 else { throw POSIXError(.EIO) }
        if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
}
