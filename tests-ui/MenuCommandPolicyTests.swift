// Behavioral tests for the standalone menu command policy used by AppDelegate.
// The cases pin default-deny terminal command gating without compiling the full
// app runtime into the UI harness.
import Cocoa
import DanTermProtocol
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

    await uiTest("catalog defaults project to visible and hidden menu equivalents") {
        let items = CommandMenuItemFactory.items(for: commandDescriptor(id: "view.font-increase"))

        try uiExpect(items.count == 2, "both default chords should produce menu items")
        try uiExpect(items[0].title == "Increase Font Size", "catalog title should label the visible item")
        try uiExpect(items[0].keyEquivalent == "+", "primary chord should use its AppKit key equivalent")
        try uiExpect(items[0].keyEquivalentModifierMask == [.command], "plus glyph should preserve the existing AppKit mask")
        try uiExpect(!items[0].isHidden, "primary chord should remain visible")
        try uiExpect(items[1].keyEquivalent == "=", "alternate chord should keep its own equivalent")
        try uiExpect(items[1].isHidden, "alternate chord should use a hidden twin")
        try uiExpect(items[1].allowsKeyEquivalentWhenHidden, "hidden twin should still dispatch")
        try uiExpect(
            items.allSatisfy { $0.action == #selector(ConfigurableMenuCommandTarget.performConfiguredCommand(_:)) },
            "every catalog item should use the shared dispatcher"
        )
        try uiExpect(
            items.allSatisfy { $0.representedObject as? String == "view.font-increase" },
            "every catalog item should carry its stable action id"
        )
    }

    await uiTest("catalog scope keeps configurable application commands available") {
        try uiExpect(
            MenuCommandPolicy.isEnabled(commandID: "app.open-config", windowIsLive: false),
            "application-scoped catalog commands should work without a live window"
        )
        try uiExpect(
            !MenuCommandPolicy.isEnabled(commandID: "tab.new", windowIsLive: false),
            "window-scoped catalog commands should still require a live window"
        )
    }

    await uiTest("fixed App-menu items dispatch through their own selectors") {
        // Intent: Import State, Export State, Settings, and Install danterm in PATH are plain
        //   menu items -- their own selector, no configurable-command identity, and Settings
        //   alone owns cmd+, as a fixed key equivalent.
        // Why it exists: they left the keybinding catalog, so nothing else proves they still
        //   appear, still dispatch, and stay enabled with no live window.
        // Scenario: spec-first -- the App menu as the delegate builds it at launch.
        let appMenu = AppDelegate.makeAppMenu()
        let fixed: [(String, Selector)] = [
            ("Import State...", #selector(WindowIndependentMenuActions.importState(_:))),
            ("Export State...", #selector(WindowIndependentMenuActions.exportState(_:))),
            ("Settings...", #selector(WindowIndependentMenuActions.showPreferences(_:))),
            ("Install danterm Command in PATH", #selector(WindowIndependentMenuActions.installDantermInPath(_:))),
        ]

        for (title, selector) in fixed {
            guard let item = appMenu.items.first(where: { $0.title == title }) else {
                throw UITestFailure(message: "App menu should keep \(title)")
            }
            try uiExpect(item.action == selector, "\(title) should use its own selector")
            try uiExpect(item.representedObject == nil, "\(title) should carry no command identity")
            try uiExpect(
                MenuCommandPolicy.isEnabled(action: item.action, windowIsLive: false),
                "\(title) should stay enabled without a live window"
            )
        }

        let titles = appMenu.items.map(\.title)
        let order = fixed.map(\.0).compactMap { titles.firstIndex(of: $0) }
        try uiExpect(order.count == fixed.count && order == order.sorted(),
                     "the four fixed items should keep their App-menu order")

        guard let settings = appMenu.items.first(where: { $0.title == "Settings..." }) else {
            throw UITestFailure(message: "App menu should keep Settings...")
        }
        try uiExpect(settings.keyEquivalent == ",", "Settings should own the comma key equivalent")
        try uiExpect(settings.keyEquivalentModifierMask == [.command], "Settings should own cmd+,")
        for (title, _) in fixed where title != "Settings..." {
            let item = appMenu.items.first { $0.title == title }
            try uiExpect(item?.keyEquivalent.isEmpty == true, "\(title) should have no key equivalent")
        }
    }

    await uiTest("configured bindings replace defaults, alternates, and disabled actions") {
        let menu = NSMenu()
        let defaults = menu.addCommand("view.font-increase")
        let surface = ConfigurableMenuBindingSurface(menu: menu)

        guard let primary = KeyChord(compact: "cmd+option+i"),
              let alternate = KeyChord(compact: "ctrl+shift+i")
        else { throw UITestFailure(message: "test chords should parse") }
        surface.apply([
            "view.font-increase": [primary, alternate],
        ])

        try uiExpect(defaults[0].keyEquivalent == "i", "configured primary should replace the visible default")
        try uiExpect(defaults[0].keyEquivalentModifierMask == [.command, .option], "configured primary should replace its modifier mask")
        let configured = menu.items.filter { $0.representedObject as? String == "view.font-increase" }
        try uiExpect(configured.count == 2, "reconcile should resize the hidden twin set")
        try uiExpect(configured[1].keyEquivalent == "I", "configured alternate should project Shift")
        try uiExpect(configured[1].isHidden && configured[1].allowsKeyEquivalentWhenHidden,
                     "alternate should dispatch through a hidden twin")

        surface.apply(["view.font-increase": []])
        let disabled = menu.items.filter { $0.representedObject as? String == "view.font-increase" }
        try uiExpect(disabled.count == 1, "disabled action should retain only its visible menu row")
        try uiExpect(disabled[0].keyEquivalent.isEmpty, "disabled action should have no key equivalent")
    }

    // Canonical chords name a character, not a physical key, so a keyboard
    // layout switch cannot change what a projected equivalent means. This pins
    // that the projection is a pure function of the committed binding map.
    await uiTest("a keyboard layout switch leaves the projected bindings alone") {
        let menu = NSMenu()
        menu.addCommand("view.font-increase")
        let surface = ConfigurableMenuBindingSurface(menu: menu)

        guard let primary = KeyChord(compact: "cmd+option+i"),
              let alternate = KeyChord(compact: "ctrl+shift+i")
        else { throw UITestFailure(message: "test chords should parse") }
        surface.apply(["view.font-increase": [primary, alternate]])

        func projection() -> [String] {
            menu.items.map { item in
                [
                    item.representedObject as? String ?? "",
                    item.keyEquivalent,
                    String(item.keyEquivalentModifierMask.rawValue),
                    String(item.isHidden),
                    String(item.allowsKeyEquivalentWhenHidden),
                ].joined(separator: "|")
            }
        }
        let before = projection()

        NotificationCenter.default.post(
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        try uiExpect(projection() == before, "a layout switch should not touch the projected menu items")
    }
}
