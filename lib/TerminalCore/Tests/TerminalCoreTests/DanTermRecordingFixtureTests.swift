// Replays the captured Milestone 4 app workflow as deterministic TerminalCore evidence.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Keeps the first complete Swift-pane workflow in the default headless regression gate.
struct DanTermRecordingFixtureTests {
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
            case .resize(let columns, let rows):
                terminal.resize(columns: columns, rows: rows)
            case .checkpoint:
                break
            }
        }
        return terminal
    }
}

private enum ReplayChunkStrategy {
    case bytewise
    case split
}
