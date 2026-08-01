// Replays the real-Ghostty inspection corpus through TerminalCore at its recorded checkpoints.
import Foundation
import Testing

@testable import TerminalCore

/// Keeps backend migration evidence headless while treating recorded Ghostty output as adjudicable evidence.
struct GhosttyInspectionRecoveryReplayTests {
    @Test(
        "Ghostty characterization feeds reject non-base64 representations",
        arguments: [
            #"{"type":"feed","hex":"61"}"#,
            #"{"type":"feed","base64":"YQ==","hex":"61"}"#,
            #"{"type":"feed","base64":"YQ==","text":"a"}"#,
        ]
    )
    func characterizationNonBase64FeedsAreRejected(_ json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ReplayEvent.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test("Ghostty inspection and recovery corpus replays through Swift projections")
    func replayCharacterizationCorpus() throws {
        // Intent: replay the exact characterized bytes and resize sequence through
        //   TerminalCore, comparing viewport and primary recovery text at every phase.
        // Why it exists: backend parity can otherwise regress at reflow or alternate-
        //   screen boundaries while narrower native projection tests remain green.
        // Scenario: the real Ghostty-backed app emitted a primary corpus at 56 columns,
        //   reflowed it to 90 and back to 56, entered alternate screen, then returned.
        let url = try #require(Bundle.module.url(
            forResource: "inspection-recovery",
            withExtension: "json",
            subdirectory: "Fixtures/ghostty"
        ))
        let corpus = try JSONDecoder().decode(
            GhosttyInspectionRecoveryCorpus.self,
            from: Data(contentsOf: url)
        )
        #expect(corpus.format == 1)
        #expect(corpus.backend == "Ghostty v1.3.1 through DanTerm app and bundled CLI")
        #expect(corpus.widths == .init(narrow: 56, wide: 90))
        #expect(corpus.replay.initialColumns == corpus.widths.narrow)
        #expect(corpus.divergencesFromTerminalEngineContract == [alternateCursorDivergence])
        var terminal = try #require(Terminal(
            columns: corpus.replay.initialColumns,
            rows: corpus.replay.rows
        ))

        for event in corpus.replay.events {
            switch event {
            case .feed(let bytes):
                terminal.feed(bytes)
            case .resize(let columns):
                terminal.resize(columns: columns, rows: corpus.replay.rows)
            case .expect(let checkpoint):
                let expected = corpus.expectation(for: checkpoint)
                if checkpoint == .alternate {
                    let terminalCoreViewport = expected.viewport.replacingOccurrences(
                        of: "\n        ALT-TRANSIENT",
                        with: "\n          ALT-TRANSIENT"
                    )
                    #expect(
                        terminal.viewportText == terminalCoreViewport,
                        "TerminalCore's adjudicated alternate viewport changed"
                    )
                    withKnownIssue("Ghostty carries this cursor two columns behind TerminalCore after reflow.") {
                        #expect(
                            terminal.viewportText == expected.viewport,
                            "Viewport divergence at \(checkpoint.rawValue)"
                        )
                    }
                } else {
                    #expect(
                        terminal.viewportText == expected.viewport,
                        "Viewport divergence at \(checkpoint.rawValue)"
                    )
                }
                #expect(
                    terminal.primaryHistoryText == expected.primaryHistory,
                    "Primary-history divergence at \(checkpoint.rawValue)"
                )
            }
        }
    }
}

private let alternateCursorDivergence = "Ghostty places the carried cursor at column 8 on alternate-screen entry after 56/90/56 reflow; TerminalCore keeps it attached to the end of CORPUS-END at column 10."

private struct GhosttyInspectionRecoveryCorpus: Decodable {
    let format: Int
    let backend: String
    let widths: Widths
    let captures: Captures
    let divergencesFromTerminalEngineContract: [String]
    let replay: Replay

    func expectation(for checkpoint: Checkpoint) -> Expectation {
        switch checkpoint {
        case .narrow:
            Expectation(
                viewport: captures.narrow.viewport,
                primaryHistory: captures.narrow.fullOverLimit
            )
        case .wide:
            Expectation(
                viewport: captures.wide.viewport,
                primaryHistory: captures.wide.fullOverLimit
            )
        case .narrowAfterReflow:
            Expectation(
                viewport: captures.narrowAfterReflow.viewport,
                primaryHistory: captures.narrowAfterReflow.fullOverLimit
            )
        case .alternate:
            Expectation(
                viewport: captures.alternateViewport,
                primaryHistory: captures.narrowAfterReflow.fullOverLimit
            )
        case .returnedPrimary:
            Expectation(
                viewport: captures.returnedPrimaryViewport,
                primaryHistory: captures.returnedPrimaryFull
            )
        }
    }

    struct Captures: Decodable {
        let narrow: PrimaryCapture
        let wide: PrimaryCapture
        let narrowAfterReflow: PrimaryCapture
        let alternateViewport: String
        let returnedPrimaryViewport: String
        let returnedPrimaryFull: String
    }

    struct PrimaryCapture: Decodable {
        let viewport: String
        let fullOverLimit: String
    }

    struct Replay: Decodable {
        let initialColumns: Int
        let rows: Int
        let events: [ReplayEvent]
    }

    struct Widths: Decodable, Equatable {
        let narrow: Int
        let wide: Int
    }

    struct Expectation {
        let viewport: String
        let primaryHistory: String
    }
}

private enum Checkpoint: String, Decodable {
    case narrow
    case wide
    case narrowAfterReflow
    case alternate
    case returnedPrimary
}

private enum ReplayEvent: Decodable {
    case feed([UInt8])
    case resize(columns: Int)
    case expect(Checkpoint)

    private enum CodingKeys: String, CodingKey {
        case type
        case base64
        case hex
        case text
        case columns
        case checkpoint
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "feed":
            guard values.contains(.hex) == false, values.contains(.text) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: values.contains(.hex) ? .hex : .text,
                    in: values,
                    debugDescription: "Characterization feeds must contain only base64"
                )
            }
            let base64 = try values.decode(String.self, forKey: .base64)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .base64,
                    in: values,
                    debugDescription: "Invalid base64 feed"
                )
            }
            self = .feed(Array(data))
        case "resize":
            self = .resize(columns: try values.decode(Int.self, forKey: .columns))
        case "expect":
            self = .expect(try values.decode(Checkpoint.self, forKey: .checkpoint))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: values,
                debugDescription: "Unsupported characterization replay event: \(type)"
            )
        }
    }

}
