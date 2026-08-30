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

/// Decodes the sequence at `index` when the bytes at hand are one complete, well-formed UTF-8
/// sequence, advancing `index` past it; returns nil and leaves `index` alone when they are not.
///
/// This is the run probe's admission test, and it answers it in one step instead of walking
/// `UTF8Decoder`'s state machine byte by byte (`research/39/D9`). It accepts exactly the
/// sequences of Unicode Table 3-7, which is the same set that machine accepts, so a run admits
/// the same scalars either way. Nil means only that this decoder cannot answer: the chunk ends
/// mid-sequence, or the bytes are malformed and owe the caller a replacement scalar and a
/// re-offered byte. Both are `UTF8Decoder`'s to answer, and the probe ends the run so the
/// generic path reads those bytes through it.
func decodeWellFormedUTF8Scalar(
    in bytes: UnsafeBufferPointer<UInt8>,
    from index: inout Int
) -> Unicode.Scalar? {
    let lead = bytes[index]
    if lead < 0x80 {
        index += 1
        return Unicode.Scalar(lead)
    }

    // The lead byte fixes both the length and the range the *second* byte may take; the ranges
    // narrower than 0x80...0xBF are what reject an overlong form, a surrogate encoding and a
    // value above U+10FFFF without decoding the value first.
    let length: Int
    let secondByteRange: ClosedRange<UInt8>
    switch lead {
    case 0xC2...0xDF: (length, secondByteRange) = (2, 0x80...0xBF)
    case 0xE0: (length, secondByteRange) = (3, 0xA0...0xBF)
    case 0xE1...0xEC, 0xEE...0xEF: (length, secondByteRange) = (3, 0x80...0xBF)
    case 0xED: (length, secondByteRange) = (3, 0x80...0x9F)
    case 0xF0: (length, secondByteRange) = (4, 0x90...0xBF)
    case 0xF1...0xF3: (length, secondByteRange) = (4, 0x80...0xBF)
    case 0xF4: (length, secondByteRange) = (4, 0x80...0x8F)
    default: return nil
    }

    guard index + length <= bytes.count else { return nil }
    guard secondByteRange.contains(bytes[index + 1]) else { return nil }
    for offset in 2..<length where bytes[index + offset] & 0xC0 != 0x80 {
        return nil
    }

    var value = UInt32(lead & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07))
    for offset in 1..<length {
        value = (value << 6) | UInt32(bytes[index + offset] & 0x3F)
    }
    index += length
    // Table 3-7 admits no sequence that is not a scalar; the coalesce is what makes that premise
    // a replacement rather than a trap if the ranges above are ever changed wrongly.
    return Unicode.Scalar(value) ?? "\u{FFFD}"
}

/// Decodes one complete, well-formed UTF-8 sequence at `index`, advancing `index` past it.
///
/// Only a caller that already proved its bytes are complete and well-formed may use this -- which
/// is what a scalar run is, because `decodeWellFormedUTF8Scalar` admitted every sequence in it.
/// Under that premise the lead byte gives the length outright, so the scalar costs one branch and
/// its continuation bytes instead of the admission test's range checks (`research/39/D9`).
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
