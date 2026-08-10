// Unbuffered JSON Lines renderer for long-lived pane-tape notification streams.
import Foundation
import DanTermProtocol
import Darwin

/// Distinguishes the clean ways a followed stream can stop for CLI orchestration and tests.
enum PaneTapeFollowTermination: Equatable {
    case end
    case eof
    case brokenPipe
}

/// Reports malformed or failed follow traffic without coupling the renderer to CLI exit policy.
enum PaneTapeFollowStreamError: Error, LocalizedError {
    case rpc(String)
    case malformedResponse
    case readFailed
    case lineTooLarge
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .rpc(let message): return message
        case .malformedResponse: return "malformed response"
        case .readFailed: return "failed to read from DanTerm"
        case .lineTooLarge: return "response line too large"
        case .writeFailed: return "failed to write pane tape stream"
        }
    }
}

/// Unwraps one followed JSON-RPC conversation and writes each record directly to an output fd.
func renderPaneTapeFollowStream(
    socket: Int32,
    output: Int32,
    requestId: String
) throws -> PaneTapeFollowTermination {
    var receivedStart = false
    while let line = try readPaneTapeFollowLine(from: socket) {
        let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))

        if receivedStart == false, envelope["id"] == .string(requestId) {
            if let message = envelope["error"]?["message"]?.asString {
                throw PaneTapeFollowStreamError.rpc(message)
            }
            guard let start = envelope["result"] else {
                throw PaneTapeFollowStreamError.malformedResponse
            }
            guard try writePaneTapeFollowRecord(start, to: output) else {
                return .brokenPipe
            }
            receivedStart = true
            continue
        }

        guard receivedStart,
              envelope["method"] == .string(Methods.paneTapeEvent),
              let record = envelope["params"]?["record"]
        else {
            continue
        }
        guard try writePaneTapeFollowRecord(record, to: output) else {
            return .brokenPipe
        }
        if record["kind"] == .string("end") {
            return .end
        }
    }
    return .eof
}

private func readPaneTapeFollowLine(from descriptor: Int32) throws -> String? {
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
            throw PaneTapeFollowStreamError.readFailed
        }
        if byte == 0x0A {
            return String(data: data, encoding: .utf8)
        }
        data.append(byte)
        if data.count > 16 * 1024 * 1024 {
            throw PaneTapeFollowStreamError.lineTooLarge
        }
    }
}

private func writePaneTapeFollowRecord(_ record: JSONValue, to descriptor: Int32) throws -> Bool {
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
                throw PaneTapeFollowStreamError.writeFailed
            }
            guard written > 0 else {
                throw PaneTapeFollowStreamError.writeFailed
            }
            offset += written
        }
        return true
    }
}
