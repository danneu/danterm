// Guards the comparison the rest of this target's surface assertions go through.
//
// It holds one property, and only one: reporting a mismatch between two full
// surfaces costs a single pass. That is not a performance nicety here -- the
// alternative spelling wedges the process outright -- so it is pinned in a test
// rather than left to a comment on the helper.
import Testing

@testable import TerminalCore

@Suite("Bitmap comparison")
struct BitmapComparisonTests {
    @Test("a mismatched full surface is reported, not diffed", .timeLimit(.minutes(1)))
    func mismatchedSurfaceIsReportedWithoutDiffing() {
        // Intent: two surfaces the size this target really renders report their
        //   mismatch immediately.
        // Why it exists: `#expect(a.bytes == b.bytes)` asks Swift Testing to render
        //   the failure with `BidirectionalCollection.difference(from:)`, which is
        //   about quadratic -- four seconds at 32 KiB and unbounded at surface size.
        //   A `.timeLimit` cannot save it, because the diff is synchronous and never
        //   yields; the process just spins at full CPU until it is killed from
        //   outside. The TerminalPTY lane was dying that way on a megabyte.
        // Scenario: a 60x20 grid at displayScale 2, differing in one late pixel --
        //   the worst case, since every earlier byte matches.
        let width = 960
        let height = 640
        let bytes = [UInt8](repeating: 0x40, count: width * height * 4)
        let expected = Bitmap(width: width, height: height, bytes: bytes)
        var mutated = bytes
        mutated[mutated.count - 3] = 0x41
        let actual = Bitmap(width: width, height: height, bytes: mutated)

        let started = ContinuousClock().now
        withKnownIssue("the surfaces are deliberately unequal") {
            expectBitmap(actual, matches: expected)
        }
        let elapsed = ContinuousClock().now - started

        // Generous on purpose: the failure mode is hours, not milliseconds, so this
        // separates the two without pinning the comparison to a machine's speed.
        #expect(elapsed < .seconds(5), "reporting the mismatch took \(elapsed)")
    }
}
