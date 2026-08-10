// Test-only expansion of the parser's bulk ASCII runs back to one action per scalar.
//
// The parser hands the grid a `.printASCIIRun` range rather than a `.print` per character
// (`research/33/T8`), but that is an encoding of a token subsequence, not a different token
// stream: the run means exactly the `.print` actions it stands for. The parser suites assert on
// the scalar-level stream because that is the contract they exist to pin -- which byte produces
// which token, at which split point -- and expanding here is what keeps them stating it directly
// instead of re-deriving run boundaries in every expectation.
//
// Nothing in production expands a run. `Terminal.feed` consumes the range as a range.
@testable import TerminalCore

extension TerminalInputStream {
    /// Feeds a chunk and returns its tokens with every bulk ASCII run spelled out per scalar.
    mutating func expandedFeed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        feed(bytes).flatMap { action -> [TerminalStreamAction] in
            guard case let .printASCIIRun(range) = action else { return [action] }
            return range.map { .print(Unicode.Scalar(bytes[$0])) }
        }
    }
}
