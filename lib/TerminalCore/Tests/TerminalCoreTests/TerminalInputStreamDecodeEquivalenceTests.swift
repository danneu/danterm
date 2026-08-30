// Proves the stream decodes exactly what the resumable decoder alone would, over a systematic
// sweep of UTF-8 byte sequences rather than named examples.
//
// The stream admits a scalar run with a one-step decode of a complete well-formed sequence and
// falls back to `UTF8Decoder` only where the bytes at hand are not one (`research/39/D9`). Two
// decoders that must accept the same set is the risk that buys this file: a sequence one accepts
// and the other replaces is a different scalar on the screen, and no named case can rule that out
// across the whole encoding.
//
// The comparison is over the scalars the stream reports, not over its internals, so it stays true
// of any decoder arrangement that produces the same stream.
//
// The sweep runs millions of cases inside `just test`, which is an oversubscribed pool that other
// suites' hang guards share, so it reuses its buffers and formats nothing unless a case fails.
// Cost here is not a style preference: a sweep that burns a core for half a minute makes every
// wall-clock guard in the gate lose a race it used to win.
import Foundation
import Testing

@testable import TerminalCore

/// Sweeps UTF-8 byte space and pins the stream's scalars to the resumable decoder's.
struct TerminalInputStreamDecodeEquivalenceTests {
    @Test("every one- and two-byte sequence decodes as the resumable decoder does, in any chunking")
    func shortSequencesMatchTheResumableDecoder() {
        // Intent: over all 256 one-byte and all 65,536 two-byte inputs, the stream reports the
        //   same scalars, and the same unfinished prefix, as the resumable decoder alone.
        // Why it exists: the run probe now decides well-formedness itself, so an accepted set
        //   that differs from the decoder's by one sequence changes what reaches the grid.
        // Scenario: every byte pair a PTY read can begin with, fed whole and split down the
        //   middle.
        var sweep = Sweep()
        for first in UInt8.min...UInt8.max {
            sweep.expectMatch([first], splitAtEveryOffset: true, comparingPendingPrefix: true)
            for second in UInt8.min...UInt8.max {
                sweep.expectMatch(
                    [first, second],
                    splitAtEveryOffset: true,
                    comparingPendingPrefix: true
                )
            }
        }
    }

    @Test("three-byte sequences match the resumable decoder over every lead and byte-position pair")
    func threeByteSequencesMatchTheResumableDecoder() {
        // Intent: for every lead byte that enters the run probe, and every value of either
        //   trailing position taken against the boundary values of the other, the stream reports
        //   the same scalars as the resumable decoder alone.
        // Why it exists: three bytes is where the one-step decoder's second-byte ranges do their
        //   work -- overlong forms, surrogate encodings and the low half of the plane boundaries
        //   all live here -- and the accepted set has to come out identical to the state
        //   machine's, position by position.
        // Scenario: every three-byte sequence a run probe can be handed whose two trailing bytes
        //   are not both away from a range edge, fed as one chunk.
        //
        // Both decoders admit a byte position against a range fixed by the lead alone, so a
        // difference between them lives in one position and this sweep sees every one: each
        // trailing position is swept over all 256 values while the other sits on each edge of the
        // ranges either decoder can draw. The exhaustive 8,388,608-case cross was measured at 23
        // seconds of a core, which is not free in a gate whose other suites share the pool with
        // it and hold wall-clock guards.
        //
        // An ASCII lead never reaches the probe. The chunk-split and pending-prefix axes are left
        // to the shorter sweep, which covers both exhaustively: the probe never advances the
        // resumable decoder, so a three-byte input can only leave a prefix its own unfinished
        // tail explains, and that tail is one or two bytes.
        var sweep = Sweep()
        for lead in 0x80...0xFF {
            for swept in UInt8.min...UInt8.max {
                for edge in Self.rangeEdgeBytes {
                    sweep.expectMatch(
                        [UInt8(lead), swept, edge],
                        splitAtEveryOffset: false,
                        comparingPendingPrefix: false
                    )
                    sweep.expectMatch(
                        [UInt8(lead), edge, swept],
                        splitAtEveryOffset: false,
                        comparingPendingPrefix: false
                    )
                }
            }
        }
    }

    /// The values on and just outside each edge either decoder can put a byte position against:
    /// the continuation range, the two narrowed second-byte ranges, the ASCII split, and the ends.
    private static let rangeEdgeBytes: [UInt8] = [
        0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF,
    ]

    @Test("four-byte sequences over each byte position's boundary values match the resumable decoder")
    func fourByteBoundarySequencesMatchTheResumableDecoder() {
        // Intent: over the boundary values of each of the four byte positions, the stream reports
        //   the same scalars, and the same unfinished prefix, as the resumable decoder alone.
        // Why it exists: the four-byte forms carry the plane boundaries -- the U+10000 floor
        //   under F0 and the U+10FFFF ceiling under F4 -- which is where an accepted-set
        //   difference would admit a value that is not a scalar at all.
        // Scenario: every combination of the values that sit on, just inside, and just outside
        //   each position's admitted range, fed whole and split at every offset.
        var sweep = Sweep()
        let leads: [UInt8] = [0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF]
        let continuations: [UInt8] = [0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0xBF, 0xC0, 0xFF]
        for lead in leads {
            for second in continuations {
                for third in continuations {
                    for fourth in continuations {
                        sweep.expectMatch(
                            [lead, second, third, fourth],
                            splitAtEveryOffset: true,
                            comparingPendingPrefix: true
                        )
                    }
                }
            }
        }
    }

    /// Holds the sweep's reusable buffers so a case costs decoding and not allocation.
    private struct Sweep {
        private var subject: [UInt32] = []
        private var reference: [UInt32] = []

        init() {
            subject.reserveCapacity(8)
            reference.reserveCapacity(8)
        }

        /// Feeds `bytes` through the stream and asserts its scalars match the resumable decoder's.
        ///
        /// `splitAtEveryOffset` also feeds the same bytes as two chunks at each interior offset,
        /// which is the chunk-invariance half of the same claim: a sequence cut by a PTY read
        /// must decode to what the whole sequence does.
        mutating func expectMatch(
            _ bytes: [UInt8],
            splitAtEveryOffset: Bool,
            comparingPendingPrefix: Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            // An ESC hands the rest of the bytes to escape recognition, which is not decoding and
            // has its own suites. A candidate holding one is skipped rather than truncated:
            // everything before the ESC is a shorter candidate this file already sweeps, and the
            // decoder produces U+001B from the byte 0x1B alone -- an overlong encoding of it is
            // rejected as malformed -- so nothing goes uncovered.
            guard !bytes.contains(0x1B) else { return }

            reference.removeAll(keepingCapacity: true)
            var referenceDecoder = UTF8Decoder()
            for byte in bytes {
                var result = referenceDecoder.next(byte)
                while true {
                    if let scalar = result.scalar,
                       !TerminalInputStream.isIgnoredDecodedScalar(scalar) {
                        reference.append(scalar.value)
                    }
                    if result.consumed { break }
                    result = referenceDecoder.next(byte)
                }
            }
            let referencePrefix = comparingPendingPrefix
                ? referenceDecoder.synchronizationPrefix
                : []

            expectChunking(
                bytes,
                splitAt: nil,
                referencePrefix,
                comparingPendingPrefix,
                sourceLocation
            )
            guard splitAtEveryOffset else { return }
            for split in 1..<bytes.count {
                expectChunking(
                    bytes,
                    splitAt: split,
                    referencePrefix,
                    comparingPendingPrefix,
                    sourceLocation
                )
            }
        }

        private mutating func expectChunking(
            _ bytes: [UInt8],
            splitAt split: Int?,
            _ referencePrefix: [UInt8],
            _ comparingPendingPrefix: Bool,
            _ sourceLocation: SourceLocation
        ) {
            var stream = TerminalInputStream()
            subject.removeAll(keepingCapacity: true)
            bytes.withUnsafeBufferPointer { whole in
                withUnsafeTemporaryAllocation(
                    of: Unicode.Scalar.self,
                    capacity: TerminalInputStream.scalarRunCap
                ) { scratch in
                    for chunk in chunks(of: whole, splitAt: split) {
                        var index = 0
                        while let action = stream.nextAction(in: chunk, from: &index, into: scratch) {
                            append(action, from: chunk, scratch, sourceLocation)
                        }
                    }
                }
            }

            let prefixMatches = !comparingPendingPrefix
                || stream.synchronizationPrefix == referencePrefix
            if subject == reference, prefixMatches { return }

            // Only a mismatch formats the bytes: the sweep runs millions of cases, and building a
            // description for each one would cost more than the decoding it checks.
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let chunking = split.map { "split at \($0)" } ?? "one chunk"
            #expect(
                subject == reference,
                "\(hex) \(chunking) decoded to \(subject), decoder alone gives \(reference)",
                sourceLocation: sourceLocation
            )
            if comparingPendingPrefix {
                #expect(
                    stream.synchronizationPrefix == referencePrefix,
                    "\(hex) \(chunking) left \(stream.synchronizationPrefix) pending, decoder alone leaves \(referencePrefix)",
                    sourceLocation: sourceLocation
                )
            }
        }

        private func chunks(
            of whole: UnsafeBufferPointer<UInt8>,
            splitAt split: Int?
        ) -> [UnsafeBufferPointer<UInt8>] {
            guard let split else { return [whole] }
            return [
                UnsafeBufferPointer(rebasing: whole[..<split]),
                UnsafeBufferPointer(rebasing: whole[split...]),
            ]
        }

        /// Appends the scalars an action reports.
        ///
        /// A scalar run reports the scalars it left in the scratch, which is what the grid would
        /// be given, so the sweep compares the two decoders on the values that reach a cell rather
        /// than on a re-decode of the run's bytes.
        ///
        /// With no ESC in the candidate the stream never leaves ground state, so these four
        /// actions are the only ones it can produce and any other is itself the failure.
        private mutating func append(
            _ action: TerminalStreamAction,
            from buffer: UnsafeBufferPointer<UInt8>,
            _ scratch: UnsafeMutableBufferPointer<Unicode.Scalar>,
            _ sourceLocation: SourceLocation
        ) {
            switch action {
            case let .printASCIIRun(range):
                for offset in range { subject.append(UInt32(buffer[offset])) }
            case let .printScalarRun(_, _, scalarCount):
                for offset in 0..<scalarCount { subject.append(scratch[offset].value) }
            case let .print(printed):
                subject.append(printed.scalar.value)
            case let .execute(control):
                subject.append(UInt32(control))
            default:
                Issue.record(
                    "ground-state decoding produced \(action)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}
