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

// Parse --init <path> argument
var initSnapshot: AppModelSnapshot? = nil
do {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--init"), idx + 1 < args.count {
        let path = args[idx + 1]
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        guard initFile.version == 1 else {
            print("[init] Unsupported version: \(initFile.version)")
            throw SnapshotValidationError(message: "unsupported version")
        }
        initSnapshot = initFile.model
        print("[init] Loaded snapshot from \(path)")
    }
} catch {
    print("[init] Failed to load snapshot: \(error). Using default startup.")
    initSnapshot = nil
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
delegate.initSnapshot = initSnapshot
NSApp.delegate = delegate
NSApp.run()
