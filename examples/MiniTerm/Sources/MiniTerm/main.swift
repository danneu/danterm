// Process entry: one window holding one MiniTerminalView, and the resolution of
// the one file the engine cannot supply for itself -- the PTY bootstrap helper.
import Cocoa

/// Finds the `PTYSessionBootstrap` helper the PTY host execs to start a child.
///
/// DanTerm ships it inside its .app bundle; a plain SwiftPM executable has no
/// bundle, so this looks beside the running binary and then falls back to the
/// TerminalPTY package's own build directory. This is the sharpest edge of the
/// embedding story: the engine takes the path as a string and leaves finding it
/// to the caller.
func resolveBootstrapExecutable() -> String? {
    let candidates = [
        ProcessInfo.processInfo.environment["MINITERM_BOOTSTRAP"],
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("PTYSessionBootstrap")
            .path,
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Owns the window for the process lifetime and quits when it closes.
final class MiniTermAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    // NSApplicationDelegate: called once after the app finishes launching.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bootstrap = resolveBootstrapExecutable() else {
            FileHandle.standardError.write(Data("""
            MiniTerm: cannot find PTYSessionBootstrap.
            Build it and point MINITERM_BOOTSTRAP at it:
              swift build --package-path ../../lib/TerminalPTY --product PTYSessionBootstrap

            """.utf8))
            NSApp.terminate(nil)
            return
        }
        guard let view = MiniTerminalView(bootstrapExecutable: bootstrap, fontSize: 13) else {
            FileHandle.standardError.write(Data("MiniTerm: could not start a pane.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MiniTerm"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    // NSApplicationDelegate: the example owns exactly one window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MiniTermAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
