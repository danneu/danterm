// UI-harness tests for the shared content-sized count badge.
import Cocoa
@testable import DanTerm

@MainActor
func badgeLabelTests() async {
    print("BadgeLabel")

    await uiTest("badges keep rendered count width beside flexible content") {
        // Intent: a badge keeps its padded text width while its flexible sibling
        //   receives surplus width, and a repainted multi-digit count grows the pill.
        // Why it exists: the generic label factory let a group count badge expand
        //   across the unused width of a wide sidebar.
        // Scenario: a pane or collapsed group repaints its count from 2 to 123.
        let title = NSTextField(labelWithString: "Title")
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = BadgeLabel()
        badge.updateBadge(count: 2)
        let stack = NSStackView(views: [title, badge])
        stack.orientation = .horizontal
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 22)

        stack.layoutSubtreeIfNeeded()
        let oneDigitWidth = badge.intrinsicContentSize.width
        try uiExpect(oneDigitWidth == 14,
            "one digit should use the 14-point intrinsic floor, got \(oneDigitWidth)")

        badge.updateBadge(count: 123)
        stack.layoutSubtreeIfNeeded()
        let threeDigitWidth = badge.intrinsicContentSize.width
        try uiExpect(threeDigitWidth > oneDigitWidth,
            "three digits should widen the pill: \(threeDigitWidth) vs \(oneDigitWidth)")
        try uiExpect(
            badge.contentHuggingPriority(for: .horizontal) == .required,
            "the badge should resist horizontal expansion")
        try uiExpect(
            badge.contentCompressionResistancePriority(for: .horizontal) == .required,
            "the badge should resist horizontal compression")
    }

    await uiTest("collapsed group badges stay compact through repaint states") {
        // Intent: a real group row keeps one- and multi-digit badges compact with
        //   either title length and with its optional alert badge shown or hidden.
        // Why it exists: the observed wide-sidebar failure occurred in this row,
        //   and its collapse and recycle paths repaint the same persistent fields.
        // Scenario: a recycled row moves through collapsed, expanded, and collapsed states.
        let sidebar = SidebarView(frame: .zero)
        let cell = SidebarGroupCellView(
            textFieldDelegate: sidebar,
            caretTarget: nil,
            caretAction: #selector(NSResponder.cancelOperation(_:)))
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let groupId = GroupId()

        func projection(
            name: String,
            collapsed: Bool,
            alerts: Int,
            tabs: Int
        ) -> SidebarGroupProjection {
            SidebarGroupProjection(
                id: groupId,
                rendered: SidebarGroupProjection.Rendered(
                    isCollapsed: collapsed, name: DisplayLine(name),
                    unreadAlertCount: alerts, tabCount: tabs, isFirst: true),
                tabs: [])
        }

        cell.apply(projection(name: "Short", collapsed: true, alerts: 0, tabs: 2).rendered,
                   isEditingTitle: false)
        cell.layoutSubtreeIfNeeded()
        let oneDigitWidth = cell.tabCountBadge.frame.width
        try uiExpect(oneDigitWidth < 24,
            "one-digit group count should stay compact, got \(oneDigitWidth)")
        try uiExpect(cell.alertBadge.isHidden, "zero alerts should hide the alert badge")

        cell.apply(projection(
            name: String(repeating: "Long title ", count: 20),
            collapsed: true, alerts: 12, tabs: 123).rendered, isEditingTitle: false)
        cell.layoutSubtreeIfNeeded()
        try uiExpect(cell.tabCountBadge.frame.width > oneDigitWidth,
            "a multi-digit group count should widen the pill")
        try uiExpect(cell.tabCountBadge.frame.width < 40,
            "a multi-digit group count should not take surplus row width")
        try uiExpect(!cell.alertBadge.isHidden && cell.alertBadge.frame.width < 32,
            "a visible alert badge should stay compact")

        cell.apply(projection(name: "Expanded", collapsed: false, alerts: 12, tabs: 123).rendered,
                   isEditingTitle: false)
        cell.layoutSubtreeIfNeeded()
        try uiExpect(cell.alertBadge.isHidden && cell.tabCountBadge.isHidden,
            "expansion should hide both collapsed-group badges")

        cell.apply(projection(name: "Recycled", collapsed: true, alerts: 1, tabs: 2).rendered,
                   isEditingTitle: false)
        cell.layoutSubtreeIfNeeded()
        try uiExpect(cell.tabCountBadge.frame.width == oneDigitWidth,
            "a recycled one-digit repaint should restore compact width")
    }
}
