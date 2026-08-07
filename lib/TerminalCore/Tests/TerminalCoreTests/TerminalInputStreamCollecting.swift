// Test-only eager collection of the parser's token stream.
//
// Production streams tokens straight into the grid reducer -- `Terminal.feed` pulls one action,
// applies it, and pulls the next -- so no `[TerminalStreamAction]` is built anywhere outside this
// file (`research/33/T7`). The parser's contract is still a token *sequence*, and asserting on one
// array is how these tests state it, so the array lives here rather than in the engine.
@testable import TerminalCore

extension TerminalInputStream {
    /// Drains a whole chunk into an array, leaving unfinished UTF-8 and VT state in `self`.
    mutating func feed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        var actions: [TerminalStreamAction] = []
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            while let action = nextAction(in: buffer, from: &index) {
                actions.append(action)
            }
        }
        return actions
    }
}
