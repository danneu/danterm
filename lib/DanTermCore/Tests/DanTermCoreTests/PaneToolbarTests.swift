// Swift Testing migration of the legacy `tests/PaneToolbarTests.swift`
// harness suite. Pins the pane toolbar text helpers: paneToolbarText
// (focused-pane title + optional cwd, defaults for unknown pane,
// empty-title passthrough) and formatToolbarLabel (title-only / title-
// equals-cwd abbreviation / title-differs / outside-home / outside-home
// identity).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct PaneToolbarTests {
    @Test("paneToolbarText: title only when cwd is nil")
    func paneToolbarTextTitleOnlyWhenCwdIsNil() {
        // Intent: paneToolbarText returns (title, nil) when the pane has
        //   a title but no cwd.
        // Why it exists: pins the cwd-nil branch.
        // Scenario: spec-first title only.
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "zsh" }
        model.updatePane(paneId) { $0.cwd = nil }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        #expect(title == "zsh")
        #expect(cwd == nil, "cwd should be nil")
    }

    @Test("paneToolbarText: title and cwd")
    func paneToolbarTextTitleAndCwd() {
        // Intent: paneToolbarText carries both title and cwd when both
        //   are set.
        // Why it exists: pins the happy path.
        // Scenario: spec-first title + cwd.
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "vim" }
        model.updatePane(paneId) { $0.cwd = "/Users/dan/projects" }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        #expect(title == "vim")
        #expect(cwd == "/Users/dan/projects")
    }

    @Test("paneToolbarText: default title for unknown pane")
    func paneToolbarTextDefaultTitleForUnknownPane() {
        // Intent: unknown pane returns ("Terminal", nil).
        // Why it exists: pins the fail-safe default for stale pane ids.
        // Scenario: spec-first unknown pane.
        let model = makeModel()
        let unknownId = PaneId()
        let (title, cwd) = paneToolbarText(for: unknownId, in: model)
        #expect(title == "Terminal")
        #expect(cwd == nil, "cwd should be nil")
    }

    @Test("paneToolbarText: empty title preserved")
    func paneToolbarTextEmptyTitlePreserved() {
        // Intent: an empty title is returned as "" (no default
        //   substitution).
        // Why it exists: pins the no-coerce rule.
        // Scenario: spec-first empty title.
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.updatePane(paneId) { $0.title = "" }
        let (title, _) = paneToolbarText(for: paneId, in: model)
        #expect(title == "")
    }

    // MARK: - formatToolbarLabel

    @Test("formatToolbarLabel: title only when cwd is nil")
    func formatToolbarLabelTitleOnlyWhenCwdIsNil() {
        // Intent: formatToolbarLabel(title, nil) renders just the title.
        // Why it exists: pins the cwd-nil rendering.
        // Scenario: spec-first title-only.
        #expect(formatToolbarLabel(title: "zsh", cwd: nil) == "zsh")
    }

    @Test("formatToolbarLabel: title equals cwd abbreviates home")
    func formatToolbarLabelTitleEqualsCwdAbbreviatesHome() {
        // Intent: when title == cwd and the path is under $HOME, the
        //   label abbreviates with ~/.
        // Why it exists: pins the abbreviation rule.
        // Scenario: spec-first title==cwd home abbreviation.
        let home = NSHomeDirectory()
        #expect(formatToolbarLabel(title: home + "/projects", cwd: home + "/projects") == "~/projects")
    }

    @Test("formatToolbarLabel: title differs from cwd shows both")
    func formatToolbarLabelTitleDiffersFromCwdShowsBoth() {
        // Intent: when title and cwd differ, the label renders
        //   "title \u{2013} ~/cwd".
        // Why it exists: pins the dual-render shape with the en-dash
        //   separator.
        // Scenario: spec-first title differs.
        let home = NSHomeDirectory()
        #expect(formatToolbarLabel(title: "vim", cwd: home + "/projects") == "vim \u{2013} ~/projects")
    }

    @Test("formatToolbarLabel: cwd outside home not abbreviated")
    func formatToolbarLabelCwdOutsideHomeNotAbbreviated() {
        // Intent: cwd outside $HOME is rendered verbatim.
        // Why it exists: pins the no-abbrev branch.
        // Scenario: spec-first cwd outside home.
        #expect(formatToolbarLabel(title: "zsh", cwd: "/tmp") == "zsh \u{2013} /tmp")
    }

    @Test("formatToolbarLabel: title equals cwd outside home")
    func formatToolbarLabelTitleEqualsCwdOutsideHome() {
        // Intent: title==cwd outside $HOME renders the path verbatim.
        // Why it exists: pins the identity branch for non-home paths.
        // Scenario: spec-first title==cwd outside home.
        #expect(formatToolbarLabel(title: "/tmp/foo", cwd: "/tmp/foo") == "/tmp/foo")
    }
}
