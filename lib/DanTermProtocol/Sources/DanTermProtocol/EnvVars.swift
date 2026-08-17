// Shared environment variable names used by the DanTerm GUI and CLI.
import Foundation

public enum EnvVars {
    public static let flag = "DANTERM"
    public static let sock = "DANTERM_SOCK"
    public static let pane = "DANTERM_PANE"
    /// Seconds the CLI waits on its control socket. Supplied by the caller, never by
    /// DanTerm: it is the one name here that is an input to the CLI rather than a fact
    /// DanTerm exports about a pane.
    public static let socketTimeout = "DANTERM_SOCKET_TIMEOUT"
}
