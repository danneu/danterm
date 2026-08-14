// JSON-RPC method names for server messages outside the client request catalog.
import Foundation

public enum Methods {
    public static let hello = "hello"
    /// Replaces hello when the server refuses a connection before service starts.
    public static let rejected = "rejected"
    public static let paneTapeEvent = "pane.tape.event"
}
