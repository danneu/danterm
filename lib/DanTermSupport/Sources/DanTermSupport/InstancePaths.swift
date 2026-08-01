// Identity-keyed paths for temporary process state shared by the app runtime and support tests.
import DanTermProtocol
import Foundation

/// Isolates disposable replay files so one instance's launch cleanup cannot erase another's.
func scrollbackReplayDirectoryURL(
    identity: DanTermInstanceIdentity,
    temporaryDirectory: URL
) -> URL {
    temporaryDirectory
        .appendingPathComponent("danterm-scrollback", isDirectory: true)
        .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
}

/// Removes only one identity's abandoned replay files while other live instances keep theirs.
func cleanupStaleScrollbackReplayDirectory(
    identity: DanTermInstanceIdentity,
    temporaryDirectory: URL,
    fileManager: FileManager = .default
) {
    let directory = scrollbackReplayDirectoryURL(
        identity: identity,
        temporaryDirectory: temporaryDirectory
    )
    try? fileManager.removeItem(at: directory)
}
