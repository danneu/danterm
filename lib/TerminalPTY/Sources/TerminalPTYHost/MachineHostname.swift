// The single ambient read of this machine's name, shared by the app and the workflow harness.
//
// It lives here, in the PTY layer, rather than in `TerminalCore`: the core stays free of
// ambient reads, and a nil machine hostname at the core boundary keeps its deliberate
// meaning ("accept `localhost` only") instead of becoming an accident of who forgot to
// pass one. Every `machineHostname:` parameter down the PTY/session stack defaults to this,
// so no caller has to choose its own source -- which is how the two spellings of this
// machine's name diverged in the first place.
import Darwin

/// Namespace for the machine identity that OSC 7 reports are matched against.
public enum MachineHostname {
    /// The POSIX hostname from `gethostname(3)` -- byte-for-byte what `hostname(1)` prints
    /// and what fish/zsh/bash interpolate into their `file://<host>/...` cwd reports.
    /// Notably *not* `ProcessInfo.processInfo.hostName`, which returns the mDNS `.local`
    /// form that no shell ever sends. nil when the system cannot supply a name.
    public static var posix: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
