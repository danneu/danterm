// Executable OSC 133 prompt-anchor oracle proofs, including every check's can-fire case.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves the prompt-anchor oracle covers the complete DanTerm recording corpus and mutation domain.
struct TerminalSemanticPromptInvariantTests {
    @Test("every DanTerm recording preserves prompt-anchor invariants after every event")
    func recordingCorpus() throws {
        // Intent: every authored recording runs every stable and mutation-level prompt check.
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

    @Test("each semantic prompt invariant check rejects an invalid state or transition")
    func everyCheckCanFire() {
        let blank = TerminalSemanticPromptRowSnapshot(
            stamp: .none,
            cells: [],
            isSoftWrapped: false
        )
        let vacated = TerminalSemanticPromptRowSnapshot(
            stamp: .vacated,
            cells: [],
            isSoftWrapped: false
        )
        let prompt = TerminalSemanticPromptRowSnapshot(
            stamp: .prompt,
            cells: [],
            isSoftWrapped: false
        )
        let wrapped = TerminalSemanticPromptRowSnapshot(
            stamp: .none,
            cells: [],
            isSoftWrapped: true
        )
        #expect(semanticPromptStateViolations(in: [vacated, prompt]).contains(.ownership))
        #expect(
            semanticPromptStateViolations(in: [wrapped, prompt]).contains(.logicalLineIntegrity)
        )
        #expect(
            semanticPromptStateViolations(in: [
                TerminalSemanticPromptRowSnapshot(
                    stamp: .vacated,
                    cells: [],
                    isSoftWrapped: true
                ),
            ]).contains(.totalVacating)
        )

        let output = TerminalSemanticPromptRowSnapshot(
            stamp: .output,
            cells: [],
            isSoftWrapped: false
        )
        let changedOutput = TerminalSemanticPromptRowSnapshot(
            stamp: .output,
            cells: [TerminalCell(
                kind: .narrow,
                scalars: .single("x"),
                style: TerminalStyle()
            )],
            isSoftWrapped: false
        )
        let base = TerminalSemanticPromptTransitionState(
            rows: [output, blank],
            cursorRow: 1,
            scrollRegion: 0..<2,
            isAlternateScreenActive: false
        )
        #expect(Terminal.semanticPromptTransitionViolationsForTesting(
            mutation: .vacate,
            redrawMode: .full,
            before: base,
            after: TerminalSemanticPromptTransitionState(
                rows: [changedOutput, blank],
                cursorRow: 1,
                scrollRegion: 0..<2,
                isAlternateScreenActive: false
            )
        ).contains(.outputFloor))
        #expect(Terminal.semanticPromptTransitionViolationsForTesting(
            mutation: .reclaim(top: 0, removed: 1),
            redrawMode: .full,
            before: TerminalSemanticPromptTransitionState(
                rows: [vacated, prompt],
                cursorRow: 1,
                scrollRegion: 0..<2,
                isAlternateScreenActive: true
            ),
            after: TerminalSemanticPromptTransitionState(
                rows: [prompt, blank],
                cursorRow: 0,
                scrollRegion: 0..<2,
                isAlternateScreenActive: true
            )
        ).contains(.geometryCoherence))
        #expect(Terminal.semanticPromptTransitionViolationsForTesting(
            mutation: .vacate,
            redrawMode: .disabled,
            before: base,
            after: TerminalSemanticPromptTransitionState(
                rows: [output, vacated],
                cursorRow: 1,
                scrollRegion: 0..<2,
                isAlternateScreenActive: false
            )
        ).contains(.redrawModeScope))
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
