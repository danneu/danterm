// Socket-and-pipe coverage for the CLI's unbuffered pane-tape JSON Lines renderer.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermCLI

struct PaneTapeStreamTests {
    @Test("the renderer flushes each record and stops after end")
    func rendererWritesImmediateLinesThroughProductionDescriptors() throws {
        // Intent: every start, event, and end record is visible before a later frame arrives.
        // Why it exists: print or FileHandle buffering would defeat live pane observation.
        // Scenario: an agent tails a quiet pane, sees isolated output, then the pane closes.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        let completion = StreamCompletionProbe()
        defer {
            Darwin.close(socket.peer)
            Darwin.close(output.read)
        }

        DispatchQueue.global().async {
            do {
                completion.finish(try renderPaneTapeStream(
                    socket: socket.connection,
                    output: output.write,
                    requestId: "R1"
                ))
            } catch {
                completion.fail(error)
            }
            Darwin.close(socket.connection)
            Darwin.close(output.write)
        }

        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: startRecord(capture: "follow")),
            to: socket.peer
        )
        #expect(try readDescriptorRecord(output.read) == startRecord(capture: "follow"))

        try writeFrame(notification(record("event")), to: socket.peer)
        #expect(try readDescriptorRecord(output.read) == record("event"))

        try writeFrame(notification(record("end")), to: socket.peer)
        #expect(try readDescriptorRecord(output.read) == record("end"))
        #expect(try completion.wait() == .init(termination: .end, capture: .follow))
    }

    @Test("the renderer treats EOF after start as clean termination")
    func rendererStopsCleanlyOnEOF() throws {
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: startRecord(capture: "follow")),
            to: socket.peer
        )
        Darwin.close(socket.peer)

        #expect(try renderPaneTapeStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .init(termination: .eof, capture: .follow))
        #expect(try readDescriptorRecord(output.read) == startRecord(capture: "follow"))
    }

    @Test("the renderer treats a closed stdout pipe as clean termination")
    func rendererStopsCleanlyOnBrokenPipe() throws {
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(socket.peer)
            Darwin.close(output.write)
        }
        signal(SIGPIPE, SIG_IGN)
        Darwin.close(output.read)
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: startRecord(capture: "follow")),
            to: socket.peer
        )

        #expect(try renderPaneTapeStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .init(termination: .brokenPipe, capture: .follow))
    }

    @Test("the renderer reports the capture its start record declared")
    func rendererReportsTheDeclaredCaptureMode() throws {
        // Intent: the outcome names the capture the start record declared, beside how the
        //   stream stopped.
        // Why it exists: only the producer knows which capture it opened, and the caller
        //   decides from that pair whether an ending is legitimate. A snapshot that stops at
        //   EOF has lost records, and without the declared mode the caller would have to
        //   re-read what it already wrote out to tell that from a followed pane's clean stop.
        // Scenario: the app dies partway through a finite dump, so the socket reaches EOF
        //   before the terminator that dump promised.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: startRecord(capture: "snapshot")),
            to: socket.peer
        )
        Darwin.close(socket.peer)

        #expect(try renderPaneTapeStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .init(termination: .eof, capture: .snapshot))
    }

    @Test("the renderer reports no capture when the stream ends before its start record")
    func rendererReportsNoCaptureWithoutAStart() throws {
        // Intent: a stream that closes before any start record reports no capture at all.
        // Why it exists: the caller turns a missing capture into a nonzero exit, so a dump
        //   that produced nothing cannot be mistaken for one that produced everything. An
        //   outcome that guessed a mode here would make an empty file look like a whole
        //   recording to the next command in a shell pipeline.
        // Scenario: DanTerm accepts the connection and then dies before it can reply.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        Darwin.close(socket.peer)

        #expect(try renderPaneTapeStream(
            socket: socket.connection,
            output: output.write,
            requestId: "R1"
        ) == .init(termination: .eof, capture: nil))
    }

    @Test("only a capture that owed a terminator fails when its stream reaches EOF")
    func onlyAnOwedTerminatorMakesEOFAFailure() {
        // Intent: EOF fails a finite dump and a stream that never opened, and does not fail a
        //   followed capture; no other ending fails at all.
        // Why it exists: this one decision is the whole reason the outcome carries its capture.
        //   Losing it would make a truncated dump exit 0, so the next command in a pipeline
        //   would read a partial file as a whole recording. Inverting it would make every
        //   crash-surviving follow capture -- the case the tape exists for -- look like an
        //   error.
        // Scenario: the four endings a rendered stream can report, against each capture.
        #expect(paneTapeStreamFailure(for: .init(termination: .eof, capture: .snapshot)) != nil)
        #expect(paneTapeStreamFailure(for: .init(termination: .eof, capture: nil)) != nil)
        #expect(paneTapeStreamFailure(for: .init(termination: .eof, capture: .follow)) == nil)
        #expect(paneTapeStreamFailure(for: .init(termination: .end, capture: .snapshot)) == nil)
        #expect(paneTapeStreamFailure(
            for: .init(termination: .brokenPipe, capture: .snapshot)
        ) == nil)
    }

    private func record(_ kind: String) -> JSONValue {
        .object(["kind": .string(kind)])
    }

    private func startRecord(capture: String) -> JSONValue {
        .object([
            "kind": .string("start"),
            "version": .number(2),
            "capture": .string(capture),
        ])
    }

    private func notification(_ record: JSONValue) -> JsonRpcRequest {
        JsonRpcRequest(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("S1"),
                "record": record,
            ])
        )
    }
}

private struct DescriptorPair: @unchecked Sendable {
    let connection: Int32
    let peer: Int32
}

private struct DescriptorPipe: @unchecked Sendable {
    let read: Int32
    let write: Int32
}

private final class StreamCompletionProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<PaneTapeStreamOutcome, Error>?

    func finish(_ outcome: PaneTapeStreamOutcome) {
        store(.success(outcome))
    }

    func fail(_ error: Error) {
        store(.failure(error))
    }

    func wait() throws -> PaneTapeStreamOutcome {
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            throw CocoaError(.coderReadCorrupt)
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }

    private func store(_ result: Result<PaneTapeStreamOutcome, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }
}

private func descriptorPair() throws -> DescriptorPair {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPair(connection: descriptors[0], peer: descriptors[1])
}

private func descriptorPipe() throws -> DescriptorPipe {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DescriptorPipe(read: descriptors[0], write: descriptors[1])
}

private func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    let data = try encodeIpcLine(value)
    try writeDescriptorData(data, to: descriptor)
}

/// Reads one whole output line and decodes it back into a record.
///
/// The comparison is on the decoded record, not on the line's text: a record's keys are not
/// serialized in a fixed order, so two encodings of the same record can differ byte for byte.
/// Reading a whole line still proves the flushing this suite is about, because a line arrives
/// only once its terminator does.
private func readDescriptorRecord(_ descriptor: Int32) throws -> JSONValue? {
    guard let line = try readDescriptorLine(descriptor) else { return nil }
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

private func writeDescriptorData(_ data: Data, to descriptor: Int32) throws {
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

private func readDescriptorLine(_ descriptor: Int32) throws -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&readiness, 1, 2_000)
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw CocoaError(.coderReadCorrupt) }
        let count = Darwin.read(descriptor, &byte, 1)
        if count < 0 && errno == EINTR { continue }
        if count == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
        guard count > 0 else { throw POSIXError(.EIO) }
        if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
}
