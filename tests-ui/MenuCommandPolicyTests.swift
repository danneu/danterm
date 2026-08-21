// Behavioral tests for the standalone menu command policy used by AppDelegate.
// The cases pin default-deny terminal command gating without compiling the full
// app runtime into the UI harness.
import Foundation
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func menuCommandPolicyTests() async {
    print("MenuCommandPolicy")

    await uiTest("terminal action follows window liveness") {
        let closePane = Selector(("closePane:"))

        try uiExpect(
            !MenuCommandPolicy.isEnabled(action: closePane, windowIsLive: false),
            "terminal action should be disabled without a live window"
        )
        try uiExpect(
            MenuCommandPolicy.isEnabled(action: closePane, windowIsLive: true),
            "terminal action should be enabled with a live window"
        )
    }

    await uiTest("window-independent app action ignores window liveness") {
        let preferences = #selector(WindowIndependentMenuActions.showPreferences(_:))

        try uiExpect(
            MenuCommandPolicy.isEnabled(action: preferences, windowIsLive: false),
            "app action should stay enabled without a live window"
        )
        try uiExpect(
            MenuCommandPolicy.isEnabled(action: preferences, windowIsLive: true),
            "app action should stay enabled with a live window"
        )
    }

    await uiTest("unknown action is window-scoped by default") {
        let brandNewCommand = Selector(("brandNewCommand:"))

        try uiExpect(
            !MenuCommandPolicy.isEnabled(action: brandNewCommand, windowIsLive: false),
            "unknown action should be disabled without a live window"
        )
    }

    await uiTest("nil action is enabled") {
        try uiExpect(
            MenuCommandPolicy.isEnabled(action: nil, windowIsLive: false),
            "nil action should stay enabled for separators and submenu parents"
        )
    }
}
