// Byte-oriented stream reduction that joins incremental UTF-8 with discard-only VT recognition.

/// Carries scalar and control actions from stream recognition into the terminal grid reducer.
enum TerminalStreamAction: Equatable, Sendable {
    case print(Unicode.Scalar)
    case execute(UInt8)
}

/// Owns all pending ingestion state so feeds remain deterministic and value-semantic.
struct TerminalInputStream: Equatable, Sendable {
    private var decoder = UTF8Decoder()
    private var absorber = EscapeAbsorber()

    /// Reduces a byte chunk synchronously without flushing unfinished UTF-8 or VT sequences.
    mutating func feed(_ bytes: [UInt8]) -> [TerminalStreamAction] {
        var actions: [TerminalStreamAction] = []

        for byte in bytes {
            if absorber.isGround {
                decode(byte, into: &actions)
            } else if let control = absorber.consume(byte) {
                actions.append(.execute(control))
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
