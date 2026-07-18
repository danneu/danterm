// Bounded VT500 recognition that surfaces complete CSI values and discards other families.

/// Carries one parser event from raw escape recognition into the stream reducer.
enum EscapeEvent: Equatable, Sendable {
    case execute(UInt8)
    case escape(UInt8)
    case csi(CSISequence)
}

/// Preserves the syntactic CSI payload needed by terminal dispatch without interpreting it.
struct CSISequence: Equatable, Sendable {
    let parameters: [UInt16]
    let colonSeparators: [Bool]
    let intermediates: [UInt8]
    let final: UInt8
}

/// Recognizes VT sequence families while retaining only bounded CSI and DCS collection state.
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

    private static let parameterCapacity = 24
    private static let intermediateCapacity = 4

    private var state = State.ground
    private var parameters: [UInt16] = []
    private var colonSeparators: [Bool] = []
    private var intermediates: [UInt8] = []
    private var parameterAccumulator: UInt16 = 0
    private var hasParameterDigits = false

    /// Distinguishes raw sequence bytes from ground-state bytes that require UTF-8 decoding.
    var isGround: Bool { state == .ground }

    /// Starts 7-bit escape recognition after the stream decoder emits ESC.
    mutating func startEscape() {
        clearCollection()
        state = .escape
    }

    /// Consumes one raw sequence byte and surfaces at most one control or CSI dispatch.
    mutating func consume(_ byte: UInt8) -> EscapeEvent? {
        switch byte {
        case 0x18, 0x1A:
            clearCollection()
            state = .ground
            return .execute(byte)
        case 0x80...0x8F, 0x91...0x97, 0x99, 0x9A:
            clearCollection()
            state = .ground
            return .execute(byte)
        case 0x9C:
            clearCollection()
            state = .ground
            return nil
        case 0x1B:
            clearCollection()
            state = .escape
            return nil
        case 0x98, 0x9E, 0x9F:
            clearCollection()
            state = .sosPmApcString
            return nil
        case 0x9B:
            clearCollection()
            state = .csiEntry
            return nil
        case 0x90:
            clearCollection()
            state = .dcsEntry
            return nil
        case 0x9D:
            clearCollection()
            state = .oscString
            return nil
        default:
            break
        }

        switch state {
        case .ground:
            return nil

        case .escape:
            if isExecutableC0(byte) { return .execute(byte) }
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
                state = .escapeIntermediate
            case 0x50:
                clearCollection()
                state = .dcsEntry
            case 0x58, 0x5E, 0x5F:
                clearCollection()
                state = .sosPmApcString
            case 0x5B:
                clearCollection()
                state = .csiEntry
            case 0x5D:
                clearCollection()
                state = .oscString
            case 0x30...0x4F, 0x51...0x57, 0x59...0x5A, 0x5C, 0x60...0x7E:
                clearCollection()
                state = .ground
                return .escape(byte)
            default:
                break
            }
            return nil

        case .escapeIntermediate:
            if isExecutableC0(byte) { return .execute(byte) }
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
            case 0x30...0x7E:
                clearCollection()
                state = .ground
            default:
                break
            }
            return nil

        case .csiEntry:
            if isExecutableC0(byte) { return .execute(byte) }
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
                state = .csiIntermediate
            case 0x3A:
                clearCollection()
                state = .csiIgnore
            case 0x30...0x39, 0x3B:
                collectParameter(byte)
                state = .csiParameter
            case 0x3C...0x3F:
                collectIntermediate(byte)
                state = .csiParameter
            case 0x40...0x7E:
                state = .ground
                return dispatchCSI(final: byte)
            default:
                break
            }
            return nil

        case .csiParameter:
            if isExecutableC0(byte) { return .execute(byte) }
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
                state = .csiIntermediate
            case 0x30...0x3A:
                collectParameter(byte)
            case 0x3B:
                collectParameter(byte)
            case 0x3C...0x3F:
                clearCollection()
                state = .csiIgnore
            case 0x40...0x7E:
                state = .ground
                return dispatchCSI(final: byte)
            default:
                break
            }
            return nil

        case .csiIntermediate:
            if isExecutableC0(byte) { return .execute(byte) }
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
            case 0x30...0x3F:
                clearCollection()
                state = .csiIgnore
            case 0x40...0x7E:
                state = .ground
                return dispatchCSI(final: byte)
            default:
                break
            }
            return nil

        case .csiIgnore:
            if isExecutableC0(byte) { return .execute(byte) }
            if (0x40...0x7E).contains(byte) {
                clearCollection()
                state = .ground
            }
            return nil

        case .dcsEntry:
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
                state = .dcsIntermediate
            case 0x30...0x39, 0x3B:
                collectParameter(byte)
                state = .dcsParameter
            case 0x3C...0x3F:
                collectIntermediate(byte)
                state = .dcsParameter
            case 0x3A:
                clearCollection()
                state = .dcsIgnore
            case 0x40...0x7E:
                clearCollection()
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsParameter:
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
                state = .dcsIntermediate
            case 0x30...0x39, 0x3B:
                collectParameter(byte)
            case 0x3A, 0x3C...0x3F:
                clearCollection()
                state = .dcsIgnore
            case 0x40...0x7E:
                clearCollection()
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsIntermediate:
            switch byte {
            case 0x20...0x2F:
                collectIntermediate(byte)
            case 0x30...0x3F:
                clearCollection()
                state = .dcsIgnore
            case 0x40...0x7E:
                clearCollection()
                state = .dcsPassthrough
            default:
                break
            }
            return nil

        case .dcsPassthrough, .dcsIgnore, .sosPmApcString:
            return nil

        case .oscString:
            if byte == 0x07 {
                clearCollection()
                state = .ground
            }
            return nil
        }
    }

    private mutating func clearCollection() {
        parameters.removeAll(keepingCapacity: true)
        colonSeparators.removeAll(keepingCapacity: true)
        intermediates.removeAll(keepingCapacity: true)
        parameterAccumulator = 0
        hasParameterDigits = false
    }

    private mutating func collectIntermediate(_ byte: UInt8) {
        guard intermediates.count < Self.intermediateCapacity else { return }
        intermediates.append(byte)
    }

    private mutating func collectParameter(_ byte: UInt8) {
        if byte == 0x3A || byte == 0x3B {
            guard parameters.count < Self.parameterCapacity else { return }
            parameters.append(parameterAccumulator)
            colonSeparators.append(byte == 0x3A)
            parameterAccumulator = 0
            hasParameterDigits = false
            return
        }

        let multiplied = parameterAccumulator.multipliedReportingOverflow(by: 10)
        parameterAccumulator = multiplied.overflow ? .max : multiplied.partialValue
        let added = parameterAccumulator.addingReportingOverflow(UInt16(byte - 0x30))
        parameterAccumulator = added.overflow ? .max : added.partialValue
        hasParameterDigits = true
    }

    private mutating func dispatchCSI(final: UInt8) -> EscapeEvent? {
        defer { clearCollection() }
        guard parameters.count < Self.parameterCapacity else { return nil }
        if hasParameterDigits || parameters.isEmpty == false {
            guard parameters.count < Self.parameterCapacity else { return nil }
            parameters.append(parameterAccumulator)
            colonSeparators.append(false)
        }
        guard final == 0x6D || colonSeparators.allSatisfy({ $0 == false }) else { return nil }
        return .csi(CSISequence(
            parameters: parameters,
            colonSeparators: colonSeparators,
            intermediates: intermediates,
            final: final
        ))
    }

    private func isExecutableC0(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (0x1C...0x1F).contains(byte)
    }
}
