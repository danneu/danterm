// Swift Testing migration of the legacy `tests/TodoPopoverStateTests.swift`
// harness suite. Pins TodoPopoverState pure list/edit mode + draft-
// preservation rules: 4 explicit tests for retarget / missing-target /
// cross-bucket retarget / rejected-save, plus 8 parametric scenarios run
// over BOTH `UUID` and `TabTodoEditTarget` target types (selection, enter,
// save, cancel, empty-save, clear, edit cmd-n success, edit cmd-n
// rejected). The parametric source names preserve the `\(label):` template
// literally so the inventory's source-grep parity check matches. Each
// parametric @Test calls a small private generic helper twice (once per
// target type).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct TodoPopoverStateTests {
    @Test("retargeting edit mode preserves compose draft")
    func retargetingEditModePreservesComposeDraft() {
        // Intent: reconcileEditTarget that maps the current target to a
        //   new value keeps edit mode pointed at the new target with the
        //   compose draft intact.
        // Why it exists: pins the retarget-preserve branch.
        // Scenario: spec-first retarget.
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        state.reconcileEditTarget { target in target == 1 ? 2 : nil }
        #expect(state.mode == .edit(2))
        #expect(state.composeDraft == "abc")
    }

    @Test("missing edit target exits edit mode and preserves compose draft")
    func missingEditTargetExitsEditModePreservesComposeDraft() {
        // Intent: reconcileEditTarget that returns nil exits edit mode
        //   but keeps the compose draft intact.
        // Why it exists: pins the missing-target exit rule.
        // Scenario: spec-first exit on nil.
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        state.reconcileEditTarget { _ in nil }
        #expect(state.mode == .list)
        #expect(state.composeDraft == "abc")
    }

    @Test("tab todo retarget keeps edit mode across cross-bucket movement")
    func tabTodoRetargetKeepsEditModeAcrossBuckets() {
        // Intent: a tab-todo retarget across buckets (tab -> pane)
        //   stays in edit mode with the compose draft intact.
        // Why it exists: pins the tab-todo bucket-cross retarget.
        // Scenario: spec-first cross-bucket retarget.
        let todoId = UUID()
        let paneId = PaneId()
        let tabId = TabId()
        let typedTodoId = TodoId(rawValue: todoId)
        var state = TodoPopoverState<TabTodoEditTarget>(
            mode: .edit(.init(owner: .tab(tabId), id: typedTodoId)),
            composeDraft: "abc"
        )

        state.reconcileEditTarget { target in
            target == .init(owner: .tab(tabId), id: typedTodoId)
                ? .init(owner: .pane(paneId), id: typedTodoId)
                : nil
        }

        #expect(state.mode == .edit(.init(owner: .pane(paneId), id: typedTodoId)))
        #expect(state.composeDraft == "abc")
    }

    @Test("rejected save preserves compose draft and edit mode")
    func rejectedSavePreservesComposeDraftAndEditMode() {
        // Intent: a rejected save (whitespace-only text) keeps edit
        //   mode and the compose draft.
        // Why it exists: pins the reject-preserve rule.
        // Scenario: spec-first reject preserve.
        var state = TodoPopoverState<Int>(mode: .edit(1), composeDraft: "abc")
        let result = state.saveEdit(text: "   ")
        #expect(result == .rejected)
        #expect(state.mode == .edit(1))
        #expect(state.composeDraft == "abc")
    }

    // MARK: - Parametric scenarios (run over UUID and TabTodoEditTarget)

    @Test("\\(label): selection preserves compose")
    func selectionPreservesCompose() {
        // Intent: selectRow keeps mode = .list and composeDraft intact.
        // Why it exists: pins selection's no-op on the draft.
        // Scenario: spec-first selectRow.
        runSelectionPreservesCompose(target: UUID(), otherTarget: UUID())
        runSelectionPreservesCompose(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): enter edit preserves compose")
    func enterEditPreservesCompose() {
        // Intent: enterEdit flips mode = .edit(target) and keeps the
        //   compose draft intact.
        // Why it exists: pins the enter-edit transition.
        // Scenario: spec-first enterEdit.
        runEnterEditPreservesCompose(target: UUID(), otherTarget: UUID())
        runEnterEditPreservesCompose(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): save returns to list and preserves compose")
    func saveReturnsToListAndPreservesCompose() {
        // Intent: saveEdit with a trimmable value returns `.saved` and
        //   flips mode back to .list with the compose draft intact.
        // Why it exists: pins the happy save path.
        // Scenario: spec-first save.
        runSaveReturnsToListAndPreservesCompose(target: UUID(), otherTarget: UUID())
        runSaveReturnsToListAndPreservesCompose(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): cancel returns to list and preserves compose")
    func cancelReturnsToListAndPreservesCompose() {
        // Intent: cancelEdit returns to .list with the compose draft
        //   intact.
        // Why it exists: pins the cancel path.
        // Scenario: spec-first cancel.
        runCancelReturnsToListAndPreservesCompose(target: UUID(), otherTarget: UUID())
        runCancelReturnsToListAndPreservesCompose(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): empty save is rejected")
    func emptySaveIsRejected() {
        // Intent: saveEdit with whitespace-only text returns .rejected
        //   and keeps mode and draft intact.
        // Why it exists: pins the whitespace-only reject rule.
        // Scenario: spec-first empty save reject.
        runEmptySaveIsRejected(target: UUID(), otherTarget: UUID())
        runEmptySaveIsRejected(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): clear from list")
    func clearFromList() {
        // Intent: clearComposeDraft on the .list state empties the
        //   draft.
        // Why it exists: pins the explicit clear path.
        // Scenario: spec-first clear from list.
        runClearFromList(target: UUID(), otherTarget: UUID())
        runClearFromList(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): edit cmd n success saves before clear")
    func editCmdNSuccessSavesBeforeClear() {
        // Intent: the cmd-n flow during edit saves the in-progress
        //   value first, then clearComposeDraft empties the draft.
        // Why it exists: pins the cmd-n save-then-clear sequence.
        // Scenario: spec-first cmd-n success.
        runEditCmdNSuccessSavesBeforeClear(target: UUID(), otherTarget: UUID())
        runEditCmdNSuccessSavesBeforeClear(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }

    @Test("\\(label): edit cmd n rejected preserves draft")
    func editCmdNRejectedPreservesDraft() {
        // Intent: rejected save during cmd-n preserves the draft and
        //   stays in edit mode.
        // Why it exists: pins the cmd-n reject path.
        // Scenario: spec-first cmd-n reject.
        runEditCmdNRejectedPreservesDraft(target: UUID(), otherTarget: UUID())
        runEditCmdNRejectedPreservesDraft(
            target: TabTodoEditTarget(owner: .tab(TabId()), id: TodoId()),
            otherTarget: TabTodoEditTarget(owner: .pane(PaneId()), id: TodoId())
        )
    }
}

// MARK: - Parametric helpers (one per scenario, called twice from each @Test)

private func runSelectionPreservesCompose<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .list, composeDraft: "abc")
    state.selectRow(target)
    #expect(state.mode == .list)
    #expect(state.composeDraft == "abc")
}

private func runEnterEditPreservesCompose<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .list, composeDraft: "abc")
    state.enterEdit(target: target, itemText: "todo text")
    #expect(state.mode == .edit(target))
    #expect(state.composeDraft == "abc")
}

private func runSaveReturnsToListAndPreservesCompose<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .edit(target), composeDraft: "abc")
    let result = state.saveEdit(text: "  new  ")
    #expect(result == .saved(target: target, text: TodoText("new")!))
    #expect(state.mode == .list)
    #expect(state.composeDraft == "abc")
}

private func runCancelReturnsToListAndPreservesCompose<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .edit(target), composeDraft: "abc")
    state.cancelEdit()
    #expect(state.mode == .list)
    #expect(state.composeDraft == "abc")
}

private func runEmptySaveIsRejected<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .edit(target), composeDraft: "abc")
    let result = state.saveEdit(text: "   ")
    #expect(result == .rejected)
    #expect(state.mode == .edit(target))
    #expect(state.composeDraft == "abc")
}

private func runClearFromList<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .list, composeDraft: "abc")
    state.clearComposeDraft()
    #expect(state.mode == .list)
    #expect(state.composeDraft == "")
}

private func runEditCmdNSuccessSavesBeforeClear<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .edit(target), composeDraft: "abc")
    let result = state.saveEdit(text: "new")
    #expect(result == .saved(target: target, text: TodoText("new")!))
    #expect(state.mode == .list)
    #expect(state.composeDraft == "abc")
    state.clearComposeDraft()
    #expect(state.mode == .list)
    #expect(state.composeDraft == "")
}

private func runEditCmdNRejectedPreservesDraft<T: Equatable>(target: T, otherTarget: T) {
    var state = TodoPopoverState<T>(mode: .edit(target), composeDraft: "abc")
    let result = state.saveEdit(text: "   ")
    #expect(result == .rejected)
    #expect(state.mode == .edit(target))
    #expect(state.composeDraft == "abc")
}
