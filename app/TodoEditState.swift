/// Pure state machine for todo-list edit transitions (enter, dirty-switch,
/// submit, cancel). No AppKit dependency — unit-testable via TodoEditStateTests.

import Foundation

struct TodoEditState {
    var editingTodoId: UUID? = nil
    var preEditDraft: String = ""

    /// Selection changed to a new row. Returns auto-save info if dirty-switching.
    /// Stashes the draft on first entry from add mode.
    mutating func beginEditing(item: TodoItem, fieldText: String) -> (autoSaveId: UUID, text: String)? {
        guard editingTodoId != item.id else { return nil }
        var autoSave: (UUID, String)? = nil
        if let oldId = editingTodoId {
            let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { autoSave = (oldId, trimmed) }
        } else {
            preEditDraft = fieldText
        }
        editingTodoId = item.id
        return autoSave
    }

    /// Submit edit. Clears edit state and draft.
    mutating func submit() {
        editingTodoId = nil
        preEditDraft = ""
    }

    /// Cancel edit. Returns draft to restore.
    mutating func cancel() -> String {
        editingTodoId = nil
        let draft = preEditDraft
        preEditDraft = ""
        return draft
    }

    /// Check if the editing todo still exists. Returns true if it was deleted.
    func editingTodoWasDeleted(from todos: [TodoItem]) -> Bool {
        guard let editId = editingTodoId else { return false }
        return !todos.contains(where: { $0.id == editId })
    }
}
