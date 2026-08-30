// Test-only expansion of the parser's bulk print runs back to one action per scalar.
//
// The parser hands the grid byte ranges rather than a `.print` per character (`research/33/T8`),
// but each range is an encoding of a token subsequence, not a different token stream. The parser
// suites assert on the scalar-level stream because that is the contract they exist to pin --
// which byte produces which token, at which split point -- and expanding here keeps them stating
// it directly instead of re-deriving run boundaries in every expectation.
//
// Nothing in production expands a run. `Terminal.feed` consumes the range as a range.
//
// Expanding is also the one place that can check a run's carried scalar count against an
// independent decode of the same bytes, so it does that here rather than leaving the count
// pinned only where an expectation happens to spell the number out.
import Testing

@testable import TerminalCore

extension TerminalInputStream {
    /// Feeds a chunk and returns its tokens with every bulk print run spelled out per scalar.
    mutating func expandedFeed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        feed(bytes).flatMap { action -> [TerminalStreamAction] in
            switch action {
            case let .printASCIIRun(range):
                return range.map { .print(PrintedScalar(Unicode.Scalar(bytes[$0]))) }
            case let .printScalarRun(range, _, scalarCount):
                var decoder = UTF8Decoder()
                let prints: [TerminalStreamAction] = range.compactMap { offset in
                    decoder.next(bytes[offset]).scalar.map { .print(PrintedScalar($0)) }
                }
                // Every parser suite runs through here, so checking the count against an
                // independent decode of the same range pins it wherever a run appears rather
                // than only where an expectation spells the number out.
                #expect(
                    prints.count == scalarCount,
                    "run \(range) carries \(scalarCount) but decodes to \(prints.count) scalars"
                )
                return prints
            default:
                return [action]
            }
        }
    }
}
