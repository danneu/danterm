import Cocoa
import GhosttyKit

// Resolve the user's login shell environment. When launched from Finder,
// the process inherits a minimal PATH (/usr/bin:/bin) from launchd.
// We spawn a login shell to get the full environment (nix, homebrew, etc.)
// and apply it to our process so child shells inherit the correct PATH.
do {
    // Use the user's login shell (from directory services / SHELL env var).
    // Falls back to /bin/zsh (macOS default since 10.15).
    let shell = ProcessInfo.processInfo.environment["SHELL"]
        ?? String(cString: getpwuid(getuid())!.pointee.pw_shell)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: shell)
    task.arguments = ["-l", "-c", "env"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in output.split(separator: "\n") {
        guard let eqIdx = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eqIdx])
        let value = String(line[line.index(after: eqIdx)...])
        setenv(key, value, 1)
    }
}

// Initialize ghostty — must happen before anything else.
let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard rc == GHOSTTY_SUCCESS else {
    print("ghostty_init failed with code \(rc)")
    exit(1)
}

// Parse restore-related CLI arguments.
var initSnapshot: AppModelSnapshot? = nil
var restoreBehavior = RestoreCommandBehavior.prefill
do {
    let args = CommandLine.arguments
    restoreBehavior = restoreCommandBehavior(from: args)
    if let idx = args.firstIndex(of: "--restore-commands"), idx + 1 < args.count {
        let value = args[idx + 1]
        if value != RestoreCommandBehavior.prefill.rawValue && value != RestoreCommandBehavior.execute.rawValue {
            print("[init] Unknown --restore-commands value '\(value)'; defaulting to prefill")
        }
    }
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
var lastSessionSnapshot: AppModelSnapshot? = nil
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
        lastSessionSnapshot = mergeCheckpoints(light: light.snapshot, enriched: enriched.snapshot)
    } else if let ld = lightData, let light = try? loadValidatedInitFile(from: ld) {
        lastSessionSnapshot = light.snapshot
    } else if let ed = enrichedData, let enriched = try? loadValidatedInitFile(from: ed) {
        lastSessionSnapshot = enriched.snapshot
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate()
    delegate.initSnapshot = initSnapshot
    delegate.restoreCommandBehavior = restoreBehavior
    delegate.lastSessionSnapshot = lastSessionSnapshot
    delegate.previousSessionCrashed = previousSessionCrashed
    NSApp.delegate = delegate
    return delegate
}
NSApp.run()
