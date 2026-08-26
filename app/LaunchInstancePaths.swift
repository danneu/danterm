// The one place in the app that turns the running process into filesystem paths.
// It reads the ambient facts -- the main bundle's identity and the user-domain
// root directories -- exactly once, at launch, and everything downstream is handed
// the resolved value instead. Nothing else in `app/` or `lib/` may read those facts
// for a path, so a leaf cannot quietly derive a directory of its own.
//
// The config file is resolved here too, from the launch arguments, but it is a value
// of its own rather than a field on the instance paths: every path that value yields
// is keyed by the instance identity, and the config file deliberately is not --
// production and the canonical dev app are two identities that read one file.
import DanTermProtocol
import Foundation

/// The launch argument that names the config file this process owns.
let launchConfigArgument = "--config"

/// Why a launch could not decide which config file it owns.
///
/// Both cases refuse the launch instead of falling back to the standard file: a
/// fallback would point a harness or a pool slot at the user's own config, which is
/// exactly what naming the file at launch removes.
enum LaunchConfigArgumentError: LocalizedError, Equatable {
    case missingValue
    case repeated

    var errorDescription: String? {
        switch self {
        case .missingValue: "\(launchConfigArgument) needs a file path."
        case .repeated: "\(launchConfigArgument) was given more than once."
        }
    }
}

/// Decide which config file this launch owns: the `--config` argument when the launch
/// names one, otherwise the standard per-user file. Launch calls it once, ahead of
/// everything that reads config, and hands the result down.
func resolveLaunchConfigURL(
    arguments: [String],
    home: String = NSHomeDirectory()
) throws -> URL {
    let named = arguments.indices.filter { arguments[$0] == launchConfigArgument }
    guard let index = named.first else {
        return URL(fileURLWithPath: DanTermConfigPaths.standardConfigFilePath(home: home))
    }
    guard named.count == 1 else { throw LaunchConfigArgumentError.repeated }
    // The next token is the path. Another argument in that position means the caller
    // dropped the value, so treat it as absent rather than owning a file named `--fresh`.
    guard index + 1 < arguments.count else { throw LaunchConfigArgumentError.missingValue }
    let value = arguments[index + 1]
    guard value.isEmpty == false, value.hasPrefix("--") == false else {
        throw LaunchConfigArgumentError.missingValue
    }
    return URL(fileURLWithPath: value)
}

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
