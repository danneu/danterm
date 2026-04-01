import Cocoa

func sidebarBadgeTests() {
    print("SidebarBadge")

    uiTest("visibleAlertBadge finds visible badge") {
        let cell = NSTableCellView()
        let badge = NSTextField.makeBadge()
        badge.identifier = NSUserInterfaceItemIdentifier("bellDot")
        badge.updateBadge(count: 3)
        let stack = NSStackView(views: [badge])
        stack.identifier = NSUserInterfaceItemIdentifier("tabAccessoryStack")
        cell.addSubview(stack)

        let result = visibleAlertBadge(in: cell)
        try uiExpect(result === badge, "should find the badge")
    }

    uiTest("visibleAlertBadge returns nil when badge hidden") {
        let cell = NSTableCellView()
        let badge = NSTextField.makeBadge()
        badge.identifier = NSUserInterfaceItemIdentifier("bellDot")
        badge.updateBadge(count: 0)
        let stack = NSStackView(views: [badge])
        stack.identifier = NSUserInterfaceItemIdentifier("tabAccessoryStack")
        cell.addSubview(stack)

        let result = visibleAlertBadge(in: cell)
        try uiExpect(result == nil, "should return nil for hidden badge")
    }

    uiTest("visibleAlertBadge returns nil for cell without badge") {
        let cell = NSTableCellView()
        let result = visibleAlertBadge(in: cell)
        try uiExpect(result == nil, "should return nil for empty cell")
    }
}
