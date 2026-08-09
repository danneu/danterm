// Research doc 33, task T17: retain complete CSI values and count their live heap blocks.
import Darwin

private let sequenceCount = 10_000
private let csiInput: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x68]
private let escapeInput: [UInt8] = [0x1B, 0x23, 0x38]

private func liveBlocks() -> UInt32 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.blocks_in_use
}

var absorber = EscapeAbsorber()
var retainedCSI: [CSISequence] = []
retainedCSI.reserveCapacity(sequenceCount)

let csiBefore = liveBlocks()
for _ in 0..<sequenceCount {
    absorber.startEscape()
    for byte in csiInput.dropFirst() {
        guard case let .csi(sequence)? = absorber.consume(byte) else { continue }
        retainedCSI.append(sequence)
    }
}
let csiAfter = liveBlocks()
let csiAllocations = Int(csiAfter) - Int(csiBefore)

var retainedEscape: [EscapeSequence] = []
retainedEscape.reserveCapacity(sequenceCount)

let escapeBefore = liveBlocks()
for _ in 0..<sequenceCount {
    absorber.startEscape()
    for byte in escapeInput.dropFirst() {
        guard case let .escapeSequence(sequence)? = absorber.consume(byte) else { continue }
        retainedEscape.append(sequence)
    }
}
let escapeAfter = liveBlocks()
let escapeAllocations = Int(escapeAfter) - Int(escapeBefore)

print("csiSequences=\(retainedCSI.count)")
print("csiLiveHeapBlocks=\(csiAllocations)")
print("allocationsPerCSI=\(Double(csiAllocations) / Double(retainedCSI.count))")
print("escapeSequences=\(retainedEscape.count)")
print("escapeLiveHeapBlocks=\(escapeAllocations)")
print("allocationsPerEscape=\(Double(escapeAllocations) / Double(retainedEscape.count))")
