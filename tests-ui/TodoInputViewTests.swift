// UI tests for TodoInputView sizing and undo ownership.

import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func todoInputViewTests() async {
    print("TodoInputView")

    await uiTest("default input reports compact height") {
        let input = TodoInputView()
        try uiExpect(
            TodoInputView.inputHeight == TodoInputView.height(visibleLineCount: TodoInputView.defaultVisibleLineCount),
            "default input height should match the compact line count"
        )
        try uiExpect(
            input.fittingSize.height == TodoInputView.inputHeight,
            "default fitting height should match inputHeight"
        )
    }

    await uiTest("edit input reports larger visible line count height") {
        let input = TodoInputView(visibleLineCount: TodoInputView.editVisibleLineCount)
        let expectedHeight = TodoInputView.inputLineHeight * CGFloat(TodoInputView.editVisibleLineCount)
            + TodoInputView.inputInsetY * 2

        try uiExpect(expectedHeight > TodoInputView.inputHeight, "edit height should be larger than default")
        try uiExpect(
            TodoInputView.height(visibleLineCount: TodoInputView.editVisibleLineCount) == expectedHeight,
            "edit height should use the requested line count"
        )
        try uiExpect(
            input.fittingSize.height == expectedHeight,
            "edit fitting height should match the requested line count"
        )
    }

    await uiTest("todo input scopes undo to its own manager and still undoes typing") {
        // Intent: a TodoInputView's typing undo lives in a manager owned by the
        //   field, and in-field undo while composing still works.
        // Why it exists: regression for the 2026-06-09 SIGSEGV. Typing undo
        //   registered against the window's shared manager outlived the
        //   transient popover text view, so a later Cmd-Z messaged a freed object.
        // Scenario: a user types in a todo popover, dismisses it without saving,
        //   then presses Cmd-Z in the parent window. No undo registration should
        //   survive in the window manager after the field goes away.
        let input = TodoInputView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = input
        window.makeFirstResponder(input.textView)
        let textView = input.textView

        try uiExpect(textView.undoManager != nil, "todo input should expose an undo manager")
        try uiExpect(
            textView.undoManager !== window.undoManager,
            "todo input undo must be scoped to the field, not the window's shared manager"
        )

        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        try uiExpect(textView.string == "hello", "sanity: text was inserted")
        try uiExpect(textView.undoManager?.canUndo == true, "the field's manager recorded the edit")
        try uiExpect(
            window.undoManager?.canUndo == false,
            "the edit must not leak into the window's manager"
        )

        textView.undoManager?.undo()
        try uiExpect(textView.string.isEmpty, "in-field undo restores the text")
    }
}
