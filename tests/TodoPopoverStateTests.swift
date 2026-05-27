// Tests for TodoPopoverState: pure list/edit mode and draft-preservation rules.
import Foundation

func todoPopoverStateTests() {
    print("TodoPopoverState tests:")

    runTodoPopoverStateCases(
        label: "UUID",
        target: UUID(),
        otherTarget: UUID()
    )

    let tabTarget = TabTodoEditTarget.tab(todoId: UUID())
    let paneTarget = TabTodoEditTarget.pane(paneId: PaneId(), todoId: UUID())

    runTodoPopoverStateCases(
        label: "TabTodoEditTarget",
        target: tabTarget,
        otherTarget: paneTarget
    )

    test("retargeting edit mode preserves compose draft") {
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        state.reconcileEditTarget { target in target == 1 ? 2 : nil }
        try expectEqual(state.mode, .edit(2))
        try expectEqual(state.composeDraft, "abc")
    }

    test("missing edit target exits edit mode and preserves compose draft") {
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        state.reconcileEditTarget { _ in nil }
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("tab todo retarget keeps edit mode across cross-bucket movement") {
        let todoId = UUID()
        let paneId = PaneId()
        var state = TodoPopoverState<TabTodoEditTarget>(
            mode: .edit(.tab(todoId: todoId)),
            composeDraft: "abc"
        )

        state.reconcileEditTarget { target in
            target == .tab(todoId: todoId) ? .pane(paneId: paneId, todoId: todoId) : nil
        }

        try expectEqual(state.mode, .edit(.pane(paneId: paneId, todoId: todoId)))
        try expectEqual(state.composeDraft, "abc")
    }

    test("rejected save preserves compose draft and edit mode") {
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        let result = state.saveEdit(text: "   ")
        try expectEqual(result, .rejected)
        try expectEqual(state.mode, .edit(1))
        try expectEqual(state.composeDraft, "abc")
    }
}

private func runTodoPopoverStateCases<Target: Equatable>(
    label: String,
    target: Target,
    otherTarget: Target
) {
    test("\(label): selection preserves compose") {
        var state = TodoPopoverState<Target>(mode: .list, composeDraft: "abc")
        state.selectRow(target)
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): enter edit preserves compose") {
        var state = TodoPopoverState<Target>(mode: .list, composeDraft: "abc")
        state.enterEdit(target: target, itemText: "todo text")
        try expectEqual(state.mode, .edit(target))
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): save returns to list and preserves compose") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        let result = state.saveEdit(text: "  new  ")
        try expectEqual(result, .saved(target: target, text: "new"))
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): cancel returns to list and preserves compose") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        state.cancelEdit()
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): empty save is rejected") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        let result = state.saveEdit(text: "   ")
        try expectEqual(result, .rejected)
        try expectEqual(state.mode, .edit(target))
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): rebuild missing target falls back") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        state.rebuild { $0 == otherTarget }
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): rebuild preserves draft on list") {
        var state = TodoPopoverState<Target>(mode: .list, composeDraft: "abc")
        state.rebuild { $0 == target }
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
    }

    test("\(label): clear from list") {
        var state = TodoPopoverState<Target>(mode: .list, composeDraft: "abc")
        state.clearComposeDraft()
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "")
    }

    test("\(label): edit cmd n success saves before clear") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        let result = state.saveEdit(text: "new")
        try expectEqual(result, .saved(target: target, text: "new"))
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "abc")
        state.clearComposeDraft()
        try expectEqual(state.mode, .list)
        try expectEqual(state.composeDraft, "")
    }

    test("\(label): edit cmd n rejected preserves draft") {
        var state = TodoPopoverState<Target>(mode: .edit(target), composeDraft: "abc")
        let result = state.saveEdit(text: "   ")
        try expectEqual(result, .rejected)
        try expectEqual(state.mode, .edit(target))
        try expectEqual(state.composeDraft, "abc")
    }
}
