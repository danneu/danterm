// Bounded VT500 recognition that surfaces complete CSI values and discards other families.

/// Carries one parser event from raw escape recognition into the stream reducer.
enum EscapeEvent: Equatable, Sendable {
    case execute(UInt8)
    case escape(UInt8)
    case escapeSequence(EscapeSequence)
    case csi(CSISequence)
    case osc([UInt8])
    case dcs(DCSSequence)
}

/// Names the DCS headers the terminal dispatches, so the parser collects a body only for those.
///
/// The route is decided from the header alone -- before any body byte arrives -- which is what
/// keeps an unrouted DCS as cheap as it was when every DCS was discarded.
enum DCSRoute: Equatable, Sendable {
    /// DCS `$ q`: a request for one setting's current value.
    case decrqss

    init?(intermediates: SequenceIntermediates, final: UInt8) {
        guard intermediates.count == 1, final == 0x71 else { return nil }
        switch intermediates[0] {
        case 0x24: self = .decrqss
        default: return nil
        }
    }

    /// The header bytes that re-select this route, for stream-synchronization prefixes.
    var headerBytes: [UInt8] {
        switch self {
        case .decrqss: [0x24, 0x71]
        }
    }
}

/// Preserves a completed routed DCS sequence for terminal dispatch without interpreting its body.
///
/// The body is verbatim: every byte the sender put between the header and the terminator, high
/// bytes and C0 included. A routed protocol decides validity from the whole body, so a byte
/// outside its alphabet has to reach the handler rather than be elided into a match.
struct DCSSequence: Equatable, Sendable {
    let route: DCSRoute
    let parameters: CSIParameters
    let body: [UInt8]

    init(route: DCSRoute, parameters: CSIParameters, body: [UInt8]) {
        self.route = route
        self.parameters = parameters
        self.body = body
    }
}

/// Preserves an ESC intermediate and final when terminal dispatch depends on both.
struct EscapeSequence: Equatable, Sendable {
    let intermediates: SequenceIntermediates
    let final: UInt8

    init(intermediates: SequenceIntermediates, final: UInt8) {
        self.intermediates = intermediates
        self.final = final
    }

    init(intermediates: [UInt8], final: UInt8) {
        self.init(intermediates: SequenceIntermediates(intermediates), final: final)
    }
}

/// Preserves the syntactic CSI payload needed by terminal dispatch without interpreting it.
struct CSISequence: Equatable, Sendable {
    let parameters: CSIParameters
    let colonSeparators: CSIColonSeparators
    let intermediates: SequenceIntermediates
    let final: UInt8

    init(
        parameters: CSIParameters,
        colonSeparators: CSIColonSeparators,
        intermediates: SequenceIntermediates,
        final: UInt8
    ) {
        self.parameters = parameters
        self.colonSeparators = colonSeparators
        self.intermediates = intermediates
        self.final = final
    }

    init(
        parameters: [UInt16],
        colonSeparators: [Bool],
        intermediates: [UInt8],
        final: UInt8
    ) {
        self.init(
            parameters: CSIParameters(parameters),
            colonSeparators: CSIColonSeparators(colonSeparators),
            intermediates: SequenceIntermediates(intermediates),
            final: final
        )
    }
}

/// Stores the parser's bounded parameter payload inside each CSI value.
struct CSIParameters: Equatable, RandomAccessCollection, Sendable {
    typealias Element = UInt16
    typealias Index = Int

    static let capacity = 24

    private var storage = InlineArray<24, UInt16>(repeating: 0)
    private var storageCount: UInt8 = 0

    init() {}

    init(_ values: [UInt16]) {
        precondition(values.count <= Self.capacity)
        for value in values {
            append(value)
        }
    }

    var startIndex: Int { 0 }
    var endIndex: Int { Int(storageCount) }

    subscript(index: Int) -> UInt16 {
        precondition(indices.contains(index))
        return storage[index]
    }

    mutating func append(_ value: UInt16) {
        precondition(endIndex < Self.capacity)
        storage[endIndex] = value
        storageCount += 1
    }

    mutating func removeAll() {
        storageCount = 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elementsEqual(rhs)
    }
}

/// Stores whether each bounded CSI parameter ended with a colon in one bit mask.
struct CSIColonSeparators: Equatable, RandomAccessCollection, Sendable {
    typealias Element = Bool
    typealias Index = Int

    private var bits: UInt32 = 0
    private var storageCount: UInt8 = 0

    init() {}

    init(_ values: [Bool]) {
        precondition(values.count <= CSIParameters.capacity)
        for value in values {
            append(value)
        }
    }

    var startIndex: Int { 0 }
    var endIndex: Int { Int(storageCount) }

    subscript(index: Int) -> Bool {
        precondition(indices.contains(index))
        return bits & (1 << UInt32(index)) != 0
    }

    mutating func append(_ value: Bool) {
        precondition(endIndex < CSIParameters.capacity)
        if value {
            bits |= 1 << UInt32(endIndex)
        }
        storageCount += 1
    }

    mutating func removeAll() {
        bits = 0
        storageCount = 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storageCount == rhs.storageCount && lhs.bits == rhs.bits
    }
}

/// Packs the parser's at-most-four intermediate bytes into one dispatch key.
struct SequenceIntermediates: Equatable, RandomAccessCollection, Sendable {
    typealias Element = UInt8
    typealias Index = Int

    private(set) var key: UInt32 = 0
    private var storageCount: UInt8 = 0

    init() {}

    init(_ values: [UInt8]) {
        precondition(values.count <= 4)
        for value in values {
            append(value)
        }
    }

    var startIndex: Int { 0 }
    var endIndex: Int { Int(storageCount) }

    subscript(index: Int) -> UInt8 {
        precondition(indices.contains(index))
        return UInt8(truncatingIfNeeded: key >> UInt32(index * 8))
    }

    mutating func append(_ value: UInt8) {
        precondition(endIndex < 4)
        key |= UInt32(value) << UInt32(endIndex * 8)
        storageCount += 1
    }

    mutating func removeAll() {
        key = 0
        storageCount = 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storageCount == rhs.storageCount && lhs.key == rhs.key
    }
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
        case dcsEscape
        case dcsIgnore
        case oscString
        case oscEscape
        case sosPmApcString
    }

    // One buffer serves OSC and routed DCS because their states are mutually exclusive: a
    // control string is collecting for exactly one family at a time. `pending-control-string`
    // in docs/terminal-capabilities.md is the bound both of them spend.
    private static let controlStringPayloadCapacity = 2 * 1_024 * 1_024

    private var state = State.ground
    private var parameters = CSIParameters()
    private var colonSeparators = CSIColonSeparators()
    private var intermediates = SequenceIntermediates()
    private var parameterAccumulator: UInt16 = 0
    private var hasParameterDigits = false
    private var controlStringPayload: [UInt8] = []
    private var controlStringPayloadOverflowed = false
    private var dcsRoute: DCSRoute?

    /// Distinguishes raw sequence bytes from ground-state bytes that require UTF-8 decoding.
    var isGround: Bool { state == .ground }

    /// Returns a normalized unfinished sequence prefix with the same next-byte behavior.
    var synchronizationPrefix: [UInt8] {
        var bytes: [UInt8]
        switch state {
        case .ground:
            return []
        case .escape:
            return [0x1B]
        case .escapeIntermediate:
            return [0x1B] + Array(intermediates)
        case .csiEntry:
            return [0x1B, 0x5B]
        case .csiIntermediate:
            bytes = [0x1B, 0x5B]
            appendPrivateIntermediates(to: &bytes)
            appendParameters(to: &bytes)
            appendFinalIntermediates(to: &bytes)
            return bytes
        case .csiParameter:
            bytes = [0x1B, 0x5B]
            bytes.append(contentsOf: Array(intermediates))
            appendParameters(to: &bytes)
            return bytes
        case .csiIgnore:
            return [0x1B, 0x5B, 0x3A]
        case .dcsEntry:
            return [0x1B, 0x50]
        case .dcsParameter:
            bytes = [0x1B, 0x50]
            bytes.append(contentsOf: Array(intermediates))
            appendParameters(to: &bytes)
            return bytes
        case .dcsIntermediate:
            bytes = [0x1B, 0x50]
            appendPrivateIntermediates(to: &bytes)
            appendParameters(to: &bytes)
            appendFinalIntermediates(to: &bytes)
            return bytes
        case .dcsPassthrough, .dcsEscape:
            // An unrouted body is never collected, so the normalized `q` header stands in for
            // whichever header opened it: both resume in a passthrough that discards.
            bytes = [0x1B, 0x50] + (dcsRoute?.headerBytes ?? [0x71]) + controlStringPayload
                + (controlStringPayloadOverflowed ? [0x20] : [])
            if state == .dcsEscape { bytes.append(0x1B) }
            return bytes
        case .dcsIgnore:
            return [0x1B, 0x50, 0x3A]
        case .oscString:
            return [0x1B, 0x5D] + controlStringPayload
                + (controlStringPayloadOverflowed ? [0x20] : [])
        case .oscEscape:
            return [0x1B, 0x5D] + controlStringPayload
                + (controlStringPayloadOverflowed ? [0x20] : []) + [0x1B]
        case .sosPmApcString:
            return [0x1B, 0x58]
        }
    }

    private func appendParameters(to bytes: inout [UInt8]) {
        for index in parameters.indices {
            bytes.append(contentsOf: String(parameters[index]).utf8)
            bytes.append(colonSeparators[index] ? 0x3A : 0x3B)
        }
        if hasParameterDigits {
            bytes.append(contentsOf: String(parameterAccumulator).utf8)
        }
    }

    private func appendPrivateIntermediates(to bytes: inout [UInt8]) {
        bytes.append(contentsOf: intermediates.filter { (0x3C...0x3F).contains($0) })
    }

    private func appendFinalIntermediates(to bytes: inout [UInt8]) {
        bytes.append(contentsOf: intermediates.filter { (0x20...0x2F).contains($0) })
    }

    /// Starts 7-bit escape recognition after the stream decoder emits ESC.
    mutating func startEscape() {
        clearCollection()
        state = .escape
    }

    /// Consumes one raw sequence byte and surfaces at most one control or CSI dispatch.
    mutating func consume(_ byte: UInt8) -> EscapeEvent? {
        if state == .oscString {
            if byte == 0x18 || byte == 0x1A {
                clearCollection()
                state = .ground
                return .execute(byte)
            }
            if byte == 0x07 { return dispatchOSC() }
            if byte == 0x1B {
                state = .oscEscape
                return nil
            }
            if byte >= 0x20, byte != 0x7F {
                collectControlString(byte)
            }
            return nil
        }
        if state == .oscEscape {
            if byte == 0x5C { return dispatchOSC() }
            clearCollection()
            state = .escape
            return consume(byte)
        }
        // A routed DCS collects its body verbatim, so it returns here rather than falling into
        // the C1 dispatch below: inside a control string those bytes are payload, not controls.
        if state == .dcsPassthrough, dcsRoute != nil {
            if byte == 0x18 || byte == 0x1A {
                clearCollection()
                state = .ground
                return .execute(byte)
            }
            if byte == 0x1B {
                state = .dcsEscape
                return nil
            }
            collectControlString(byte)
            return nil
        }
        if state == .dcsEscape {
            if byte == 0x5C { return dispatchDCS() }
            clearCollection()
            state = .escape
            return consume(byte)
        }
        if isNonOSCControlString, byte >= 0x80 {
            return nil
        }
        switch byte {
        case 0x18, 0x1A:
            clearCollection()
            state = .ground
            return .execute(byte)
        case 0x80...0x8F, 0x91...0x97, 0x99, 0x9A:
            clearCollection()
            state = .ground
            return .execute(byte)
        // Both OSC states returned above, so this switch never sees one: 0x9C inside an OSC
        // payload is UTF-8 continuation data (U+201C is E2 80 9C), not a terminator, and
        // only BEL or `ESC \` closes an OSC.
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
                let sequence = EscapeSequence(intermediates: intermediates, final: byte)
                clearCollection()
                state = .ground
                return .escapeSequence(sequence)
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
                beginDCSPassthrough(final: byte)
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
                beginDCSPassthrough(final: byte)
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
                beginDCSPassthrough(final: byte)
            default:
                break
            }
            return nil

        case .dcsPassthrough, .dcsIgnore, .sosPmApcString:
            return nil

        case .dcsEscape:
            preconditionFailure("Routed DCS states return before general control dispatch")

        case .oscString, .oscEscape:
            preconditionFailure("OSC states return before general control dispatch")
        }
    }

    private mutating func clearCollection() {
        parameters.removeAll()
        colonSeparators.removeAll()
        intermediates.removeAll()
        parameterAccumulator = 0
        hasParameterDigits = false
        controlStringPayload.removeAll(keepingCapacity: true)
        controlStringPayloadOverflowed = false
        dcsRoute = nil
    }

    /// Enters the DCS body with the route the header selected, so only a routed header collects.
    private mutating func beginDCSPassthrough(final: UInt8) {
        // The header's last parameter is still accumulating when its final byte arrives, exactly
        // as in `dispatchCSI`, so it is flushed here rather than left out of the dispatched value.
        if parameters.count < CSIParameters.capacity,
           hasParameterDigits || parameters.isEmpty == false {
            parameters.append(parameterAccumulator)
            colonSeparators.append(false)
        }
        let route = DCSRoute(intermediates: intermediates, final: final)
        let header = parameters
        clearCollection()
        if let route {
            dcsRoute = route
            parameters = header
        }
        state = .dcsPassthrough
    }

    private var isNonOSCControlString: Bool {
        switch state {
        case .dcsEntry, .dcsParameter, .dcsIntermediate, .dcsPassthrough, .dcsEscape,
             .dcsIgnore, .sosPmApcString:
            true
        default:
            false
        }
    }

    private mutating func collectIntermediate(_ byte: UInt8) {
        guard intermediates.count < 4 else { return }
        intermediates.append(byte)
    }

    private mutating func collectParameter(_ byte: UInt8) {
        if byte == 0x3A || byte == 0x3B {
            guard parameters.count < CSIParameters.capacity else { return }
            parameters.append(parameterAccumulator)
            // Whatever follows the last slot is overflow the dispatch discards, so that slot
            // never separates this parameter from a retained one and never carries a colon.
            colonSeparators.append(byte == 0x3A && parameters.count < CSIParameters.capacity)
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
        // Parameters past the cap are ignored, never a reason to drop the sequence: the
        // dispatch carries the first `capacity` of them, exactly as if the sender had stopped
        // there. Anything still accumulating at the final byte belongs to the overflow.
        if parameters.count < CSIParameters.capacity,
           hasParameterDigits || parameters.isEmpty == false {
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

    private mutating func collectControlString(_ byte: UInt8) {
        guard controlStringPayloadOverflowed == false else { return }
        guard controlStringPayload.count < Self.controlStringPayloadCapacity else {
            controlStringPayloadOverflowed = true
            return
        }
        controlStringPayload.append(byte)
    }

    private mutating func dispatchOSC() -> EscapeEvent? {
        let event = controlStringPayloadOverflowed
            ? nil
            : EscapeEvent.osc(controlStringPayload)
        clearCollection()
        state = .ground
        return event
    }

    /// Hands a completed routed DCS to the terminal, or drops an over-long one whole.
    ///
    /// An over-truncated body would be answered as if it were the query the sender wrote, so a
    /// body past the bound produces no event at all.
    private mutating func dispatchDCS() -> EscapeEvent? {
        var event: EscapeEvent?
        if let dcsRoute, controlStringPayloadOverflowed == false {
            event = .dcs(DCSSequence(
                route: dcsRoute,
                parameters: parameters,
                body: controlStringPayload
            ))
        }
        clearCollection()
        state = .ground
        return event
    }

    private func isExecutableC0(_ byte: UInt8) -> Bool {
        byte <= 0x17 || byte == 0x19 || (0x1C...0x1F).contains(byte)
    }
}
