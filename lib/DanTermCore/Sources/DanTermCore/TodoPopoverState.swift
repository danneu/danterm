// Pure mode and compose-draft state for todo popovers.
// Controllers own AppKit focus and model sends; this helper owns only the
// list/edit mode transitions and compose draft preservation rules.

import Foundation

enum TodoPopoverMode<Target: Equatable>: Equatable {
    case list
    case edit(Target)
}

enum TodoPopoverSaveResult<Target: Equatable>: Equatable {
    case saved(target: Target, text: String)
    case rejected
}

struct TodoPopoverState<Target: Equatable>: Equatable {
    var mode: TodoPopoverMode<Target> = .list
    var composeDraft = ""

    var editTarget: Target? {
        guard case .edit(let target) = mode else { return nil }
        return target
    }

    var isEditing: Bool { editTarget != nil }

    /// Row selection is intentionally mode-neutral and never changes the
    /// compose draft.
    mutating func selectRow(_ target: Target?) {
        _ = target
    }

    /// Enter explicit edit mode while preserving any compose draft.
    mutating func enterEdit(target: Target, itemText: String) {
        _ = itemText
        mode = .edit(target)
    }

    /// Save the active edit if the text is non-empty after trimming.
    mutating func saveEdit(text: String) -> TodoPopoverSaveResult<Target> {
        guard let target = editTarget else { return .rejected }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        mode = .list
        return .saved(target: target, text: trimmed)
    }

    /// Leave edit mode without changing the compose draft.
    mutating func cancelEdit() {
        mode = .list
    }

    /// Reconcile edit mode against a rebuilt target set, allowing callers to
    /// retarget the edit before falling back to list mode.
    mutating func reconcileEditTarget(resolve: (Target) -> Target?) {
        guard let target = editTarget else { return }
        if let resolved = resolve(target) {
            mode = .edit(resolved)
        } else {
            mode = .list
        }
    }

    /// Mirror user edits in the compose field.
    mutating func setComposeDraft(_ text: String) {
        composeDraft = text
    }

    /// Clear the compose draft after a confirmed new-item path.
    mutating func clearComposeDraft() {
        composeDraft = ""
    }
}
