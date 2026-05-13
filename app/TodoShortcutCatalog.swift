/// Pure shortcut catalog for todo popover keyboard help.
/// Keeps shortcut copy shared between pane and tab popovers and unit-testable.

enum TodoShortcutScope: Equatable {
    case pane
    case tab
}

struct TodoShortcutItem: Equatable {
    let keys: String
    let action: String
}

struct TodoShortcutSection: Equatable {
    let title: String
    let items: [TodoShortcutItem]
}

/// Build the shortcut help sections for the requested todo popover scope.
func todoShortcutSections(scope: TodoShortcutScope) -> [TodoShortcutSection] {
    var listItems = [
        TodoShortcutItem(keys: "J/K or ↑/↓", action: "Move selection"),
        TodoShortcutItem(keys: "⏎", action: "Edit selected task"),
        TodoShortcutItem(keys: "Space", action: "Toggle done"),
        TodoShortcutItem(keys: "Esc", action: "Close popover"),
        TodoShortcutItem(keys: "Tab / ⇧Tab", action: "Move between list and input"),
        TodoShortcutItem(keys: "⌘N", action: "New task"),
        TodoShortcutItem(keys: "⌘⌫", action: "Delete selected task"),
        TodoShortcutItem(keys: "⇧J / ⇧K", action: "Move task"),
    ]

    if scope == .tab {
        listItems.append(TodoShortcutItem(keys: "⇧H / ⇧L", action: "Move task between sections"))
    }

    return [
        TodoShortcutSection(title: "List", items: listItems),
        TodoShortcutSection(title: "Compose", items: [
            TodoShortcutItem(keys: "⏎", action: "Add task"),
            TodoShortcutItem(keys: "⇧⏎", action: "Insert newline"),
            TodoShortcutItem(keys: "Esc", action: "Focus list or close"),
            TodoShortcutItem(keys: "Tab / ⇧Tab", action: "Focus list"),
        ]),
        TodoShortcutSection(title: "Edit", items: [
            TodoShortcutItem(keys: "⏎", action: "Save changes"),
            TodoShortcutItem(keys: "⇧⏎", action: "Insert newline"),
            TodoShortcutItem(keys: "Esc", action: "Cancel edit"),
            TodoShortcutItem(keys: "Tab / ⇧Tab", action: "Move between edit controls"),
            TodoShortcutItem(keys: "⌘N", action: "Save and add new task"),
        ]),
    ]
}
