// JSON-RPC method names for server messages outside the client request catalog.
import Foundation

public enum Methods {
    public static let hello = "hello"
    /// Replaces hello when the server refuses a connection before service starts.
    public static let rejected = "rejected"
    public static let paneTapeEvent = "pane.tape.event"
    /// Carries one whole pane roster to a subscriber. Every event replaces the roster
    /// before it, so a client never merges and there is nothing to resynchronize.
    public static let rosterEvent = "roster.event"
}
