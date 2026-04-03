// Tests for TodoEditState: pure edit-transition state machine for the todo popover.
import Foundation

func todoEditStateTests() {
    print("TodoEditState tests:")

    // MARK: - beginEditing

    test("beginEditing from add mode stashes draft and returns nil") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task A", isDone: false)
        let result = state.beginEditing(item: item, fieldText: "my draft")
        try expect(result == nil, "should not auto-save when entering from add mode")
        try expectEqual(state.editingTodoId, item.id)
        try expectEqual(state.preEditDraft, "my draft")
    }

    test("beginEditing dirty switch returns auto-save for old row") {
        var state = TodoEditState()
        let itemA = TodoItem(id: UUID(), text: "task A", isDone: false)
        let itemB = TodoItem(id: UUID(), text: "task B", isDone: false)
        // Enter edit on A
        _ = state.beginEditing(item: itemA, fieldText: "")
        // Switch to B with modified text
        let result = state.beginEditing(item: itemB, fieldText: "edited A text")
        try expect(result != nil, "should auto-save old row")
        try expectEqual(result!.autoSaveId, itemA.id)
        try expectEqual(result!.text, "edited A text")
        try expectEqual(state.editingTodoId, itemB.id)
        // Draft should still be the original stash from first entry
        try expectEqual(state.preEditDraft, "")
    }

    test("beginEditing dirty switch does not re-stash draft") {
        var state = TodoEditState()
        let itemA = TodoItem(id: UUID(), text: "task A", isDone: false)
        let itemB = TodoItem(id: UUID(), text: "task B", isDone: false)
        // Enter edit from add mode with draft
        _ = state.beginEditing(item: itemA, fieldText: "original draft")
        try expectEqual(state.preEditDraft, "original draft")
        // Switch to B — draft should be preserved, not overwritten
        _ = state.beginEditing(item: itemB, fieldText: "edited A")
        try expectEqual(state.preEditDraft, "original draft")
    }

    test("beginEditing same row returns nil (no-op)") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task", isDone: false)
        _ = state.beginEditing(item: item, fieldText: "")
        let result = state.beginEditing(item: item, fieldText: "modified")
        try expect(result == nil, "reselection of same row should be no-op")
        try expectEqual(state.editingTodoId, item.id)
    }

    test("beginEditing dirty switch with whitespace-only text does not auto-save") {
        var state = TodoEditState()
        let itemA = TodoItem(id: UUID(), text: "task A", isDone: false)
        let itemB = TodoItem(id: UUID(), text: "task B", isDone: false)
        _ = state.beginEditing(item: itemA, fieldText: "")
        let result = state.beginEditing(item: itemB, fieldText: "   ")
        try expect(result == nil, "should not auto-save whitespace-only text")
    }

    // MARK: - cancel

    test("cancel restores draft and clears editing state") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task", isDone: false)
        _ = state.beginEditing(item: item, fieldText: "my draft")
        let draft = state.cancel()
        try expectEqual(draft, "my draft")
        try expect(state.editingTodoId == nil, "editingTodoId should be nil")
        try expectEqual(state.preEditDraft, "")
    }

    // MARK: - submit

    test("submit clears editing state and draft") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task", isDone: false)
        _ = state.beginEditing(item: item, fieldText: "draft")
        state.submit()
        try expect(state.editingTodoId == nil, "editingTodoId should be nil")
        try expectEqual(state.preEditDraft, "")
    }

    // MARK: - editingTodoWasDeleted

    test("editingTodoWasDeleted returns true when todo is gone") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task", isDone: false)
        _ = state.beginEditing(item: item, fieldText: "")
        let other = TodoItem(id: UUID(), text: "other", isDone: false)
        let deleted = state.editingTodoWasDeleted(from: [other])
        try expect(deleted, "should detect deleted todo")
        // State should not be cleared yet — caller calls cancel()
        try expectEqual(state.editingTodoId, item.id)
    }

    test("editingTodoWasDeleted returns false when todo exists") {
        var state = TodoEditState()
        let item = TodoItem(id: UUID(), text: "task", isDone: false)
        _ = state.beginEditing(item: item, fieldText: "")
        let deleted = state.editingTodoWasDeleted(from: [item])
        try expect(!deleted, "should not report deletion when todo still exists")
    }

    test("editingTodoWasDeleted returns false when not editing") {
        let state = TodoEditState()
        let deleted = state.editingTodoWasDeleted(from: [])
        try expect(!deleted, "should return false when not editing")
    }
}
