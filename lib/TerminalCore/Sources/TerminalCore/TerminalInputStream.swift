// Byte-oriented stream reduction that joins incremental UTF-8 with bounded VT recognition.

/// Carries scalar and control actions from stream recognition into the terminal grid reducer.
enum TerminalStreamAction: Equatable, Sendable {
    /// A maximal run of printable ASCII, as a range into the chunk being fed.
    ///
    /// The parser recognizes multi-byte units already, and this is one more: input varies at the
    /// granularity of a run of plain text, so the grid should be told about a run rather than
    /// rediscover it a character at a time (`research/33/T8`). A range rather than the bytes
    /// keeps the action POD and copies nothing; it is only meaningful to the caller that supplied
    /// the chunk, which is the same call that receives it.
    ///
    /// Semantically this is one *GL print* per byte in the range -- the parser tests state the
    /// token stream that way and `expandedFeed` expands it -- so no caller may treat the run as
    /// a unit the character path could not produce. A GL print is not the same as `.print`: the
    /// grid reducer translates each byte through the invoked character set, while `.print`
    /// carries an already-decoded scalar that no character set touches.
    case printASCIIRun(Range<Int>)
    /// A maximal byte range of complete, valid UTF-8 scalars that are safe to stamp as independent
    /// cells of one width, which `isWide` names.
    ///
    /// Semantically this is one `.print` per decoded scalar. Unlike `printASCIIRun`, these scalars
    /// never pass through GL character-set translation. The range contains no ASCII bytes and is
    /// meaningful only while the chunk that produced the action remains borrowed by the caller.
    ///
    /// The run carries its width because the width decides which writer stamps it, and the stream
    /// already read the classification that answers it; making the printer re-derive it per scalar
    /// would put back the per-scalar table read the run exists to amortize. It carries
    /// `scalarCount` for the same reason: the probe already knows how many scalars it admitted, so
    /// a printer that re-counted them would traverse the run's bytes an extra time to learn what
    /// the stream had in hand (`research/39/D9`).
    case printScalarRun(Range<Int>, isWide: Bool, scalarCount: Int)
    case print(Unicode.Scalar)
    case execute(UInt8)
    case escape(UInt8)
    case escapeSequence(EscapeSequence)
    case csi(CSISequence)
    case osc([UInt8])
    /// A completed DCS sequence on a route the terminal dispatches; other DCS families never
    /// reach the grid reducer at all.
    case dcs(DCSSequence)
}

/// Owns all pending ingestion state so feeds remain deterministic and value-semantic.
struct TerminalInputStream: Equatable, Sendable {
    private var decoder = UTF8Decoder()
    private var absorber = EscapeAbsorber()

    /// Returns the unfinished byte prefix that recreates this stream reducer's next-byte state.
    var synchronizationPrefix: [UInt8] {
        decoder.synchronizationPrefix + absorber.synchronizationPrefix
    }

    /// Printable ASCII: the bytes that decode to themselves and print as one narrow cell.
    ///
    /// 0x7F is deliberately outside it -- DEL is an `.execute` -- and so is 0x1B, which starts an
    /// escape.
    static func isPrintableASCII(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// Identifies decoded protocol controls that ground state consumes without an action.
    static func isIgnoredDecodedScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x80...0x9F).contains(scalar.value)
    }

    /// Recognizes the next action in `bytes` starting at `index`, advancing `index` over exactly
    /// the bytes that action consumed, and returns nil once the chunk is exhausted. Unfinished
    /// UTF-8 and VT sequences stay in `self` for the next chunk, so feeding is chunk-invariant.
    ///
    /// The caller owns the loop, and that is the whole point: `Terminal.feed` applies each action
    /// to the grid before asking for the next one, so the token stream is never materialized as an
    /// array (`research/33/F9` sized the one this replaced at 60-80x the corpus's own byte count).
    /// A sink-closure form would put grid mutation inside a call that is already mutating
    /// `Terminal.inputStream`, which is overlapping access to `self`; storing the chunk and a
    /// position on the stream itself would put mid-feed state into a value that is `Equatable`
    /// and compared between feeds. Both are avoided by leaving the position on the caller's stack.
    ///
    /// A byte the decoder does not consume -- the byte that proved a truncated sequence malformed
    /// -- leaves `index` where it is and is re-offered on the next call, which is how one byte can
    /// produce a replacement scalar and then its own action.
    mutating func nextAction(
        in bytes: UnsafeBufferPointer<UInt8>,
        from index: inout Int
    ) -> TerminalStreamAction? {
        input: while index < bytes.count {
            let byte = bytes[index]
            // Ground state with an idle decoder is the only condition under which a printable
            // ASCII byte is exactly one printable ASCII scalar, and it stays true for as long as
            // the run does, because neither the absorber nor the decoder is consulted inside it.
            // Returning the whole run is what amortizes this per-token call boundary: `research/33/F15`
            // measured it as the reason streaming cost 1.7-5.4% before the run granularity existed.
            if absorber.isGround, decoder.isIdle, Self.isPrintableASCII(byte) {
                let start = index
                repeat { index += 1 } while index < bytes.count && Self.isPrintableASCII(bytes[index])
                return .printASCIIRun(start..<index)
            }

            if absorber.isGround, decoder.isIdle, byte >= 0x80 {
                let start = index
                var probeIndex = index
                var runEnd = index
                var probe = decoder
                var firstNonBulkScalar: Unicode.Scalar?
                // A run is one width, so the first admitted scalar fixes it and the run is cut
                // where the width changes. The cut costs the boundary scalar nothing: it opens
                // the next run.
                var runIsWide = false
                var runScalarCount = 0

                while probeIndex < bytes.count, bytes[probeIndex] >= 0x80 {
                    let scalarStart = probeIndex
                    var consumedEveryByte = true
                    var scalar: Unicode.Scalar?
                    while probeIndex < bytes.count, scalar == nil {
                        let result = probe.next(bytes[probeIndex])
                        consumedEveryByte = consumedEveryByte && result.consumed
                        if result.consumed { probeIndex += 1 }
                        scalar = result.scalar
                    }
                    guard let scalar else { break }
                    let encodedByteCount = TerminalScalars.utf8ByteCount(of: scalar)
                    guard consumedEveryByte, probeIndex - scalarStart == encodedByteCount else {
                        break
                    }
                    if Self.isIgnoredDecodedScalar(scalar) {
                        guard scalarStart == start else { break }
                        decoder = probe
                        index = probeIndex
                        continue input
                    }
                    let classification = terminalUnicodeClassification(for: scalar)
                    guard classification.isBulkPrintable else {
                        if scalarStart == start { firstNonBulkScalar = scalar }
                        break
                    }
                    let isWide = classification.properties.cellWidth == .wide
                    if runEnd == start {
                        runIsWide = isWide
                    } else if isWide != runIsWide {
                        break
                    }
                    runEnd = probeIndex
                    runScalarCount += 1
                }

                if runEnd > start {
                    index = runEnd
                    return .printScalarRun(start..<runEnd, isWide: runIsWide, scalarCount: runScalarCount)
                }
                if let firstNonBulkScalar {
                    decoder = probe
                    index = probeIndex
                    return .print(firstNonBulkScalar)
                }
            }

            guard absorber.isGround else {
                index += 1
                guard let event = absorber.consume(byte) else { continue }
                switch event {
                case let .execute(control):
                    return .execute(control)
                case let .escape(final):
                    return .escape(final)
                case let .escapeSequence(sequence):
                    return .escapeSequence(sequence)
                case let .csi(sequence):
                    return .csi(sequence)
                case let .osc(payload):
                    return .osc(payload)
                case let .dcs(sequence):
                    return .dcs(sequence)
                }
            }

            let result = decoder.next(byte)
            if result.consumed {
                index += 1
            }
            guard let scalar = result.scalar else { continue }
            if Self.isIgnoredDecodedScalar(scalar) { continue }

            switch scalar.value {
            case 0x1B:
                absorber.startEscape()
            case 0x00...0x1F, 0x7F:
                return .execute(UInt8(scalar.value))
            default:
                return .print(scalar)
            }
        }

        return nil
    }
}
