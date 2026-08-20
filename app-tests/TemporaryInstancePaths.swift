// The one place app tests get an instance-paths value. Every runtime and every IPC
// server a test builds is rooted here, so no test can write a checkpoint, a lock, an
// audit line, or a socket into the user's real Application Support or Caches tree.
import DanTermProtocol
import Foundation
@testable import DanTerm

/// Roots one test's identity-keyed paths under a disposable directory it owns.
///
/// Nothing is created on disk: the production writers make their own directories, so
/// a test that never writes leaves nothing behind, and a test that does writes only
/// under `rootURL`.
///
/// The root sits directly under `/tmp` with a short name because the control socket
/// is derived from it, and a Unix socket path may not exceed 104 bytes. The identity
/// is short for the same reason, and is deliberately not a real DanTerm identity: no
/// test should be able to reach a production or development instance's files.
struct TemporaryInstancePaths {
    let rootURL: URL
    let paths: DanTermInstancePaths

    var socketURL: URL { paths.controlSocket }

    /// A path inside the fixture for a config file that deliberately does not exist,
    /// so a runtime under test loads defaults instead of the user's real config.
    var absentConfigURL: URL { rootURL.appendingPathComponent("absent-config.json") }

    init() {
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("dt-\(UUID().uuidString)", isDirectory: true)
        paths = DanTermInstancePaths(
            identity: DanTermInstanceIdentity(bundleIdentifier: "dt.test"),
            applicationSupportRoot: rootURL.appendingPathComponent("as", isDirectory: true),
            cachesRoot: rootURL.appendingPathComponent("ca", isDirectory: true),
            temporaryRoot: rootURL.appendingPathComponent("tmp", isDirectory: true)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
