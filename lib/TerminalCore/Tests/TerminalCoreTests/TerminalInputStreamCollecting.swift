// Test-only eager collection of the parser's token stream.
//
// Production streams tokens straight into the grid reducer -- `Terminal.feed` pulls one action,
// applies it, and pulls the next -- so no `[TerminalStreamAction]` is built anywhere outside this
// file (`research/33/T7`). The parser's contract is still a token *sequence*, and asserting on one
// array is how these tests state it, so the array lives here rather than in the engine.
@testable import TerminalCore

/// Lends a scratch the size production uses, for a suite that drives `nextAction` itself.
func withScalarRunScratch<R>(
    _ body: (UnsafeMutableBufferPointer<Unicode.Scalar>) -> R
) -> R {
    withUnsafeTemporaryAllocation(
        of: Unicode.Scalar.self,
        capacity: TerminalInputStream.scalarRunCap,
        body
    )
}

extension TerminalInputStream {
    /// Drains a whole chunk into an array, leaving unfinished UTF-8 and VT state in `self`.
    mutating func feed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        feedCapturingRunScalars(bytes).actions
    }

    /// Drains a chunk and copies out the scalars each scalar run left in the scratch.
    ///
    /// The scratch lives for one feed and every run in it overwrites the last one's entries, so a
    /// caller that wants a run's scalars must take them while that run is the current action --
    /// which is what the grid reducer does, and what this reproduces for the suites. A test that
    /// only wants the token stream uses `feed` instead.
    mutating func feedCapturingRunScalars(
        _ bytes: [UInt8]
    ) -> (actions: [TerminalStreamAction], runScalars: [[Unicode.Scalar]]) {
        var actions: [TerminalStreamAction] = []
        var runScalars: [[Unicode.Scalar]] = []
        bytes.withUnsafeBufferPointer { buffer in
            withScalarRunScratch { scratch in
                var index = 0
                while let action = nextAction(in: buffer, from: &index, into: scratch) {
                    if case let .printScalarRun(_, _, scalarCount) = action {
                        runScalars.append(Array(scratch[0..<scalarCount]))
                    }
                    actions.append(action)
                }
            }
        }
        return (actions, runScalars)
    }
}
