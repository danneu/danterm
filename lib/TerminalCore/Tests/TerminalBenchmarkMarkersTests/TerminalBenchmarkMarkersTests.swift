// Behavioral contracts for the benchmark marker scan.
//
// The scan replaced a `String`-building search inside the app's benchmark
// observer, which no test target compiles. These tests are therefore the only
// automated guard on detection semantics, so they check the scan against a
// direct transcription of the previous implementation rather than only against
// hand-written expectations.
import Foundation
import TerminalCore
import TerminalRenderPlanning
import Testing

@testable import TerminalBenchmarkMarkers

@Suite("Terminal benchmark marker scan")
struct TerminalBenchmarkMarkersTests {
    private static let start = "DANTERM-BENCH-START-4242"
    private static let completion = "DANTERM-BENCH-COMPLETE-4242"
    private static let finalState = "DANTERM-BENCH-FINAL-STATE-4242"

    private func makeScanner() -> TerminalBenchmarkMarkerScanner {
        TerminalBenchmarkMarkerScanner(
            startMarker: Self.start,
            completionMarker: Self.completion,
            expectedFinalState: Self.finalState
        )
    }

    private func scalarRuns(_ lines: [String]) -> [[Unicode.Scalar]] {
        lines.map { Array($0.unicodeScalars) }
    }

    private func scan(_ lines: [String]) -> TerminalBenchmarkMarkerScan {
        var scanner = makeScanner()
        return scanner.scan(runs: scalarRuns(lines))
    }

    // MARK: - Reference implementation

    /// Verbatim transcription of the observer's previous `String`-joining scan,
    /// kept as the oracle these tests compare against.
    private func referenceScan(_ lines: [String]) -> TerminalBenchmarkMarkerScan {
        let text = scalarRuns(lines)
            .map { $0.map(String.init).joined() }
            .joined(separator: "\n")
        var expected = TerminalBenchmarkMarkerScan()
        expected.containsStartMarker = text.contains(Self.start)
        expected.containsLocalizedReady = text.contains("DANTERM-BENCH-LOCALIZED-READY")
        expected.containsCompletionMarker = text.contains(Self.completion)
        expected.containsExpectedFinalState = text.contains(Self.finalState)
        if let marker = text.range(of: "DANTERM-BENCH-LOCALIZED-") {
            let suffix = text[marker.upperBound...].prefix(6)
            expected.localizedSequence = suffix.count == 6 ? Int(suffix) : nil
        }
        return expected
    }

    // MARK: - Equivalence with the replaced implementation

    @Test("the scan agrees with the replaced String-joining search on every fixture")
    func agreesWithReferenceImplementation() {
        // Intent: the byte-level scan reports exactly what the previous
        //   `frameText` + `contains` + `range(of:)` implementation reported.
        // Why it exists: the observer that calls this lives in `app/`, which no
        //   test target compiles, so a silent behavior change there would only
        //   surface as a benchmark run that hangs waiting for an acknowledgment
        //   that never arrives. This is the pin that makes the swap safe.
        // Scenario: spec-first. Each fixture is a frame the producer can
        //   actually put on screen -- idle churn, the start row, the ready
        //   sentinel, a numbered update, the completion pair -- plus the
        //   boundary cases that distinguish the two implementations.
        let fixtures: [[String]] = [
            [],
            [""],
            ["hello", "world"],
            [Self.start],
            ["....", Self.start, "...."],
            ["DANTERM-BENCH-LOCALIZED-READY"],
            ["DANTERM-BENCH-LOCALIZED-000123 status"],
            ["DANTERM-BENCH-LOCALIZED-READY", "DANTERM-BENCH-LOCALIZED-000123"],
            ["DANTERM-BENCH-LOCALIZED-000123", "DANTERM-BENCH-LOCALIZED-READY"],
            [Self.finalState, Self.completion],
            [Self.finalState],
            [Self.completion],
            ["DANTERM-BENCH-LOCALIZED-"],
            ["DANTERM-BENCH-LOCALIZED-12"],
            ["DANTERM-BENCH-LOCALIZED-12345678"],
            ["DANTERM-BENCH-LOCALIZED-abcdef"],
            ["DANTERM-BENCH-START-", "4242"],
            ["DANTERM-BENCH-", "LOCALIZED-000123"],
            [Self.start, Self.finalState, Self.completion, "DANTERM-BENCH-LOCALIZED-000007"],
        ]
        for fixture in fixtures {
            #expect(scan(fixture) == referenceScan(fixture), "fixture: \(fixture)")
        }
    }

    // MARK: - The semantics that equivalence depends on

    @Test("a marker split across two runs is not found")
    func markerSplitAcrossRunsIsNotFound() {
        // Intent: run boundaries are hard boundaries for matching.
        // Why it exists: the scan concatenates runs with "\n" specifically so a
        //   marker cannot be assembled from two adjacent runs. Dropping the
        //   separator would look like a harmless simplification while making the
        //   observer acknowledge frames that never showed a complete marker.
        // Scenario: spec-first. Style changes fragment a row into several runs,
        //   so adjacent runs routinely abut with no gap on screen.
        let split = scan(["DANTERM-BENCH-START-", "4242"])
        #expect(split.containsStartMarker == false)

        let whole = scan(["DANTERM-BENCH-START-4242"])
        #expect(whole.containsStartMarker)
    }

    @Test("only the first localized marker supplies the sequence")
    func onlyTheFirstLocalizedMarkerSuppliesTheSequence() {
        // Intent: a READY sentinel appearing before a numbered marker yields no
        //   sequence, rather than the later marker's number.
        // Why it exists: the producer keeps both on the same row so they can
        //   never coexist, but that invariant lives in the producer, not here.
        //   If a future change puts them on different rows, this test forces the
        //   resulting silent no-acknowledgment to show up as a failure here
        //   instead of as a hung benchmark run.
        // Scenario: spec-first.
        let readyFirst = scan([
            "DANTERM-BENCH-LOCALIZED-READY",
            "DANTERM-BENCH-LOCALIZED-000123",
        ])
        #expect(readyFirst.localizedSequence == nil)
        #expect(readyFirst.containsLocalizedReady)

        let numberedFirst = scan([
            "DANTERM-BENCH-LOCALIZED-000123",
            "DANTERM-BENCH-LOCALIZED-READY",
        ])
        #expect(numberedFirst.localizedSequence == 123)
    }

    @Test("the sequence is exactly six scalars wide")
    func sequenceIsExactlySixScalarsWide() {
        #expect(scan(["DANTERM-BENCH-LOCALIZED-000123"]).localizedSequence == 123)
        #expect(scan(["DANTERM-BENCH-LOCALIZED-12345678"]).localizedSequence == 123456)
        #expect(scan(["DANTERM-BENCH-LOCALIZED-12345"]).localizedSequence == nil)
        #expect(scan(["DANTERM-BENCH-LOCALIZED-"]).localizedSequence == nil)
        #expect(scan(["DANTERM-BENCH-LOCALIZED-abcdef"]).localizedSequence == nil)
    }

    @Test("the sequence may complete across a run boundary exactly as the joined text did")
    func sequenceMayCompleteAcrossARunBoundary() {
        // Intent: the six scalars following the marker are read from the joined
        //   text, so a run boundary contributes its "\n" and defeats the parse.
        // Why it exists: reading only within the matching run would be a subtle
        //   divergence from the replaced implementation, in the direction of
        //   accepting sequences the old code rejected.
        // Scenario: spec-first.
        #expect(scan(["DANTERM-BENCH-LOCALIZED-", "000123"]).localizedSequence == nil)
    }

    @Test("completion requires both markers and reports them independently")
    func completionRequiresBothMarkers() {
        #expect(scan([Self.completion]).containsCompletionMarker)
        #expect(scan([Self.completion]).containsExpectedFinalState == false)
        #expect(scan([Self.finalState]).containsExpectedFinalState)
        #expect(scan([Self.finalState]).containsCompletionMarker == false)

        let both = scan([Self.finalState, Self.completion])
        #expect(both.containsCompletionMarker)
        #expect(both.containsExpectedFinalState)
    }

    @Test("a frame with no markers reports nothing")
    func frameWithoutMarkersReportsNothing() {
        #expect(scan(["....", "hello world", ""]) == TerminalBenchmarkMarkerScan())
        #expect(scan([]) == TerminalBenchmarkMarkerScan())
    }

    @Test("a scanner reused across frames does not leak state between them")
    func reusedScannerDoesNotLeakStateBetweenFrames() {
        // Intent: the scratch buffer that makes the scan cheap is fully reset
        //   per frame.
        // Why it exists: the buffer is retained across calls on purpose, so a
        //   missing reset would make markers from an earlier frame keep
        //   satisfying later frames -- the observer would acknowledge draws that
        //   never contained the marker, and every draw after completion would
        //   look like completion.
        // Scenario: spec-first. The observer holds one scanner for the process
        //   and scans every published and drawn frame through it.
        var scanner = makeScanner()
        let markedFrame = scanner.scan(runs: scalarRuns([Self.start, Self.completion, Self.finalState]))
        #expect(markedFrame.containsStartMarker)
        #expect(markedFrame.containsCompletionMarker)

        let plainFrame = scanner.scan(runs: scalarRuns(["nothing here", "or here"]))
        #expect(plainFrame == TerminalBenchmarkMarkerScan())

        let markedAgain = scanner.scan(runs: scalarRuns(["DANTERM-BENCH-LOCALIZED-000042"]))
        #expect(markedAgain.localizedSequence == 42)
        #expect(markedAgain.containsStartMarker == false)
    }

    // MARK: - The planned-frame entry point the observer actually calls

    @Test("scanning a planned frame agrees with scanning its text directly")
    func scanningAPlannedFrameAgreesWithScanningItsText() throws {
        // Intent: `scan(_ plan:)`, the concrete entry point the app calls, finds
        //   the same markers as `scan(runs:)`, which every other test uses.
        // Why it exists: the two entry points traverse separately -- one walks a
        //   render plan's runs and cells, the other a caller-supplied sequence --
        //   so they can drift. `scan(_ plan:)` is the one that decides whether a
        //   benchmark run makes progress, and it is the one no other test covers.
        // Scenario: spec-first. A real terminal is fed the markers the producer
        //   writes, and the frame is planned exactly as the app plans it.
        var terminal = try #require(Terminal(columns: 40, rows: 4))
        terminal.feed(Array("DANTERM-BENCH-LOCALIZED-000123 status\r\n".utf8))
        terminal.feed(Array("\(Self.finalState)\r\n".utf8))
        terminal.feed(Array("\(Self.completion)".utf8))
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        var scanner = makeScanner()
        let planned = scanner.scan(plan)
        #expect(planned.localizedSequence == 123)
        #expect(planned.containsExpectedFinalState)
        #expect(planned.containsCompletionMarker)
        #expect(planned.containsStartMarker == false)

        var textScanner = makeScanner()
        let fromText = textScanner.scan(
            runs: plan.textRuns.map { $0.cells.flatMap(\.scalars) }
        )
        #expect(planned == fromText)
    }

    @Test("a row-limited scan sees only the rows the frame changed")
    func rowLimitedScanSeesOnlyChangedRows() throws {
        // Intent: `scan(_ plan:limitedToRows:)` reports only markers standing in
        //   the rows it is given, and reports every marker when given none.
        // Why it exists: a render plan carries the whole viewport, including
        //   rows a frame did not touch, so scanning all of it makes a marker
        //   left on screen by an earlier producer indistinguishable from one the
        //   current frame just wrote. Limiting the scan to the damaged rows is
        //   what makes "this frame wrote a marker" expressible at all.
        // Scenario: a screen still showing a finished block's start marker, on
        //   which a later frame changes one unrelated row -- the state that made
        //   an idle benchmark app open a block nobody had started.
        var terminal = try #require(Terminal(columns: 48, rows: 4))
        terminal.feed(Array("\(Self.start)\r\nsecond\r\nthird\r\nfourth".utf8))
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        var scanner = makeScanner()
        #expect(scanner.scan(plan, limitedToRows: [2]).containsStartMarker == false)
        #expect(scanner.scan(plan, limitedToRows: [0, 2]).containsStartMarker)
        #expect(scanner.scan(plan, limitedToRows: []).containsStartMarker == false)
        #expect(scanner.scan(plan, limitedToRows: nil) == scanner.scan(plan))
        #expect(scanner.scan(plan, limitedToRows: nil).containsStartMarker)
    }

    @Test("a row-limited scan cannot match a marker across the rows it skipped")
    func rowLimitedScanDoesNotMatchAcrossSkippedRows() throws {
        // Intent: rows excluded from a limited scan leave a run separator behind
        //   them, exactly as excluded-by-absence rows do in a full scan.
        // Why it exists: the scan's text is defined as the runs joined by "\n",
        //   and that definition is what stops a marker from being found across a
        //   row boundary. Dropping rows by splicing their neighbors together
        //   would invent adjacencies the screen never had.
        var scanner = makeScanner()
        let halves = ["DANTERM-BENCH-", "unrelated", "START-4242"]
        var terminal = try #require(Terminal(columns: 48, rows: 3))
        terminal.feed(Array(halves.joined(separator: "\r\n").utf8))
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        #expect(scanner.scan(plan, limitedToRows: [0, 2]).containsStartMarker == false)
    }

    @Test("scanning accepts lazily flattened runs without materializing them")
    func scanningAcceptsLazilyFlattenedRuns() {
        // Intent: the generic signature admits the shape the observer actually
        //   passes -- a lazy flatMap over per-cell scalar arrays.
        // Why it exists: if this stopped compiling, the call site's only easy
        //   fix would be to build arrays per frame, silently restoring the
        //   allocation cost this scan exists to remove.
        // Scenario: spec-first. Render text runs hold `[RenderTextCell]`, each
        //   with its own `[Unicode.Scalar]`.
        let cells: [[[Unicode.Scalar]]] = [
            [Array("DANTERM-BENCH-LOCALIZED-".unicodeScalars), Array("000042".unicodeScalars)],
        ]
        var scanner = makeScanner()
        let result = scanner.scan(runs: cells.lazy.map { $0.lazy.flatMap(\.self) })
        #expect(result.localizedSequence == 42)
    }
}
