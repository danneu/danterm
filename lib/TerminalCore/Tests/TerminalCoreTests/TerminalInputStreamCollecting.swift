// Test-only eager collection of the parser's token stream.
//
// Production streams tokens straight into the grid reducer -- `Terminal.feed` pulls one action,
// applies it, and pulls the next -- so no `[TerminalStreamAction]` is built anywhere outside this
// file (`research/33/T7`). The parser's contract is still a token *sequence*, and asserting on one
// array is how these tests state it, so the array lives here rather than in the engine.
@testable import TerminalCore

/// One captured scratch entry: the scalar a stretch stored and the writer it named for it.
///
/// The scratch itself is two spans that the next stretch overwrites, so a suite that wants to
/// assert on a stretch's entries copies them out as pairs while that stretch is current.
struct TerminalStretchEntry: Equatable {
    let scalar: Unicode.Scalar
    let kind: TerminalStretchSegmentKind
}

/// Lends a scratch the size production uses, for a suite that drives `nextAction` itself.
func withStretchScratch<R>(
    _ body: (TerminalStretchScratch) -> R
) -> R {
    TerminalStretchScratch.withScratch(body)
}

extension TerminalInputStream {
    /// Drains a whole chunk into an array, leaving unfinished UTF-8 and VT state in `self`.
    mutating func feed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        feedCapturingStretchScalars(bytes).actions
    }

    /// Drains a chunk and copies out the entries each text stretch left in the scratch.
    ///
    /// The scratch lives for one feed and every stretch in it overwrites the last one's entries,
    /// so a caller that wants a stretch's scalars must take them while that stretch is the current
    /// action -- which is what the grid reducer does, and what this reproduces for the suites. A
    /// test that only wants the token stream uses `feed` instead.
    mutating func feedCapturingStretchScalars(
        _ bytes: [UInt8]
    ) -> (actions: [TerminalStreamAction], stretchScalars: [[TerminalStretchEntry]]) {
        var actions: [TerminalStreamAction] = []
        var stretchScalars: [[TerminalStretchEntry]] = []
        bytes.withUnsafeBufferPointer { buffer in
            withStretchScratch { scratch in
                var index = 0
                while let action = nextAction(in: buffer, from: &index, into: scratch) {
                    if case let .printTextStretch(_, scalarCount) = action {
                        stretchScalars.append((0..<scalarCount).map {
                            TerminalStretchEntry(scalar: scratch.scalars[$0], kind: scratch.kinds[$0])
                        })
                    }
                    actions.append(action)
                }
            }
        }
        return (actions, stretchScalars)
    }
}
