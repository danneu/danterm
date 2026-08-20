// Recovery-store side effects: the session-lock read/write/delete I/O against the
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

/// Written to ~/Library/Application Support/<bundle-id>/Recovery/session.json at launch
/// and deleted on clean exit. If this file exists at next launch, the previous exit
/// was unclean (crash or kill -9) and we prompt before restoring.
struct SessionLock: Codable {
    let pid: Int32
    let startedAt: Date
}

// MARK: - Session Lock I/O
//
// All session lock serialization goes through these three helpers so the
// JSON encoder/decoder date strategy (.iso8601) is configured in one place.
// The paths value says where the lock lives; the defaulted now/pid seams let a
// test freeze the clock and the process id. Those defaults drop the former
// `env: CoreEnv` parameter -- a CoreEnv dependency would pull DanTermCore into
// this layer, the support->core edge the split forbids.

/// Write a session lock file at launch. Its presence at next launch means the
/// previous exit was unclean -- no PID liveness check needed.
func writeSessionLockFile(
    paths: DanTermInstancePaths,
    now: Date = Date(),
    pid: Int32 = ProcessInfo.processInfo.processIdentifier
) {
    let lock = SessionLock(pid: pid, startedAt: now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(lock) else { return }
    try? FileManager.default.createDirectory(
        at: paths.recoveryDirectory,
        withIntermediateDirectories: true
    )
    try? data.write(to: paths.sessionLockFile, options: .atomic)
}

/// Read the session lock if it exists (non-nil = previous exit was unclean).
func readSessionLockFile(paths: DanTermInstancePaths) -> SessionLock? {
    guard let data = try? Data(contentsOf: paths.sessionLockFile) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionLock.self, from: data)
}

/// Delete the session lock on clean termination.
func deleteSessionLockFile(paths: DanTermInstancePaths) {
    try? FileManager.default.removeItem(at: paths.sessionLockFile)
}
