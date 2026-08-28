// The injected system boundary for enumerating and signaling members of one PTY session,
// plus the pure per-stage value that prevents duplicate signals without losing late members.
import Darwin
import PaneProcessLifecycle

/// Names one process that the census witness found in a specific session.
package struct TerminalPTYSessionMember: Hashable, Sendable {
    /// The process identifier used to deduplicate signals within one ladder stage.
    package let pid: pid_t
}

/// Carries the session identity and every member that one successful enumeration proved.
package struct TerminalPTYSessionCensus: Sendable {
    package let sessionID: pid_t
    package let members: [TerminalPTYSessionMember]

    /// Lets a census witness return one proof value without making callers re-derive membership.
    package init(sessionID: pid_t, memberPIDs: [pid_t]) {
        self.sessionID = sessionID
        members = memberPIDs.map(TerminalPTYSessionMember.init(pid:))
    }
}

/// Owns the nondeterministic session enumeration and every signal sent from its result.
package protocol TerminalPTYSessionCensusing: Sendable {
    func census(sessionID: pid_t) -> TerminalPTYSessionCensus?
    func signal(_ signal: Int32, to member: TerminalPTYSessionMember)
}

/// Tracks which members received the current ladder stage while admitting later arrivals.
package struct TerminalPTYSessionSweep: Sendable {
    package private(set) var stage: TeardownStage
    private var signaledPIDs: Set<pid_t> = []

    package init(stage: TeardownStage) {
        self.stage = stage
    }

    /// Starts a fresh signal set when the reducer advances to a new ladder stage.
    package mutating func advance(to stage: TeardownStage) {
        guard stage != self.stage else { return }
        self.stage = stage
        signaledPIDs.removeAll(keepingCapacity: true)
    }

    /// Returns and records only members that this stage has not signaled before.
    package mutating func takeUnsignaledMembers(
        from census: TerminalPTYSessionCensus
    ) -> [TerminalPTYSessionMember] {
        census.members.filter { signaledPIDs.insert($0.pid).inserted }
    }
}

/// Decodes Darwin's byte-count result and filters it into one session proof value.
package struct SystemTerminalPTYSessionCensus: TerminalPTYSessionCensusing {
    package init() {}

    package func census(sessionID: pid_t) -> TerminalPTYSessionCensus? {
        let reportedByteCapacity = Int(proc_listallpids(nil, 0))
        guard reportedByteCapacity >= 0 else { return nil }
        let pidSize = MemoryLayout<pid_t>.size
        var capacity = max(reportedByteCapacity / pidSize, 256) + 64
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = pids.withUnsafeMutableBytes { buffer in
                Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count)))
            }
            guard let decoded = Self.decodePIDs(byteCount: byteCount, buffer: pids) else {
                if byteCount == pids.count * pidSize {
                    capacity *= 2
                    continue
                }
                return nil
            }
            return TerminalPTYSessionCensus(
                sessionID: sessionID,
                memberPIDs: decoded.filter { $0 > 0 && getsid($0) == sessionID }
            )
        }
        return nil
    }

    package func signal(_ signal: Int32, to member: TerminalPTYSessionMember) {
        _ = kill(member.pid, signal)
    }

    /// Treats the syscall result as bytes and rejects a full buffer as possibly truncated.
    package static func decodePIDs(byteCount: Int, buffer: [pid_t]) -> [pid_t]? {
        guard byteCount >= 0, byteCount < buffer.count * MemoryLayout<pid_t>.size else {
            return nil
        }
        return Array(buffer.prefix(byteCount / MemoryLayout<pid_t>.size))
    }
}
