// DanTerm-owned AppKit boundary for process-wide terminal backends and stable
// per-pane sessions. Backend-specific handles, bytes, grids, and rendering stay out.
import Cocoa
import DanTermProtocol

/// Selects temporary Ghostty fallback polling or mutation-driven Swift recovery.
enum TerminalRecoveryScheduling {
    case periodicFallback
    case eventDriven
}

/// Scrollbar position reported by a terminal session in logical terminal rows.
struct TerminalScrollPosition: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
}

/// View-local terminal state consumed synchronously by the native scroll chrome.
struct TerminalSessionState: Equatable {
    let scrollbarEnabled: Bool
    let cellHeight: CGFloat
    let scrollPosition: TerminalScrollPosition?
}

/// Receives main-actor session state without routing view-only data through AppModel.
@MainActor
protocol TerminalSessionStateObserver: AnyObject {
    func terminalSessionStateDidChange(_ state: TerminalSessionState)
}

/// Gates both terminal callback channels at the session teardown boundary.
@MainActor
final class TerminalSessionCallbackGate {
    var onEvent: ((TerminalSessionEvent) -> Void)?
    weak var stateObserver: (any TerminalSessionStateObserver)?
    private(set) var isActive = true

    func emit(_ event: TerminalSessionEvent) {
        guard isActive else { return }
        onEvent?(event)
    }

    func emit(_ state: TerminalSessionState) {
        guard isActive else { return }
        stateObserver?.terminalSessionStateDidChange(state)
    }

    func tearDown() {
        isActive = false
        onEvent = nil
        stateObserver = nil
    }
}

/// Inputs needed to create one terminal session without exposing adapter handles.
struct TerminalSessionRequest {
    let shellIntegrationToken: String
    let workingDirectory: String?
    let command: String?
    let launchCommand: String?
    let waitAfterCommand: Bool
    let restoreCommandBehavior: RestoreCommandBehavior
    let environment: [(String, String)]
}

/// Stable per-pane terminal owner mounted and reparented by the AppKit reconciler.
@MainActor
protocol TerminalSession: AnyObject {
    var hostView: NSView { get }
    var paneWrapper: PaneWrapperView? { get set }
    var state: TerminalSessionState { get }
    var stateObserver: (any TerminalSessionStateObserver)? { get set }
    var onEvent: ((TerminalSessionEvent) -> Void)? { get set }
    var onPrimaryHistoryMutation: ((String) -> Void)? { get set }
    var hasSelection: Bool { get }

    func sendText(_ text: String)
    func sendInputText(_ text: String)
    func sendInputKey(_ key: KeyName, modifiers: KeyMods)
    func setFocused(_ focused: Bool)
    func setVisible(_ visible: Bool)
    func setDisplayID(_ displayID: UInt32)
    func setScrollbarEnabled(_ enabled: Bool)
    func refreshBackingProperties()
    func applyTheme(_ themeName: String)
    func clearTheme()
    func startSearch()
    func setSearchNeedle(_ needle: String)
    func navigateSearch(_ direction: SearchDirection)
    func endSearch()
    func readViewportText() -> String?
    func readFullHistoryText() -> String?
    /// Reads persistent primary history without changing pane-read active-screen semantics.
    func readPrimaryHistoryText() -> String?
    func scroll(toRow row: Int)
    func copySelection()
    func pasteClipboard()
    func requestClose()
    func setFocusBorder(_ focused: Bool, hasBell: Bool)
    /// Fences accepted terminal mutations before the final recovery capture.
    func fenceForApplicationExit()
    func tearDown()
}

/// Process-wide terminal factory and app/config operations consumed by DanTerm.
@MainActor
protocol TerminalBackend: AnyObject {
    var isReady: Bool { get }
    var onEvent: ((TerminalBackendEvent) -> Void)? { get set }
    var preferences: GhosttyPrefs { get }
    var configFilePath: String? { get }
    var recoveryScheduling: TerminalRecoveryScheduling { get }

    func createSession(_ request: TerminalSessionRequest) -> (any TerminalSession)?
    func setAppFocused(_ focused: Bool)
    func reloadConfig()
    /// Runs the backend's bounded process teardown after the final checkpoint is captured.
    func terminateForApplicationExit()
}

extension TerminalBackend {
    /// Gives backends a final synchronous process-lifetime teardown hook during orderly exit.
    func terminateForApplicationExit() {}
}
