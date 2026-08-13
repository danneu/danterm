// Unbuffered JSON Lines renderer for pane-tape streams, finite and followed alike.
import Foundation
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
    case .snapshot, nil: return .incompleteCapture
    }
}

/// Reports malformed or failed tape traffic without coupling the renderer to CLI exit policy.
enum PaneTapeStreamError: Error, LocalizedError {
    case rpc(String)
    case malformedResponse
    case readFailed
    case lineTooLarge
    case writeFailed
    case incompleteCapture

    var errorDescription: String? {
        switch self {
        case .rpc(let message): return message
        case .malformedResponse: return "malformed response"
        case .readFailed: return "failed to read from DanTerm"
        case .lineTooLarge: return "response line too large"
        case .writeFailed: return "failed to write pane tape stream"
        case .incompleteCapture: return "DanTerm closed the connection before the tape ended"
        }
    }
}

/// Unwraps one tape conversation and writes each record directly to an output fd.
///
/// `transform` is applied to every unwrapped record before it is written, one record at a
/// time, which is what keeps a derived view from needing the whole recording in memory.
func renderPaneTapeStream(
    socket: Int32,
    output: Int32,
    requestId: String,
    transform: (JSONValue) throws -> JSONValue = { $0 }
) throws -> PaneTapeStreamOutcome {
    var capture: PaneTapeCaptureMode?
    while let line = try readPaneTapeLine(from: socket) {
        let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))

        if capture == nil, envelope["id"] == .string(requestId) {
            if let message = envelope["error"]?["message"]?.asString {
                throw PaneTapeStreamError.rpc(message)
            }
            // A capture this build does not know is malformed, not a follow. Failing open
            // here would apply the permissive ending rule to a stream that never claimed it.
            guard let start = envelope["result"],
                  let mode = start["capture"]?.asString
                      .flatMap(PaneTapeCaptureMode.init(rawValue:))
            else {
                throw PaneTapeStreamError.malformedResponse
            }
            guard try writePaneTapeRecord(transform(start), to: output) else {
                return .init(termination: .brokenPipe, capture: mode)
            }
            capture = mode
            continue
        }

        guard capture != nil,
              envelope["method"] == .string(Methods.paneTapeEvent),
              let record = envelope["params"]?["record"]
        else {
            continue
        }
        guard try writePaneTapeRecord(transform(record), to: output) else {
            return .init(termination: .brokenPipe, capture: capture)
        }
        if record["kind"] == .string("end") {
            return .init(termination: .end, capture: capture)
        }
    }
    return .init(termination: .eof, capture: capture)
}

private func readPaneTapeLine(from descriptor: Int32) throws -> String? {
    var data = Data()
    var byte = UInt8(0)
    while true {
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            Darwin.read(descriptor, buffer.baseAddress, 1)
        }
        if count == 0 {
            return data.isEmpty ? nil : String(data: data, encoding: .utf8)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw PaneTapeStreamError.readFailed
        }
        if byte == 0x0A {
            return String(data: data, encoding: .utf8)
        }
        data.append(byte)
        if data.count > 16 * 1024 * 1024 {
            throw PaneTapeStreamError.lineTooLarge
        }
    }
}

private func writePaneTapeRecord(_ record: JSONValue, to descriptor: Int32) throws -> Bool {
    let line = try encodeIpcLine(record)
    return try line.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EPIPE { return false }
                throw PaneTapeStreamError.writeFailed
            }
            guard written > 0 else {
                throw PaneTapeStreamError.writeFailed
            }
            offset += written
        }
        return true
    }
}
