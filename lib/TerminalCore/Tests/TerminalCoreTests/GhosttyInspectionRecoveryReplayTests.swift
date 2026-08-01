// Replays the real-Ghostty inspection corpus through TerminalCore at its recorded checkpoints.
import Foundation
import Testing

@testable import TerminalCore

/// Keeps backend migration evidence headless while treating recorded Ghostty output as adjudicable evidence.
struct GhosttyInspectionRecoveryReplayTests {
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
        case hex
        case base64
        case columns
        case checkpoint
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "feed":
            if let base64 = try values.decodeIfPresent(String.self, forKey: .base64) {
                guard let data = Data(base64Encoded: base64) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .base64,
                        in: values,
                        debugDescription: "Invalid base64 feed"
                    )
                }
                self = .feed(Array(data))
            } else {
                let hex = try values.decode(String.self, forKey: .hex)
                self = .feed(try Self.decodeHex(hex))
            }
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

    private static func decodeHex(_ hex: String) throws -> [UInt8] {
        guard hex.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Odd-length hex feed"))
        }
        return try stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            guard let byte = UInt8(hex[start..<end], radix: 16) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid hex feed"))
            }
            return byte
        }
    }
}
