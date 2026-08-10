// Recovery-store side effects: the on-disk paths under
// ~/Library/Application Support/<bundle-id>/Recovery/ and the session-lock
// read/write/delete I/O. This is the FileManager/Data boundary that the pure
// snapshot/merge/validation policy in DanTermCore deliberately does NOT own --
// core decides what to persist (toSnapshot, mergeCheckpoints, the codec), this
// layer resolves where it lives and touches the disk. Lives in DanTermSupport,
// not core, so core stays IO-free and unit-testable without a filesystem. The
// production entry points are zero-arg (real dir/clock/pid computed here) so the
// app's call sites are byte-for-byte unchanged, while defaulted recoveryDir/now/pid
// seams let the round-trip test inject a temp dir + frozen clock + fixed pid.
// Depends only on DanTermProtocol + Foundation -- never on DanTermCore (a core
// dependency would be the forbidden support->core edge), which is why SessionLock
// is defined here too.
import DanTermProtocol
import Foundation

/// Written to ~/Library/Application Support/<bundle-id>/Recovery/session.json at launch
/// and deleted on clean exit. If this file exists at next launch, the previous exit
/// was unclean (crash or kill -9) and we prompt before restoring.
struct SessionLock: Codable {
    let pid: Int32
    let startedAt: Date
}

// MARK: - Recovery Paths
//
// Session persistence lives in
// ~/Library/Application Support/<bundle-id>/Recovery/:
//   last-light.json    -- frequent structural checkpoint (no scrollback, fixed 2s window)
//   last-enriched.json -- periodic full checkpoint (structure + scrollback, 60s timer)
//   session.json       -- lock file, written at launch and deleted on clean exit
//
// Namespacing by bundle ID isolates DanTerm.app (com.danneu.danterm) from
// DanTerm Dev.app (com.danneu.danterm-dev) so the dev build never restores
// from a prod session and vice versa. The identity parameter exists for
// tests; production code always takes the default.

func recoveryDirectoryURL(
    identity: DanTermInstanceIdentity = DanTermInstanceIdentity()
) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
}

func lightCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-light.json")
}

func enrichedCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-enriched.json")
}

func sessionLockURL(recoveryDir: URL = recoveryDirectoryURL()) -> URL {
    recoveryDir.appendingPathComponent("session.json")
}

// MARK: - Session Lock I/O
//
// All session lock serialization goes through these three helpers so the
// JSON encoder/decoder date strategy (.iso8601) is configured in one place.
// The defaulted recoveryDir/now/pid seams let tests point at a per-test temp
// dir, frozen clock, and fixed pid; production code omits them and gets the real
// Application Support recovery dir, wall-clock time, and process id. The
// defaults drop the former `env: CoreEnv` parameter -- a CoreEnv dependency would
// pull DanTermCore into this layer, the support->core edge the split forbids.

/// Write a session lock file at launch. Its presence at next launch means the
/// previous exit was unclean -- no PID liveness check needed.
func writeSessionLockFile(
    recoveryDir: URL = recoveryDirectoryURL(),
    now: Date = Date(),
    pid: Int32 = ProcessInfo.processInfo.processIdentifier
) {
    let lock = SessionLock(pid: pid, startedAt: now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(lock) else { return }
    let lockURL = sessionLockURL(recoveryDir: recoveryDir)
    try? FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
    try? data.write(to: lockURL, options: .atomic)
}

/// Read the session lock if it exists (non-nil = previous exit was unclean).
func readSessionLockFile(recoveryDir: URL = recoveryDirectoryURL()) -> SessionLock? {
    guard let data = try? Data(contentsOf: sessionLockURL(recoveryDir: recoveryDir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionLock.self, from: data)
}

/// Delete the session lock on clean termination.
func deleteSessionLockFile(recoveryDir: URL = recoveryDirectoryURL()) {
    try? FileManager.default.removeItem(at: sessionLockURL(recoveryDir: recoveryDir))
}
