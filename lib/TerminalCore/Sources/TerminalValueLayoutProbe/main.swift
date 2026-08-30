// Prints the in-memory size and stride of a `Terminal` value, from the built module.
//
// It exists for one reader: `scripts/terminal-self-copy-gate.py`, which fails when a
// copy of that many bytes reappears in a feed-path function of the release object
// (research/39/D5). The gate has to learn the length from the product it disassembles
// rather than carry the 1513 bytes of the day it was written, and a `MemoryLayout`
// answer is only correct when it comes from the same build. Nothing else belongs here:
// this target is a number, not a probe with a measurement in it.
import TerminalCore

// Both lengths, because a whole-value copy lowers to either: the size for a copy of the
// value itself, the stride when it is copied through an array or a stack slot the
// compiler padded.
print("size \(MemoryLayout<Terminal>.size) stride \(MemoryLayout<Terminal>.stride)")
