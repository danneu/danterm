// Socket-and-pipe coverage for the CLI's unbuffered pane-tape JSON Lines renderer.
//
// The renderer reads through a DanTermClient session now, so the socket half of each
// fixture only exists to feed that session real bytes at the moment the test chooses --
// which is what the flushing assertions need.
import Foundation
import Testing
import DanTermClient
import DanTermProtocol
import Darwin
@testable import DanTermCLI

@Suite(.timeLimit(.minutes(1)))
struct PaneTapeStreamTests {
    @Test("the renderer flushes each record and stops after end")
    func rendererWritesImmediateLinesThroughProductionDescriptors() throws {
        // Intent: every start, event, and end record is visible before a later frame arrives.
        // Why it exists: print or FileHandle buffering would defeat live pane observation.
        // Scenario: an agent tails a quiet pane, sees isolated output, then the pane closes.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        let completion = StreamCompletionProbe<PaneTapeStreamOutcome>()
        defer {
            Darwin.close(socket.peer)
            Darwin.close(output.read)
        }

        runOnItsOwnThread {
            do {
                completion.finish(try renderPaneTapeStream(
                    session: streamSession(socket.connection),
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

    @Test("a batched notification renders one stdout line per record and still stops at end")
    func rendererWritesEveryRecordOfABatchedNotification() throws {
        // Intent: a notification carrying several records writes one JSON Lines record per
        //   record, in wire order, and a terminator inside such a notification still ends
        //   the stream.
        // Why it exists: the producer delivers a whole batch in one notification now. The
        //   CLI's output contract did not move with it: every consumer downstream of
        //   `danterm pane tape` still reads one record per line.
        // Scenario: a busy pane's records are grouped, and the pane then closes.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        let completion = StreamCompletionProbe<PaneTapeStreamOutcome>()
        defer {
            Darwin.close(socket.peer)
            Darwin.close(output.read)
        }

        runOnItsOwnThread {
            do {
                completion.finish(try renderPaneTapeStream(
                    session: streamSession(socket.connection),
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

        try writeFrame(
            notification(record("gap"), record("event"), record("end")),
            to: socket.peer
        )
        #expect(try readDescriptorRecord(output.read) == record("gap"))
        #expect(try readDescriptorRecord(output.read) == record("event"))
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
            session: streamSession(socket.connection),
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
            session: streamSession(socket.connection),
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
            session: streamSession(socket.connection),
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
            session: streamSession(socket.connection),
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

    @Test("the renderer applies its transform to every record it writes")
    func rendererAppliesItsTransformToEveryRecord() throws {
        // Intent: the start record and the event records that follow it are both written in the
        //   form the transform returned, not the form they arrived in.
        // Why it exists: a transform applied to only part of a stream would emit a stream that
        //   states one format and carries another, and a reader keying off the start record
        //   would decode the rest wrong.
        // Scenario: an agent asks for the inspect view of a followed pane.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }

        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: replayStartRecord()),
            to: socket.peer
        )
        try writeFrame(notification(replayEventRecord()), to: socket.peer)
        Darwin.close(socket.peer)

        #expect(try renderPaneTapeStream(
            session: streamSession(socket.connection),
            output: output.write,
            requestId: "R1",
            transform: paneTapeInspectRecord
        ) == .init(termination: .eof, capture: .follow))

        #expect(try readDescriptorRecord(output.read) == .object([
            "kind": .string("start"),
            "version": .number(Double(paneTapeStreamVersion)),
            "capture": .string("follow"),
            "format": .string("inspect"),
            "reconstructible": .bool(true),
            "initial": .object([
                "columns": .number(80),
                "rows": .number(24),
                "pinned": .bool(false),
            ]),
            "cursor": .object([
                "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ]))
        #expect(try readDescriptorRecord(output.read) == .object([
            "kind": .string("event"),
            "sequence": .number(4),
            "elapsedNanoseconds": .number(900),
            "byteOffset": .number(0),
            "byteLength": .number(3),
            "event": .object([
                "type": .string("feed"),
                "spans": .array([
                    .object(["text": .string("hi")]),
                    .object(["control": .string("ESC")]),
                ]),
            ]),
        ]))
    }

    private func replayStartRecord() -> JSONValue {
        startRecord(capture: "follow")
    }

    private func replayEventRecord() -> JSONValue {
        .object([
            "kind": .string("event"),
            "sequence": .number(4),
            "elapsedNanoseconds": .number(900),
            "byteOffset": .number(0),
            "byteLength": .number(3),
            "event": .object([
                "type": .string("feed"),
                "base64": .string(Data("hi\u{1B}".utf8).base64EncodedString()),
            ]),
        ])
    }

    private func record(_ kind: String) -> JSONValue {
        .object(["kind": .string(kind)])
    }

    /// A start record with every field the producer states. The renderer decodes it rather
    /// than picking one key out of it, so a fixture missing the cursor baseline would be
    /// malformed here in the same way it would be malformed on the wire.
    private func startRecord(capture: String) -> JSONValue {
        .object([
            "kind": .string("start"),
            "version": .number(Double(paneTapeStreamVersion)),
            "capture": .string(capture),
            "format": .string(PaneTapeFormat.replay.rawValue),
            "reconstructible": .bool(capture != "dump"),
            "initial": .object([
                "columns": .number(80),
                "rows": .number(24),
                "pinned": .bool(false),
            ]),
            "cursor": .object([
                "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ])
    }

    private func notification(_ records: JSONValue...) -> JsonRpcRequest {
        JsonRpcRequest(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("S1"),
                "records": .array(records),
            ])
        )
    }
}
