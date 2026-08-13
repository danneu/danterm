// The synchronous system witness that classifies one child-exit probe without
// owning retry policy or mutable lifecycle state.
import Darwin
import PaneProcessLifecycle

/// Reports the complete outcome of one nonblocking child-exit probe.
package enum TerminalPTYChildExitProbeResult: Sendable {
    case exited(ChildExitStatus)
    case notYetWaitable
    case failed
}

/// Lets the PTY owner substitute a genuinely nondeterministic wait boundary in package tests.
package protocol TerminalPTYChildExitProbing: Sendable {
    func probe(_ leaderPID: pid_t) -> TerminalPTYChildExitProbeResult
}

/// Keeps the production witness stateless and identical to the direct waitid operation.
package struct SystemTerminalPTYChildExitProbe: TerminalPTYChildExitProbing {
    package init() {}

    package func probe(_ leaderPID: pid_t) -> TerminalPTYChildExitProbeResult {
        var info = siginfo_t()
        let rc = waitid(P_PID, id_t(leaderPID), &info, WEXITED | WNOHANG | WNOWAIT)
        guard rc == 0, info.si_pid == leaderPID else {
            if rc == 0, info.si_pid == 0 {
                return .notYetWaitable
            }
            return .failed
        }
        switch info.si_code {
        case CLD_EXITED:
            return .exited(.exited(info.si_status))
        default:
            return .exited(.signaled(info.si_status))
        }
    }
}
