// The reading side of `roster.event`: one notification carrying one whole roster.
//
// It is a separate type rather than a case of the tape reader because the two share only
// the socket. What a roster means, and how it is encoded, belongs to DanTermProtocol's
// PaneRoster; this file only says which notification carries one.
import Foundation
import DanTermProtocol

/// One `roster.event` notification: the complete pane roster as the server sent it.
///
/// Returns nil for a notification of another method, so a client holding one connection
/// for both the tape stream and the roster subscription can offer each frame to every
/// decoder and let the one that owns it claim it.
public struct PaneRosterNotification: Equatable, Sendable {
    public let roster: PaneRoster

    /// Reads the roster out of a notification, or answers nil when this is not one.
    public init?(method: String, params: JSONValue?) {
        guard method == Methods.rosterEvent,
              let params,
              let roster = PaneRoster(jsonValue: params)
        else { return nil }
        self.roster = roster
    }
}
