// The identity PTY tests hand a host when the test is about something else entirely.
import TerminalCore

extension TerminalProductIdentity {
    /// A host needs an identity because no embedder may go unnamed, but a test about
    /// lifecycle or geometry has no product of its own. One shared value keeps those
    /// tests from inventing a name each, and keeps "DanTerm" out of them.
    public static let test = TerminalProductIdentity(name: "TestTerm", version: "test")
}
