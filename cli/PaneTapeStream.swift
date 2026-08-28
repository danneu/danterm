// Unbuffered JSON Lines renderer for pane-tape streams, finite and followed alike.
//
// This file renders; it does not read a socket. The conversation it renders comes from a
// DanTermClient session, and each record's shape is decoded by that module's reader, so
// the only spellings left here are the CLI's own output policy.
import Foundation
import DanTermClient
import DanTermProtocol
import Darwin

/// Distinguishes the ways a tape stream can stop, so the CLI can hold each capture to its own
/// ending: a finite dump owes an explicit terminator, while a followed stream may legitimately
/// end at EOF because the app stopped.
enum PaneTapeStreamTermination: Equatable {
    case end
    case eof
    case brokenPipe
}

/// Reports what a rendered stream turned out to be, so the caller can judge how it ended
/// without re-parsing the records it already wrote out.
struct PaneTapeStreamOutcome: Equatable {
    let termination: PaneTapeStreamTermination
    /// The capture the start record declared, or nil if no start record ever arrived.
    let capture: PaneTapeCaptureMode?
}

/// Decides whether a finished stream left a whole capture on stdout, or nothing downstream
/// should trust.
///
/// A finite dump always states its own end, so reaching EOF instead means records are missing.
/// A followed capture that reaches EOF is a real recording of everything up to the moment the
/// app stopped, which is what surviving a crash looks like. A stream that never opened at all
/// produced no capture of either kind. A closed stdout is the consumer's own choice and ends
/// every capture cleanly.
func paneTapeStreamFailure(for outcome: PaneTapeStreamOutcome) -> PaneTapeStreamError? {
    guard outcome.termination == .eof else { return nil }
    switch outcome.capture {
    case .follow: return nil
    case .dump, .snapshot, nil: return .incompleteCapture
    }
}

/// Reports malformed or failed tape traffic without coupling the renderer to CLI exit policy.
enum PaneTapeStreamError: Error, LocalizedError {
    case rpc(String)
    case malformedResponse
    case writeFailed
    case incompleteCapture

    var errorDescription: String? {
        switch self {
        case .rpc(let message): return message
        case .malformedResponse: return "malformed response"
        case .writeFailed: return "failed to write pane tape stream"
        case .incompleteCapture: return "DanTerm closed the connection before the tape ended"
        }
    }
}

/// Renders one tape conversation, writing each record directly to an output fd.
///
/// `transform` is applied to every unwrapped record before it is written, one record at a
/// time, which is what keeps a derived view from needing the whole recording in memory.
/// Every record is written as it arrived rather than re-encoded from a decoded form, so a
/// replay capture keeps the exact bytes -- including a record kind this build does not
/// know, which is passed through and does not end the stream.
func renderPaneTapeStream(
    session: DanTermClientSession,
    output: Int32,
    requestId: String,
    transform: (JSONValue) throws -> JSONValue = { $0 }
) throws -> PaneTapeStreamOutcome {
    guard let response = try session.awaitReply(id: .string(requestId)) else {
        return .init(termination: .eof, capture: nil)
    }
    if let error = response.error {
        throw PaneTapeStreamError.rpc(error.message)
    }
    // A capture this build does not know is malformed, not a follow. Failing open here
    // would apply the permissive ending rule to a stream that never claimed it.
    guard let start = response.result,
          case .start(let opening)? = decodePaneTapeRecord(start)
    else {
        throw PaneTapeStreamError.malformedResponse
    }
    let capture = opening.capture
    guard try writePaneTapeRecord(transform(start), to: output) else {
        return .init(termination: .brokenPipe, capture: capture)
    }

    while let notification = try session.nextNotification() {
        guard let carried = PaneTapeEventNotification<JSONValue>(
            method: notification.method,
            params: notification.params
        ) else { continue }
        // One stdout line per record, whatever the producer grouped into this notification:
        // the grouping is a wire economy, and nothing downstream of this renderer knows it
        // happened.
        for record in carried.records {
            guard try writePaneTapeRecord(transform(record), to: output) else {
                return .init(termination: .brokenPipe, capture: capture)
            }
            if case .end? = decodePaneTapeRecord(record) {
                return .init(termination: .end, capture: capture)
            }
        }
    }
    return .init(termination: .eof, capture: capture)
}

/// Words the shared writer's failure as this stream's own, so a tape that could not be
/// written says so rather than naming the writer.
private func writePaneTapeRecord(_ record: JSONValue, to descriptor: Int32) throws -> Bool {
    do {
        return try writeJsonLine(record, to: descriptor)
    } catch is JsonLineWriteError {
        throw PaneTapeStreamError.writeFailed
    }
}
