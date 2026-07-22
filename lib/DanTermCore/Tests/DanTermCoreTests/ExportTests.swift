// Swift Testing migration of the legacy `tests/ExportTests.swift` harness
// suite. Pins commandStarted Msg side effects, truncateScrollback's char/line/whitespace
// rules, exportState's snapshot payload, the toSnapshot/validateAndBuild
// round-trip + launch field projection, and the JSON encode/decode contract.
// `guard case` patterns that the legacy suite asserted via `throw
// TestFailure` migrate to `Issue.record + return` (1:1 with the throw).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct ExportTests {
    // MARK: - commandStarted Msg

    @Test("commandStarted sets lastCommand")
    func commandStartedSetsLastCommand() {
        // Intent: dispatching .commandStarted updates the pane's
        //   lastCommand to the supplied command string.
        // Why it exists: pins the model update for the .commandStarted Msg
        //   that the title-channel translation feeds.
        // Scenario: spec-first update -- pane gets lastCommand = "vim".
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        #expect(model.pane(paneId)?.lastCommand == "vim")
    }

    @Test("commandStarted overwrites previous command")
    func commandStartedOverwritesPreviousCommand() {
        // Intent: a second .commandStarted overwrites the prior
        //   lastCommand (no history list).
        // Why it exists: pins the latest-only semantics; the field tracks
        //   the most recent command, not a history.
        // Scenario: spec-first overwrite -- vim then ssh -> lastCommand
        //   is "ssh".
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        update(&model, .commandStarted(paneId: paneId, command: "ssh"))
        #expect(model.pane(paneId)?.lastCommand == "ssh")
    }

    @Test("commandStarted does not affect title")
    func commandStartedDoesNotAffectTitle() {
        // Intent: .commandStarted updates lastCommand but never the pane
        //   title (those are separate channels).
        // Why it exists: pins the channel separation so a command-event
        //   does not rename the pane.
        // Scenario: spec-first separation -- title is unchanged after
        //   .commandStarted.
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        let titleBefore = model.pane(paneId)?.title
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        #expect(model.pane(paneId)?.title == titleBefore)
    }

    @Test("surfaceTitle does not affect lastCommand")
    func surfaceTitleDoesNotAffectLastCommand() {
        // Intent: a subsequent .surfaceTitle does NOT clear or change
        //   lastCommand (only .commandStarted/.commandEnded do).
        // Why it exists: pins the inverse of the previous test --
        //   ordinary title updates do not regress the command field.
        // Scenario: spec-first preservation -- after a title change,
        //   lastCommand still equals the previously started command.
        var model = makeModel()
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        update(&model, .commandStarted(paneId: paneId, command: "vim"))
        update(&model, .surfaceTitle(paneId: paneId, title: "new title"))
        #expect(model.pane(paneId)?.lastCommand == "vim")
    }

    // MARK: - truncateScrollback

    @Test("truncateScrollback: empty string returns nil")
    func truncateScrollbackEmptyStringReturnsNil() {
        // Intent: an empty input string returns nil (not "").
        // Why it exists: pins the no-content guard so the snapshot stays
        //   absent rather than carrying a useless empty string.
        // Scenario: spec-first guard -- "" returns nil.
        #expect(truncateScrollback("") == nil, "empty should be nil")
    }

    @Test("truncateScrollback: whitespace-only returns nil")
    func truncateScrollbackWhitespaceOnlyReturnsNil() {
        // Intent: a whitespace-only input (spaces + newlines) returns nil.
        // Why it exists: pins the "no real content" guard; an idle terminal
        //   that scrolls only whitespace should produce no scrollback.
        // Scenario: spec-first guard -- "  \n  \n  " returns nil.
        #expect(truncateScrollback("  \n  \n  ") == nil, "whitespace should be nil")
    }

    @Test("enriched recovery dirties only when the persisted projection changes")
    func enrichedRecoveryMutationClassification() {
        #expect(enrichedRecoveryProjectionChanged(from: "", to: "  \n ") == false)
        #expect(enrichedRecoveryProjectionChanged(from: "shell", to: "shell\n\n  ") == false)
        #expect(enrichedRecoveryProjectionChanged(from: "shell", to: "shell output") == true)
    }

    @Test("truncateScrollback: text under limits gets trailing newline")
    func truncateScrollbackTextUnderLimitsGetsTrailingNewline() {
        // Intent: a multi-line input without a trailing newline acquires
        //   one in the output.
        // Why it exists: pins the canonical line-terminated form so
        //   downstream concatenation is predictable.
        // Scenario: spec-first canonicalization -- 3 lines without
        //   trailing newline become 3 lines + "\n".
        #expect(truncateScrollback("line1\nline2\nline3") == "line1\nline2\nline3\n")
    }

    @Test("truncateScrollback: text already ending in newline preserved")
    func truncateScrollbackTextAlreadyEndingInNewlinePreserved() {
        // Intent: a multi-line input ALREADY ending in newline survives
        //   unchanged.
        // Why it exists: idempotency of the trailing-newline normalization.
        // Scenario: spec-first idempotent -- a line-terminated input
        //   passes through.
        #expect(truncateScrollback("line1\nline2\n") == "line1\nline2\n")
    }

    @Test("truncateScrollback: keeps last maxLines lines")
    func truncateScrollbackKeepsLastMaxLinesLines() {
        // Intent: with input lines exceeding maxLines, the last maxLines
        //   are retained (the older lines drop).
        // Why it exists: pins the "tail" retention strategy so checkpoint
        //   storage is bounded.
        // Scenario: spec-first tail -- 5000 lines truncated to 4000
        //   surfaces lines 1001..5000.
        let lines = (1...5000).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let result = truncateScrollback(text, maxLines: 4000)!
        let resultLines = result.split(separator: "\n")
        #expect(resultLines.count == 4000)
        #expect(String(resultLines.first!) == "line 1001")
        #expect(String(resultLines.last!) == "line 5000")
    }

    @Test("truncateScrollback: over maxChars truncates at newline")
    func truncateScrollbackOverMaxCharsTruncatesAtNewline() {
        // Intent: a text exceeding maxChars (but under maxLines) is
        //   truncated to <= maxChars, breaking at a newline boundary.
        // Why it exists: pins the byte-bound; ensures the truncation
        //   point is a newline (no torn line).
        // Scenario: spec-first cap -- 100 lines of 100-char text capped
        //   at 500 chars and starting on a clean line.
        // Build text that's under line limit but over char limit
        let longLine = String(repeating: "x", count: 100)
        let lines = (1...100).map { _ in longLine }
        let text = lines.joined(separator: "\n")
        // maxChars=500 with 100-char lines + newlines
        let result = truncateScrollback(text, maxLines: 10000, maxChars: 500)!
        #expect(result.count <= 500, "result should be at most maxChars")
        // Should break at a newline boundary
        #expect(!result.hasPrefix("\n"), "should not start with newline")
    }

    @Test("truncateScrollback: exactly at limit")
    func truncateScrollbackExactlyAtLimit() {
        // Intent: an input exactly at maxLines retains everything and
        //   appends the trailing newline.
        // Why it exists: pins the boundary case so off-by-one drops don't
        //   sneak in.
        // Scenario: spec-first boundary -- 2 lines at maxLines=2 keeps
        //   both.
        let result = truncateScrollback("a\nb", maxLines: 2)!
        #expect(result == "a\nb\n")
    }

    @Test("truncateScrollback: one over limit")
    func truncateScrollbackOneOverLimit() {
        // Intent: an input one line over maxLines drops the OLDEST line
        //   (the first), retaining the last maxLines.
        // Why it exists: pins the tail-keep direction at the boundary.
        // Scenario: spec-first boundary -- 3 lines at maxLines=2 keeps
        //   the latter two.
        let result = truncateScrollback("a\nb\nc", maxLines: 2)!
        #expect(result == "b\nc\n")
    }

    @Test("truncateScrollback: consecutive newlines count as empty lines")
    func truncateScrollbackConsecutiveNewlinesCountAsEmptyLines() {
        // Intent: consecutive \n sequences count as empty lines for the
        //   maxLines tail-keep -- a "\n\n\n" prefix produces three empty
        //   lines.
        // Why it exists: pins the line-counting semantics so blank lines
        //   in the middle aren't silently coalesced.
        // Scenario: spec-first count -- "a\n\n\nb" at maxLines=2 keeps
        //   one empty line and "b".
        let result = truncateScrollback("a\n\n\nb", maxLines: 2)!
        #expect(result == "\nb\n")
    }

    @Test("truncateScrollback: trailing whitespace-only lines are stripped")
    func truncateScrollbackTrailingWhitespaceOnlyLinesAreStripped() {
        // Intent: lines at the tail that contain only whitespace are
        //   removed before the trailing newline is added.
        // Why it exists: pins the ghostty-padding behavior -- ghostty
        //   pads the visible buffer with whitespace lines that should
        //   not pollute the saved scrollback.
        // Scenario: spec-first stripping -- "hello\nworld\n   \n   \n
        //   \n" becomes "hello\nworld\n".
        let result = truncateScrollback("hello\nworld\n   \n   \n   \n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("truncateScrollback: trailing empty lines are stripped")
    func truncateScrollbackTrailingEmptyLinesAreStripped() {
        // Intent: trailing entirely-empty lines (just \n\n\n) are stripped.
        // Why it exists: pins the no-trailing-blanks rule for the saved
        //   form.
        // Scenario: spec-first stripping -- "hello\nworld\n\n\n\n"
        //   becomes "hello\nworld\n".
        let result = truncateScrollback("hello\nworld\n\n\n\n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("truncateScrollback: trailing whitespace-only lines without final newline")
    func truncateScrollbackTrailingWhitespaceOnlyLinesWithoutFinalNewline() {
        // Intent: stripping also applies when the input lacks a final
        //   newline; the result still ends in a single "\n".
        // Why it exists: pins the canonicalization symmetric to the
        //   newline-terminated case.
        // Scenario: spec-first stripping -- "hello\nworld\n   \n   "
        //   becomes "hello\nworld\n".
        let result = truncateScrollback("hello\nworld\n   \n   ")!
        #expect(result == "hello\nworld\n")
    }

    @Test("truncateScrollback: trailing empty lines without final newline")
    func truncateScrollbackTrailingEmptyLinesWithoutFinalNewline() {
        // Intent: symmetric stripping for empty (not whitespace) trailing
        //   lines without a final newline.
        // Why it exists: pins the empty-vs-whitespace symmetry.
        // Scenario: spec-first stripping -- "hello\nworld\n\n" becomes
        //   "hello\nworld\n".
        let result = truncateScrollback("hello\nworld\n\n")!
        #expect(result == "hello\nworld\n")
    }

    @Test("truncateScrollback: all-whitespace without final newline returns nil")
    func truncateScrollbackAllWhitespaceWithoutFinalNewlineReturnsNil() {
        // Intent: an input that is whitespace-only and lacks a final
        //   newline still surfaces as nil.
        // Why it exists: pins the no-content guard in the unterminated
        //   variant.
        // Scenario: spec-first guard -- "   \n   " returns nil.
        #expect(truncateScrollback("   \n   ") == nil, "only whitespace lines should be nil")
    }

    @Test("truncateScrollback: all-whitespace trailing lines returns nil")
    func truncateScrollbackAllWhitespaceTrailingLinesReturnsNil() {
        // Intent: an input that is whitespace-only AND ends in newline
        //   still surfaces as nil.
        // Why it exists: pins the no-content guard in the terminated
        //   variant.
        // Scenario: spec-first guard -- "   \n   \n" returns nil.
        #expect(truncateScrollback("   \n   \n") == nil, "only whitespace lines should be nil")
    }

    @Test("truncateScrollback: real scrollback without final newline (ghostty format)")
    func truncateScrollbackRealScrollbackWithoutFinalNewlineGhosttyFormat() {
        // Intent: a real ghostty scrollback sample (padded trailing
        //   blanks, no final newline) round-trips through truncation
        //   into the cleanly trimmed visible content.
        // Why it exists: pins the regression net for the actual ghostty
        //   payload shape -- a unit test that mirrors production input.
        // Scenario: spec-first regression -- a known ghostty paste-out
        //   trims to its first two lines.
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   "
        let result = truncateScrollback(input)!
        #expect(result == "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    @Test("truncateScrollback: real scrollback with padded trailing blank lines")
    func truncateScrollbackRealScrollbackWithPaddedTrailingBlankLines() {
        // Intent: the previous sample with a final newline also trims to
        //   the same first-two-lines result.
        // Why it exists: pins the equivalence between terminated and
        //   unterminated ghostty payloads.
        // Scenario: spec-first equivalence -- same ghostty sample, with
        //   trailing newline this time, yields the same trimmed result.
        let input = "╭ repo:danterm                                                                         k8s:orbstack\n╰ $                                                                                                \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n                                                                                                   \n"
        let result = truncateScrollback(input)!
        #expect(result == "╭ repo:danterm                                                                         k8s:orbstack\n╰ $\n")
    }

    // MARK: - exportState Msg/Command

    @Test("exportState command contains AppModelSnapshot")
    func exportStateCommandContainsAppModelSnapshot() {
        // Intent: dispatching .exportState produces exactly one
        //   .exportState Command whose snapshot agrees with what
        //   toSnapshot(model) would have produced (groups, panes,
        //   selectedTabId, IDs, launch.command, launch.cwd) AND whose
        //   focused pane's leaf embeds the pane.
        // Why it exists: pins the export wire payload, including the
        //   leaf-embedded pane shape and the pure-snapshot scrollback
        //   contract (nil here -- enrichment happens at runtime).
        // Scenario: spec-first export -- a tab with a vim-running pane at
        //   ~/projects exports a snapshot whose launch surfaces the cwd
        //   abbreviated to "~/projects" and the command "vim".
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.lastCommand = "vim" }
        model.updatePane(paneId) { $0.cwd = NSHomeDirectory() + "/projects" }
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
        // Verify launch fields (panes now live embedded in the tree leaves)
        let snapPane = allPaneSnapshots(snapshot)[0]
        #expect(snapPane.id == allPaneSnapshots(expected)[0].id)
        #expect(snapPane.launch?.command == "vim")
        #expect(snapPane.launch?.cwd == "~/projects")
        // Pure snapshot has nil scrollback (enrichment happens in runtime)
        #expect(snapPane.scrollback == nil, "pure snapshot should have nil scrollback")
        // Verify rootNode type -- the leaf embeds the focused pane.
        if case .leaf(let leafPane) = snapshot.groups[0].tabs[0].rootNode {
            #expect(leafPane.id == paneId.rawValue.uuidString)
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
        let origPaneId = model.groups[0].tabs[0].focusedPaneId
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
        #expect(snapshot.selectedTabId == firstTabId.rawValue.uuidString)
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
        update(&model, .splitPane(direction: .horizontal))
        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)!
        let tab = rebuilt.groups[0].tabs[0]
        if case .split(_, let dir, _, _, let ratio) = tab.rootNode {
            #expect(dir == .horizontal)
            #expect(ratio == 0.5)
        } else {
            Issue.record("expected split node")
            return
        }
        #expect(allPaneIds(tab.rootNode).count == 2)
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

    // MARK: - Launch field

    @Test("lastCommand maps to launch.command in snapshot")
    func lastCommandMapsToLaunchCommandInSnapshot() {
        // Intent: a pane's lastCommand surfaces in its snapshot
        //   pane.launch.command.
        // Why it exists: pins the lastCommand -> launch.command projection
        //   that the encoder uses.
        // Scenario: spec-first projection -- set lastCommand="vim",
        //   snapshot.launch.command == "vim".
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.lastCommand = "vim" }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].launch?.command == "vim")
    }

    @Test("launch omitted when no command and no cwd")
    func launchOmittedWhenNoCommandAndNoCwd() {
        // Intent: a pane with neither cwd nor lastCommand has a nil launch
        //   field on its snapshot (no spurious empty launch object).
        // Why it exists: pins the snapshot's optional-empty convention.
        // Scenario: spec-first projection -- clear both fields, snapshot
        //   launch is nil.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.cwd = nil }
        model.updatePane(paneId) { $0.lastCommand = nil }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].launch == nil, "launch should be nil when no command and no cwd")
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
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.cwd = home + "/projects" }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].cwd == "~/projects")
    }

    @Test("launch.cwd present when cwd is set")
    func launchCwdPresentWhenCwdIsSet() {
        // Intent: with a cwd set (and no command), launch is present and
        //   carries the abbreviated cwd.
        // Why it exists: pins the "cwd alone implies a launch" projection.
        // Scenario: spec-first projection -- cwd = ~/work, snapshot
        //   launch.cwd = "~/work".
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.cwd = home + "/work" }
        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot)[0].launch?.cwd == "~/work")
    }

    @Test("launch has both command and cwd when both set")
    func launchHasBothCommandAndCwdWhenBothSet() {
        // Intent: with both lastCommand and cwd set, launch is present
        //   and carries both fields.
        // Why it exists: pins the combined projection from the model into
        //   the snapshot.launch object.
        // Scenario: spec-first projection -- cwd + command -> snapshot
        //   launch has both.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let home = NSHomeDirectory()
        model.updatePane(paneId) { $0.cwd = home + "/code" }
        model.updatePane(paneId) { $0.lastCommand = "claude" }
        let snapshot = toSnapshot(model)
        let launch = allPaneSnapshots(snapshot)[0].launch
        #expect(launch != nil, "launch should be present")
        #expect(launch?.command == "claude")
        #expect(launch?.cwd == "~/code")
    }

    // MARK: - JSON round-trip

    @Test("JSON round-trip preserves command metadata")
    func jsonRoundTripPreservesCommandMetadata() throws {
        // Intent: a model with a split tab and a vim-running pane at
        //   ~/work survives encode (with sorted-keys + pretty-print) and
        //   decode + validateAndBuild, with the launch fields intact and
        //   both panes reachable.
        // Why it exists: pins the JSON-side round-trip distinct from the
        //   in-memory snapshot round-trip (different code paths).
        // Scenario: spec-first JSON round-trip -- the decoded pane's
        //   launch.command/cwd match what was set; the rebuilt model has
        //   the expected pane count.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.lastCommand = "claude" }
        model.updatePane(paneId) { $0.cwd = NSHomeDirectory() + "/work" }
        let initFile = toInitFile(model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(initFile)
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: data)

        // Verify snapshot-level launch fields survive encoding (panes embedded in leaves)
        let exportedPane = paneSnapshot(paneId.rawValue.uuidString, in: decoded.model)
        #expect(exportedPane != nil, "pane should exist in decoded snapshot")
        #expect(exportedPane?.launch?.command == "claude")
        #expect(exportedPane?.launch?.cwd == "~/work")

        // Verify full rebuild succeeds
        let rebuilt = validateAndBuild(decoded.model)
        #expect(rebuilt != nil, "JSON round-trip should produce valid model")
        #expect(rebuilt!.allPaneIds.count == 2)
    }
}
