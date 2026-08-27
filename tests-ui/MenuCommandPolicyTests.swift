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
        let items = CommandMenuItemFactory.items(for: commandDescriptor(.fontIncrease))

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
            items.allSatisfy { $0.representedObject as? ConfigurableCommand == .fontIncrease },
            "every catalog item should carry its typed command"
        )
    }

    await uiTest("catalog scope keeps configurable application commands available") {
        try uiExpect(
            MenuCommandPolicy.isEnabled(command: .openConfig, windowIsLive: false),
            "application-scoped catalog commands should work without a live window"
        )
        try uiExpect(
            !MenuCommandPolicy.isEnabled(command: .newTab, windowIsLive: false),
            "window-scoped catalog commands should still require a live window"
        )
    }

    await uiTest("every shared-dispatch menu item carries a typed command") {
        // Intent: every item routed through the configurable dispatcher carries the closed
        //   command vocabulary rather than a wire-format string.
        // Why it exists: a missed builder call would compile but silently fall out of typed
        //   dispatch and validation after the menu channel changes.
        // Scenario: walk every menu exactly as the delegate builds it at launch.
        let menus = [
            AppDelegate.makeAppMenu(), AppDelegate.makeEditMenu(),
            AppDelegate.makeViewMenu(), AppDelegate.makeTabMenu(),
            AppDelegate.makePaneMenu(), AppDelegate.makeWindowMenu(),
        ]

        for item in menus.flatMap(configurableItems(in:)) {
            try uiExpect(
                item.representedObject is ConfigurableCommand,
                "\(item.title) should carry a typed configurable command"
            )
        }
    }

    await uiTest("delegate validation reads typed command scope without a live window") {
        // Intent: typed application commands stay enabled without a window while typed
        //   window commands stay disabled.
        // Why it exists: an Any payload cast can compile after its writer changes type and
        //   silently fall through to selector-based validation for every command.
        // Scenario: validate one command of each scope through the real delegate with no window.
        let delegate = AppDelegate(
            instancePaths: makeUITestRuntime().instancePaths,
            configURL: uiTestAbsentConfigURL()
        )
        let applicationItem = NSMenuItem(
            title: "Open DanTerm Config",
            action: #selector(ConfigurableMenuCommandTarget.performConfiguredCommand(_:)),
            keyEquivalent: ""
        )
        applicationItem.representedObject = ConfigurableCommand.openConfig
        let windowItem = NSMenuItem(
            title: "New Tab",
            action: #selector(ConfigurableMenuCommandTarget.performConfiguredCommand(_:)),
            keyEquivalent: ""
        )
        windowItem.representedObject = ConfigurableCommand.newTab

        try uiExpect(
            delegate.validateMenuItem(applicationItem),
            "application-scoped command should stay enabled without a live window"
        )
        try uiExpect(
            !delegate.validateMenuItem(windowItem),
            "window-scoped command should stay disabled without a live window"
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

    await uiTest("menu builders preserve configurable item order and key equivalents") {
        // Intent: each menu keeps the same configurable rows and default key equivalents.
        // Why it exists: a valid but wrong command at any builder call site would keep the
        //   catalog and binding tests green while changing the menu the user sees.
        // Scenario: spec-first inventory of every menu as the delegate builds it at launch.
        let expected: [(NSMenu, [MenuItemIdentity])] = [
            (AppDelegate.makeAppMenu(), [
                item("Open DanTerm Config", ",", [.command, .option]),
                item("Reload Config", ",", [.command, .shift]),
            ]),
            (AppDelegate.makeEditMenu(), [
                item("Find", "f"), item("Find Next", "g"),
                item("Find Previous", "G", [.command, .shift]),
            ]),
            (AppDelegate.makeViewMenu(), [
                item("Toggle Theme Browser", "B", [.command, .shift]),
                item("Increase Font Size", "+"),
                item("Increase Font Size", "="), item("Decrease Font Size", "-"),
                item("Actual Size", "0"), item("Toggle Sidebar"), item("Toggle Alerts"),
            ]),
            (AppDelegate.makeTabMenu(), [
                item("New Tab", "t"),
                item("New Tab at End of Group", "T", [.command, .shift]),
                item("New Group", "n"), item("Rename Tab", "R", [.command, .shift]),
                item("Clear Custom Title"), item("Next Tab", "N", [.command, .shift]),
                item("Previous Tab", "P", [.command, .shift]),
                item("Jump to Tab...", "F", [.command, .shift]),
                item("Recent Tab (Older)", "O", [.command, .shift]),
                item("Recent Tab (Newer)", "I", [.command, .shift]),
                item("Red", "1"), item("Orange", "2"), item("Yellow", "3"),
                item("Green"), item("Blue"), item("Purple"), item("Gray"),
                item("Clear Color", "9"), item("Clear Tab Alerts", "."),
                item("Toggle Tab To-do List", "'"),
                item("Close Tab", "W", [.command, .shift]),
            ]),
            (AppDelegate.makePaneMenu(), [
                item("Split Right", "d"), item("Split Down", "D", [.command, .shift]),
                item("Toggle Zoom", "\r"),
                item("Focus Left", "H", [.command, .shift]),
                item("Focus Down", "J", [.command, .shift]),
                item("Focus Up", "K", [.command, .shift]),
                item("Focus Right", "L", [.command, .shift]),
                item("Next Unread Alert", "A", [.command, .shift]),
                item("Clear Pane Alerts", ".", [.command, .shift]),
                item("Toggle Pane To-do List", "'", [.command, .shift]),
                item("Close Pane", "w"),
            ]),
            (AppDelegate.makeWindowMenu(), []),
        ]

        for (menu, expectedItems) in expected {
            let actual = configurableItems(in: menu).map {
                MenuItemIdentity(
                    title: $0.title,
                    keyEquivalent: $0.keyEquivalent,
                    modifierMask: $0.keyEquivalent.isEmpty ? [] : $0.keyEquivalentModifierMask
                )
            }
            try uiExpect(actual == expectedItems,
                         "\(menu.title) configurable items changed: \(actual)")
        }
    }

    await uiTest("configured bindings replace defaults, alternates, and disabled actions") {
        let menu = NSMenu()
        let defaults = menu.addCommand(.fontIncrease)
        let surface = ConfigurableMenuBindingSurface(menu: menu)

        guard let primary = KeyChord(compact: "cmd+option+i"),
              let alternate = KeyChord(compact: "ctrl+shift+i")
        else { throw UITestFailure(message: "test chords should parse") }
        surface.apply([
            "view.font-increase": [primary, alternate],
        ])

        try uiExpect(defaults[0].keyEquivalent == "i", "configured primary should replace the visible default")
        try uiExpect(defaults[0].keyEquivalentModifierMask == [.command, .option], "configured primary should replace its modifier mask")
        let configured = menu.items.filter {
            $0.representedObject as? ConfigurableCommand == .fontIncrease
        }
        try uiExpect(configured.count == 2, "reconcile should resize the hidden twin set")
        try uiExpect(configured[1].keyEquivalent == "I", "configured alternate should project Shift")
        try uiExpect(configured[1].isHidden && configured[1].allowsKeyEquivalentWhenHidden,
                     "alternate should dispatch through a hidden twin")

        surface.apply(["view.font-increase": []])
        let disabled = menu.items.filter {
            $0.representedObject as? ConfigurableCommand == .fontIncrease
        }
        try uiExpect(disabled.count == 1, "disabled action should retain only its visible menu row")
        try uiExpect(disabled[0].keyEquivalent.isEmpty, "disabled action should have no key equivalent")
    }

    // Canonical chords name a character, not a physical key, so a keyboard
    // layout switch cannot change what a projected equivalent means. This pins
    // that the projection is a pure function of the committed binding map.
    await uiTest("a keyboard layout switch leaves the projected bindings alone") {
        let menu = NSMenu()
        menu.addCommand(.fontIncrease)
        let surface = ConfigurableMenuBindingSurface(menu: menu)

        guard let primary = KeyChord(compact: "cmd+option+i"),
              let alternate = KeyChord(compact: "ctrl+shift+i")
        else { throw UITestFailure(message: "test chords should parse") }
        surface.apply(["view.font-increase": [primary, alternate]])

        func projection() -> [String] {
            menu.items.map { item in
                [
                    (item.representedObject as? ConfigurableCommand)?.rawValue ?? "",
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

private struct MenuItemIdentity: Equatable {
    let title: String
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags
}

private func item(
    _ title: String,
    _ keyEquivalent: String? = nil,
    _ modifierMask: NSEvent.ModifierFlags = [.command]
) -> MenuItemIdentity {
    MenuItemIdentity(
        title: title,
        keyEquivalent: keyEquivalent ?? "",
        modifierMask: keyEquivalent == nil ? [] : modifierMask
    )
}

private func configurableItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { menuItem in
        let nested = menuItem.submenu.map(configurableItems(in:)) ?? []
        return (menuItem.action == #selector(ConfigurableMenuCommandTarget.performConfiguredCommand(_:))
            ? [menuItem] : []) + nested
    }
}
