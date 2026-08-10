// Application entry point: resolves explicit init or recovery state, then hands
// startup ownership to AppKit.
import Cocoa
import Darwin
import DanTermProtocol

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

#if DANTERM_TERMINAL_CHARACTERIZATION || DANTERM_TERMINAL_BENCHMARK
/// Publish the app process's resolved filesystem paths before terminal creation,
/// allowing the real-backend harness to reject any escape from its isolated run.
func writeTerminalCharacterizationPathProbe(to path: String) throws {
    let fileManager = FileManager.default
    let paths: [String: Any] = [
        "home": NSHomeDirectory(),
        "applicationSupport": fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path,
        "caches": fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].path,
        "temporary": danTermTemporaryDirectoryURL(fileManager: fileManager).path,
        "config": DanTermConfigPaths.configFilePath(),
        "recovery": recoveryDirectoryURL().path,
        "socket": controlSocketPath().path,
        "replay": scrollbackReplayDirectoryURL().path,
        "displayScale": NSScreen.main?.backingScaleFactor ?? 1.0,
    ]
    let data = try JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

// Session recovery: detect crash (stale lock file) and load last checkpoint.
// Carries the merged *validated* restore so the recovered structure is decoded
// and validated exactly once (here), not again at bootstrap.
var lastSessionSnapshot: ValidatedAppRestore? = nil
var previousSessionCrashed = false

if initSnapshot == nil, launchPolicy.startup == .promptForRecovery {
    // Crash detection: lock file exists = previous exit was unclean.
    // Don't delete it here — writeSessionLockFile() in applicationDidFinishLaunching
    // atomically overwrites it, so there's no gap where a startup crash would be
    // mistaken for a clean exit on the next launch.
    if readSessionLockFile() != nil {
        previousSessionCrashed = true
    }

    // Load last session from split checkpoint files.
    // Light has fresh structure; enriched has scrollback. Merge both when available.
    let lightData = try? Data(contentsOf: lightCheckpointURL())
    let enrichedData = try? Data(contentsOf: enrichedCheckpointURL())

    if let ld = lightData, let ed = enrichedData,
       let light = try? loadValidatedInitFile(from: ld),
       let enriched = try? loadValidatedInitFile(from: ed) {
        lastSessionSnapshot = mergeCheckpoints(light: light, enriched: enriched)
    } else if let ld = lightData, let light = try? loadValidatedInitFile(from: ld) {
        lastSessionSnapshot = light
    } else if let ed = enrichedData, let enriched = try? loadValidatedInitFile(from: ed) {
        lastSessionSnapshot = enriched
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate()
    delegate.initSnapshot = initSnapshot
    delegate.lastSessionSnapshot = lastSessionSnapshot
    delegate.previousSessionCrashed = previousSessionCrashed
    delegate.launchPolicy = launchPolicy
    NSApp.delegate = delegate
    return delegate
}
NSApp.run()
