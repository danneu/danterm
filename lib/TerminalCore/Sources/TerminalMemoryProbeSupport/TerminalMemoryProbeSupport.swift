// The payload matrix and reporting shape for the headless terminal-memory probe.
//
// This is the instrument doc 15's Phase 1 asks for, and it exists because the tool that came
// before it cannot do the job. `just benchmark-memory` drives the GUI app and samples process
// footprint; doc 15's F6 showed it reporting a *fixed* build as larger than a leaky one, because
// one memgraph samples one arbitrary point on a sawtooth and GUI compositing churn dwarfs anything
// the grid does. It is a leak detector, not a measurement instrument.
//
// This probe answers the other question -- "what does terminal state actually cost, and where does
// it go" -- and answers it deterministically: no GUI, no renderer, no allocator sampling, no
// timing. Each payload is fed to a fresh `Terminal` and measured with `Terminal.memoryCensus`,
// which reports exact `MemoryLayout` stride arithmetic rather than malloc buckets or process pages.
// Run it twice and it prints the same numbers.
//
// Logic lives here rather than in the executable so it can be unit-tested -- in particular so the
// matrix can be proven to actually exercise what its payload names claim, which is the failure mode
// that would quietly invalidate every number the probe produces.
import Darwin
import Foundation
import TerminalCore

/// One payload in the matrix: a name, and the bytes that put a terminal into that state.
///
/// Payloads are deterministic by construction -- no randomness, no clock -- because the probe's
/// whole value over `benchmark-memory` is that a second run is comparable to the first.
public struct MemoryProbePayload: Sendable {
    public let name: String
    public let bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }
}

/// What one payload cost, in exact grid bytes and in process pages.
///
/// Both are reported because they answer different questions and doc 15's investigation rules
/// require saying which one a claim rests on: the census is the representation cost, the footprint
/// delta is what the OS actually charged for holding it.
public struct MemoryProbePayloadReport: Codable, Equatable, Sendable {
    public var name: String
    public var columns: Int
    public var rows: Int
    public var scrollbackBudgetBytes: Int
    public var fedByteCount: Int
    public var census: TerminalMemoryCensus
    public var footprintBeforeBytes: UInt64
    public var footprintAfterBytes: UInt64

    /// Process pages charged while this payload was resident. Signed: the allocator can return
    /// pages, and a negative delta is information rather than an error.
    public var footprintDeltaBytes: Int64 {
        Int64(footprintAfterBytes) - Int64(footprintBeforeBytes)
    }

    /// How much of the process delta the grid's own cell bytes explain. Below 1.0 means the
    /// allocator is holding pages the census cannot see; above 1.0 means pages were returned.
    /// This is the ratio doc 15's F5 is about.
    public var footprintCoverageOfCellStorage: Double {
        footprintDeltaBytes == 0 ? 0 : Double(census.cellStorageBytes) / Double(footprintDeltaBytes)
    }
}

/// A full matrix run, with the geometry every payload shares.
public struct MemoryProbeReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var columns: Int
    public var rows: Int
    public var scrollbackBudgetBytes: Int
    public var cellStrideBytes: Int
    public var payloads: [MemoryProbePayloadReport]
}

/// Builds the payload matrix doc 15 specifies, plus the geometry it is measured at.
///
/// The matrix deliberately mirrors the axes libghostty's author used -- empty, full screen, and a
/// deep scrollback in plain / unicode / styled / mixed content -- so DanTerm's numbers are
/// comparable in kind, not because the techniques transfer.
public enum MemoryProbeMatrix {
    /// Lines of history each scrollback payload writes. Large enough that a production budget
    /// evicts, which is the state the product actually runs in.
    public static let scrollbackLineCount = 10_000

    public static func payloads(columns: Int, lineCount: Int = scrollbackLineCount) -> [MemoryProbePayload] {
        [
            MemoryProbePayload(name: "empty", bytes: []),
            MemoryProbePayload(name: "full-screen", bytes: fullScreen(columns: columns)),
            MemoryProbePayload(name: "scrollback-plain", bytes: plain(lineCount: lineCount)),
            MemoryProbePayload(name: "scrollback-unicode", bytes: unicode(lineCount: lineCount)),
            MemoryProbePayload(name: "scrollback-styled", bytes: styled(lineCount: lineCount)),
            MemoryProbePayload(name: "scrollback-mixed", bytes: mixed(lineCount: lineCount)),
        ]
    }

    /// Fills every column of many rows, so no cell is left at its default. Distinct from the
    /// scrollback payloads: it measures a screen the user is looking at, not history.
    static func fullScreen(columns: Int) -> [UInt8] {
        var text = ""
        for row in 0..<200 {
            for column in 0..<columns {
                text.unicodeScalars.append(Unicode.Scalar(UInt8(33 + (row &+ column) % 94)))
            }
            text += "\r\n"
        }
        return Array(text.utf8)
    }

    static func plainLine(_ line: Int) -> [UInt8] {
        Array("DANTERM-MEMORY-\(String(format: "%05d", line)) plain ascii scrollback payload\r\n".utf8)
    }

    static func plain(lineCount: Int) -> [UInt8] {
        (0..<lineCount).flatMap(plainLine)
    }

    /// Mixes wide CJK, combining marks, and emoji ZWJ sequences, so the payload exercises spacer
    /// cells and multi-scalar spill storage rather than merely being non-ASCII.
    static let unicodeSamples = [
        "\u{754C}\u{9762}",
        "e\u{301}a\u{308}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        "\u{4E16}\u{754C}",
    ]

    static func unicodeLine(_ line: Int) -> [UInt8] {
        let first = unicodeSamples[line % unicodeSamples.count]
        let second = unicodeSamples[(line + 1) % unicodeSamples.count]
        return Array("\(first) unicode \(second) row \(line)\r\n".utf8)
    }

    static func unicode(lineCount: Int) -> [UInt8] {
        (0..<lineCount).flatMap(unicodeLine)
    }

    /// Varies foreground, background, and attribute bits so a dedup table would have real work to
    /// do. Sizes doc 15's H3 against something less trivial than the fixture corpus, which doc
    /// 12's F3 found had at most nine distinct styles.
    static func styledLine(_ line: Int) -> [UInt8] {
        let foreground = 30 + line % 8
        let background = 40 + (line / 8) % 8
        let attribute = [1, 2, 3, 4, 7, 9][line % 6]
        return Array(
            "\u{1B}[\(attribute);\(foreground);\(background)mstyled row \(line) with attributes\u{1B}[0m\r\n".utf8
        )
    }

    static func styled(lineCount: Int) -> [UInt8] {
        (0..<lineCount).flatMap(styledLine)
    }

    /// Interleaves the three per line, which is the closest of the four to a real session.
    ///
    /// Round-robin rather than three concatenated blocks, and that is not a style choice. Blocks
    /// degenerate under eviction: at the production budget only the final block survives, so a
    /// concatenated "mixed" payload measured byte-identical to `scrollback-styled`. Interleaving
    /// keeps all three axes resident at any depth.
    static func mixed(lineCount: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for line in 0..<lineCount {
            switch line % 3 {
            case 0: bytes += plainLine(line)
            case 1: bytes += unicodeLine(line)
            default: bytes += styledLine(line)
            }
        }
        return bytes
    }
}

/// Reads the process's physical footprint -- the same quantity `footprint(1)` reports.
///
/// Sampled in-process rather than by polling from outside so each payload's delta is attributable
/// to that payload, which is the whole reason the probe can answer doc 15's F3 and F5 where
/// `benchmark-memory` cannot.
public func processPhysicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Feeds one payload to a fresh terminal and reports what it cost.
///
/// The terminal is held until after the census and the closing footprint read, so neither can race
/// its deallocation.
public func measure(
    payload: MemoryProbePayload,
    columns: Int,
    rows: Int
) -> MemoryProbePayloadReport? {
    let before = processPhysicalFootprintBytes()
    // The public initializer, so the probe always measures the production budget. The
    // budget-taking initializer is internal on purpose -- that the public one pins 10 MiB is an
    // invariant with its own test, and a measurement tool is not a reason to weaken it. Depth is
    // varied with `lineCount` instead.
    guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
    if payload.bytes.isEmpty == false { terminal.feed(payload.bytes) }

    let census = terminal.memoryCensus
    let after = processPhysicalFootprintBytes()
    withExtendedLifetime(terminal) {}

    return MemoryProbePayloadReport(
        name: payload.name,
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
        fedByteCount: payload.bytes.count,
        census: census,
        footprintBeforeBytes: before,
        footprintAfterBytes: after
    )
}

/// Runs the whole matrix at one geometry.
/// Runs the matrix, or one named payload of it.
///
/// `only` exists because footprint deltas are only attributable in a single-payload process: the
/// allocator reuses pages a previous payload freed, so every delta after the first understates its
/// payload. Census fields are exact and unaffected either way.
public func runMatrix(
    columns: Int,
    rows: Int,
    lineCount: Int = MemoryProbeMatrix.scrollbackLineCount,
    only: String? = nil
) -> MemoryProbeReport {
    let reports = MemoryProbeMatrix
        .payloads(columns: columns, lineCount: lineCount)
        .filter { only == nil || $0.name == only }
        .compactMap { measure(payload: $0, columns: columns, rows: rows) }
    return MemoryProbeReport(
        schemaVersion: 1,
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
        cellStrideBytes: reports.first?.census.cellStrideBytes ?? 0,
        payloads: reports
    )
}
