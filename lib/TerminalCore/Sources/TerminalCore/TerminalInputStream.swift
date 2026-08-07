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
    /// Semantically this *is* one `.print` per byte in the range -- the tests state the token
    /// stream that way and `expandedFeed` expands it -- so no caller may treat the run as a unit
    /// the character path could not produce.
    case printASCIIRun(Range<Int>)
    case print(Unicode.Scalar)
    case execute(UInt8)
    case escape(UInt8)
    case escapeSequence(EscapeSequence)
    case csi(CSISequence)
    case osc([UInt8])
}

/// Owns all pending ingestion state so feeds remain deterministic and value-semantic.
struct TerminalInputStream: Equatable, Sendable {
    private var decoder = UTF8Decoder()
    private var absorber = EscapeAbsorber()

    /// Printable ASCII: the bytes that decode to themselves and print as one narrow cell.
    ///
    /// 0x7F is deliberately outside it -- DEL is an `.execute` -- and so is 0x1B, which starts an
    /// escape.
    static func isPrintableASCII(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// Reduces a byte chunk synchronously without flushing unfinished UTF-8 or VT sequences.
    mutating func feed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        var actions: [TerminalStreamAction] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            // Ground state with an idle decoder is the only condition under which a printable
            // ASCII byte is exactly one printable ASCII scalar, and it stays true for as long as
            // the run does, because neither the absorber nor the decoder is consulted inside it.
            if absorber.isGround, decoder.isIdle, Self.isPrintableASCII(byte) {
                let start = index
                repeat { index += 1 } while index < bytes.count && Self.isPrintableASCII(bytes[index])
                actions.append(.printASCIIRun(start..<index))
                continue
            }
            index += 1

            if absorber.isGround {
                decode(byte, into: &actions)
            } else if let event = absorber.consume(byte) {
                switch event {
                case let .execute(control):
                    actions.append(.execute(control))
                case let .escape(final):
                    actions.append(.escape(final))
                case let .escapeSequence(sequence):
                    actions.append(.escapeSequence(sequence))
                case let .csi(sequence):
                    actions.append(.csi(sequence))
                case let .osc(payload):
                    actions.append(.osc(payload))
                }
            }
        }

        return actions
    }

    private mutating func decode(_ byte: UInt8, into actions: inout [TerminalStreamAction]) {
        var consumed = false
        while consumed == false {
            let result = decoder.next(byte)
            consumed = result.consumed
            guard let scalar = result.scalar else { continue }

            switch scalar.value {
            case 0x1B:
                absorber.startEscape()
            case 0x00...0x1F, 0x7F:
                actions.append(.execute(UInt8(scalar.value)))
            default:
                actions.append(.print(scalar))
            }
        }
    }
}
