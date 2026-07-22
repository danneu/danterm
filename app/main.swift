// Application entry point: initializes libghostty, resolves explicit init or
// recovery state, then hands startup ownership to AppKit.
import Cocoa
import Darwin
import DanTermProtocol
import GhosttyKit

#if DANTERM_TERMINAL_CHARACTERIZATION
/// Publish the app process's resolved filesystem paths before terminal creation,
/// allowing the real-backend harness to reject any escape from its isolated run.
func writeTerminalCharacterizationPathProbe(to path: String) throws {
    let fileManager = FileManager.default
    let paths: [String: String] = [
        "home": NSHomeDirectory(),
        "applicationSupport": fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path,
        "caches": fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].path,
        "temporary": danTermTemporaryDirectoryURL(fileManager: fileManager).path,
        "config": DanTermConfigPaths.configFilePath(),
        "recovery": recoveryDirectoryURL().path,
        "socket": controlSocketPath().path,
        "replay": scrollbackReplayDirectoryURL().path,
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

// Restore variables are reserved for per-pane injection. Ghostty can only add
// surface overrides, so inherited values must be removed process-wide first.
for name in reservedRestoreEnvironmentVariableNames {
    unsetenv(name)
}

// Initialize ghostty -- must happen before anything else.
let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard rc == GHOSTTY_SUCCESS else {
    print("ghostty_init failed with code \(rc)")
    exit(1)
}

// Parse restore-related CLI arguments.
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

if initSnapshot == nil {
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
    NSApp.delegate = delegate
    return delegate
}
NSApp.run()
