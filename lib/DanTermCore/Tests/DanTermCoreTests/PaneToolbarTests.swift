// Swift Testing coverage for toolbar label formatting from the legacy
// `tests/PaneToolbarTests.swift` harness suite. Pins the title-only,
// title-equals-cwd abbreviation, title-differs, outside-home, and outside-home
// identity cases.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct PaneToolbarTests {
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
