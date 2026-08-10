// Menu command enablement policy shared by the app delegate and the UI-test
// harness. Keep this file free of AppKit view/runtime dependencies so command
// validation can be tested without standing up the app runtime.
import Foundation

/// App-level commands that remain valid even when the terminal window is not
/// visible; AppDelegate conforms so selector renames must update the allowlist.
@MainActor
@objc protocol WindowIndependentMenuActions {
    func showPreferences(_ sender: Any?)
    func quitApp(_ sender: Any?)
    func importState(_ sender: Any?)
    func exportState(_ sender: Any?)
    func openDanTermConfig(_ sender: Any?)
    func reloadConfig(_ sender: Any?)
    func installDantermInPath(_ sender: Any?)
}

/// Centralizes the menu actions that remain valid without a visible terminal
/// window; every other AppDelegate action is window-scoped by default.
enum MenuCommandPolicy {
    static let windowIndependentActions: Set<Selector> = [
        #selector(WindowIndependentMenuActions.showPreferences(_:)),
        #selector(WindowIndependentMenuActions.quitApp(_:)),
        #selector(WindowIndependentMenuActions.importState(_:)),
        #selector(WindowIndependentMenuActions.exportState(_:)),
        #selector(WindowIndependentMenuActions.openDanTermConfig(_:)),
        #selector(WindowIndependentMenuActions.reloadConfig(_:)),
        #selector(WindowIndependentMenuActions.installDantermInPath(_:)),
    ]

    static func isEnabled(action: Selector?, windowIsLive: Bool) -> Bool {
        guard let action else { return true }
        if windowIndependentActions.contains(action) { return true }
        return windowIsLive
    }
}
