// The deterministic pseudo-random source the randomized suites in this target share.
// Several suites drive a terminal with a seeded byte stream -- random feeds interleaved with
// resizes, selections, or scrollback pressure -- and each had grown its own byte-identical
// private copy of the same xorshift64 struct. One shared home means a seeded failure reproduces
// the same way from every suite. It lives in its own file rather than in TerminalGridAssertions,
// which is scoped to structural assertions about a grid; a random source is not an assertion.
//
// Nothing but the shared generator belongs here.

/// A seeded xorshift64 stream. The two accessors are named for their width on purpose: a call
/// site's seeded sequence depends on which one it uses (`% 6` over the truncated low byte and
/// over the full word give different answers), so moving a site between them silently changes
/// what it exercises. Overloading on return type would let that happen by inference.
struct SeededByteGenerator {
    var state: UInt64

    /// Advances the stream and returns the low byte of the new state.
    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: nextWord())
    }

    /// Advances the stream and returns the whole new state.
    mutating func nextWord() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
