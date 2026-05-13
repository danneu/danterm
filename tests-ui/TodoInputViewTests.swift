/// UI tests for TodoInputView sizing.

import Cocoa

func todoInputViewTests() {
    print("TodoInputView")

    uiTest("default input reports compact height") {
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

    uiTest("edit input reports larger visible line count height") {
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
}
