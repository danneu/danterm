// The unbuffered JSON Lines writer shared by every streaming CLI command.
//
// It exists on its own because more than one stream renderer needs it and none of them
// owns it: `pane tape` and `roster --follow` both write one whole JSON value per line to
// a raw descriptor, and both must survive an interrupted write and a consumer that walks
// away. What does not belong here is any stream's own policy -- which values are written,
// when a stream ends, or what an ending means.
import Foundation
import DanTermProtocol
import Darwin

/// Reports a write that failed for a reason the consumer did not choose.
///
/// A closed stdout is not one of these: the writer answers that with `false`, because
/// every stream treats it as the consumer ending the stream rather than as an error.
enum JsonLineWriteError: Error {
    case writeFailed
}

/// Writes one JSON value and its newline straight to `descriptor`, returning false when
/// the consumer closed its end.
///
/// `Darwin.write` rather than `FileHandle` or `print`: a followed stream is read line by
/// line as it happens, and any buffering layer would hold a line back until the next one
/// filled the buffer. A partial write is resumed, `EINTR` is retried, and `EPIPE` is the
/// consumer's own choice.
func writeJsonLine(_ value: JSONValue, to descriptor: Int32) throws -> Bool {
    let line = try encodeIpcLine(value)
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
                throw JsonLineWriteError.writeFailed
            }
            guard written > 0 else {
                throw JsonLineWriteError.writeFailed
            }
            offset += written
        }
        return true
    }
}
