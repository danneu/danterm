import Foundation

func paneToolbarTests() {
    print("PaneToolbar")

    test("paneToolbarText: title only when cwd is nil") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "zsh" }
        model.updatePane(paneId) { $0.cwd = nil }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        try expectEqual(title, "zsh")
        try expect(cwd == nil, "cwd should be nil")
    }

    test("paneToolbarText: title and cwd") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "vim" }
        model.updatePane(paneId) { $0.cwd = "/Users/dan/projects" }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        try expectEqual(title, "vim")
        try expectEqual(cwd, "/Users/dan/projects")
    }

    test("paneToolbarText: default title for unknown pane") {
        let model = makeModel()
        let unknownId = PaneId()
        let (title, cwd) = paneToolbarText(for: unknownId, in: model)
        try expectEqual(title, "Terminal")
        try expect(cwd == nil, "cwd should be nil")
    }

    test("paneToolbarText: empty title preserved") {
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "" }
        let (title, _) = paneToolbarText(for: paneId, in: model)
        try expectEqual(title, "")
    }

    // formatToolbarLabel

    test("formatToolbarLabel: title only when cwd is nil") {
        try expectEqual(formatToolbarLabel(title: "zsh", cwd: nil), "zsh")
    }

    test("formatToolbarLabel: title equals cwd abbreviates home") {
        let home = NSHomeDirectory()
        try expectEqual(formatToolbarLabel(title: home + "/projects", cwd: home + "/projects"), "~/projects")
    }

    test("formatToolbarLabel: title differs from cwd shows both") {
        let home = NSHomeDirectory()
        try expectEqual(formatToolbarLabel(title: "vim", cwd: home + "/projects"), "vim \u{2013} ~/projects")
    }

    test("formatToolbarLabel: cwd outside home not abbreviated") {
        try expectEqual(formatToolbarLabel(title: "zsh", cwd: "/tmp"), "zsh \u{2013} /tmp")
    }

    test("formatToolbarLabel: title equals cwd outside home") {
        try expectEqual(formatToolbarLabel(title: "/tmp/foo", cwd: "/tmp/foo"), "/tmp/foo")
    }
}
