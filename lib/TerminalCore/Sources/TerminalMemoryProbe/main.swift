// Thin CLI over the headless terminal-memory probe. All logic lives in
// TerminalMemoryProbeSupport so it can be unit-tested; this file only parses flags, picks an
// output format, and writes.
//
// Two output modes on purpose. `--json` is the machine-readable artifact an agent diffs between
// two builds; the default table is what a human reads to decide whether the diff is worth taking.
// Both come from the same report, so they cannot disagree.
import Foundation
import TerminalCore
import TerminalMemoryProbeSupport

func flagValue(_ name: String, default fallback: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Int(CommandLine.arguments[index + 1])
    else { return fallback }
    return value
}

let columns = flagValue("--columns", default: 179)
let rows = flagValue("--rows", default: 66)
let lineCount = flagValue("--lines", default: MemoryProbeMatrix.scrollbackLineCount)
let wantsJSON = CommandLine.arguments.contains("--json")
// `--chunk 0` restores single-shot feeding, which measures the parse spike rather than the resident
// cost. Kept reachable because that spike is itself worth measuring -- it is what a large paste
// does -- but it is not the default, since attributing it to holding a terminal is what made the
// probe's first footprint numbers wrong.
let chunkBytes: Int? = {
    let value = flagValue("--chunk", default: defaultFeedChunkBytes)
    return value > 0 ? value : nil
}()

// `--payload NAME` runs one payload and exits. This is the only mode whose footprint delta is
// attributable: payloads share one process, and the allocator reuses pages the previous payload
// freed, so in a full-matrix run every delta after the first understates its payload by whatever
// the largest predecessor already claimed. Census numbers are unaffected -- they are exact and
// per-terminal -- so the matrix run remains the right default for representation work.
let selectedPayload: String? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--payload"),
          index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}()

// `--vmmap` is the only way to see *dirty* allocator pages, which is the quantity `phys_footprint`
// actually charges for. `MallocHeapSnapshot.bytesAllocated` cannot answer it: it counts reserved
// region address space, ~20 MB of which exists before a single byte is fed and most of it clean.
//
// Sampled through `whileResident` so vmmap observes the process while the terminal is alive; run
// after `measure` returns it would describe a freed grid. Captured rather than printed inline so
// the tables stay contiguous, and dumped verbatim rather than parsed -- vmmap's format is not a
// contract, and a wrong parse produces a confident number, which is the failure mode doc 15 keeps
// hitting.
let wantsVmmap = CommandLine.arguments.contains("--vmmap")
// `nonisolated(unsafe)` because `whileResident` is a plain non-isolated closure, and the probe is
// synchronous single-threaded start to finish: the hook runs on this thread inside the `measure`
// call below, before anything reads the buffer.
nonisolated(unsafe) var vmmapLines: [String] = []

func captureVmmapSummary() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    process.arguments = ["--summary", String(ProcessInfo.processInfo.processIdentifier)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        vmmapLines.append("vmmap failed to launch: \(error)")
        return
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n", omittingEmptySubsequences: false)
    where line.contains("MALLOC") || line.contains("VIRTUAL") || line.contains("TOTAL") {
        vmmapLines.append(String(line))
    }
}

let residentHook: ((TerminalMemoryCensus) -> Void)? = wantsVmmap ? { _ in captureVmmapSummary() } : nil

let report: MemoryProbeReport
if let selectedPayload {
    // Validated by name at `lineCount: 1`, so this check never materializes the ~2 MB of payload
    // bytes the full matrix would build and throw away -- the process that measures a single
    // payload's footprint delta should not have allocated the other five first. The known-name list
    // is built only on the failure path, where nothing is about to be measured.
    let matched = MemoryProbeMatrix.payloads(columns: columns, lineCount: 1, named: selectedPayload)
    guard matched.isEmpty == false else {
        let known = MemoryProbeMatrix.payloads(columns: columns, lineCount: 1).map(\.name)
        FileHandle.standardError.write(
            Data("unknown payload '\(selectedPayload)'; known: \(known.joined(separator: ", "))\n".utf8)
        )
        exit(2)
    }
    report = runMatrix(
        columns: columns,
        rows: rows,
        lineCount: lineCount,
        only: selectedPayload,
        chunkBytes: chunkBytes,
        whileResident: residentHook
    )
} else {
    report = runMatrix(
        columns: columns,
        rows: rows,
        lineCount: lineCount,
        chunkBytes: chunkBytes,
        whileResident: residentHook
    )
}
let budget = report.scrollbackBudgetBytes

if wantsJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        FileHandle.standardError.write(Data("failed to encode probe report\n".utf8))
        exit(1)
    }
} else {
    func megabytes(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
    func megabytes(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

    print("terminal memory probe -- \(columns)x\(rows), budget \(megabytes(budget)), stride \(report.cellStrideBytes) B, feed chunk \(chunkBytes.map(String.init) ?? "single-shot")")
    print("")
    print("payload                 rows    cells   cell bytes   B/cell   allocs   footprint delta")
    print("---------------------------------------------------------------------------------------")
    for payload in report.payloads {
        let census = payload.census
        let totalRows = census.screenRowCount + census.scrollbackRowCount
        let name = payload.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let rowText = String(totalRows).leftPadded(to: 7)
        let cellText = String(census.cellCount).leftPadded(to: 9)
        let byteText = megabytes(census.cellStorageBytes).leftPadded(to: 12)
        let perCell = String(format: "%.1f", census.bytesPerCell).leftPadded(to: 8)
        let allocText = String(census.rowStorageAllocationCount).leftPadded(to: 8)
        let footprint = megabytes(payload.footprintDeltaBytes).leftPadded(to: 17)
        print("\(name)\(rowText)\(cellText)\(byteText)\(perCell)\(allocText)\(footprint)")
    }

    print("")
    print("content shape (sizes doc 15's H2/H3/H4)")
    print("payload               styled   distinct styles   multi-scalar   hyperlink   identities")
    print("---------------------------------------------------------------------------------------")
    for payload in report.payloads {
        let census = payload.census
        let name = payload.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print(
            name
                + String(census.styledCellCount).leftPadded(to: 8)
                + String(census.distinctStyleCount).leftPadded(to: 18)
                + String(census.multiScalarCellCount).leftPadded(to: 15)
                + String(census.hyperlinkCellCount).leftPadded(to: 12)
                + String(census.distinctContentIdentityCount).leftPadded(to: 13)
        )
    }

    // What it costs to *hold* this terminal, split into the only two parts that are separately
    // measurable: the exact cell bytes the census walked, and the live heap on top of them, which
    // Phase 1 established is malloc bucket rounding on the per-row allocations. Coverage is cell
    // bytes over the process delta; it reads ~0.85 with chunked feeding and ~0.35 without, which is
    // the difference between measuring a resident terminal and measuring one huge parse.
    //
    // No "non-heap" column on purpose: `bytesAllocated` is reserved address space, not dirty pages,
    // so differencing it against the footprint yields a plausible number that came out negative on
    // three of six payloads. Use --vmmap for dirty allocator pages.
    print("")
    print("cost of holding this terminal")
    print("payload               cell bytes   bucket rounding   per row   live heap   footprint   coverage")
    print("-----------------------------------------------------------------------------------------------")
    for payload in report.payloads {
        let rows = max(payload.census.rowStorageAllocationCount, 1)
        let name = payload.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print(
            name
                + megabytes(payload.census.cellStorageBytes).leftPadded(to: 13)
                + megabytes(payload.perAllocationOverheadBytes).leftPadded(to: 18)
                + String(payload.perAllocationOverheadBytes / Int64(rows)).leftPadded(to: 10)
                + megabytes(payload.liveHeapDeltaBytes).leftPadded(to: 12)
                + megabytes(payload.footprintDeltaBytes).leftPadded(to: 12)
                + String(format: "%.2f", payload.footprintCoverageOfCellStorage).leftPadded(to: 11)
        )
    }

    if vmmapLines.isEmpty == false {
        print("")
        print("vmmap --summary, sampled while the terminal was resident (DIRTY is what the footprint charges)")
        vmmapLines.forEach { print($0) }
    }

    if selectedPayload == nil {
        print("")
        print("note: only the first footprint delta is attributable -- payloads share one process")
        print("      and the allocator reuses freed pages. Use --payload NAME for a clean delta.")
    }

    let overdrawn = report.payloads.filter(\.census.hasRetainedStorageOverdraft)
    if overdrawn.isEmpty == false {
        print("")
        print("WARNING: retained history charges past its arena capacity in: "
            + overdrawn.map(\.name).joined(separator: ", "))
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
