// Behavioral proofs for `TerminalScalars`, the inline-storage scalar payload shared by
// `TerminalCell` and the render plan. These pin the two properties the rest of the
// codebase silently depends on: that it behaves as an ordinary collection of scalars,
// and that equality compares contents rather than storage representation. The second is
// not a nicety -- `TerminalCell`, `RenderTextCell`, `RenderTextRun`, and `RenderFramePlan`
// are all `Equatable` and compared whole, so representation-sensitive equality would make
// identical frames compare unequal depending on how their content was produced.
import Testing

@testable import TerminalCore

struct TerminalScalarsTests {
    @Test("Empty, single, and spilled payloads report collection basics consistently")
    func collectionBasics() {
        let empty = TerminalScalars()
        #expect(empty.isEmpty)
        #expect(empty.count == 0)
        #expect(empty.first == nil)
        #expect(Array(empty) == [])

        let single: TerminalScalars = ["a"]
        #expect(single.isEmpty == false)
        #expect(single.count == 1)
        #expect(single.first == "a")
        #expect(single[0] == "a")
        #expect(Array(single) == ["a"])

        let spilled = TerminalScalars(Array("e\u{301}\u{327}".unicodeScalars))
        #expect(spilled.count == 3)
        #expect(spilled.first == "e")
        #expect(spilled[2] == "\u{327}")
        #expect(Array(spilled) == Array("e\u{301}\u{327}".unicodeScalars))
    }

    @Test("Equality compares scalar contents, not the storage case that holds them")
    func equalityIsContentBased() {
        // Intent: two payloads with the same scalars are equal even when one is held
        //   inline and the other spilled to the heap.
        // Why it exists: this is the one way an inline-storage optimization can change
        //   observable behavior. `TerminalCell`, `RenderTextCell`, `RenderTextRun`, and
        //   `RenderFramePlan` all derive `==` from this type, and roughly ninety test
        //   sites compare scalar payloads directly, so a representation-derived `==`
        //   would break plan equality wherever identical content arrived by a different
        //   route -- silently, and only for some inputs.
        // Scenario: a single-scalar cell built inline versus the same scalar arriving
        //   through the array-backed initializer.
        let inline: TerminalScalars = ["a"]
        let viaArray = TerminalScalars(["a"])
        #expect(inline == viaArray)

        let emptyLiteral: TerminalScalars = []
        #expect(TerminalScalars() == emptyLiteral)
        #expect(TerminalScalars() == TerminalScalars([]))

        #expect(TerminalScalars(["a"]) != TerminalScalars(["b"]))
        #expect(TerminalScalars(["a"]) != TerminalScalars(["a", "b"]))
        #expect(TerminalScalars(["a", "b"]) == TerminalScalars(Array("ab".unicodeScalars)))
    }

    @Test("Sequence use keeps flatMap and append(contentsOf:) working")
    func sequenceInterop() {
        // Intent: the payload is consumable as a plain sequence of scalars.
        // Why it exists: `TerminalBenchmarkMarkers` flat-maps payloads to scan for
        //   markers and the executor appends them into a scalar view; both would break
        //   on a type that only supported subscripting.
        let payloads: [TerminalScalars] = [["a"], [], TerminalScalars(Array("e\u{301}".unicodeScalars))]
        #expect(payloads.flatMap { $0 } == Array("ae\u{301}".unicodeScalars))

        var view = String.UnicodeScalarView()
        for payload in payloads { view.append(contentsOf: payload) }
        #expect(String(view) == "ae\u{301}")
    }
}
