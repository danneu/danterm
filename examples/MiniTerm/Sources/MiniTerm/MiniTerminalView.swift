// The whole embedding surface of DanTerm's terminal engine in one AppKit view:
// it owns a pane session, draws the frames the session plans, and forwards key
// and resize events back. Anything DanTerm's own host view does beyond this --
// selection, links, search, the pane tape, scrollbars -- is deliberately absent.
import Cocoa
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning

/// Hosts one terminal pane: engine in, pixels out, keys back.
final class MiniTerminalView: NSView {
    private let controller: TerminalPaneSessionController
    private var metrics: TerminalRenderMetrics
    private var appliedDimensions: TerminalDimensions?
    /// Held because `TerminalRenderMetrics` does not publish the font size it was
    /// built from, so re-deriving metrics at a new display scale needs the input again.
    private let fontSize: CGFloat

    /// Fails only when the PTY cannot be spawned; every other input is a value
    /// the caller states outright, which is the point of the example.
    init?(bootstrapExecutable: String, fontSize: CGFloat) {
        guard let metrics = TerminalRenderMetrics(displayScale: 2, fontSize: fontSize) else {
            return nil
        }
        self.metrics = metrics
        self.fontSize = fontSize

        let configuration = assembleTerminalPaneLaunch(
            request: TerminalPaneLaunchRequest(
                workingDirectory: FileManager.default.currentDirectoryPath,
                command: nil,
                launchCommand: nil,
                environment: []
            ),
            facts: MiniTerminalView.launchFacts()
        )
        guard let host = try? TerminalPTYHost(
            launchInput: configuration.launchInput,
            bootstrapExecutable: bootstrapExecutable,
            programVersion: "MiniTerm"
        ) else {
            return nil
        }
        controller = TerminalPaneSessionController(host: host, theme: .dark)

        super.init(frame: .zero)

        controller.onFrame = { [weak self] _ in self?.needsDisplay = true }
        controller.onSessionEnded = { _ in NSApp.terminate(nil) }
        controller.setRenderingAvailable(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MiniTerm builds its view in code") }

    /// Reads the ambient facts the engine refuses to read for itself. DanTerm
    /// resolves these from its bundle and account database; here they are the
    /// plainest defaults that still launch a login shell.
    private static func launchFacts() -> TerminalPaneLaunchFacts {
        let environment = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { EnvironmentEntry(name: $0.key, value: $0.value) }
        let home = environment.first { $0.name == "HOME" }?.value
        let shell = environment.first { $0.name == "SHELL" }?.value
        return TerminalPaneLaunchFacts(
            accountShell: shell,
            executablePaths: ["/bin/zsh", "/bin/bash", "/bin/sh"],
            homeDirectory: home,
            accessibleDirectories: [FileManager.default.currentDirectoryPath, home].compactMap { $0 },
            inheritedEnvironment: environment,
            localeFallback: "en_US.UTF-8",
            terminalProgramVersion: "MiniTerm",
            shellIntegrationDirectory: FileManager.default.currentDirectoryPath
        )
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let plan = controller.currentPlan,
              let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }
        drawRenderFrame(plan, metrics: metrics, in: context)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor,
           let rescaled = TerminalRenderMetrics(displayScale: scale, fontSize: fontSize) {
            metrics = rescaled
        }
        window?.makeFirstResponder(self)
        controller.sendFocus(true, origin: nil)
        applyGrid()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyGrid()
    }

    /// Resends geometry only when the derived grid actually changes, so a
    /// point-space resize inside one cell does not churn the child's SIGWINCH.
    private func applyGrid() {
        guard let dimensions = terminalGridDimensions(
            size: TerminalPointSize(width: bounds.width, height: bounds.height),
            cellSize: TerminalPointSize(
                width: metrics.cellSize.width,
                height: metrics.cellSize.height
            )
        ), dimensions != appliedDimensions else {
            return
        }
        appliedDimensions = dimensions
        controller.setGridDimensions(dimensions, pinned: false)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = MiniTerminalView.key(for: event) else { return }
        controller.sendKey(key, modifiers: MiniTerminalView.modifiers(for: event), origin: nil)
    }

    /// Maps the subset of AppKit key events a shell session needs. DanTerm's own
    /// mapping is far larger; this covers what a person types to prove the seam.
    private static func key(for event: NSEvent) -> TerminalInputKey? {
        switch event.keyCode {
        case 36: return .returnKey
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }
        return .character(scalar)
    }

    private static func modifiers(for event: NSEvent) -> TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
