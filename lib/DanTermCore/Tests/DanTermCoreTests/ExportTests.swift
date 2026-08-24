// Swift Testing migration of the legacy `tests/ExportTests.swift` harness
// suite. Pins checkpoint normalization, exportState's snapshot payload, the toSnapshot/validateAndBuild
// round-trip + launch field projection, and the JSON encode/decode contract.
// `guard case` patterns that the legacy suite asserted via `throw
// TestFailure` migrate to `Issue.record + return` (1:1 with the throw).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct ExportTests {
    // MARK: - normalizeCheckpointScrollback

    @Test("normalizeCheckpointScrollback: empty string returns nil")
    func normalizeCheckpointScrollbackEmptyStringReturnsNil() {
        // Intent: an empty input string returns nil (not "").
        // Why it exists: pins the no-content guard so the snapshot stays
        //   absent rather than carrying a useless empty string.
        // Scenario: spec-first guard -- "" returns nil.
        #expect(normalizeCheckpointScrollback("") == nil, "empty should be nil")
    }

    @Test("normalizeCheckpointScrollback: whitespace-only returns nil")
    func normalizeCheckpointScrollbackWhitespaceOnlyReturnsNil() {
        // Intent: a whitespace-only input (spaces + newlines) returns nil.
        // Why it exists: pins the "no real content" guard; an idle terminal
        //   that scrolls only whitespace should produce no scrollback.
        // Scenario: spec-first guard -- "  \n  \n  " returns nil.
        #expect(normalizeCheckpointScrollback("  \n  \n  ") == nil, "whitespace should be nil")
    }

    @Test("normalizeCheckpointScrollback: text under limits gets trailing newline")
    func normalizeCheckpointScrollbackTextUnderLimitsGetsTrailingNewline() {
        // Intent: a multi-line input without a trailing newline acquires
        //   one in the output.
        // Why it exists: pins the canonical line-terminated form so
        //   downstream concatenation is predictable.
        // Scenario: spec-first canonicalization -- 3 lines without
        //   trailing newline become 3 lines + "\n".
        #expect(normalizeCheckpointScrollback("line1\nline2\nline3") == "line1\nline2\nline3\n")
    }

    @Test("normalizeCheckpointScrollback: text already ending in newline preserved")
    func normalizeCheckpointScrollbackTextAlreadyEndingInNewlinePreserved() {
        // Intent: a multi-line input ALREADY ending in newline survives
        //   unchanged.
        // Why it exists: idempotency of the trailing-newline normalization.
        // Scenario: spec-first idempotent -- a line-terminated input
        //   passes through.
        #expect(normalizeCheckpointScrollback("line1\nline2\n") == "line1\nline2\n")
    }


    @Test("normalizeCheckpointScrollback: trailing whitespace-only lines are stripped")
    func normalizeCheckpointScrollbackTrailingWhitespaceOnlyLinesAreStripped() {
        // Intent: lines at the tail that contain only whitespace are
        //   removed before the trailing newline is added.
        // Why it exists: a viewport read pads the visible buffer out to
        //   its full row count with whitespace lines, which should not
        //   pollute the saved scrollback.
        // Scenario: spec-first stripping -- "hello\nworld\n   \n   \n
        //   \n" becomes "hello\nworld\n".
        let result = normalizeCheckpointScrollback("hello\nworld\n   \n   \n   \n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("normalizeCheckpointScrollback: trailing empty lines are stripped")
    func normalizeCheckpointScrollbackTrailingEmptyLinesAreStripped() {
        // Intent: trailing entirely-empty lines (just \n\n\n) are stripped.
        // Why it exists: pins the no-trailing-blanks rule for the saved
        //   form.
        // Scenario: spec-first stripping -- "hello\nworld\n\n\n\n"
        //   becomes "hello\nworld\n".
        let result = normalizeCheckpointScrollback("hello\nworld\n\n\n\n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("normalizeCheckpointScrollback: trailing whitespace-only lines without final newline")
    func normalizeCheckpointScrollbackTrailingWhitespaceOnlyLinesWithoutFinalNewline() {
        // Intent: stripping also applies when the input lacks a final
        //   newline; the result still ends in a single "\n".
        // Why it exists: pins the canonicalization symmetric to the
        //   newline-terminated case.
        // Scenario: spec-first stripping -- "hello\nworld\n   \n   "
        //   becomes "hello\nworld\n".
        let result = normalizeCheckpointScrollback("hello\nworld\n   \n   ")!
        #expect(result == "hello\nworld\n")
    }

    @Test("normalizeCheckpointScrollback: trailing empty lines without final newline")
    func normalizeCheckpointScrollbackTrailingEmptyLinesWithoutFinalNewline() {
        // Intent: symmetric stripping for empty (not whitespace) trailing
        //   lines without a final newline.
        // Why it exists: pins the empty-vs-whitespace symmetry.
        // Scenario: spec-first stripping -- "hello\nworld\n\n" becomes
        //   "hello\nworld\n".
        let result = normalizeCheckpointScrollback("hello\nworld\n\n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("normalizeCheckpointScrollback: all-whitespace without final newline returns nil")
    func normalizeCheckpointScrollbackAllWhitespaceWithoutFinalNewlineReturnsNil() {
        // Intent: an input that is whitespace-only and lacks a final
        //   newline still surfaces as nil.
        // Why it exists: pins the no-content guard in the unterminated
        //   variant.
        // Scenario: spec-first guard -- "   \n   " returns nil.
        #expect(normalizeCheckpointScrollback("   \n   ") == nil, "only whitespace lines should be nil")
    }

    @Test("normalizeCheckpointScrollback: all-whitespace trailing lines returns nil")
    func normalizeCheckpointScrollbackAllWhitespaceTrailingLinesReturnsNil() {
        // Intent: an input that is whitespace-only AND ends in newline
        //   still surfaces as nil.
        // Why it exists: pins the no-content guard in the terminated
        //   variant.
        // Scenario: spec-first guard -- "   \n   \n" returns nil.
        #expect(normalizeCheckpointScrollback("   \n   \n") == nil, "only whitespace lines should be nil")
    }

    @Test("normalizeCheckpointScrollback: real scrollback without final newline (ghostty format)")
    func normalizeCheckpointScrollbackRealScrollbackWithoutFinalNewlineGhosttyFormat() {
        // Intent: a real ghostty scrollback sample (padded trailing
        //   blanks, no final newline) round-trips through truncation
        //   into the cleanly trimmed visible content.
        // Why it exists: pins the regression net for the actual ghostty
        //   payload shape -- a unit test that mirrors production input.
        // Scenario: spec-first regression -- a known ghostty paste-out
        //   trims to its first two lines.
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   "
        let result = normalizeCheckpointScrollback(input)!
        #expect(result == "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    @Test("normalizeCheckpointScrollback: real scrollback with padded trailing blank lines")
    func normalizeCheckpointScrollbackRealScrollbackWithPaddedTrailingBlankLines() {
        // Intent: the previous sample with a final newline also trims to
        //   the same first-two-lines result.
        // Why it exists: pins the equivalence between terminated and
        //   unterminated ghostty payloads.
        // Scenario: spec-first equivalence -- same ghostty sample, with
        //   trailing newline this time, yields the same trimmed result.
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n"
        let result = normalizeCheckpointScrollback(input)!
        #expect(result == "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    // MARK: - exportState Msg/Command

    @Test("exportState command contains AppModelSnapshot")
    func exportStateCommandContainsAppModelSnapshot() {
        // Intent: dispatching .exportState produces exactly one
        //   .exportState Command whose snapshot agrees with what
        //   toSnapshot(model) would have produced (groups, panes,
        //   selectedTabId, IDs, and session cwd) AND whose
        //   focused pane's leaf embeds the pane.
        // Why it exists: pins the export wire payload, including the
        //   leaf-embedded pane shape and the pure-snapshot scrollback
        //   contract (nil here -- enrichment happens at runtime).
        // Scenario: spec-first export -- a tab with a vim-running pane at
        //   ~/projects exports a structural snapshot whose launch surfaces
        //   the abbreviated cwd without a runtime lifecycle graft.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) { $0.session?.cwd = NSHomeDirectory() + "/projects" }
        let expected = toSnapshot(model)
        let commands = update(&model, .exportState)
        #expect(commands.count == 1)
        guard case .exportState(let snapshot) = commands[0] else {
            Issue.record("expected .exportState command")
            return
        }
        #expect(snapshot.groups.count == expected.groups.count)
        #expect(allPaneSnapshots(snapshot).count == allPaneSnapshots(expected).count)
        #expect(snapshot.selectedTabId == expected.selectedTabId)
        // Verify IDs match
        #expect(snapshot.groups[0].id == expected.groups[0].id)
        #expect(snapshot.groups[0].tabs[0].id == expected.groups[0].tabs[0].id)
        #expect(snapshot.groups[0].tabs[0].focusedPaneId == expected.groups[0].tabs[0].focusedPaneId)
        // Verify pane fields (panes now live embedded in the tree leaves)
        let snapPane = allPaneSnapshots(snapshot)[0]
        #expect(snapPane.id == allPaneSnapshots(expected)[0].id)
        #expect(snapPane.command == nil)
        #expect(snapPane.cwd == "~/projects")
        // Pure snapshot has nil scrollback (enrichment happens in runtime)
        #expect(snapPane.scrollback == nil, "pure snapshot should have nil scrollback")
        // Verify rootNode type -- the leaf embeds the focused pane.
        if case .leaf(let leafPane) = snapshot.groups[0].tabs[0].rootNode {
            #expect(leafPane.id == paneId)
        } else {
            Issue.record("expected leaf rootNode")
            return
        }
    }

    // MARK: - toSnapshot round-trip

    @Test("toSnapshot round-trips through validateAndBuild")
    func toSnapshotRoundTripsThroughValidateAndBuild() {
        // Intent: toSnapshot then validateAndBuild reconstructs a model
        //   that agrees on group count and pane count.
        // Why it exists: pins the encode/decode round-trip; deeper field
        //   parity is covered by sibling tests.
        // Scenario: spec-first round-trip -- one tab survives the round
        //   trip with matching counts.
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        #expect(rebuilt != nil, "round-trip should produce valid model")
        #expect(rebuilt!.groups.count == model.groups.count)
        #expect(rebuilt!.allPaneIds.count == model.allPaneIds.count)
    }

    @Test("toSnapshot preserves UUIDs through round-trip")
    func toSnapshotPreservesUUIDsThroughRoundTrip() {
        // Intent: group/tab/pane/selectedTab UUIDs survive the round trip
        //   verbatim.
        // Why it exists: pins identity preservation so external bookmarks
        //   and references survive a restart.
        // Scenario: spec-first preservation -- every typed-id field
        //   on the rebuilt model equals the originating model.
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        #expect(rebuilt.groups[0].id == model.groups[0].id)
        #expect(rebuilt.groups[0].tabs[0].id == model.groups[0].tabs[0].id)
        #expect(rebuilt.selectedTabId == model.selectedTabId)
        let origPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        #expect(rebuilt.pane(origPaneId) != nil, "pane ID should survive round-trip")
    }

    @Test("toSnapshot preserves selectedTabId")
    func toSnapshotPreservesSelectedTabId() {
        // Intent: selectedTabId reflects the currently-selected tab AFTER
        //   a .selectTab Msg, not a stale value.
        // Why it exists: pins the round-trip of explicit tab selection
        //   independent of insertion order.
        // Scenario: spec-first preservation -- create two tabs, select
        //   the first, snapshot's selectedTabId matches.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        let snapshot = toSnapshot(model)
        #expect(snapshot.selectedTabId == firstTabId)
    }

    @Test("toSnapshot preserves split tree structure")
    func toSnapshotPreservesSplitTreeStructure() {
        // Intent: a horizontal split with ratio 0.5 survives the round-
        //   trip with direction and ratio intact AND with two pane leaves.
        // Why it exists: pins the split branch of the snapshot encoder/
        //   decoder; the leaf branch is covered by the round-trip test.
        // Scenario: spec-first split round-trip -- the rebuilt rootNode
        //   is .split with the same direction/ratio.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        let tab = rebuilt.groups[0].tabs[0]
        if case .split(_, let dir, _, _, let ratio) = tab.paneTree.root {
            #expect(dir == .horizontal)
            #expect(ratio == 0.5)
        } else {
            Issue.record("expected split node")
            return
        }
        #expect(allPaneIds(tab.paneTree.root).count == 2)
    }

    @Test("toSnapshot preserves multiple groups")
    func toSnapshotPreservesMultipleGroups() {
        // Intent: two groups in declared order survive the round-trip
        //   with their names.
        // Why it exists: pins the group-level preservation.
        // Scenario: spec-first round-trip -- General + Work names survive.
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        #expect(rebuilt.groups.count == 2)
        #expect(rebuilt.groups[0].name == "General")
        #expect(rebuilt.groups[1].name == "Work")
    }

    @Test("toSnapshot preserves group collapsed state")
    func toSnapshotPreservesGroupCollapsedState() {
        // Intent: a group's isCollapsed flag (true) survives encoding to
        //   the snapshot.
        // Why it exists: pins the collapse state's serialization so the
        //   sidebar restores in the same shape.
        // Scenario: spec-first round-trip -- a collapsed group surfaces
        //   isCollapsed == true on its snapshot.
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        update(&model, .toggleGroupCollapse(groupId: model.groups[1].id))
        let snapshot = toSnapshot(model)
        #expect(snapshot.groups[1].isCollapsed == true)
    }

    // MARK: - Recovery command

    @Test("the structural snapshot excludes the model command mirror")
    func structuralSnapshotExcludesModelCommandMirror() {
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].command == nil)
    }

    @Test("command and cwd are nil when their sources are absent")
    func commandAndCwdAreNilWhenSourcesAreAbsent() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) { $0.session?.cwd = nil }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].command == nil)
        #expect(allPaneSnapshots(snapshot)[0].cwd == nil)
    }

    @Test("cwd abbreviated with ~ in export")
    func cwdAbbreviatedWithTildeInExport() {
        // Intent: a pane's cwd containing the user's home expands BACK to
        //   ~/relative in the exported snapshot.
        // Why it exists: pins the inverse of expandTilde so exports stay
        //   portable across users.
        // Scenario: spec-first abbreviation -- cwd = $HOME/projects
        //   exports as ~/projects.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.session?.cwd = home + "/projects" }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].cwd == "~/projects")
    }

    @Test("pane cwd is present when cwd is set")
    func paneCwdPresentWhenCwdIsSet() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.session?.cwd = home + "/work" }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].cwd == "~/work")
    }

    @Test("session recovery memo combines command with structural cwd")
    func sessionRecoveryMemoCombinesCommandAndCwd() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.session?.cwd = home + "/code" }
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("claude")))
        let snapshot = toSnapshot(model)
        let pane = allPaneSnapshots(snapshot)[0]
        #expect(pane.command == "claude")
        #expect(pane.cwd == "~/code")
    }

    // MARK: - JSON round-trip

    @Test("JSON round-trip preserves command metadata")
    func jsonRoundTripPreservesCommandMetadata() throws {
        // Intent: a model with a split tab and a vim-running pane at
        //   ~/work survives encode (with sorted-keys + pretty-print) and
        //   decode + validateAndBuild, with the recovery fields intact and
        //   both panes reachable.
        // Why it exists: pins the JSON-side round-trip distinct from the
        //   in-memory snapshot round-trip (different code paths).
        // Scenario: spec-first JSON round-trip -- the decoded pane's
        //   command/cwd match what was set; the rebuilt model has
        //   the expected pane count.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) { $0.session?.cwd = NSHomeDirectory() + "/work" }
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("claude")))
        let snapshot = toSnapshot(model)
        let initFile = toInitFile(snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(initFile)
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: data)

        // Verify snapshot-level recovery fields survive encoding.
        let exportedPane = paneSnapshot(paneId, in: decoded.model)
        #expect(exportedPane != nil, "pane should exist in decoded snapshot")
        #expect(exportedPane?.command == "claude")
        #expect(exportedPane?.cwd == "~/work")

        // Verify full rebuild succeeds
        let rebuilt = validateAndBuild(decoded.model)
        #expect(rebuilt != nil, "JSON round-trip should produce valid model")
        #expect(rebuilt!.allPaneIds.count == 2)
    }
}
