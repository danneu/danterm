// Admission of user-supplied names into the model: what `singleLineName`
// accepts, what it rewrites, and what it rejects outright.
import Foundation
import Testing

@testable import DanTermCore

struct EntityTitleTests {
    @Test("an ordinary name is admitted unchanged")
    func ordinaryNameIsAdmitted() {
        #expect("build".singleLineName == "build")
    }

    @Test("an embedded newline collapses to a space")
    func embeddedNewlineCollapses() {
        #expect("line one\nline two".singleLineName == "line one line two")
    }

    @Test("leading and trailing whitespace is dropped")
    func edgeWhitespaceIsDropped() {
        #expect("  build  ".singleLineName == "build")
    }

    // New with DisplayLine: a name pasted out of terminal output could carry a
    // BEL or ESC, and the model used to store it verbatim.
    @Test("a trailing BEL is stripped")
    func trailingBellIsStripped() {
        #expect("build\u{0007}".singleLineName == "build")
    }

    @Test("an escape sequence fragment is stripped")
    func escapeFragmentIsStripped() {
        #expect("\u{001B}]0;build".singleLineName == "]0;build")
    }

    @Test("a name with nothing to show is rejected", arguments: ["", "   ", "\n\t", "\u{0007}", "\u{001B}\u{0007}"])
    func emptyishNameIsRejected(raw: String) {
        #expect(raw.singleLineName == nil)
    }
}
