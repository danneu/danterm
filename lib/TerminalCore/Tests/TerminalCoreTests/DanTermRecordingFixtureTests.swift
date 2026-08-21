// Replays the captured Milestone 4 app workflow as deterministic TerminalCore evidence.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Keeps the first complete Swift-pane workflow in the default headless regression gate.
struct DanTermRecordingFixtureTests {
    @Test("captured zsh OSC 133 width sweep remains chunk invariant without stale prompts")
    func zshOSC133WidthSweepRecording() throws {
        // Intent: replay the diagnosed zsh repaint byte pattern across interleaved resizes.
        // Why it exists: a final-state-only synthetic feed misses the resize/repaint ordering
        //   that produced the split-pane prompt staircase.
        // Scenario: AppKit emits several intermediate split widths and zsh redraws its
        //   two-line semantic prompt after each SIGWINCH.
        let recording = try loadRecording(named: "zsh-osc133-width-sweep")
        try recording.provenance.validate()
        let authored = try recording.replay()
        let bytewise = try replay(recording, strategy: .bytewise)
        let split = try replay(recording, strategy: .split)

        #expect(bytewise == authored)
        #expect(split == authored)
        #expect(authored.fullHistoryText.components(separatedBy: "ABCDEFGHIJKL").count - 1 == 1)
        expectValidGrid(authored)
    }

    @Test("fish title hook with U+2733 never leaks control-string bytes")
    func fishU2733TitleRecording() throws {
        // Intent: replay the fish title hook and matching program output without allowing
        //   U+2733's 0x9c continuation byte to terminate OSC.
        // Why it exists: valid command text in OSC 0 must not become replacement glyphs or
        //   stale title bytes in the terminal grid.
        // Scenario: fish titles a `printf '✳'` command, the program prints the scalar,
        //   and the following prompt appears on the next line.
        let recording = try loadRecording(named: "fish-u2733-title")
        let authored = try recording.replay()
        let bytes = try #require(recording.events.first?.feedBytes)

        #expect(authored.screenText == "✳                   \n$                   \n                    ")
        #expect(authored.screenText.contains("\u{FFFD}") == false)
        #expect(authored.screenText.contains("printf") == false)

        var bytewise = try #require(Terminal(columns: 20, rows: 3))
        for byte in bytes { bytewise.feed([byte]) }
        #expect(bytewise == authored)

        for offset in 0...bytes.count {
            var split = try #require(Terminal(columns: 20, rows: 3))
            split.feed(Array(bytes[..<offset]))
            split.feed(Array(bytes[offset...]))
            #expect(split == authored, "split at \(offset)")
        }
    }

    @Test("DanTerm Kitty input recording replays mode-aware bytes")
    func kittyInputRecording() throws {
        let url = try #require(Bundle.module.url(
            forResource: "keyboard-kitty",
            withExtension: "json",
            subdirectory: "Fixtures/danterm"
        ))
        let recording = try JSONDecoder().decode(
            NeutralTerminalRecording.self,
            from: Data(contentsOf: url)
        )
        try recording.provenance.validate()

        var terminal = try #require(Terminal(columns: 8, rows: 3))
        var emitted: [UInt8] = []
        for event in recording.events {
            switch event {
            case .feed(let bytes):
                terminal.feed(bytes)
                emitted.append(contentsOf: terminal.drainReplyBytes())
            case .input(let key, let modifiers):
                let before = terminal
                emitted.append(contentsOf: encodeTerminalKey(key, modifiers: modifiers, modes: terminal.inputModes))
                #expect(terminal == before)
            case .paste(let text):
                let before = terminal
                emitted.append(contentsOf: encodeTerminalPaste(text, modes: terminal.inputModes))
                #expect(terminal == before)
            case .focus(let focused):
                // Focus is the one input the terminal retains, so this arm changes state.
                emitted.append(contentsOf: terminal.setFocused(focused))
            case .write, .mouse, .resize, .viewport, .checkpoint:
                break
            }
        }

        // The `\u{1B}[O` sits where the recording enables mode 1004: the terminal answers the
        // enable with the focus it retains, which is unfocused until the later focus event.
        #expect(emitted == Array("\u{1B}[?1u\u{1B}[97;5u\u{1B}[13;2u\u{1B}[O\u{1B}[200~safe\ntext\u{1B}[201~\u{1B}[I".utf8))
    }

    @Test("captured Milestone 4 workflow is provenance-valid and chunk-invariant")
    func milestone4ViabilityRecording() throws {
        // Intent: prove the real app capture validates as DanTerm evidence, produces
        //   one final state under three feed chunkings, and retains the gate markers.
        // Why it exists: a green interactive run is otherwise ephemeral and cannot
        //   protect the engine's complete first-pane workflow in the default gate.
        // Scenario: the Milestone 4 viability harness completed ordinary and composed
        //   input, Unicode, editing, jobs, files, paging, reflow, and hidden-pane output.
        let url = try #require(Bundle.module.url(
            forResource: "milestone-4-viability",
            withExtension: "json",
            subdirectory: "Fixtures/danterm"
        ))
        let recording = try JSONDecoder().decode(
            NeutralTerminalRecording.self,
            from: Data(contentsOf: url)
        )

        try recording.provenance.validate()
        #expect(recording.provenance == .danTerm(test: "milestone-4-viability"))

        let authored = try recording.replay()
        let bytewise = try replay(recording, strategy: .bytewise)
        let split = try replay(recording, strategy: .split)

        #expect(bytewise == authored)
        #expect(split == authored)

        let requiredMarkers = [
            "TYPED:ordinary",
            "DEADKEY:é",
            "SPANISH: niño, acción, corazón",
            "CHINESE: 你好世界",
            "EMOJI: 🙂 🚀",
            "EDIT:right",
            "JOB-CTRL-C",
            "JOB-BACKGROUND-DONE",
            "LS-DONE",
            "CAT-DONE",
            "LESS-QUIT-DONE",
            "REFLOW-BEGIN",
            "REFLOW-END",
            "HIDDEN-PANE-OUTPUT",
            "VIABILITY-FINAL",
        ]
        for marker in requiredMarkers {
            #expect(authored.fullHistoryText.contains(marker), "Missing workflow marker: \(marker)")
        }
    }

    private func replay(
        _ recording: NeutralTerminalRecording,
        strategy: ReplayChunkStrategy
    ) throws -> Terminal {
        var terminal = try #require(Terminal(
            columns: recording.initial.columns,
            rows: recording.initial.rows
        ))
        for event in recording.events {
            switch event {
            case .feed(let bytes):
                switch strategy {
                case .bytewise:
                    for byte in bytes {
                        terminal.feed([byte])
                    }
                case .split:
                    let midpoint = bytes.count / 2
                    terminal.feed(Array(bytes[..<midpoint]))
                    terminal.feed(Array(bytes[midpoint...]))
                }
            case .write, .input, .paste, .focus, .mouse:
                break
            case .resize(let columns, let rows, _):
                terminal.resize(columns: columns, rows: rows)
            case .viewport(let navigation):
                switch navigation {
                case .byRows(let rows): terminal.scroll(byRows: rows)
                case .toTopRow(let row): terminal.scroll(toTopRow: row)
                case .toBottom: terminal.scrollToBottom()
                }
            case .checkpoint:
                break
            }
        }
        return terminal
    }

    private func loadRecording(named name: String) throws -> NeutralTerminalRecording {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/danterm"
        ))
        return try JSONDecoder().decode(NeutralTerminalRecording.self, from: Data(contentsOf: url))
    }
}

private extension NeutralTerminalRecordingEvent {
    var feedBytes: [UInt8]? {
        guard case .feed(let bytes) = self else { return nil }
        return bytes
    }
}

private enum ReplayChunkStrategy {
    case bytewise
    case split
}
