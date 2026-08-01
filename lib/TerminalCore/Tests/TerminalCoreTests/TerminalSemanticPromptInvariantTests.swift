// Executable OSC 133 prompt-anchor proofs: the universal snapshot oracle over the recording
// corpus (I1, I2, I4) with every check's can-fire case, plus targeted behavioral tests that
// bracket the vacate and reclaim operations for the transition invariants (I3, I5, I6), which
// no post-event snapshot can prove.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves the prompt-anchor snapshot oracle covers the complete DanTerm recording corpus and the
/// transition invariants hold across precisely bracketed vacate and reclaim operations.
struct TerminalSemanticPromptInvariantTests {
    @Test("every DanTerm recording preserves prompt-anchor invariants after every event")
    func recordingCorpus() throws {
        // Intent: every authored recording runs every snapshot-provable prompt check.
        // Why it exists: named fixture lists let future recordings silently miss the oracle.
        // Scenario: a new live-pane recording is added to Fixtures/danterm without a test edit.
        let root = try #require(Bundle.module.resourceURL)
            .appending(path: "Fixtures/danterm", directoryHint: .isDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(urls.isEmpty == false)

        for url in urls {
            let decoded = try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: Data(contentsOf: url)
            )
            let recording = decoded.provenance.source == "danterm" ? decoded : NeutralTerminalRecording(
                provenance: .danTerm(test: url.deletingPathExtension().lastPathComponent),
                initial: decoded.initial,
                events: decoded.events
            )
            _ = try recording.replay { eventIndex, terminal in
                expectSemanticPromptInvariants(
                    terminal,
                    context: "\(url.lastPathComponent) event \(eventIndex)"
                )
            }
        }
    }

    @Test("each snapshot oracle check rejects an invalid state")
    func everyCheckCanFire() {
        let vacated = TerminalSemanticPromptRowSnapshot(
            stamp: .vacated,
            isSoftWrapped: false,
            isEmpty: true
        )
        let prompt = TerminalSemanticPromptRowSnapshot(
            stamp: .prompt,
            isSoftWrapped: false,
            isEmpty: false
        )
        let wrapped = TerminalSemanticPromptRowSnapshot(
            stamp: .none,
            isSoftWrapped: true,
            isEmpty: false
        )
        #expect(semanticPromptStateViolations(in: [vacated, prompt]).contains(.ownership))
        #expect(
            semanticPromptStateViolations(in: [wrapped, prompt]).contains(.logicalLineIntegrity)
        )
        #expect(
            semanticPromptStateViolations(in: [
                TerminalSemanticPromptRowSnapshot(
                    stamp: .vacated,
                    isSoftWrapped: true,
                    isEmpty: true
                ),
            ]).contains(.totalVacating)
        )
    }

    @Test("resize blanking and reclaim never touch completed command output")
    func outputFloorSurvivesVacateAndReclaim() throws {
        // Intent: an output-stamped row keeps its content through both prompt-anchor
        //   mutations -- resize blanking of the prompt block and reclaim of the stale head.
        // Why it exists: I3 is a transition invariant no post-event snapshot can prove;
        //   this bracket drives each mutation and checks the floor directly.
        // Scenario: the pre-d1eb808 bug deleted finished output during reclaim while
        //   leaving structurally valid rows behind; this is the regression shape.
        var terminal = try #require(Terminal(columns: 8, rows: 5))
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}$ cmd\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;C\u{7}DONE\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}old".utf8))
        #expect(terminal.semanticPromptRowsForTesting[1].stamp == .output)

        terminal.resize(columns: 9, rows: 5)
        var lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("$ cmd"))
        #expect(lines[1].hasPrefix("DONE"))
        #expect(terminal.screenText.contains("old") == false)
        #expect(terminal.semanticPromptRowsForTesting[1].stamp == .output)

        terminal.feed(Array("\r\n\u{1B}]133;A;redraw=1\u{7}new".utf8))
        lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("$ cmd"))
        #expect(lines[1].hasPrefix("DONE"))
        #expect(lines[2].hasPrefix("new"))
        #expect(terminal.semanticPromptRowsForTesting[1].stamp == .output)
        expectSemanticPromptInvariants(terminal, context: "output floor")
    }

    @Test("resize blanking honors the declared redraw mode's scope")
    func redrawModeScopesResizeBlanking() throws {
        // Intent: under redraw=0 a resize blanks nothing; under redraw=last it blanks
        //   only the final prompt row and leaves rows above shell-owned.
        // Why it exists: I6 is a transition invariant over what one blanking pass was
        //   allowed to change; only a bracket around the resize can observe its scope.
        var disabled = try #require(Terminal(columns: 8, rows: 4))
        disabled.feed(Array("\u{1B}]133;A;redraw=0\u{7}$ keep".utf8))
        disabled.resize(columns: 8, rows: 5)
        #expect(disabled.screenText.hasPrefix("$ keep"))
        #expect(disabled.semanticPromptRowsForTesting[0].stamp == .prompt)
        expectSemanticPromptInvariants(disabled, context: "redraw disabled")

        var last = try #require(Terminal(columns: 8, rows: 4))
        last.feed(Array("\u{1B}]133;A;redraw=last\u{7}TOP\r\nBOT".utf8))
        last.resize(columns: 8, rows: 5)
        let stamps = last.semanticPromptRowsForTesting
        #expect(last.screenText.hasPrefix("TOP"))
        #expect(last.screenText.contains("BOT") == false)
        #expect(stamps[0].stamp == .prompt)
        #expect(stamps[1].stamp == .vacated)
        #expect(stamps[1].isEmpty)
        expectSemanticPromptInvariants(last, context: "redraw last")
    }

    @Test(
        "reclaim preserves earlier prompt rows outside full redraw mode",
        arguments: ["last", "0"]
    )
    func redrawModeScopesReclaim(_ redrawMode: String) throws {
        // Intent: a new prompt head under redraw=last or redraw=0 does not reclaim an
        //   earlier soft-wrapped prompt head or pull the cursor upward.
        // Why it exists: I6 constrains reclaim as well as resize blanking, so the mode
        //   guard needs a focused behavioral bracket independent of dialect recordings.
        // Scenario: a non-full-redraw shell marks a new prompt directly below a wrapped
        //   earlier head whose shape would be reclaimable under redraw=1.
        var terminal = try #require(Terminal(columns: 4, rows: 5))
        terminal.feed(Array("\u{1B}]133;A;redraw=\(redrawMode)\u{7}ABCDX\r".utf8))
        let cursorBeforeMark = try #require(terminal.geometry.cursor)

        terminal.feed(Array("\u{1B}]133;A;redraw=\(redrawMode)\u{7}new".utf8))

        #expect(terminal.geometry.cursor?.row == cursorBeforeMark.row)
        #expect(terminal.screenText.hasPrefix("ABCD\nnew"))
        #expect(terminal.semanticPromptRowsForTesting.filter { $0.stamp == .prompt }.count == 2)
        expectSemanticPromptInvariants(terminal, context: "redraw=\(redrawMode) reclaim")
    }

    @Test("reclaim runs only on coherent primary-screen geometry")
    func reclaimGuardDomain() throws {
        var permitted = try #require(Terminal(columns: 8, rows: 5))
        permitted.feed(Array("KEEP\r\n\u{1B}]133;A;redraw=1\u{7}old".utf8))
        permitted.resize(columns: 9, rows: 5)
        let beforeCursor = try #require(permitted.geometry.cursor?.row)
        permitted.feed(Array("\r\n\u{1B}]133;A;redraw=1\u{7}new".utf8))
        #expect(permitted.geometry.cursor?.row == beforeCursor)
        let permittedLines = permitted.screenText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        #expect(permittedLines[0].hasPrefix("KEEP"))
        #expect(permittedLines[1].hasPrefix("new"))
        #expect(permitted.screenText.contains("old") == false)
        expectSemanticPromptInvariants(permitted, context: "permitted reclaim")

        var alternate = try #require(Terminal(columns: 4, rows: 5))
        alternate.feed(Array("\u{1B}[?1049h\u{1B}]133;A;redraw=1\u{7}ABCDX\r".utf8))
        alternate.feed(Array("\u{1B}]133;A;redraw=1\u{7}new".utf8))
        #expect(alternate.semanticPromptRowsForTesting.filter { $0.stamp == .prompt }.count == 2)
        expectSemanticPromptInvariants(alternate, context: "alternate-screen guard")

        var region = try #require(Terminal(columns: 4, rows: 5))
        region.feed(Array("\u{1B}]133;A;redraw=1\u{7}ABCDX".utf8))
        region.feed(Array("\u{1B}[2;5r\u{1B}[2;1H\u{1B}]133;A;redraw=1\u{7}new".utf8))
        #expect(region.semanticPromptRowsForTesting.filter { $0.stamp == .prompt }.count == 2)
        expectSemanticPromptInvariants(region, context: "scroll-region guard")
    }
}
