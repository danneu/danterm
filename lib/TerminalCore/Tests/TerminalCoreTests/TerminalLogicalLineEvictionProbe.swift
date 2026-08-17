// The research/31/F8 eviction probe for doc 31, plus the `AR6` residency reading `research/31/D4` sequences into the
// same slice: what does head-granular eviction on the arena cost against today's budget
// enforcement, and what does an arena pane actually leave resident once its ring has cycled?
//
// `research/31/D4` -- frozen at `2ac87e1`, before this file existed and before any eviction or residency
// number did -- states the arms, the two statistics, the five stimulus classes with their
// calibration bands, the eight validity gates, the 1.09x reject / 1.00x confirm thresholds and the
// verdicts. This file takes the measurement and prints gate outcomes; it contains no threshold and
// no verdict. The rule is applied once, by hand, to what this prints.
//
// **Three arms.** `A` reproduces `Terminal.swift#enforceScrollbackBudget` -- the byte-bounded loop,
// `ScrollbackBuffer.removeFirst` including the slot-release write and `compactIfNeeded`, the
// `scrollbackByteCost` and `storedCellCount` subtractions, the `isSoftWrapped` read, and once per
// call the `isHistoryHeadTruncated` write, the observation bump and what survives of
// `handleEviction` without a `Terminal` to hold anchors (see its doc comment); its `steady`
// statistic also carries `appendToScrollback` exactly as `research/31/F3`'s baseline did. Those members are
// `private` to `Terminal`, so the arm reproduces them rather than calling them, which is this
// probe's stated fidelity limit exactly as it was `research/31/F1`'s and `research/31/F3`'s. `B` is **not** a prototype: it
// is `Terminal.LogicalLineStore`, the store slice 3 landed, driven through `admit` and
// `evictOneDisplayRow`. `C` is whole-record eviction, descriptive only and outside the verdict.
//
// Belongs here: the two evicters, the five stimulus classes, arm C's granularity pair, the gates,
// and the residency reading. Does not belong here: a threshold, a verdict, or any edit to `research/31/F1`'s,
// `research/31/F2`'s, `research/31/F3`'s, `research/31/F7`'s or `research/31/F9`'s probe files -- the isolation practice `research/31/F2` established and every
// probe since has kept. Nothing under `lib/TerminalCore/Sources/` is touched by this finding.
//
// Two places where `research/31/D4`'s letter cannot be executed as written, both resolved **here, in the file
// header, before the probe was first run**, so the resolution is visible in the same commit as the
// numbers it governs, and both recorded as deferred decisions in `research/31/F8`:
//
//   * **`research/31/DD29` -- the `drain` statistic times a fixed step count, not a budget-driven call.** `research/31/D4`
//     asks for 2,000 display rows admitted "with enforcement suppressed" and then one enforcement
//     call that drains back to the budget. Under `31/I2` the arena's capacity *is* the budget and
//     is a `let`, so admission cannot be run with enforcement suppressed without changing the
//     arena's defining geometry. Both arms therefore run the same fixed 2,000-step eviction loop --
//     which is the body of `evictToBudget` / `enforceScrollbackBudget` with the loop condition
//     supplied by the harness -- and each arm's once-per-call epilogue runs once. Both arms are
//     treated identically, so the ratio the rule reads is unaffected; `research/31/D4` gate 3's drain half is
//     satisfied by construction and is reported as such rather than dropped.
//   * **`research/31/DD30` -- arm C is the arena *design* reproduced in this file, run in both granularities.**
//     `research/31/D4` asks for whole-record eviction "on the same arena". `LogicalLineStore` exposes no
//     whole-record eviction and adding one to production for a descriptive arm is not licensed by
//     `research/31/D1`'s scoping, so arm C is a linear reproduction of the arena -- same 8-byte
//     `LogicalLineRecord` header, same `LogicalLineFold`, same cell words -- run head-granular and
//     whole-record. The granularity ratio is therefore measured on **one** implementation, which is
//     what the attribution needs, and the reproduction's head-granular arm is reported against the
//     real store so the substitution's size is visible rather than assumed.
//
// Not part of the `just test` gate. Every measurement is skipped unless `DANTERM_LOGICAL_LINE_PROBE`
// is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLineEvictionProbe
//
// and the residency reading one process per state, as `research/31/D4` requires for an attributable footprint
// delta:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 DANTERM_RESIDENCY_CASE=arena/plain/cycled \
//       swift test -c release --package-path lib/TerminalCore --filter residencyReading
//
// Release matters: `research/31/D4`'s 1.09x line is derived from release-build cost shares.
import Darwin
import Foundation
import Testing

@testable import TerminalCore

// MARK: - Content classes

/// The five stimulus classes `research/31/D4` froze, with every band cited to its source.
///
/// `mix` and `full` are `research/28/F23`'s measured distribution and its full-width saturation bound;
/// `stream` is `research/28/F20` Observation 5's `scrollback-stream` row shape and the class the 1.09x line
/// is derived from; `wrapped` is new at `research/31/D4` (`research/31/DD21`) and is the only class in which a step trims
/// *inside* a record, so it is the only class that exercises the persisted head cell offset at all;
/// `wide` is `research/31/F3`'s CJK generator and is descriptive, because no ladder threshold derives from wide
/// content.
enum EvictionContentClass: String, CaseIterable {
    case mix
    case full
    case stream
    case wrapped
    case wide

    /// Whether `research/31/D4`'s thresholds are read against this class at all.
    var isVerdictBearing: Bool { self != .wide }

    /// Display rows the stimulus is built to, before it is cycled up to the budget.
    ///
    /// `wrapped` needs whole 336-row logical lines, so its target is a multiple of one; the rest
    /// take a figure large enough that a cycle boundary is rare inside a timed region.
    var stimulusDisplayRows: Int { self == .wrapped ? 6_720 : 6_000 }
}

/// The logical lines a class is made of, before the engine wraps them.
///
/// `mix` and `full` delegate to `research/31/F1`'s generator and `stream` reproduces `research/31/F3`'s verbatim
/// `scrollback-stream` template, so the campaign's probes keep measuring one content model.
/// `wrapped` is 60,000 cells -- 91.6% of `research/31/DD3`'s 65,536-cell cap, deliberately below it so the
/// forced-split path does not fire inside a measured region -- which folds to 336 display rows at
/// 179 columns.
func evictionLogicalLines(for contentClass: EvictionContentClass, count: Int) -> [String] {
    switch contentClass {
    case .mix, .full, .stream, .wide:
        let admissionClass: AdmissionContentClass = switch contentClass {
        case .mix: .mix
        case .full: .full
        case .stream: .stream
        default: .wide
        }
        return admissionLogicalLines(for: admissionClass, count: count)
    case .wrapped:
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 -_/.:")
        return (0..<count).map { index in
            var line = String()
            line.reserveCapacity(60_000)
            for offset in 0..<60_000 {
                line.append(alphabet[(index &* 31 &+ offset &* 7) % alphabet.count])
            }
            return line
        }
    }
}

/// Feeds a real `Terminal` and takes back the display rows it retained, materialized to full width
/// and trimmed to a logical-line boundary.
///
/// Full width because production admission is handed a live-grid row -- `pack` walks every column
/// and decides the trim itself, and so must the candidate. The two side-table fields are stripped
/// from every cell, exactly as `research/31/F1` and `research/31/F3` stripped them and conservative toward the baseline for
/// the same reason (`research/31/D4`'s "what this measurement does not see"). Caps are raised far above
/// production so the fill stops on the stimulus rather than on a bound; eviction is driven here by
/// the arms, not by the source terminal.
func buildEvictionStimulus(
    contentClass: EvictionContentClass,
    columns: Int = 179,
    rows: Int = 66
) -> RetainedStimulus {
    var terminal = Terminal(
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: 1 << 28
    )!

    let target = contentClass.stimulusDisplayRows
    let lineBudget = contentClass == .wrapped ? 64 : 60_000
    let lines = evictionLogicalLines(for: contentClass, count: lineBudget)
    var fed = 0
    while terminal.scrollbackRowCount < target + rows, fed < lines.count {
        terminal.feed(Array("\(lines[fed])\r\n".utf8))
        fed += 1
    }

    var displayRows: [Terminal.GridRow] = []
    var lineStarts: [Int] = [0]
    var index = 0
    while index < terminal.scrollbackRowCount {
        guard var row = terminal.retainedRowForTesting(at: index) else { break }
        for column in row.cells.indices {
            row.cells[column].hyperlinkId = nil
            row.cells[column].contentIdentity = nil
        }
        displayRows.append(row.materialized(to: columns))
        if row.isSoftWrapped == false { lineStarts.append(displayRows.count) }
        index += 1
        if displayRows.count >= target, row.isSoftWrapped == false { break }
    }
    if lineStarts.last != displayRows.count {
        displayRows.removeLast(displayRows.count - lineStarts[lineStarts.count - 1])
    }

    return RetainedStimulus(displayRows: displayRows, lineStarts: lineStarts, columns: columns)
}

// MARK: - The shared checksum

/// Checksums one display row over every scalar, style id and kind, plus its soft-wrap flag.
///
/// `research/31/D4` gate 1 compares the two arms over the display rows both retain, and the two stores
/// legitimately disagree about how much *default* trailing padding they keep -- today's `pack`
/// trims to canonical extent, while the arena measures a hard-ended row to its content end. So
/// only cells that differ from the default contribute, keyed by column, which makes the check
/// exactly "the same content in the same places" and not "the same array length".
@inline(__always)
func evictionRowChecksum(_ row: Terminal.GridRow, into checksum: inout UInt64) {
    checksum = checksum &* 31 &+ (row.isSoftWrapped ? 1 : 2)
    for column in row.cells.indices where row.cells[column] != Terminal.GridCell() {
        let cell = row.cells[column]
        checksum = checksum &* 1_099_511_628_211 &+ UInt64(column)
        checksum = checksum &* 31 &+ UInt64(cell.kind.probeCode)
        checksum = checksum &* 31 &+ UInt64(cell.styleId)
        checksum = checksum &* 31 &+ UInt64(cell.scalars.count)
        if cell.scalars.count > 0 { checksum = checksum &+ UInt64(cell.scalars[0].value) }
    }
}

/// Folds a handful of state words into one value that travels with an `ArmRound`.
@inline(__always)
func evictionProduct(_ terms: [Int]) -> UInt64 {
    var value: UInt64 = 1_469_598_103_934_665_603
    for term in terms {
        value = (value ^ UInt64(bitPattern: Int64(term))) &* 1_099_511_628_211
    }
    return value
}

extension Terminal.LogicalLineStore {
    /// The per-round product `research/31/D4` gate 4 cross-checks, folded so one value travels with an
    /// `ArmRound`. Lives here rather than in the store: it is a probe's accounting, not the
    /// store's, and nothing under `lib/TerminalCore/Sources/` is touched by this finding.
    var product: UInt64 {
        evictionProduct([
            recordCount, census.arenaBytesInUse, grandDisplayRowTotal, evictedRowCount,
        ])
    }
}

// MARK: - Arm A: today's budget enforcement

/// Today's retained-row store and its budget enforcement, reproduced.
///
/// `Terminal.ScrollbackBuffer`, `Terminal.scrollbackByteCost(of:)`,
/// `Terminal.appendToScrollback`, `Terminal.enforceScrollbackBudget` and `Terminal.handleEviction`
/// are all `private` to `Terminal`, so this reproduces them rather than calling them -- `research/31/D4`'s
/// stated fidelity limit. What it does *not* substitute is the encoder: `PackedRetainedRow.pack`
/// is the production one, and `removeFirst` keeps the slot-release write and `compactIfNeeded`
/// that `research/15/F4` put there.
struct BudgetEnforcedRowStore {
    private var storage: [Terminal.PackedRetainedRow] = []
    private var storageStart = 0
    private(set) var chargedBytes = 0
    private(set) var storedCells = 0
    private(set) var isHistoryHeadTruncated = false
    private(set) var evictedRowCount = 0
    private(set) var observation: UInt64 = 0
    /// How many times `compactIfNeeded` actually copied. Reported because it is a real, amortized
    /// term of today's eviction path and a round that pays one is not comparable to one that does
    /// not -- so the count travels with the number rather than hiding inside it.
    private(set) var compactionCount = 0

    let budgetBytes: Int

    init(budgetBytes: Int) { self.budgetBytes = budgetBytes }

    var retainedRowCount: Int { storage.count - storageStart }
    var slotCount: Int { storage.count }
    var headSlot: Int { storageStart }

    func retainedRow(at index: Int) -> Terminal.GridRow {
        storage[storageStart + index].unpacked()
    }

    func retainedIsSoftWrapped(at index: Int) -> Bool {
        storage[storageStart + index].isSoftWrapped
    }

    /// `Terminal.swift#appendToScrollback`, for one row.
    @inline(__always)
    mutating func admit(_ row: Terminal.GridRow) {
        let packed = Terminal.PackedRetainedRow.pack(row)
        storage.append(packed)
        chargedBytes += Self.byteCost(of: packed)
        storedCells += packed.storedCellCount
    }

    /// `Terminal.swift#enforceScrollbackBudget`, with the two deleted caps' terms omitted because
    /// the arms are compared at the byte budget alone (`research/31/D2` Decision 4 deletes both caps).
    @discardableResult
    @inline(__always)
    mutating func enforceBudget() -> Int {
        var lastEvictedIsSoftWrapped: Bool?
        var evictedCount = 0
        while chargedBytes > budgetBytes {
            let evicted = removeFirst()
            chargedBytes -= Self.byteCost(of: evicted)
            storedCells -= evicted.storedCellCount
            lastEvictedIsSoftWrapped = evicted.isSoftWrapped
            evictedCount += 1
        }
        finishEviction(lastEvictedIsSoftWrapped, evictedCount)
        return evictedCount
    }

    /// The same loop bounded by a step count instead of by the charge (`research/31/F8`'s `research/31/DD29`).
    @discardableResult
    @inline(__always)
    mutating func evictSteps(_ steps: Int) -> Int {
        var lastEvictedIsSoftWrapped: Bool?
        var evictedCount = 0
        while evictedCount < steps, retainedRowCount > 0 {
            let evicted = removeFirst()
            chargedBytes -= Self.byteCost(of: evicted)
            storedCells -= evicted.storedCellCount
            lastEvictedIsSoftWrapped = evicted.isSoftWrapped
            evictedCount += 1
        }
        finishEviction(lastEvictedIsSoftWrapped, evictedCount)
        return evictedCount
    }

    @inline(__always)
    private mutating func finishEviction(_ lastEvictedIsSoftWrapped: Bool?, _ evictedCount: Int) {
        if let lastEvictedIsSoftWrapped { isHistoryHeadTruncated = lastEvictedIsSoftWrapped }
        if evictedCount > 0 { observation &+= 1 }
        handleEviction(of: evictedCount)
    }

    /// `Terminal.swift#handleEviction`, reduced to the part that survives without a `Terminal`.
    ///
    /// The real one clamps a selection, a search occurrence, two link states and a browsing
    /// anchor; the probe holds none of them, so what is left is the guard and the counter. **The
    /// five nil tests are deliberately not faked in**: written against compile-time `nil` they
    /// would be deleted by the optimizer, and a hand-rolled stand-in would be a cost this rule did
    /// not ask for. So arm A is charged slightly *less* than production here, which is
    /// conservative toward the candidate -- and the arena's step 4 has no analogue at all
    /// (`research/31/D2` Decision 2 as amended: no anchor cache), so the omission cannot flatter arm B.
    @inline(__always)
    private mutating func handleEviction(of rowCount: Int) {
        guard rowCount > 0 else { return }
        evictedRowCount += rowCount
    }

    /// `Terminal.ScrollbackBuffer.removeFirst`, transcribed including the release and the
    /// amortized compaction.
    @inline(__always)
    private mutating func removeFirst() -> Terminal.PackedRetainedRow {
        let row = storage[storageStart]
        storage[storageStart] = Terminal.PackedRetainedRow()
        storageStart += 1
        compactIfNeeded()
        return row
    }

    @inline(__always)
    private mutating func compactIfNeeded() {
        if storageStart == storage.count {
            storage.removeAll(keepingCapacity: false)
            storageStart = 0
            compactionCount += 1
            return
        }
        guard storageStart >= 1_024, storageStart * 2 >= storage.count else { return }
        storage = Array(storage[storageStart...])
        storageStart = 0
        compactionCount += 1
    }

    /// `Terminal.swift#scrollbackByteCost(of:)`, transcribed.
    @inline(__always)
    static func byteCost(of row: Terminal.PackedRetainedRow) -> Int {
        var total = MemoryLayout<Terminal.PackedRetainedRow>.stride
            + Terminal.arrayStorageHeaderBytes
            + row.storage.capacity
        if row.spillCount > 0 {
            total += Terminal.arrayStorageHeaderBytes
                + row.spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride
            for spill in row.spills {
                total += Terminal.arrayStorageHeaderBytes
                    + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
            }
        }
        return total
    }

    var product: UInt64 {
        evictionProduct([retainedRowCount, chargedBytes, storedCells, evictedRowCount])
    }
}

// MARK: - Arm C: the arena design at two granularities

/// A linear reproduction of the arena, evicted either one display row at a time or one whole
/// record at a time (`research/31/F8`'s `research/31/DD30`).
///
/// Linear rather than a ring on purpose: arm C measures a **drain**, which writes nothing at the
/// tail, so the ring's wrap discipline cannot participate in the number and reproducing it would
/// only add code that is never exercised inside a timed region. What is reproduced exactly is the
/// part the granularity question turns on: the 8-byte `LogicalLineRecord` header, the C1 cell word,
/// and `LogicalLineFold`'s own boundary walk -- all three used directly rather than transcribed.
struct GranularityArena {
    enum Granularity: String {
        /// `research/31/D2` Decision 2's rule: fold one display row from the head, trim inside the record
        /// when it holds more, drop it when it does not.
        case headRow
        /// `research/31/DD2` as originally written: the whole head record leaves in one step.
        case wholeRecord
    }

    private var arena: [UInt8]
    private var offsets: [Int] = []
    private var offsetsStart = 0
    private(set) var displayRowTotal = 0
    private(set) var evictedRowCount = 0
    private(set) var bytesInUse = 0
    let width: Int

    var recordCount: Int { offsets.count - offsetsStart }

    init(capacityBytes: Int, width: Int) {
        arena = [UInt8](repeating: 0, count: capacityBytes)
        self.width = width
    }

    mutating func warm() {
        _ = arena.withUnsafeMutableBufferPointer { $0.count }
        _ = offsets.withUnsafeMutableBufferPointer { $0.count }
    }

    /// Appends one logical line's cells as one record. Admission is outside every timed region
    /// here, so it is written for clarity rather than for speed.
    mutating func appendRecord(cells: [Terminal.GridCell]) -> Bool {
        let length = Terminal.LogicalLineRecord.headerAndCells(cells.count)
        guard bytesInUse + length <= arena.count else { return false }
        let offset = bytesInUse
        var word: UInt64 = 0
        var hasWide = false
        for (index, cell) in cells.enumerated() {
            word = UInt64(cell.kind.packedCode) << Terminal.PackedRetainedRow.Header.cellKindShift
            word |= UInt64(cell.styleId) << Terminal.PackedRetainedRow.Header.cellStyleShift
            if cell.scalars.count == 1 { word |= UInt64(cell.scalars[0].value) }
            if cell.kind == .wideHead { hasWide = true }
            setWord(word, at: offset + Terminal.LogicalLineRecord.headerAndCells(index))
        }
        let record = Terminal.LogicalLineRecord(cellCount: cells.count, hasWideCells: hasWide)
        setWord(record.word, at: offset)
        offsets.append(offset)
        bytesInUse += length
        displayRowTotal += rowCount(of: record, at: offset)
        return true
    }

    /// Evicts until at least `rows` display rows are gone. Returns the rows actually dropped,
    /// which whole-record granularity overshoots -- that overshoot is `research/31/F6` `research/31/HR5`'s hazard and is
    /// reported rather than hidden.
    @discardableResult
    @inline(__always)
    mutating func drain(rows: Int, granularity: Granularity) -> Int {
        var dropped = 0
        while dropped < rows, offsetsStart < offsets.count {
            let offset = offsets[offsetsStart]
            let record = Terminal.LogicalLineRecord(word: word(at: offset))
            switch granularity {
            case .headRow:
                let cut = Terminal.LogicalLineFold.firstRowCellEnd(
                    cellCount: record.cellCount,
                    width: width,
                    isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
                )
                if cut >= record.cellCount {
                    offsetsStart += 1
                    bytesInUse -= record.byteLength
                } else {
                    var trimmed = record
                    trimmed.cellCount -= cut
                    trimmed.startsMidLine = true
                    let newOffset = offset + cut * Terminal.LogicalLineRecord.cellBytes
                    setWord(trimmed.word, at: newOffset)
                    offsets[offsetsStart] = newOffset
                    bytesInUse -= cut * Terminal.LogicalLineRecord.cellBytes
                }
                dropped += 1
                displayRowTotal -= 1
                evictedRowCount += 1
            case .wholeRecord:
                let rowsHere = rowCount(of: record, at: offset)
                offsetsStart += 1
                bytesInUse -= record.byteLength
                dropped += rowsHere
                displayRowTotal -= rowsHere
                evictedRowCount += rowsHere
            }
        }
        return dropped
    }

    private func rowCount(of record: Terminal.LogicalLineRecord, at offset: Int) -> Int {
        Terminal.LogicalLineFold.rowCount(
            cellCount: record.cellCount,
            width: width,
            hasWideCells: record.hasWideCells,
            isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
        )
    }

    @inline(__always)
    private func isWideHead(recordAt offset: Int, cell index: Int) -> Bool {
        let value = word(at: offset + Terminal.LogicalLineRecord.headerAndCells(index))
        let kind = (value >> Terminal.PackedRetainedRow.Header.cellKindShift)
            & Terminal.PackedRetainedRow.Header.cellKindMask
        return kind == UInt64(TerminalCellKind.wideHead.packedCode)
    }

    @inline(__always)
    private func word(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 { value |= UInt64(arena[offset + byte]) << (8 * byte) }
        return value
    }

    @inline(__always)
    private mutating func setWord(_ value: UInt64, at offset: Int) {
        for byte in 0..<8 { arena[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
    }

    var product: UInt64 {
        evictionProduct([recordCount, bytesInUse, displayRowTotal, evictedRowCount])
    }
}

// MARK: - Residency instrumentation

/// Live and obtained bytes across every malloc zone, as `#mallocHeapSnapshot` reads them.
func residentHeapBytes() -> (inUse: UInt64, allocated: UInt64) {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return (UInt64(statistics.size_in_use), UInt64(statistics.size_allocated))
}

/// `vmmap --summary`'s MALLOC / VIRTUAL / TOTAL lines, dumped verbatim.
///
/// Dumped rather than parsed, which is the probe's own rule: vmmap's format is not a contract and
/// a wrong parse produces a confident number.
///
/// `/usr/bin/vmmap` is a Mac tool, and `Process` -- the only way to reach it -- does not exist off
/// the Mac. Rather than make the whole suite host-bound for this one reading, the probe reports the
/// reading as unavailable there; the caller already prints whatever comes back verbatim.
func vmmapSummaryLines() -> [String] {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    process.arguments = ["--summary", String(ProcessInfo.processInfo.processIdentifier)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["vmmap failed to launch: \(error)"] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { $0.contains("MALLOC") || $0.contains("VIRTUAL") || $0.contains("TOTAL") }
        .map(String.init)
    #else
    return ["vmmap is unavailable off macOS"]
    #endif
}

// MARK: - The probe

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// `research/31/F8`: prices head-granular eviction against today's budget enforcement, and reads the four
/// residency states `AR6` asks for.
///
/// Reports distributions and gate outcomes; it prints no verdict. The thresholds live in `research/31/D4`
/// and are applied once, by hand, to what this prints.
@Suite(.serialized)
struct TerminalLogicalLineEvictionProbe {
    static let probeIsEnabled =
        ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil
    static let residencyCase = ProcessInfo.processInfo.environment["DANTERM_RESIDENCY_CASE"]
    static let residencyIsEnabled = probeIsEnabled && residencyCase != nil

    static let columns = 179
    static let budget = Terminal.scrollbackByteLimit
    static let rounds = 5
    static let warmupRounds = 2
    static let steadyAdmissions = 5_000
    static let drainRows = 2_000

    // MARK: Stimulus and saturated baselines

    /// Both arms filled to the budget from one fed stream, plus everything the gates need to read
    /// them. Every fill happens outside every timed region.
    ///
    /// A saturated store is **rebuilt** per round rather than copied from one baseline, and that is
    /// not fastidiousness: `PackedRetainedRow` owns two Swift arrays, so a copied baseline keeps a
    /// reference to every retained row's blob and arm A's evictions decrement instead of calling
    /// `free`. That silently deletes a real per-eviction cost from the baseline only -- the arena
    /// has no per-row allocation to free -- which is a bias in the candidate's *disfavour* and was
    /// removed before any number here was read.
    struct Bench {
        let contentClass: EvictionContentClass
        let stimulus: RetainedStimulus
        let baselineA: BudgetEnforcedRowStore
        let baselineB: Terminal.LogicalLineStore
        let totalFed: Int

        func fedRow(_ index: Int) -> Terminal.GridRow {
            stimulus.displayRows[index % stimulus.displayRows.count]
        }

        /// Today's store, filled to the budget from the same fed prefix the gates read.
        func fillArmA() -> BudgetEnforcedRowStore {
            var store = BudgetEnforcedRowStore(budgetBytes: TerminalLogicalLineEvictionProbe.budget)
            for index in 0..<totalFed {
                store.admit(fedRow(index))
                store.enforceBudget()
            }
            return store
        }

        /// The arena slice 3 landed, filled from the same fed prefix.
        func fillArmB() -> Terminal.LogicalLineStore {
            var store = Terminal.LogicalLineStore(
                capacityBytes: TerminalLogicalLineEvictionProbe.budget,
                width: TerminalLogicalLineEvictionProbe.columns
            )
            for index in 0..<totalFed { store.admit(fedRow(index)) }
            return store
        }
    }

    /// Fills both arms from the same cycled stream until each has evicted at least as many display
    /// rows as it retains, so both are at genuine steady state and the arena's ring has wrapped at
    /// least once before anything is timed.
    static func makeBench(_ contentClass: EvictionContentClass) -> Bench {
        let stimulus = buildEvictionStimulus(contentClass: contentClass)
        var armA = BudgetEnforcedRowStore(budgetBytes: budget)
        var armB = Terminal.LogicalLineStore(capacityBytes: budget, width: columns)

        var fed = 0
        let source = stimulus.displayRows
        while true {
            let row = source[fed % source.count]
            armA.admit(row)
            armA.enforceBudget()
            armB.admit(row)
            fed += 1
            let cycleComplete = fed % source.count == 0
            guard cycleComplete else { continue }
            let armASettled = armA.evictedRowCount >= armA.retainedRowCount
            let armBSettled = armB.evictedRowCount >= armB.grandDisplayRowTotal
            if armASettled, armBSettled { break }
        }
        return Bench(
            contentClass: contentClass,
            stimulus: stimulus,
            baselineA: armA,
            baselineB: armB,
            totalFed: fed
        )
    }

    // MARK: Calibration

    @Test("F8 calibration: what each class produces, and how its records fold", .enabled(if: probeIsEnabled))
    func evictionCalibration() throws {
        print("[F8 calibration] load average: \(loadAverageDescription())")
        for contentClass in EvictionContentClass.allCases {
            let stimulus = buildEvictionStimulus(contentClass: contentClass)
            let counts = stimulus.storedCellCounts()
            let sorted = counts.sorted()
            let softWrapped = stimulus.displayRows.filter(\.isSoftWrapped).count
            let spacers = stimulus.displayRows.reduce(0) { total, row in
                total + row.cells.filter { $0.kind == .spacerHead }.count
            }
            let wideRows = stimulus.displayRows.filter { row in
                row.cells.contains { $0.kind == .wideHead }
            }.count
            var rowsPerLine: [Int] = []
            for index in 0..<stimulus.lineCount {
                rowsPerLine.append(stimulus.lineStarts[index + 1] - stimulus.lineStarts[index])
            }
            let sortedRowsPerLine = rowsPerLine.sorted()
            print(
                """
                [F8 calibration] class=\(contentClass.rawValue) verdictBearing=\(contentClass.isVerdictBearing) \
                displayRows=\(counts.count) logicalLines=\(stimulus.lineCount) n=\(counts.count)
                  medianCells=\(sorted[sorted.count / 2]) p95Cells=\(percentile(counts, 0.95)) \
                meanCells=\(String(format: "%.1f", Double(counts.reduce(0, +)) / Double(counts.count))) \
                minCells=\(sorted.first ?? 0) maxCells=\(sorted.last ?? 0)
                  softWrappedFraction=\(String(format: "%.4f", Double(softWrapped) / Double(counts.count))) \
                spacerHeads=\(spacers) wideRows=\(wideRows) \
                medianRowsPerLine=\(sortedRowsPerLine[sortedRowsPerLine.count / 2]) \
                minRowsPerLine=\(sortedRowsPerLine.first ?? 0) maxRowsPerLine=\(sortedRowsPerLine.last ?? 0)
                """
            )
            #expect(counts.count >= 1_000)
        }
    }

    // MARK: The two verdict-bearing statistics

    @Test("F8: the whole write path at steady state, and eviction alone", .enabled(if: probeIsEnabled))
    func evictionComparison() throws {
        print("[F8] load average before: \(loadAverageDescription())")

        for contentClass in EvictionContentClass.allCases {
            let bench = Self.makeBench(contentClass)
            try reportDepthsAndFidelity(bench)
            try measureSteady(bench)
            try measureDrain(bench)
        }

        print("[F8] load average after: \(loadAverageDescription())")
    }

    /// Gates 1 and 2, plus the depth reading `research/31/D4` asks for beside every class.
    private func reportDepthsAndFidelity(_ bench: Bench) throws {
        let armA = bench.baselineA
        let armB = bench.baselineB
        let retainedA = armA.retainedRowCount
        let retainedB = armB.grandDisplayRowTotal

        var checksumA: UInt64 = 5_381
        for index in 0..<retainedA { evictionRowChecksum(armA.retainedRow(at: index), into: &checksumA) }
        var checksumB: UInt64 = 5_381
        for index in 0..<retainedB {
            guard let row = armB.displayRow(at: index) else { break }
            evictionRowChecksum(row, into: &checksumB)
        }

        // Gate 1, first half: each arm against an expectation for the suffix of the fed stream it
        // should have retained, computed from the source rows and touching neither store.
        let expectedA = Self.suffixChecksum(bench, retained: retainedA)
        let expectedB = Self.suffixChecksum(bench, retained: retainedB)
        // Gate 1, second half: the two arms over the display rows both retain.
        let overlap = min(retainedA, retainedB)
        var overlapA: UInt64 = 5_381
        for index in (retainedA - overlap)..<retainedA {
            evictionRowChecksum(armA.retainedRow(at: index), into: &overlapA)
        }
        var overlapB: UInt64 = 5_381
        for index in (retainedB - overlap)..<retainedB {
            guard let row = armB.displayRow(at: index) else { break }
            evictionRowChecksum(row, into: &overlapB)
        }

        // Gate 2: the first retained display row reads as a mid-line continuation exactly when the
        // row above it was soft-wrapped.
        let aboveA = bench.fedRow(bench.totalFed - retainedA - 1).isSoftWrapped
        let aboveB = bench.fedRow(bench.totalFed - retainedB - 1).isSoftWrapped
        let stampedB = armB.recordSummary(at: 0)?.startsMidLine ?? false

        // Gate 4's independent half for arm B: the grand total against a recount off the arena.
        let recountB = armB.independentDisplayRowRecount()

        print(
            """
            [F8 \(bench.contentClass.rawValue)/depths] fedRows=\(bench.totalFed) \
            budget=\(Self.budget) B
              armA retainedRows=\(retainedA) chargedBytes=\(armA.chargedBytes) \
              storedCells=\(armA.storedCells) evicted=\(armA.evictedRowCount) \
              slots=\(armA.slotCount) headSlot=\(armA.headSlot) compactions=\(armA.compactionCount)
              armB retainedRows=\(retainedB) records=\(armB.recordCount) \
            charged=\(armB.census.chargedBytes) (arena \(armB.census.arenaBytesInUse) + \
            index \(armB.census.indexBytes) + side \(armB.census.sideTableBytes)) \
            capacity=\(armB.capacityBytes) evicted=\(armB.evictedRowCount) recount=\(recountB)
              depthRatio(B/A)=\(String(format: "%.3f", Double(retainedB) / Double(retainedA)))x \
            rowsPerRecord=\(String(format: "%.2f", Double(retainedB) / Double(max(armB.recordCount, 1))))
              gate1 armAMatchesFedSuffix=\(checksumA == expectedA) \
            armBMatchesFedSuffix=\(checksumB == expectedB) overlapRows=\(overlap) \
            overlapChecksumsEqual=\(overlapA == overlapB)
              gate2 armA isHistoryHeadTruncated=\(armA.isHistoryHeadTruncated) expected=\(aboveA) \
            armB startsMidLine=\(stampedB) expected=\(aboveB)
            """
        )

        #expect(checksumA == expectedA)
        #expect(checksumB == expectedB)
        #expect(overlapA == overlapB)
        #expect(armA.isHistoryHeadTruncated == aboveA)
        #expect(stampedB == aboveB)
        #expect(recountB == retainedB)
    }

    static func suffixChecksum(_ bench: Bench, retained: Int) -> UInt64 {
        var checksum: UInt64 = 5_381
        for index in (bench.totalFed - retained)..<bench.totalFed {
            evictionRowChecksum(bench.fedRow(index), into: &checksum)
        }
        return checksum
    }

    /// `steady`: the whole write path per admitted display row, on a store already at the budget.
    private func measureSteady(_ bench: Bench) throws {
        let admissions = Self.steadyAdmissions
        let start = bench.totalFed

        func armAOnce() -> (ArmRound, Int, Int) {
            var store = bench.fillArmA()
            let evictedBefore = store.evictedRowCount
            let compactionsBefore = store.compactionCount
            let started = now()
            for offset in 0..<admissions {
                store.admit(bench.fedRow(start + offset))
                store.enforceBudget()
            }
            let elapsed = now() &- started
            return (
                ArmRound(nanoseconds: elapsed, readCount: admissions, checksum: store.product),
                store.evictedRowCount - evictedBefore,
                store.compactionCount - compactionsBefore
            )
        }

        func armBOnce() -> (ArmRound, Int) {
            var store = bench.fillArmB()
            let evictedBefore = store.evictedRowCount
            let started = now()
            for offset in 0..<admissions {
                store.admit(bench.fedRow(start + offset))
            }
            let elapsed = now() &- started
            return (
                ArmRound(nanoseconds: elapsed, readCount: admissions, checksum: store.product),
                store.evictedRowCount - evictedBefore
            )
        }

        let (expectedA, evictedA, compactionsA) = armAOnce()
        let (expectedB, evictedB) = armBOnce()

        let measured = interleavedRounds(
            rounds: Self.rounds, warmupRounds: Self.warmupRounds,
            armA: { armAOnce().0 }, armB: { armBOnce().0 }
        )
        let aa = interleavedRounds(
            rounds: Self.rounds, warmupRounds: Self.warmupRounds,
            armA: { armAOnce().0 }, armB: { armAOnce().0 }
        )
        Self.report(
            label: "steady", bench: bench, unit: "ns/admitted row",
            measured: measured, aa: aa, samples: admissions,
            extra: """
                gate3 armA evicted=\(evictedA)/\(admissions) \
                (\(String(format: "%+.2f", Double(evictedA - admissions) / Double(admissions) * 100))%) \
                armB evicted=\(evictedB)/\(admissions) \
                (\(String(format: "%+.2f", Double(evictedB - admissions) / Double(admissions) * 100))%) \
                armA compactions/round=\(compactionsA)
                  gate4 products armAExpected=\(expectedA.checksum) measured=\(measured.checksumA) \
                armBExpected=\(expectedB.checksum) measured=\(measured.checksumB)
                """
        )
        #expect(measured.checksumA == expectedA.checksum)
        #expect(measured.checksumB == expectedB.checksum)
        #expect(abs(evictedA - admissions) * 100 <= admissions)
        #expect(abs(evictedB - admissions) * 100 <= admissions)
    }

    /// `drain`: eviction alone per evicted display row, over a fixed 2,000-step loop (`research/31/DD29`).
    private func measureDrain(_ bench: Bench) throws {
        let steps = Self.drainRows

        func armAOnce() -> ArmRound {
            var store = bench.fillArmA()
            let started = now()
            let dropped = store.evictSteps(steps)
            let elapsed = now() &- started
            return ArmRound(nanoseconds: elapsed, readCount: dropped, checksum: store.product)
        }

        func armBOnce() -> ArmRound {
            var store = bench.fillArmB()
            let started = now()
            var dropped = 0
            while dropped < steps, store.evictOneDisplayRow() { dropped += 1 }
            let elapsed = now() &- started
            return ArmRound(nanoseconds: elapsed, readCount: dropped, checksum: store.product)
        }

        let expectedA = armAOnce()
        let expectedB = armBOnce()

        let measured = interleavedRounds(
            rounds: Self.rounds, warmupRounds: Self.warmupRounds, armA: armAOnce, armB: armBOnce
        )
        let aa = interleavedRounds(
            rounds: Self.rounds, warmupRounds: Self.warmupRounds, armA: armAOnce, armB: armAOnce
        )
        Self.report(
            label: "drain", bench: bench, unit: "ns/evicted row",
            measured: measured, aa: aa, samples: steps,
            extra: """
                gate3 armA evicted=\(expectedA.readCount)/\(steps) armB evicted=\(expectedB.readCount)/\(steps) \
                (satisfied by construction: research/31/DD29's fixed-step loop)
                  gate4 products armAExpected=\(expectedA.checksum) measured=\(measured.checksumA) \
                armBExpected=\(expectedB.checksum) measured=\(measured.checksumB)
                """
        )
        #expect(measured.checksumA == expectedA.checksum)
        #expect(measured.checksumB == expectedB.checksum)
        #expect(expectedA.readCount == steps)
        #expect(expectedB.readCount == steps)
    }

    static func report(
        label: String,
        bench: Bench,
        unit: String,
        measured: (a: [Double], b: [Double], checksumA: UInt64, checksumB: UInt64, readCount: Int),
        aa: (a: [Double], b: [Double], checksumA: UInt64, checksumB: UInt64, readCount: Int),
        samples: Int,
        extra: String
    ) {
        let baseline = median(measured.a)
        let candidate = median(measured.b)
        let aaLeft = median(aa.a)
        let aaRight = median(aa.b)
        print(
            """
            [F8 \(bench.contentClass.rawValue)/\(label)] n=\(Self.rounds) rounds, \
            \(samples) samples/round, verdictBearing=\(bench.contentClass.isVerdictBearing)
              armA (today)  median=\(String(format: "%.1f", baseline)) \(unit) \
            (min \(String(format: "%.1f", measured.a.min() ?? .nan)), \
            max \(String(format: "%.1f", measured.a.max() ?? .nan)), n=\(measured.a.count))
              armB (arena)  median=\(String(format: "%.1f", candidate)) \(unit) \
            (min \(String(format: "%.1f", measured.b.min() ?? .nan)), \
            max \(String(format: "%.1f", measured.b.max() ?? .nan)), n=\(measured.b.count))
              ratio=\(String(format: "%.3f", candidate / baseline))x \
            delta=\(String(format: "%+.2f", (candidate / baseline - 1) * 100))%
              gate5 A/A ratio=\(String(format: "%.3f", aaRight / aaLeft))x \
            delta=\(String(format: "%+.2f", (aaRight / aaLeft - 1) * 100))% (resolution floor, n=\(aa.a.count))
              \(extra)
            """
        )
    }

    // MARK: Gate 7 -- complexity fidelity

    @Test("F8 gate 7: per-step cost by quartile of a record's drain, on wrapped", .enabled(if: probeIsEnabled))
    func complexityFidelity() throws {
        let bench = Self.makeBench(.wrapped)
        var store = bench.fillArmB()

        var quartiles: [[Double]] = [[], [], [], []]
        var terminalSteps: [Double] = []
        var recordsDrained = 0
        let targetRecords = 20

        while recordsDrained < targetRecords, store.recordCount > 0 {
            guard let summary = store.recordSummary(at: 0), summary.displayRowCount > 0 else { break }
            let total = summary.displayRowCount
            guard total >= 8 else {
                _ = store.evictOneDisplayRow()
                continue
            }
            for step in 0..<total {
                let started = now()
                _ = store.evictOneDisplayRow()
                let elapsed = Double(now() &- started)
                if step == total - 1 {
                    terminalSteps.append(elapsed)
                } else {
                    quartiles[min(3, step * 4 / total)].append(elapsed)
                }
            }
            recordsDrained += 1
        }

        let medians = quartiles.map { median($0) }
        let ratio = medians[3] / medians[0]
        print(
            """
            [F8 gate7] class=wrapped recordsDrained=\(recordsDrained) \
            rowsPerRecord=\(quartiles.reduce(0) { $0 + $1.count } / max(recordsDrained, 1) + 1)
              Q1 median=\(String(format: "%.1f", medians[0])) ns (n=\(quartiles[0].count)) \
            Q2=\(String(format: "%.1f", medians[1])) ns (n=\(quartiles[1].count)) \
            Q3=\(String(format: "%.1f", medians[2])) ns (n=\(quartiles[2].count)) \
            Q4=\(String(format: "%.1f", medians[3])) ns (n=\(quartiles[3].count))
              Q4/Q1=\(String(format: "%.3f", ratio))x   ceiling 1.20x; a record walk would separate by ~7x
              record-drop step (last of each record, excluded from the quartiles and reported \
            beside them): median=\(String(format: "%.1f", median(terminalSteps))) ns (n=\(terminalSteps.count))
            """
        )
        #expect(recordsDrained >= 8)
    }

    // MARK: Arm C -- granularity, descriptive only

    @Test("F8 arm C: head-granular against whole-record eviction on one arena", .enabled(if: probeIsEnabled))
    func granularityComparison() throws {
        print("[F8 armC] load average: \(loadAverageDescription())")
        for contentClass in EvictionContentClass.allCases {
            let stimulus = buildEvictionStimulus(contentClass: contentClass)
            var baseline = GranularityArena(capacityBytes: Self.budget, width: Self.columns)
            var line: [Terminal.GridCell] = []
            var records = 0
            fill: for _ in 0..<64 {
                for row in stimulus.displayRows {
                    let end = row.isSoftWrapped
                        ? row.cells.count
                        : ((row.cells.lastIndex { $0 != Terminal.GridCell() } ?? -1) + 1)
                    var cells = Array(row.cells[0..<end])
                    if cells.last?.kind == .spacerHead { cells.removeLast() }
                    line.append(contentsOf: cells)
                    guard row.isSoftWrapped == false else { continue }
                    guard baseline.appendRecord(cells: line) else { break fill }
                    records += 1
                    line.removeAll(keepingCapacity: true)
                }
            }

            let steps = Self.drainRows
            func arm(_ granularity: GranularityArena.Granularity) -> () -> ArmRound {
                {
                    var arena = baseline
                    arena.warm()
                    let started = now()
                    let dropped = arena.drain(rows: steps, granularity: granularity)
                    let elapsed = now() &- started
                    return ArmRound(
                        nanoseconds: elapsed, readCount: dropped, checksum: arena.product
                    )
                }
            }

            let measured = interleavedRounds(
                rounds: Self.rounds, warmupRounds: Self.warmupRounds,
                armA: arm(.headRow), armB: arm(.wholeRecord)
            )
            var probe = baseline
            let droppedWhole = probe.drain(rows: steps, granularity: .wholeRecord)
            let headMedian = median(measured.a)
            let wholeMedian = median(measured.b)
            print(
                """
                [F8 armC \(contentClass.rawValue)] records=\(records) \
                rows=\(baseline.displayRowTotal) bytes=\(baseline.bytesInUse) \
                rowsPerRecord=\(String(format: "%.2f", Double(baseline.displayRowTotal) / Double(max(records, 1))))
                  head-granular  median=\(String(format: "%.1f", headMedian)) ns/evicted row \
                (min \(String(format: "%.1f", measured.a.min() ?? .nan)), \
                max \(String(format: "%.1f", measured.a.max() ?? .nan)), n=\(measured.a.count))
                  whole-record   median=\(String(format: "%.1f", wholeMedian)) ns/evicted row \
                (min \(String(format: "%.1f", measured.b.min() ?? .nan)), \
                max \(String(format: "%.1f", measured.b.max() ?? .nan)), n=\(measured.b.count))
                  head/whole=\(String(format: "%.3f", headMedian / wholeMedian))x \
                whole-record overshoot=\(droppedWhole - steps) display rows past the \(steps) asked for
                """
            )
            #expect(records > 0)
        }
    }

    /// The substitution `research/31/DD30` names, measured rather than assumed: the reproduction's
    /// head-granular drain against the real store's, on the same class and the same step count.
    @Test("F8 arm C fidelity: the reproduction against the real store", .enabled(if: probeIsEnabled))
    func granularityReproductionFidelity() throws {
        for contentClass in [EvictionContentClass.stream, .wrapped] {
            let bench = Self.makeBench(contentClass)
            let stimulus = bench.stimulus
            var baseline = GranularityArena(capacityBytes: Self.budget, width: Self.columns)
            var line: [Terminal.GridCell] = []
            fill: for _ in 0..<64 {
                for row in stimulus.displayRows {
                    let end = row.isSoftWrapped
                        ? row.cells.count
                        : ((row.cells.lastIndex { $0 != Terminal.GridCell() } ?? -1) + 1)
                    var cells = Array(row.cells[0..<end])
                    if cells.last?.kind == .spacerHead { cells.removeLast() }
                    line.append(contentsOf: cells)
                    guard row.isSoftWrapped == false else { continue }
                    guard baseline.appendRecord(cells: line) else { break fill }
                    line.removeAll(keepingCapacity: true)
                }
            }
            let steps = Self.drainRows

            func reproductionArm() -> ArmRound {
                var arena = baseline
                arena.warm()
                let started = now()
                let dropped = arena.drain(rows: steps, granularity: .headRow)
                let elapsed = now() &- started
                return ArmRound(nanoseconds: elapsed, readCount: dropped, checksum: arena.product)
            }
            func realStoreArm() -> ArmRound {
                var store = bench.fillArmB()
                let started = now()
                var dropped = 0
                while dropped < steps, store.evictOneDisplayRow() { dropped += 1 }
                let elapsed = now() &- started
                return ArmRound(nanoseconds: elapsed, readCount: dropped, checksum: store.product)
            }

            let measured = interleavedRounds(
                rounds: Self.rounds, warmupRounds: Self.warmupRounds,
                armA: realStoreArm, armB: reproductionArm
            )
            print(
                """
                [F8 armC fidelity \(contentClass.rawValue)] n=\(Self.rounds) rounds, \(steps) steps/round
                  real store    median=\(String(format: "%.1f", median(measured.a))) ns/evicted row \
                (n=\(measured.a.count))
                  reproduction  median=\(String(format: "%.1f", median(measured.b))) ns/evicted row \
                (n=\(measured.b.count))
                  reproduction/real=\(String(format: "%.3f", median(measured.b) / median(measured.a)))x
                """
            )
        }
    }

    // MARK: Attribution, descriptive and outside the verdict

    /// Splits the candidate's admission cost into "the arena design" and "this implementation of
    /// it", by running `research/31/F3`'s own prototype beside the landed store on the same rows.
    ///
    /// **Outside `research/31/D4`'s rule entirely**, and it exists for one reason: if the verdict-bearing arms
    /// reject, the first competing interpretation is "wrap-at-read admission is expensive", and
    /// `research/31/F3` already measured the opposite on a prototype. Running `research/31/F3`'s `OpenLineAdmitter` in the
    /// same session on the same stimulus is the only thing that can tell a design cost from an
    /// implementation cost -- the same job arm C does for granularity. Eviction is not in this
    /// reading: every store here has room, so nothing evicts and the three arms price admission
    /// alone.
    @Test("F8 attribution: today's admission, research/31/F3's prototype, and the landed store", .enabled(if: probeIsEnabled))
    func implementationAttribution() throws {
        for contentClass in EvictionContentClass.allCases {
            let stimulus = buildEvictionStimulus(contentClass: contentClass)
            let rows = stimulus.displayRows
            let rowCount = rows.count
            let storedCells = stimulus.storedCellCounts().reduce(0, +)
            let arenaBytes = (storedCells + 8 * stimulus.lineCount) * 8 + 1 << 20

            func timed(_ body: () -> Int) -> Double {
                for _ in 0..<Self.warmupRounds { _ = body() }
                var samples: [Double] = []
                for _ in 0..<Self.rounds {
                    let started = now()
                    let sink = body()
                    let elapsed = now() &- started
                    #expect(sink > 0)
                    samples.append(Double(elapsed) / Double(rowCount))
                }
                return median(samples)
            }

            let today = timed {
                var store = BudgetEnforcedRowStore(budgetBytes: Int.max)
                for row in rows { store.admit(row) }
                return store.retainedRowCount
            }
            let prototype = timed {
                var store = OpenLineAdmitter(
                    arenaBytes: arenaBytes, width: stimulus.columns,
                    expectedRecords: stimulus.lineCount
                )
                for row in rows { store.admit(row) }
                store.finish()
                return store.recordCount
            }
            // Sized past the stimulus so `evictToBudget` never fires: this arm prices `admit`.
            let landed = timed {
                var store = Terminal.LogicalLineStore(
                    capacityBytes: (arenaBytes + 7) & ~7, width: stimulus.columns
                )
                for row in rows { store.admit(row) }
                return store.recordCount
            }
            print(
                """
                [F8 attribution \(contentClass.rawValue)] rows=\(rowCount) n=\(Self.rounds) rounds, \
                admission only, no eviction
                  today's pack+append+accounting=\(String(format: "%.1f", today)) ns/row
                  F3 prototype open-line append =\(String(format: "%.1f", prototype)) ns/row \
                (\(String(format: "%.3f", prototype / today))x today)
                  landed LogicalLineStore.admit =\(String(format: "%.1f", landed)) ns/row \
                (\(String(format: "%.3f", landed / today))x today, \
                \(String(format: "%.3f", landed / prototype))x the prototype)
                """
            )
        }
    }

    // MARK: The AR6 residency reading

    /// One of the four pane states `research/31/D4` names, on one content class, for one store.
    ///
    /// Selected by `DANTERM_RESIDENCY_CASE=<store>/<class>/<state>` and run **one process per
    /// reading**, because the probe's own note records that a footprint delta is attributable only
    /// when nothing else has already claimed and freed the pages.
    @Test("F8 AR6: resident pages for one pane state", .enabled(if: residencyIsEnabled))
    func residencyReading() throws {
        let parts = (Self.residencyCase ?? "").split(separator: "/").map(String.init)
        try #require(parts.count == 3, "DANTERM_RESIDENCY_CASE must be <store>/<class>/<state>")
        let storeName = parts[0]
        let className = parts[1]
        let stateName = parts[2]

        print("[F8 AR6] case=\(Self.residencyCase ?? "?") load average before: \(loadAverageDescription())")

        let source = try Self.residencySourceRows(className: className, stateName: stateName)
        settleAllocator()
        let footprintBefore = residentFootprintBytes()
        let heapBefore = residentHeapBytes()
        let vmmapBefore = vmmapSummaryLines()

        var capacityBytes = 0
        var arenaBytesInUse = 0
        var indexBytes = 0
        var sideTableBytes = 0
        var retainedRows = 0
        var evictedRows = 0
        var admitted = 0
        var vmmap: [String] = []
        var censusIdentityHolds = true

        if storeName == "arena" {
            var store = Terminal.LogicalLineStore(capacityBytes: Self.budget, width: Self.columns)
            if stateName != "empty" {
                admitted = Self.fillArena(&store, rows: source, state: stateName)
            }
            let census = store.census
            capacityBytes = census.capacityBytes
            arenaBytesInUse = census.arenaBytesInUse
            indexBytes = census.indexBytes
            sideTableBytes = census.sideTableBytes
            retainedRows = store.grandDisplayRowTotal
            evictedRows = store.evictedRowCount
            censusIdentityHolds = census.chargedBytes <= census.capacityBytes
            settleAllocator()
            vmmap = vmmapSummaryLines()
            let footprintAfter = residentFootprintBytes()
            let heapAfter = residentHeapBytes()
            Self.printResidency(
                storeName: storeName, className: className, stateName: stateName,
                footprintBefore: footprintBefore, footprintAfter: footprintAfter,
                heapBefore: heapBefore, heapAfter: heapAfter,
                capacityBytes: capacityBytes, bytesInUse: arenaBytesInUse,
                indexBytes: indexBytes, sideTableBytes: sideTableBytes,
                retainedRows: retainedRows, evictedRows: evictedRows, admitted: admitted,
                censusIdentityHolds: censusIdentityHolds,
                vmmapBefore: vmmapBefore, vmmap: vmmap
            )
            withExtendedLifetime(store) {}
        } else {
            var store = BudgetEnforcedRowStore(budgetBytes: Self.budget)
            if stateName != "empty" {
                admitted = Self.fillRowStore(&store, rows: source, state: stateName)
            }
            capacityBytes = -1
            arenaBytesInUse = store.chargedBytes
            retainedRows = store.retainedRowCount
            evictedRows = store.evictedRowCount
            censusIdentityHolds = store.chargedBytes <= Self.budget
            settleAllocator()
            vmmap = vmmapSummaryLines()
            let footprintAfter = residentFootprintBytes()
            let heapAfter = residentHeapBytes()
            Self.printResidency(
                storeName: storeName, className: className, stateName: stateName,
                footprintBefore: footprintBefore, footprintAfter: footprintAfter,
                heapBefore: heapBefore, heapAfter: heapAfter,
                capacityBytes: capacityBytes, bytesInUse: arenaBytesInUse,
                indexBytes: 0, sideTableBytes: 0,
                retainedRows: retainedRows, evictedRows: evictedRows, admitted: admitted,
                censusIdentityHolds: censusIdentityHolds,
                vmmapBefore: vmmapBefore, vmmap: vmmap
            )
            withExtendedLifetime(store) {}
        }

        print("[F8 AR6] load average after: \(loadAverageDescription())")
        #expect(censusIdentityHolds)
    }

    /// The display rows a residency class feeds, taken from the memory probe's own payloads.
    ///
    /// `scrollback-plain` and `scrollback-mixed` are `MemoryProbeMatrix`'s, transcribed rather than
    /// imported (`TerminalCoreTests` does not depend on `TerminalMemoryProbeSupport`, and adding a
    /// module dependency to run a probe is not a change this slice is licensed to make). `blank` is
    /// the degenerate regime `research/31/D4` says carries no trigger.
    static func residencySourceRows(className: String, stateName: String) throws -> [Terminal.GridRow] {
        guard stateName != "empty" else { return [] }

        if className == "blank" {
            // One blank row taken from a real engine, then repeated: a blank line's display row is
            // trivially known, and feeding 2,000,000 of them through a `Terminal` would measure the
            // source rather than the store. Stated rather than hidden.
            var terminal = Terminal(
                columns: columns, rows: 66,
                scrollbackBudgetBytes: 1 << 24
            )!
            terminal.feed(Array(String(repeating: "\r\n", count: 200).utf8))
            guard let blank = terminal.retainedRowForTesting(at: 0) else { return [] }
            return [blank]
        }

        var bytes: [UInt8] = []
        // A small pool of distinct lines that the fill then cycles, rather than one line per
        // admitted row. Two reasons, and the second is why the pool is *small* rather than merely
        // bounded. Reaching the cycled state needs ~120,000 admissions on `plain` and ~3,000,000 on
        // `blank`, so one row per admission would be hundreds of megabytes of source. And the
        // source is inside the window this reading attributes to the store: a 12,000-row pool left
        // ~27 MiB of dirty pages standing before the store was built, the allocator then handed the
        // arena pages it already owned, and the measured delta came out *negative* -- the reason
        // the first two residency invocations were voided. 300 lines keeps every class's byte
        // shape (`mixed` cycles with period 3) while leaving the baseline near an empty process.
        // The payload generators are `MemoryProbeMatrix`'s; only the pool length is this probe's.
        let lines = 300
        switch className {
        case "plain":
            bytes = (0..<lines).flatMap {
                Array("DANTERM-MEMORY-\(String(format: "%05d", $0)) plain ascii scrollback payload\r\n".utf8)
            }
        case "mixed":
            let unicodeSamples = [
                "\u{754C}\u{9762}", "e\u{301}a\u{308}",
                "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{4E16}\u{754C}",
            ]
            bytes = (0..<lines).flatMap { line -> [UInt8] in
                switch line % 3 {
                case 0:
                    return Array(
                        "DANTERM-MEMORY-\(String(format: "%05d", line)) plain ascii scrollback payload\r\n".utf8
                    )
                case 1:
                    let first = unicodeSamples[line % unicodeSamples.count]
                    let second = unicodeSamples[(line + 1) % unicodeSamples.count]
                    return Array("\(first) unicode \(second) row \(line)\r\n".utf8)
                default:
                    let foreground = 30 + line % 8
                    let background = 40 + (line / 8) % 8
                    let attribute = [1, 2, 3, 4, 7, 9][line % 6]
                    return Array(
                        "\u{1B}[\(attribute);\(foreground);\(background)mstyled row \(line) with attributes\u{1B}[0m\r\n".utf8
                    )
                }
            }
        default:
            throw ResidencyError.unknownClass(className)
        }

        var terminal = Terminal(
            columns: columns, rows: 66,
            scrollbackBudgetBytes: 1 << 28
        )!
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + 4_096, bytes.endIndex)
            terminal.feed(Array(bytes[start..<end]))
            start = end
        }
        var rows: [Terminal.GridRow] = []
        rows.reserveCapacity(terminal.scrollbackRowCount)
        for index in 0..<terminal.scrollbackRowCount {
            guard var row = terminal.retainedRowForTesting(at: index) else { break }
            for column in row.cells.indices {
                row.cells[column].hyperlinkId = nil
                row.cells[column].contentIdentity = nil
            }
            rows.append(row)
        }
        return rows
    }

    enum ResidencyError: Error { case unknownClass(String) }

    /// Admits until the named state is reached. `partial` stops at ~50% of the charged budget,
    /// `saturated` at the first eviction, `cycled` once at least two full arenas' worth of display
    /// rows have been evicted.
    static func fillArena(
        _ store: inout Terminal.LogicalLineStore,
        rows: [Terminal.GridRow],
        state: String
    ) -> Int {
        guard rows.isEmpty == false else { return 0 }
        var admitted = 0
        var saturatedRows = 0
        while true {
            store.admit(rows[admitted % rows.count])
            admitted += 1
            switch state {
            case "partial":
                if store.census.chargedBytes * 2 >= budget { return admitted }
            case "saturated":
                if store.evictedRowCount > 0 { return admitted }
            case "cycled":
                if saturatedRows == 0, store.evictedRowCount > 0 {
                    saturatedRows = store.grandDisplayRowTotal
                }
                if saturatedRows > 0, store.evictedRowCount >= 2 * saturatedRows { return admitted }
            default:
                return admitted
            }
            if admitted > 40_000_000 { return admitted }
        }
    }

    static func fillRowStore(
        _ store: inout BudgetEnforcedRowStore,
        rows: [Terminal.GridRow],
        state: String
    ) -> Int {
        guard rows.isEmpty == false else { return 0 }
        var admitted = 0
        var saturatedRows = 0
        while true {
            store.admit(rows[admitted % rows.count])
            store.enforceBudget()
            admitted += 1
            switch state {
            case "partial":
                if store.chargedBytes * 2 >= budget { return admitted }
            case "saturated":
                if store.evictedRowCount > 0 { return admitted }
            case "cycled":
                if saturatedRows == 0, store.evictedRowCount > 0 {
                    saturatedRows = store.retainedRowCount
                }
                if saturatedRows > 0, store.evictedRowCount >= 2 * saturatedRows { return admitted }
            default:
                return admitted
            }
            if admitted > 40_000_000 { return admitted }
        }
    }

    static func printResidency(
        storeName: String,
        className: String,
        stateName: String,
        footprintBefore: UInt64,
        footprintAfter: UInt64,
        heapBefore: (inUse: UInt64, allocated: UInt64),
        heapAfter: (inUse: UInt64, allocated: UInt64),
        capacityBytes: Int,
        bytesInUse: Int,
        indexBytes: Int,
        sideTableBytes: Int,
        retainedRows: Int,
        evictedRows: Int,
        admitted: Int,
        censusIdentityHolds: Bool,
        vmmapBefore: [String],
        vmmap: [String]
    ) {
        let footprintDelta = Int64(footprintAfter) - Int64(footprintBefore)
        let heapDelta = Int64(heapAfter.inUse) - Int64(heapBefore.inUse)
        func mb(_ value: Int64) -> String { String(format: "%.3f MiB", Double(value) / 1_048_576) }
        func mb(_ value: Int) -> String { mb(Int64(value)) }
        let charged = bytesInUse + indexBytes + sideTableBytes
        print(
            """
            [F8 AR6 \(storeName)/\(className)/\(stateName)] n=1 process, one reading
              footprint delta=\(mb(footprintDelta)) (\(footprintDelta) B) \
            before=\(mb(Int64(footprintBefore))) after=\(mb(Int64(footprintAfter)))
              live heap delta=\(mb(heapDelta)) (\(heapDelta) B)
              census capacity=\(capacityBytes < 0 ? "not applicable (today's store has no reservation)" : mb(capacityBytes)) \
            bytesInUse=\(mb(bytesInUse)) index=\(mb(indexBytes)) sideTables=\(mb(sideTableBytes)) \
            charged=\(mb(charged))
              charged/budget=\(String(format: "%.4f", Double(charged) / Double(budget)))x \
            residentFootprint/budget=\(String(format: "%.4f", Double(footprintDelta) / Double(budget)))x
              retainedRows=\(retainedRows) evictedRows=\(evictedRows) admittedRows=\(admitted) \
            censusIdentity(charged<=budget)=\(censusIdentityHolds)
              vmmap --summary BEFORE the store existed (allocator settled), TOTAL DIRTY is the baseline:
            \(vmmapBefore.isEmpty ? "    not measured" : vmmapBefore.map { "    " + $0 }.joined(separator: "\n"))
              vmmap --summary while the store was resident (allocator settled). DIRTY is what the \
            footprint charges; TOTAL DIRTY here minus TOTAL DIRTY above is this store's resident cost:
            \(vmmap.isEmpty ? "    not measured" : vmmap.map { "    " + $0 }.joined(separator: "\n"))
            """
        )
    }
}
