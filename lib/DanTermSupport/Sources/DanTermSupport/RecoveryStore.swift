// Recovery-store side effects: the session-lock write/presence/delete I/O against the
// paths DanTermInstancePaths names. This is the FileManager/Data boundary that the
// pure snapshot/merge/validation policy in DanTermCore deliberately does NOT own --
// core decides what to persist (toSnapshot, mergeCheckpoints, the codec), this layer
// touches the disk. Where the files live is InstancePaths' business, not this file's:
// every entry point here takes the launch-resolved value, so no call site can invent
// a recovery directory of its own. Lives in DanTermSupport, not core, so core stays
// IO-free and unit-testable without a filesystem, and depends only on DanTermProtocol
// + Foundation -- never on DanTermCore (a core dependency would be the forbidden
// support->core edge), which is why SessionLock is defined here too.
import DanTermProtocol
import Foundation
import PrivateFile

/// The payload of the session lock file, written at launch and never read back.
///
/// Diagnostics only: it answers "which process, and when" for a human inspecting a
/// crashed instance's recovery directory. Nothing in production decodes it, and
/// nothing may start -- the crash decision belongs to the file's existence
/// (`sessionLockIsPresent`), so no change to this shape can make a crashed launch
/// look clean on the next start.
struct SessionLock: Encodable {
    let pid: Int32
    let startedAt: Date
}

// MARK: - Session Lock I/O
//
// The lock's contract is "present at launch means the previous exit was unclean", so
// the three helpers below deal in the file's existence, never its contents. The paths
// value says where the lock lives; the defaulted now/pid seams let a test freeze the
// clock and the process id. Those defaults drop the former `env: CoreEnv` parameter --
// a CoreEnv dependency would pull DanTermCore into this layer, the support->core edge
// the split forbids.

/// Write a session lock file at launch. Its presence at next launch means the
/// previous exit was unclean -- no PID liveness check needed.
///
/// Throws instead of swallowing an I/O error: a lock that was never created disables
/// crash detection for the whole run, so the caller has to be able to say so.
func writeSessionLockFile(
    paths: DanTermInstancePaths,
    now: Date = Date(),
    pid: Int32 = ProcessInfo.processInfo.processIdentifier
) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(SessionLock(pid: pid, startedAt: now))
    try PrivateFile.createDirectory(at: paths.recoveryDirectory)
    try PrivateFile.writeAtomically(data, to: paths.sessionLockFile)
}

/// Whether a session lock is on disk (true = the previous exit was unclean).
///
/// Only a confirmed "no such file" answers false. Every other lookup failure -- an
/// unsearchable or unreadable recovery directory, a regular file where that directory
/// belongs -- answers true, because a location we cannot inspect may well hold a lock,
/// and reporting a crash costs a prompt while missing one costs the session.
func sessionLockIsPresent(paths: DanTermInstancePaths) -> Bool {
    var info = stat()
    if lstat(paths.sessionLockFile.path, &info) == 0 { return true }
    return errno != ENOENT
}

/// Delete the session lock on clean termination.
func deleteSessionLockFile(paths: DanTermInstancePaths) {
    try? FileManager.default.removeItem(at: paths.sessionLockFile)
}
