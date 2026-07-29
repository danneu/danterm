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

let report: MemoryProbeReport
if let selectedPayload {
    let matched = MemoryProbeMatrix
        .payloads(columns: columns, lineCount: lineCount)
        .filter { $0.name == selectedPayload }
    guard matched.isEmpty == false else {
        let known = MemoryProbeMatrix.payloads(columns: columns, lineCount: 1).map(\.name)
        FileHandle.standardError.write(
            Data("unknown payload '\(selectedPayload)'; known: \(known.joined(separator: ", "))\n".utf8)
        )
        exit(2)
    }
    report = runMatrix(columns: columns, rows: rows, lineCount: lineCount, only: selectedPayload)
} else {
    report = runMatrix(columns: columns, rows: rows, lineCount: lineCount)
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

    print("terminal memory probe -- \(columns)x\(rows), budget \(megabytes(budget)), stride \(report.cellStrideBytes) B")
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

    if selectedPayload == nil {
        print("")
        print("note: only the first footprint delta is attributable -- payloads share one process")
        print("      and the allocator reuses freed pages. Use --payload NAME for a clean delta.")
    }

    let leaking = report.payloads.filter(\.census.hasRetainedRowStorageLeak)
    if leaking.isEmpty == false {
        print("")
        print("WARNING: retained row storage exceeds live rows in: \(leaking.map(\.name).joined(separator: ", "))")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
