// Pure catalog metadata and validation for every configurable DanTerm command.
import DanTermProtocol

/// Gives AppKit an exhaustive dispatch identity for every catalog command.
enum ConfigurableCommand: String, CaseIterable, Equatable, Sendable, ExpressibleByStringLiteral {
    case importState = "app.import-state", exportState = "app.export-state"
    case settings = "app.settings", openConfig = "app.open-config"
    case reloadConfig = "app.reload-config", installCLI = "app.install-cli"
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

    init(stringLiteral value: String) {
        guard let command = Self(rawValue: value) else {
            preconditionFailure("unknown configurable command \(value)")
        }
        self = command
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

/// Owns all stable DanTerm menu and toolbar actions that can be configured.
let commandCatalog: [CommandDescriptor] = [
    command("app.import-state", "Import State...", .application, scope: .application, text: true),
    command("app.export-state", "Export State...", .application, scope: .application, text: true),
    command("app.settings", "Settings...", .application, "cmd+,", scope: .application, text: true),
    command("app.open-config", "Open DanTerm Config", .application, "cmd+option+,", scope: .application, text: true),
    command("app.reload-config", "Reload Config", .application, "cmd+shift+,", scope: .application, text: true),
    command("app.install-cli", "Install danterm Command in PATH", .application, scope: .application, text: true),

    command("edit.find", "Find", .editing, "cmd+f"),
    command("edit.find-next", "Find Next", .editing, "cmd+g", gesture: .repeatable),
    command("edit.find-previous", "Find Previous", .editing, "cmd+shift+g", gesture: .repeatable),

    command("view.toggle-theme-browser", "Toggle Theme Browser", .view, "cmd+shift+b"),
    command("view.font-increase", "Increase Font Size", .view, "cmd+shift+plus", "cmd+=", gesture: .repeatable),
    command("view.font-decrease", "Decrease Font Size", .view, "cmd+-", gesture: .repeatable),
    command("view.font-reset", "Actual Size", .view, "cmd+0"),
    command("view.toggle-sidebar", "Toggle Sidebar", .view),
    command("view.toggle-alerts", "Toggle Alerts", .view),

    command("tab.new", "New Tab", .tab, "cmd+t"),
    command("tab.new-at-end", "New Tab at End of Group", .tab, "cmd+shift+t"),
    command("tab.new-group", "New Group", .tab, "cmd+n"),
    command("tab.rename", "Rename Tab", .tab, "cmd+shift+r"),
    command("tab.clear-title", "Clear Custom Title", .tab),
    command("tab.next", "Next Tab", .tab, "cmd+shift+n", gesture: .repeatable),
    command("tab.previous", "Previous Tab", .tab, "cmd+shift+p", gesture: .repeatable),
    command("tab.jump", "Jump to Tab...", .tab, "cmd+shift+f", gesture: .jump),
    command("tab.recent-older", "Recent Tab (Older)", .tab, "cmd+shift+o", gesture: .heldMRU(.older)),
    command("tab.recent-newer", "Recent Tab (Newer)", .tab, "cmd+shift+i", gesture: .heldMRU(.newer)),
    command("tab.color-red", "Red", .tab, "cmd+1"),
    command("tab.color-orange", "Orange", .tab, "cmd+2"),
    command("tab.color-yellow", "Yellow", .tab, "cmd+3"),
    command("tab.color-green", "Green", .tab),
    command("tab.color-blue", "Blue", .tab),
    command("tab.color-purple", "Purple", .tab),
    command("tab.color-gray", "Gray", .tab),
    command("tab.color-none", "Clear Color", .tab, "cmd+9"),
    command("tab.clear-alerts", "Clear Tab Alerts", .tab, "cmd+."),
    command("tab.toggle-todo", "Toggle Tab To-do List", .tab, "cmd+'"),
    command("tab.close", "Close Tab", .tab, "cmd+shift+w"),

    command("pane.split-right", "Split Right", .pane, "cmd+d"),
    command("pane.split-down", "Split Down", .pane, "cmd+shift+d"),
    command("pane.toggle-zoom", "Toggle Zoom", .pane, "cmd+enter"),
    command("pane.focus-left", "Focus Left", .pane, "cmd+shift+h", gesture: .repeatable),
    command("pane.focus-down", "Focus Down", .pane, "cmd+shift+j", gesture: .repeatable),
    command("pane.focus-up", "Focus Up", .pane, "cmd+shift+k", gesture: .repeatable),
    command("pane.focus-right", "Focus Right", .pane, "cmd+shift+l", gesture: .repeatable),
    command("pane.next-alert", "Next Unread Alert", .pane, "cmd+shift+a"),
    command("pane.clear-alerts", "Clear Pane Alerts", .pane, "cmd+shift+."),
    command("pane.toggle-todo", "Toggle Pane To-do List", .pane, "cmd+shift+'"),
    command("pane.close", "Close Pane", .pane, "cmd+w"),
]

/// Owns fixed native shortcuts alongside the configurable catalog conflict model.
let keybindingReservations: [KeybindingReservation] = [
    reservation("Undo", "cmd+z"), reservation("Redo", "cmd+shift+z"),
    reservation("Cut", "cmd+x"), reservation("Copy", "cmd+c"),
    reservation("Paste", "cmd+v"), reservation("Select All", "cmd+a"),
    reservation("Hide DanTerm", "cmd+h"), reservation("Hide Others", "cmd+option+h"),
    reservation("Quit DanTerm", "cmd+q"), reservation("Minimize", "cmd+m"),
    reservation("Cycle Windows", "cmd+`"), reservation("Cycle Windows Backward", "cmd+shift+`"),
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

    let olderID: KeybindingActionID = "tab.recent-older"
    let newerID: KeybindingActionID = "tab.recent-newer"
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
