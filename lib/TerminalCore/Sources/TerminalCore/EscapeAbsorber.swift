// Discard-only VT500 recognition that preserves sequence state between byte chunks.

/// Recognizes complete VT sequence families without collecting or interpreting their payloads.
struct EscapeAbsorber: Equatable, Sendable {
    /// Mirrors the VT500 parser states whose transitions affect where printable input resumes.
    private enum State: Equatable, Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiIntermediate
        case csiParameter
        case csiIgnore
        case dcsEntry
        case dcsParameter
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case oscString
        case sosPmApcString
    }

    private var state = State.ground

    /// Distinguishes raw sequence bytes from ground-state bytes that require UTF-8 decoding.
    var isGround: Bool { state == .ground }

    /// Starts 7-bit escape recognition after the stream decoder emits ESC.
    mutating func startEscape() {
        state = .escape
    }

    /// Absorbs one raw sequence byte and returns a control that executes during recognition.
    mutating func consume(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x18, 0x1A:
            state = .ground
            return byte
        case 0x80...0x8F, 0x91...0x97, 0x99, 0x9A:
            state = .ground
            return byte
        case 0x9C:
            state = .ground
            return nil
        case 0x1B:
            state = .escape
            return nil
        case 0x98, 0x9E, 0x9F:
            state = .sosPmApcString
            return nil
        case 0x9B:
            state = .csiEntry
            return nil
        case 0x90:
            state = .dcsEntry
            return nil
        case 0x9D:
            state = .oscString
            return nil
        default:
            break
        }

        switch state {
        case .ground:
            return nil

        case .escape:
            if isExecutableC0(byte) { return byte }
            switch byte {
            case 0x20...0x2F:
                state = .escapeIntermediate
            case 0x50:
                state = .dcsEntry
            case 0x58, 0x5E, 0x5F:
                state = .sosPmApcString
            case 0x5B:
                state = .csiEntry
            case 0x5D:
                state = .oscString
            case 0x30...0x4F, 0x51...0x57, 0x59...0x5A, 0x5C, 0x60...0x7E:
                state = .ground
            default:
                break
            }
            return nil

        case .escapeIntermediate:
            if isExecutableC0(byte) { return byte }
            switch byte {
            case 0x20...0x2F:
                break
            case 0x30...0x7E:
                state = .ground
            default:
                break
            }
            return nil

        case .csiEntry:
            if isExecutableC0(byte) { return byte }
            switch byte {
            case 0x20...0x2F:
                state = .csiIntermediate
            case 0x3A:
                state = .csiIgnore
            case 0x30...0x39, 0x3B...0x3F:
                state = .csiParameter
            case 0x40...0x7E:
                state = .ground
            default:
                break
            }
            return nil

        case .csiParameter:
            if isExecutableC0(byte) { return byte }
            switch byte {
            case 0x20...0x2F:
                state = .csiIntermediate
            case 0x3C...0x3F:
                state = .csiIgnore
            case 0x40...0x7E:
                state = .ground
            default:
                break
            }
            return nil

        case .csiIntermediate:
            if isExecutableC0(byte) { return byte }
            switch byte {
            case 0x30...0x3F:
                state = .csiIgnore
            case 0x40...0x7E:
                state = .ground
            default:
                break
            }
            return nil

        case .csiIgnore:
            if isExecutableC0(byte) { return byte }
            if (0x40...0x7E).contains(byte) {
                state = .ground
            }
            return nil

        case .dcsEntry:
            switch byte {
            case 0x20...0x2F:
                state = .dcsIntermediate
            case 0x30...0x39, 0x3B, 0x3C...0x3F:
                state = .dcsParameter
            case 0x3A:
                state = .dcsIgnore
            case 0x40...0x7E:
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsParameter:
            switch byte {
            case 0x20...0x2F:
                state = .dcsIntermediate
            case 0x3A, 0x3C...0x3F:
                state = .dcsIgnore
            case 0x40...0x7E:
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsIntermediate:
            switch byte {
            case 0x30...0x3F:
                state = .dcsIgnore
            case 0x40...0x7E:
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsPassthrough, .dcsIgnore, .sosPmApcString:
            return nil

        case .oscString:
            if byte == 0x07 {
                state = .ground
            }
            return nil
        }
    }

    private func isExecutableC0(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (0x1C...0x1F).contains(byte)
    }
}
