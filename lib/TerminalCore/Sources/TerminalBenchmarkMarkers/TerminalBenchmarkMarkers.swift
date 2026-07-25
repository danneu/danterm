// Allocation-light search for the terminal benchmark's in-band progress markers
// in a rendered frame's text.
//
// The benchmark observer detects every producer handshake (start, localized
// ready, per-update sequence, completion) by looking for ASCII marker literals
// in the frame the app actually drew. It used to do that by building one
// `String` per scalar and joining them, which cost more main-thread time than
// the drawing it was there to measure. The search lives here -- pure,
// dependency-free, and unit-testable -- so the app-side observer keeps only the
// AppKit plumbing and stays the thin part.
//
// The scanned text is defined as exactly the runs' scalars concatenated in
// order with "\n" between runs. That definition is load-bearing, not
// incidental: it is what the observer's previous `String`-joining scan
// produced, so preserving it keeps every marker's detection semantics
// (including markers that must NOT be found across a run boundary) unchanged.
// `TerminalBenchmarkMarkersTests` pins it against a reference implementation.
//
// Belongs here: matching marker literals against a frame's text. Does not
// belong here: files, acknowledgments, or anything about what a marker means.
import TerminalRenderPlanning

/// What one scan found, in the shape the observer branches on.
///
/// One value per scan rather than four separate queries, because the observer
/// needs every answer for the same frame and the scan resolves them in a single
/// pass.
public struct TerminalBenchmarkMarkerScan: Equatable, Sendable {
    public var containsStartMarker = false
    public var containsLocalizedReady = false
    public var containsCompletionMarker = false
    public var containsExpectedFinalState = false

    /// Sequence number parsed from the digits following the *first*
    /// `DANTERM-BENCH-LOCALIZED-` occurrence, or nil when that occurrence is not
    /// followed by a parsable fixed-width number.
    ///
    /// First-occurrence-only is deliberate: it reproduces the previous
    /// `range(of:)` behavior exactly, so a frame showing the READY marker ahead
    /// of a numbered one still reports no sequence rather than silently
    /// acknowledging the wrong draw.
    public var localizedSequence: Int?

    public init() {}
}

/// Finds the benchmark's marker literals in a frame's text runs without
/// materializing the frame as a `String`.
///
/// Holds its scratch buffer across calls, so the observer must keep one
/// instance for the process rather than constructing one per frame -- the reuse
/// is the whole point.
public struct TerminalBenchmarkMarkerScanner {
    /// Prefix shared by the numbered localized markers and the READY sentinel.
    public static let localizedMarkerPrefix = "DANTERM-BENCH-LOCALIZED-"
    /// Sentinel the producer draws once before the first numbered update.
    public static let localizedReadyMarker = "DANTERM-BENCH-LOCALIZED-READY"

    /// Width of the zero-padded sequence the producer emits (`%06d`).
    private static let sequenceDigitCount = 6

    private let startMarker: [Unicode.Scalar]
    private let localizedReady: [Unicode.Scalar]
    private let localizedPrefix: [Unicode.Scalar]
    private let completionMarker: [Unicode.Scalar]
    private let expectedFinalState: [Unicode.Scalar]

    /// Distinct first scalars of every pattern, used to reject most positions
    /// with one comparison. Every DanTerm marker starts with `D`, so this is
    /// effectively a single-byte prefilter over the frame.
    private let patternFirstScalars: [Unicode.Scalar]

    private var buffer: [Unicode.Scalar] = []

    /// Markers are supplied by the harness through the environment and are
    /// assumed non-empty; an empty marker is treated as never matching, whereas
    /// `String.contains("")` would have reported true.
    public init(startMarker: String, completionMarker: String, expectedFinalState: String) {
        self.startMarker = Array(startMarker.unicodeScalars)
        self.completionMarker = Array(completionMarker.unicodeScalars)
        self.expectedFinalState = Array(expectedFinalState.unicodeScalars)
        self.localizedReady = Array(Self.localizedReadyMarker.unicodeScalars)
        self.localizedPrefix = Array(Self.localizedMarkerPrefix.unicodeScalars)

        var firsts: [Unicode.Scalar] = []
        for pattern in [
            self.startMarker, self.completionMarker, self.expectedFinalState,
            self.localizedReady, self.localizedPrefix,
        ] {
            guard let first = pattern.first, firsts.contains(first) == false else { continue }
            firsts.append(first)
        }
        self.patternFirstScalars = firsts
    }

    /// Scans one planned frame.
    ///
    /// Deliberately concrete rather than generic over the runs: the caller is in
    /// another module, and SwiftPM does not specialize a library's generics for
    /// it, so a generic signature left this loop running on unspecialized
    /// iterators and type-metadata lookups that cost more than the `String`
    /// building it replaced. Keeping the traversal on this side of the module
    /// boundary is what makes it fast.
    public mutating func scan(_ plan: RenderFramePlan) -> TerminalBenchmarkMarkerScan {
        buffer.removeAll(keepingCapacity: true)
        var needsSeparator = false
        for run in plan.textRuns {
            if needsSeparator { buffer.append("\n") }
            needsSeparator = true
            for cell in run.cells {
                buffer.append(contentsOf: cell.scalars)
            }
        }
        return searchBuffer()
    }

    /// Scans frame text supplied directly as runs of scalars.
    ///
    /// Exists for tests, which need to state a frame's text literally rather
    /// than drive a whole terminal to produce it. Kept in step with
    /// `scan(_:)` by a test that runs a real planned frame through both.
    public mutating func scan<Runs: Sequence>(runs: Runs) -> TerminalBenchmarkMarkerScan
    where Runs.Element: Sequence<Unicode.Scalar> {
        fillBuffer(from: runs)
        return searchBuffer()
    }

    private mutating func fillBuffer<Runs: Sequence>(from runs: Runs)
    where Runs.Element: Sequence<Unicode.Scalar> {
        buffer.removeAll(keepingCapacity: true)
        var needsSeparator = false
        for run in runs {
            if needsSeparator { buffer.append("\n") }
            needsSeparator = true
            buffer.append(contentsOf: run)
        }
    }

    private func searchBuffer() -> TerminalBenchmarkMarkerScan {
        var scan = TerminalBenchmarkMarkerScan()
        var resolvedLocalizedSequence = false
        for index in buffer.indices {
            guard patternFirstScalars.contains(buffer[index]) else { continue }
            if scan.containsStartMarker == false, matches(startMarker, at: index) {
                scan.containsStartMarker = true
            }
            if scan.containsLocalizedReady == false, matches(localizedReady, at: index) {
                scan.containsLocalizedReady = true
            }
            if scan.containsCompletionMarker == false, matches(completionMarker, at: index) {
                scan.containsCompletionMarker = true
            }
            if scan.containsExpectedFinalState == false, matches(expectedFinalState, at: index) {
                scan.containsExpectedFinalState = true
            }
            if resolvedLocalizedSequence == false, matches(localizedPrefix, at: index) {
                resolvedLocalizedSequence = true
                scan.localizedSequence = parseSequence(at: index + localizedPrefix.count)
            }
            if scan.containsStartMarker, scan.containsLocalizedReady,
               scan.containsCompletionMarker, scan.containsExpectedFinalState,
               resolvedLocalizedSequence
            {
                break
            }
        }
        return scan
    }

    private func matches(_ pattern: [Unicode.Scalar], at index: Int) -> Bool {
        guard pattern.isEmpty == false, index + pattern.count <= buffer.count else { return false }
        for offset in 0..<pattern.count where buffer[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private func parseSequence(at index: Int) -> Int? {
        let end = index + Self.sequenceDigitCount
        guard end <= buffer.count else { return nil }
        var digits = ""
        digits.reserveCapacity(Self.sequenceDigitCount)
        for scalar in buffer[index..<end] { digits.unicodeScalars.append(scalar) }
        return Int(digits)
    }
}
