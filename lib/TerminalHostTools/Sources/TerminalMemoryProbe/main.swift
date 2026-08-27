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
import TerminalProbeArguments

// The flag surface and its resolution are `MemoryProbeCommandLine` and
// `resolveMemoryProbeInputs`, in the support module, so the gate tests them. This file only
// turns a refusal into an exit status and a report into text.
let inputs: MemoryProbeInputs
switch MemoryProbeCommandLine.command.parse(CommandLine.arguments.dropFirst())
    .flatMap(resolveMemoryProbeInputs)
{
case .success(let resolved):
    inputs = resolved
case .failure(let error):
    FileHandle.standardError.write(Data(error.report.utf8))
    exit(2)
}

let columns = inputs.columns
let rows = inputs.rows
let lineCount = inputs.lineCount
let chunkBytes = inputs.chunkBytes
let selectedPayload = inputs.payloadName
let wantsJSON = inputs.wantsJSON

// `--vmmap` is the only way to see *dirty* allocator pages, which is the quantity `phys_footprint`
// actually charges for. `MallocHeapSnapshot.bytesAllocated` cannot answer it: it counts reserved
// region address space, ~20 MB of which exists before a single byte is fed and most of it clean.
//
// Sampled through `whileResident` so vmmap observes the process while the terminal is alive; run
// after `measure` returns it would describe a freed grid. Captured rather than printed inline so
// the tables stay contiguous, and dumped verbatim rather than parsed -- vmmap's format is not a
// contract, and a wrong parse produces a confident number, which is the failure mode doc 15 keeps
// hitting.
let wantsVmmap = inputs.wantsVmmap
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

let residentHook: (() -> Void)? = wantsVmmap ? { captureVmmapSummary() } : nil

let report: MemoryProbeReport
if let selectedPayload {
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
    print("content shape (sizes research/15/H2, research/15/H3, research/15/H4)")
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

    // What each end of the footprint window was cleared of before it was sampled. Its own table
    // rather than two more columns above, because these numbers qualify the footprint column --
    // they are not another cost, and are never subtracted from it.
    //
    // Expect zeroes on macOS 26: the request is inert there, which `settleAllocator` documents with
    // the measurement. The table stays because a reader comparing two footprint deltas needs to see
    // that the allocator was asked and gave nothing back, rather than assume it was never asked.
    print("")
    print("allocator settled before each footprint sample (best effort; qualifies the delta above)")
    print("payload                released before   released after")
    print("-------------------------------------------------------")
    for payload in report.payloads {
        let name = payload.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print(
            name
                + megabytes(Int64(payload.releasedBeforeFootprintBytes)).leftPadded(to: 18)
                + megabytes(Int64(payload.releasedAfterFootprintBytes)).leftPadded(to: 17)
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
