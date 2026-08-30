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
// Expanding is also the one place that can check what a run hands the grid -- the scalars it left
// in the scratch, and the count it carries -- against an independent decode of the same bytes, so
// it does that here rather than leaving them pinned only where an expectation happens to spell
// them out.
import Testing

@testable import TerminalCore

extension TerminalInputStream {
    /// Feeds a chunk and returns its tokens with every bulk print run spelled out per scalar.
    mutating func expandedFeed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        let (actions, runScalars) = feedCapturingRunScalars(bytes)
        var runIndex = 0
        return actions.flatMap { action -> [TerminalStreamAction] in
            switch action {
            case let .printASCIIRun(range):
                return range.map { .print(PrintedScalar(Unicode.Scalar(bytes[$0]))) }
            case let .printScalarRun(range, _, scalarCount):
                let stamped = runScalars[runIndex]
                runIndex += 1
                var decoder = UTF8Decoder()
                let decoded = range.compactMap { decoder.next(bytes[$0]).scalar }
                // Every parser suite runs through here, so checking what the run hands the grid
                // against an independent decode of the same range pins it wherever a run appears
                // rather than only where an expectation spells it out.
                #expect(
                    decoded.count == scalarCount,
                    "run \(range) carries \(scalarCount) but decodes to \(decoded.count) scalars"
                )
                #expect(
                    stamped == decoded,
                    "run \(range) stamps \(stamped) but decodes to \(decoded)"
                )
                // Expanding from the scratch rather than from the independent decode is what makes
                // every suite's token expectations a statement about the scalars the grid will
                // actually be given.
                return stamped.map { .print(PrintedScalar($0)) }
            default:
                return [action]
            }
        }
    }
}
