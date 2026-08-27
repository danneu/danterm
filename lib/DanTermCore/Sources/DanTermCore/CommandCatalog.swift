// Pure catalog metadata and validation for every configurable DanTerm command.
import DanTermProtocol

/// Gives AppKit an exhaustive dispatch identity for every catalog command.
enum ConfigurableCommand: String, CaseIterable, Equatable, Sendable {
    case openConfig = "app.open-config", reloadConfig = "app.reload-config"
    case find = "edit.find", findNext = "edit.find-next", findPrevious = "edit.find-previous"
    case toggleThemeBrowser = "view.toggle-theme-browser"
    case fontIncrease = "view.font-increase", fontDecrease = "view.font-decrease"
    case fontReset = "view.font-reset", toggleSidebar = "view.toggle-sidebar"
    case toggleAlerts = "view.toggle-alerts"
    case newTab = "tab.new", newTabAtEnd = "tab.new-at-end", newGroup = "tab.new-group"
    case renameTab = "tab.rename", clearTitle = "tab.clear-title"
    case nextTab = "tab.next", previousTab = "tab.previous", jump = "tab.jump"
    case recentOlder = "tab.recent-older", recentNewer = "tab.recent-newer"
    case colorRed = "tab.color-red", colorOrange = "tab.color-orange"
    case colorYellow = "tab.color-yellow", colorGreen = "tab.color-green"
    case colorBlue = "tab.color-blue", colorPurple = "tab.color-purple"
    case colorGray = "tab.color-gray", colorNone = "tab.color-none"
    case clearTabAlerts = "tab.clear-alerts", toggleTabTodo = "tab.toggle-todo"
    case closeTab = "tab.close"
    case splitRight = "pane.split-right", splitDown = "pane.split-down"
    case toggleZoom = "pane.toggle-zoom"
    case focusLeft = "pane.focus-left", focusDown = "pane.focus-down"
    case focusUp = "pane.focus-up", focusRight = "pane.focus-right"
    case nextAlert = "pane.next-alert", clearPaneAlerts = "pane.clear-alerts"
    case togglePaneTodo = "pane.toggle-todo", closePane = "pane.close"
}

extension TabColor {
    /// Names the configurable command that represents this color in menus and bindings.
    var configurableCommand: ConfigurableCommand {
        switch self {
        case .red: .colorRed
        case .orange: .colorOrange
        case .yellow: .colorYellow
        case .green: .colorGreen
        case .blue: .colorBlue
        case .purple: .colorPurple
        case .gray: .colorGray
        }
    }
}

extension ConfigurableCommand {
    /// Recovers the color from the single forward mapping instead of restating its pairs.
    var tabColor: TabColor? {
        TabColor.allCases.first { $0.configurableCommand == self }
    }
}

/// Groups commands for menu placement and the Settings presentation.
enum CommandCategory: String, CaseIterable, Equatable, Sendable {
    case application
    case editing
    case view
    case tab
    case pane
}

/// Defines where AppKit may dispatch a command.
enum CommandScope: Equatable, Sendable {
    case application
    case window
}

/// Describes activation behavior that needs more than ordinary menu dispatch.
enum CommandGesture: Equatable, Sendable {
    case ordinary
    case repeatable
    case jump
    case heldMRU(HeldMRUDirection)
}

/// Identifies the direction of one held recent-tab command.
enum HeldMRUDirection: Equatable, Sendable {
    case older
    case newer
}

/// Holds the single source of identity, presentation, availability, and defaults.
struct CommandDescriptor: Equatable, Sendable {
    let action: ConfigurableCommand
    var id: KeybindingActionID { KeybindingActionID(rawValue: action.rawValue) }
    let title: String
    let category: CommandCategory
    let defaultChords: [KeyChord]
    let scope: CommandScope
    let isAvailableDuringTextEditing: Bool
    let gesture: CommandGesture
}

/// Names a fixed Cocoa or macOS chord that configurable commands cannot claim.
struct KeybindingReservation: Equatable, Sendable {
    let title: String
    let chord: KeyChord
}

/// Returns either one complete effective map or diagnostics for the rejected candidate.
struct EffectiveBindingsResult: Equatable, Sendable {
    let value: [KeybindingActionID: [KeyChord]]?
    let diagnostics: [KeybindingDiagnostic]
}

/// Returns the one descriptor owned by a command through an exhaustive lookup.
func commandDescriptor(_ action: ConfigurableCommand) -> CommandDescriptor {
    switch action {
    case .openConfig:
        command(action, "Open DanTerm Config", .application, "cmd+option+,", scope: .application, text: true)
    case .reloadConfig:
        command(action, "Reload Config", .application, "cmd+shift+,", scope: .application, text: true)
    case .find:
        command(action, "Find", .editing, "cmd+f")
    case .findNext:
        command(action, "Find Next", .editing, "cmd+g", gesture: .repeatable)
    case .findPrevious:
        command(action, "Find Previous", .editing, "cmd+shift+g", gesture: .repeatable)
    case .toggleThemeBrowser:
        command(action, "Toggle Theme Browser", .view, "cmd+shift+b")
    case .fontIncrease:
        command(action, "Increase Font Size", .view, "cmd+shift+plus", "cmd+=", gesture: .repeatable)
    case .fontDecrease:
        command(action, "Decrease Font Size", .view, "cmd+-", gesture: .repeatable)
    case .fontReset:
        command(action, "Actual Size", .view, "cmd+0")
    case .toggleSidebar:
        command(action, "Toggle Sidebar", .view)
    case .toggleAlerts:
        command(action, "Toggle Alerts", .view)
    case .newTab:
        command(action, "New Tab", .tab, "cmd+t")
    case .newTabAtEnd:
        command(action, "New Tab at End of Group", .tab, "cmd+shift+t")
    case .newGroup:
        command(action, "New Group", .tab, "cmd+n")
    case .renameTab:
        command(action, "Rename Tab", .tab, "cmd+shift+r")
    case .clearTitle:
        command(action, "Clear Custom Title", .tab)
    case .nextTab:
        command(action, "Next Tab", .tab, "cmd+shift+n", gesture: .repeatable)
    case .previousTab:
        command(action, "Previous Tab", .tab, "cmd+shift+p", gesture: .repeatable)
    case .jump:
        command(action, "Jump to Tab...", .tab, "cmd+shift+f", gesture: .jump)
    case .recentOlder:
        command(action, "Recent Tab (Older)", .tab, "cmd+shift+o", gesture: .heldMRU(.older))
    case .recentNewer:
        command(action, "Recent Tab (Newer)", .tab, "cmd+shift+i", gesture: .heldMRU(.newer))
    case .colorRed:
        command(action, "Red", .tab, "cmd+1")
    case .colorOrange:
        command(action, "Orange", .tab, "cmd+2")
    case .colorYellow:
        command(action, "Yellow", .tab, "cmd+3")
    case .colorGreen:
        command(action, "Green", .tab)
    case .colorBlue:
        command(action, "Blue", .tab)
    case .colorPurple:
        command(action, "Purple", .tab)
    case .colorGray:
        command(action, "Gray", .tab)
    case .colorNone:
        command(action, "Clear Color", .tab, "cmd+9")
    case .clearTabAlerts:
        command(action, "Clear Tab Alerts", .tab, "cmd+.")
    case .toggleTabTodo:
        command(action, "Toggle Tab To-do List", .tab, "cmd+'")
    case .closeTab:
        command(action, "Close Tab", .tab, "cmd+shift+w")
    case .splitRight:
        command(action, "Split Right", .pane, "cmd+d")
    case .splitDown:
        command(action, "Split Down", .pane, "cmd+shift+d")
    case .toggleZoom:
        command(action, "Toggle Zoom", .pane, "cmd+enter")
    case .focusLeft:
        command(action, "Focus Left", .pane, "cmd+shift+h", gesture: .repeatable)
    case .focusDown:
        command(action, "Focus Down", .pane, "cmd+shift+j", gesture: .repeatable)
    case .focusUp:
        command(action, "Focus Up", .pane, "cmd+shift+k", gesture: .repeatable)
    case .focusRight:
        command(action, "Focus Right", .pane, "cmd+shift+l", gesture: .repeatable)
    case .nextAlert:
        command(action, "Next Unread Alert", .pane, "cmd+shift+a")
    case .clearPaneAlerts:
        command(action, "Clear Pane Alerts", .pane, "cmd+shift+.")
    case .togglePaneTodo:
        command(action, "Toggle Pane To-do List", .pane, "cmd+shift+'")
    case .closePane:
        command(action, "Close Pane", .pane, "cmd+w")
    }
}

/// Owns all stable DanTerm menu and toolbar actions that can be configured.
let commandCatalog = ConfigurableCommand.allCases.map(commandDescriptor)

/// Owns fixed native shortcuts alongside the configurable catalog conflict model.
let keybindingReservations: [KeybindingReservation] = [
    reservation("Undo", "cmd+z"), reservation("Redo", "cmd+shift+z"),
    reservation("Cut", "cmd+x"), reservation("Copy", "cmd+c"),
    reservation("Paste", "cmd+v"), reservation("Select All", "cmd+a"),
    reservation("Hide DanTerm", "cmd+h"), reservation("Hide Others", "cmd+option+h"),
    reservation("Quit DanTerm", "cmd+q"), reservation("Minimize", "cmd+m"),
    reservation("Cycle Windows", "cmd+`"), reservation("Cycle Windows Backward", "cmd+shift+`"),
    // Settings is a fixed App-menu item rather than a catalog command, so this entry is the
    // only thing that keeps a configurable command off the macOS-conventional chord.
    reservation("Settings", "cmd+,"),
    // The pane delivers these four to the child as Home and End, because macOS puts
    // line-start and line-end here and PageUp/PageDown/Home/End now scroll the pane instead.
    // A menu key equivalent is dispatched before the pane sees the event, so leaving them
    // configurable would let a rebind take shell line editing away with nothing left to reach
    // it by.
    reservation("Move to Line Start", "cmd+left"), reservation("Move to Line End", "cmd+right"),
    reservation("Select to Line Start", "cmd+shift+left"),
    reservation("Select to Line End", "cmd+shift+right"),
]

/// Applies replacements and atomically validates conflicts and gesture invariants.
func effectiveBindings(overrides: KeybindingOverrides) -> EffectiveBindingsResult {
    let candidate = catalogBindings(overrides: overrides)

    var diagnostics: [KeybindingDiagnostic] = []
    var owners: [KeyChord: KeybindingActionID] = [:]
    let reservations = Dictionary(uniqueKeysWithValues: keybindingReservations.map { ($0.chord, $0.title) })
    for descriptor in commandCatalog {
        for (index, chord) in candidate[descriptor.id, default: []].enumerated() {
            let path = "keybindings.\(descriptor.id.rawValue)[\(index)]"
            if let title = reservations[chord] {
                diagnostics.append(KeybindingDiagnostic(path: path, reason: "reserved by \(title)"))
            } else if let owner = owners[chord] {
                diagnostics.append(KeybindingDiagnostic(path: path, reason: "conflicts with \(owner.rawValue)"))
            } else {
                owners[chord] = descriptor.id
            }
        }
    }

    let olderID = commandDescriptor(.recentOlder).id
    let newerID = commandDescriptor(.recentNewer).id
    let older = candidate[olderID, default: []]
    let newer = candidate[newerID, default: []]
    validateHeldMRUCount(older, id: olderID, diagnostics: &diagnostics)
    validateHeldMRUCount(newer, id: newerID, diagnostics: &diagnostics)
    if let olderChord = older.first, let newerChord = newer.first,
       olderChord.modifiers != newerChord.modifiers {
        let mismatchedID = overrides.chordsByAction[newerID] != nil ? newerID : olderID
        let partnerID = mismatchedID == newerID ? olderID : newerID
        diagnostics.append(KeybindingDiagnostic(
            path: "keybindings.\(mismatchedID.rawValue)[0]",
            reason: "must use the same modifiers as \(partnerID.rawValue)"
        ))
    }

    return diagnostics.isEmpty
        ? EffectiveBindingsResult(value: candidate, diagnostics: [])
        : EffectiveBindingsResult(value: nil, diagnostics: diagnostics)
}

/// Resolves catalog defaults and explicit replacements without hiding invalid saved values.
func catalogBindings(overrides: KeybindingOverrides) -> [KeybindingActionID: [KeyChord]] {
    var candidate = Dictionary(uniqueKeysWithValues: commandCatalog.map { descriptor in
        (descriptor.id, overrides.chordsByAction[descriptor.id] ?? descriptor.defaultChords)
    })
    let known = Set(commandCatalog.map(\.id))
    candidate = candidate.filter { known.contains($0.key) }
    return candidate
}

private func command(
    _ action: ConfigurableCommand,
    _ title: String,
    _ category: CommandCategory,
    _ chords: String...,
    scope: CommandScope = .window,
    text: Bool = false,
    gesture: CommandGesture = .ordinary
) -> CommandDescriptor {
    CommandDescriptor(
        action: action,
        title: title,
        category: category,
        defaultChords: chords.map { KeyChord(compact: $0)! },
        scope: scope,
        isAvailableDuringTextEditing: text,
        gesture: gesture
    )
}

private func reservation(_ title: String, _ chord: String) -> KeybindingReservation {
    KeybindingReservation(title: title, chord: KeyChord(compact: chord)!)
}

private func validateHeldMRUCount(
    _ chords: [KeyChord],
    id: KeybindingActionID,
    diagnostics: inout [KeybindingDiagnostic]
) {
    if chords.count > 1 {
        diagnostics.append(KeybindingDiagnostic(
            path: "keybindings.\(id.rawValue)",
            reason: "held MRU actions accept at most one chord"
        ))
    }
}
