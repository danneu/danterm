// Test-only expansion of the parser's bulk print runs back to one action per scalar.
//
// The parser hands the grid byte ranges rather than a `.print` per character (`research/33/T8`),
// but each range is an encoding of a token subsequence, not a different token stream. The parser
// suites assert on the scalar-level stream because that is the contract they exist to pin --
// which byte produces which token, at which split point -- and expanding here keeps them stating
// it directly instead of re-deriving run boundaries in every expectation.
//
// Nothing in production expands a run. `Terminal.feed` consumes the range as a range.
@testable import TerminalCore

extension TerminalInputStream {
    /// Feeds a chunk and returns its tokens with every bulk print run spelled out per scalar.
    mutating func expandedFeed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        feed(bytes).flatMap { action -> [TerminalStreamAction] in
            switch action {
            case let .printASCIIRun(range):
                return range.map { .print(Unicode.Scalar(bytes[$0])) }
            case let .printScalarRun(range):
                var decoder = UTF8Decoder()
                return range.compactMap { offset in
                    decoder.next(bytes[offset]).scalar.map(TerminalStreamAction.print)
                }
            default:
                return [action]
            }
        }
    }
}
