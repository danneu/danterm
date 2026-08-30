// Incremental UTF-8 decoding with maximal-subpart replacement and resumable value state.

/// Preserves partial UTF-8 across feeds so byte chunking cannot change scalar output.
struct UTF8Decoder: Equatable, Sendable {
    private static let acceptState: UInt8 = 0
    private static let rejectState: UInt8 = 12

    private static let characterClasses: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3,
        11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    ]

    private static let transitions: [UInt8] = [
        0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12,
        12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12,
        12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
        12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
        12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    ]

    private var accumulator: UInt32 = 0
    private var state = acceptState
    private var pending0: UInt8 = 0
    private var pending1: UInt8 = 0
    private var pending2: UInt8 = 0
    private var pendingCount: UInt8 = 0

    /// True when no partial sequence is buffered, so the next ASCII byte decodes to itself.
    ///
    /// This is what lets the parser hand a whole run of printable ASCII to the grid without
    /// stepping each byte through `next(_:)` (`research/33/T8`): from the accept state an ASCII
    /// byte takes character class 0, which leaves the accumulator equal to the byte and the state
    /// equal to accept, so the skipped calls would have produced exactly those scalars and left
    /// exactly this state.
    var isIdle: Bool { state == Self.acceptState }

    /// Returns the incomplete scalar prefix that must precede later continuation bytes.
    var synchronizationPrefix: [UInt8] {
        switch pendingCount {
        case 0: []
        case 1: [pending0]
        case 2: [pending0, pending1]
        default: [pending0, pending1, pending2]
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accumulator == rhs.accumulator
            && lhs.state == rhs.state
            && lhs.synchronizationPrefix == rhs.synchronizationPrefix
    }

    /// Consumes one byte, or asks the caller to retry it after replacing a malformed prefix.
    mutating func next(_ byte: UInt8) -> (scalar: Unicode.Scalar?, consumed: Bool) {
        let characterClass = Self.characterClasses[Int(byte)]
        let initialState = state

        if state == Self.acceptState {
            accumulator = (0xFF >> characterClass) & UInt32(byte)
        } else {
            accumulator = (accumulator << 6) | UInt32(byte & 0x3F)
        }

        state = Self.transitions[Int(state + characterClass)]

        if state == Self.acceptState {
            let scalar = Unicode.Scalar(accumulator) ?? "\u{FFFD}"
            accumulator = 0
            pendingCount = 0
            return (scalar, true)
        }

        if state == Self.rejectState {
            accumulator = 0
            state = Self.acceptState
            pendingCount = 0
            return ("\u{FFFD}", initialState == Self.acceptState)
        }

        if initialState == Self.acceptState {
            pending0 = byte
            pendingCount = 1
        } else if pendingCount == 1 {
            pending1 = byte
            pendingCount = 2
        } else {
            pending2 = byte
            pendingCount = 3
        }

        return (nil, true)
    }
}

/// Decodes one complete, well-formed UTF-8 sequence at `index`, advancing `index` past it.
///
/// Only a caller that already proved its bytes are complete and well-formed may use this -- which
/// is what a scalar run is, because the stream's probe admitted every sequence in it through
/// `UTF8Decoder` first. Under that premise the lead byte gives the length outright, so the scalar
/// costs one branch and its continuation bytes instead of a state-machine step per byte
/// (`research/39/D9`). Malformed input, a truncated tail, and resumption across chunks stay with
/// `UTF8Decoder`, which is the only decoder that can answer them.
func decodeCompleteUTF8Scalar(
    in bytes: UnsafeBufferPointer<UInt8>,
    from index: inout Int
) -> Unicode.Scalar {
    let lead = bytes[index]
    let length: Int
    var value: UInt32
    switch lead {
    case 0x00...0x7F:
        index += 1
        return Unicode.Scalar(lead)
    case 0xC0...0xDF:
        length = 2
        value = UInt32(lead & 0x1F)
    case 0xE0...0xEF:
        length = 3
        value = UInt32(lead & 0x0F)
    default:
        length = 4
        value = UInt32(lead & 0x07)
    }
    for offset in 1..<length {
        value = (value << 6) | UInt32(bytes[index + offset] & 0x3F)
    }
    index += length
    // A well-formed sequence always names a scalar; the coalesce is what makes that premise a
    // replacement rather than a trap if a caller ever breaks it.
    return Unicode.Scalar(value) ?? "\u{FFFD}"
}
