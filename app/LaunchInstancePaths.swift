// The one place in the app that turns the running process into filesystem paths.
// It reads the ambient facts -- the main bundle's identity and the user-domain
// root directories -- exactly once, at launch, and everything downstream is handed
// the resolved value instead. Nothing else in `app/` or `lib/` may read those facts
// for a path, so a leaf cannot quietly derive a directory of its own.
import DanTermProtocol
import Foundation

/// Resolve DanTerm's process-temporary root, with a harness-only override
/// because macOS Foundation ignores a launched app's `TMPDIR` value.
func danTermTemporaryDirectoryURL(fileManager: FileManager = .default) -> URL {
    #if DANTERM_TERMINAL_CHARACTERIZATION || DANTERM_TERMINAL_BENCHMARK
    if let path = ProcessInfo.processInfo.environment["DANTERM_TERMINAL_CHARACTERIZATION_TEMP_ROOT"] {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
    return fileManager.temporaryDirectory
}

/// Build this process's instance paths from the bundle identity and the user's root
/// directories. Launch calls it once and hands the result down; a second call would
/// be a second answer to a question the process already settled.
func resolveLaunchInstancePaths(fileManager: FileManager = .default) -> DanTermInstancePaths {
    DanTermInstancePaths(
        identity: DanTermInstanceIdentity(bundle: .main),
        applicationSupportRoot: fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0],
        cachesRoot: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        temporaryRoot: danTermTemporaryDirectoryURL(fileManager: fileManager)
    )
}
