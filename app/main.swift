// Application entry point: resolves explicit init or recovery state, then hands
// startup ownership to AppKit.
import Cocoa
import Darwin
import DanTermProtocol
import PrivateFile

/// Keeps the launcher-owned slot lock in the app while preventing pane children
/// from inheriting it and delaying slot reuse after the app process dies.
func configureDevelopmentSlotLock(arguments: [String]) throws {
    let prefix = "--development-slot-lock-fd="
    guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
    guard let descriptor = Int32(argument.dropFirst(prefix.count)), descriptor >= 0 else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

do {
    try configureDevelopmentSlotLock(arguments: CommandLine.arguments)
} catch {
    fputs("DanTerm: invalid development slot lock: \(error.localizedDescription)\n", stderr)
    exit(2)
}

// The one resolution of this process's identity-keyed paths. Everything below --
// the path probe, the recovery read, the delegate, and through it the runtime and
// the IPC server -- is handed this value instead of deriving a path of its own.
let launchInstancePaths = resolveLaunchInstancePaths()

// The one resolution of the config file this process owns, deliberately ahead of the
// path probe below and of every config read. A launch that named an unusable file
// stops here rather than quietly reading the user's own config.
let launchConfigURL: URL
do {
    launchConfigURL = try resolveLaunchConfigURL(arguments: CommandLine.arguments)
} catch {
    fputs("DanTerm: invalid config argument: \(error.localizedDescription)\n", stderr)
    exit(2)
}

// Launch's first fallible step, deliberately ahead of the `--init` file, the
// checkpoints, and every line of AppKit construction below: it reads the lock the
// previous launch may have left and claims this launch's own. Anything that crashes
// after this point leaves the lock behind for the next launch to find.
let sessionLock = claimSessionLock(paths: launchInstancePaths)

#if DANTERM_TERMINAL_CHARACTERIZATION || DANTERM_TERMINAL_BENCHMARK
/// Publish the app process's resolved filesystem paths before terminal creation,
/// allowing the real-backend harness to reject any escape from its isolated run.
func writeTerminalCharacterizationPathProbe(to path: String) throws {
    let paths: [String: Any] = [
        "home": NSHomeDirectory(),
        "applicationSupport": launchInstancePaths.applicationSupportRoot.path,
        "caches": launchInstancePaths.cachesRoot.path,
        "temporary": launchInstancePaths.temporaryRoot.path,
        "config": launchConfigURL.path,
        "recovery": launchInstancePaths.recoveryDirectory.path,
        "socket": launchInstancePaths.controlSocket.path,
        "replay": launchInstancePaths.scrollbackReplayDirectory.path,
        "displayScale": NSScreen.main?.backingScaleFactor ?? 1.0,
    ]
    let data = try JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted, .sortedKeys])
    try PrivateFile.writeAtomically(data, to: URL(fileURLWithPath: path))
}

if let path = ProcessInfo.processInfo.environment["DANTERM_TERMINAL_CHARACTERIZATION_PATH_PROBE"] {
    do {
        try writeTerminalCharacterizationPathProbe(to: path)
    } catch {
        print("[characterization] Failed to write path probe: \(error)")
        exit(1)
    }
}
#endif

// Restore variables are reserved for per-pane injection. A session can only add
// per-session overrides, so inherited values must be removed process-wide first.
for name in reservedRestoreEnvironmentVariableNames {
    unsetenv(name)
}

// Resolve explicit launch policy and parse restore-related CLI arguments.
let launchPolicy = AppLaunchPolicy(arguments: CommandLine.arguments)
var initSnapshot: AppModelSnapshot? = nil
do {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--init"), idx + 1 < args.count {
        let path = args[idx + 1]
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let loaded = try loadValidatedInitFile(from: data)
        initSnapshot = loaded.snapshot
        print("[init] Loaded snapshot from \(path)")
    }
} catch let error as AppInitFileLoadError {
    switch error {
    case .decodeFailed:
        print("[init] Failed to decode snapshot JSON. Using default startup.")
    case .unsupportedVersion(let version):
        print("[init] Unsupported version: \(version). Using default startup.")
    case .invalidSnapshot:
        print("[init] Snapshot validation failed. Using default startup.")
    }
    initSnapshot = nil
} catch {
    print("[init] Failed to load snapshot: \(error). Using default startup.")
    initSnapshot = nil
}

// Session recovery: load the previous session's checkpoints. The restore comes back
// decoded and validated, so the recovered structure is validated exactly once, at
// launch, and not again at bootstrap.
let launchRestore = loadLaunchCheckpoints(
    paths: launchInstancePaths,
    startup: launchPolicy.startup,
    hasInitSnapshot: initSnapshot != nil
)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate(instancePaths: launchInstancePaths, configURL: launchConfigURL)
    delegate.initSnapshot = initSnapshot
    delegate.lastSessionSnapshot = launchRestore
    delegate.previousSessionCrashed = sessionLock.previousSessionCrashed
    delegate.sessionLockClaimFailure = sessionLock.claimFailure
    delegate.launchPolicy = launchPolicy
    NSApp.delegate = delegate
    return delegate
}
NSApp.run()
