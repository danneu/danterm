// Unbuffered JSON Lines renderer for `danterm roster --follow`.
//
// The app answers a `roster` request with the current roster and then pushes every later
// roster on the same connection until it ends. This file turns that one conversation into
// one whole roster per stdout line. It does not decode a roster: the wire encoding is the
// output contract, so a field this build does not know is passed through untouched.
//
// Not here: how a roster is built, and the one-shot `roster` form, which is an ordinary
// bounded request through the shared execution path.
import Foundation
import DanTermClient
import DanTermProtocol

/// Reports failed roster traffic without coupling the renderer to CLI exit policy.
enum RosterStreamError: Error, LocalizedError {
    case rpc(String)
    case closedBeforeRoster
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .rpc(let message): return message
        // The same sentence the one-shot path gives for a reply that never arrived: which
        // form the caller typed does not change what happened to the connection.
        case .closedBeforeRoster: return "DanTerm closed the connection"
        case .writeFailed: return "failed to write roster stream"
        }
    }
}

/// Renders one roster subscription, writing each whole roster directly to an output fd.
///
/// Returns at EOF, which is this stream's only success ending: the subscription lasts as
/// long as the connection, so the app closing it is the app stopping, and every roster up
/// to that moment was already written. A closed stdout ends the stream the same way,
/// because that is the consumer's own choice.
func renderRosterStream(
    session: DanTermClientSession,
    output: Int32,
    requestId: String
) throws {
    guard let response = try session.awaitReply(id: .string(requestId)) else {
        throw RosterStreamError.closedBeforeRoster
    }
    if let error = response.error {
        throw RosterStreamError.rpc(error.message)
    }
    guard try writeRoster(response.result ?? .null, to: output) else { return }

    while let notification = try session.nextNotification() {
        guard notification.method == Methods.rosterEvent,
              let params = notification.params
        else { continue }
        guard try writeRoster(params, to: output) else { return }
    }
}

/// Words the shared writer's failure as this stream's own.
private func writeRoster(_ roster: JSONValue, to descriptor: Int32) throws -> Bool {
    do {
        return try writeJsonLine(roster, to: descriptor)
    } catch is JsonLineWriteError {
        throw RosterStreamError.writeFailed
    }
}
