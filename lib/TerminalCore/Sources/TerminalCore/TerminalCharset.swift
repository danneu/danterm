// The 7-bit GL half of ISO 2022: the character sets a program can designate, the four slots
// it designates them into, and the invocation state that decides which slot translates the
// next GL byte.
//
// Only the translation vocabulary lives here. Which sequences move the state, and where in
// the print path a byte gets translated, belong to the reducer in `Terminal.swift`.
//
// There is no GR bank and no 96-character set. Every byte at or above 0x80 is consumed by
// the UTF-8 decoder before charset logic could see it, so a GR designation could never be
// observed -- it would be dead state carried through DECSC, the alternate screen, and reset.

/// One character set a slot can hold, as a mapping over the GL bytes 0x20...0x7E.
///
/// Deliberately three cases and no `utf8`: DanTerm's stream is UTF-8 by construction, so the
/// identity mapping is what `ascii` already means.
enum TerminalCharset: UInt8, Equatable, Sendable {
    case ascii
    case decSpecialGraphics
    case british

    /// Reads the final byte of an SCS designation, or nil when DanTerm has no such set.
    ///
    /// A nil answer is not "ignore the sequence": the caller designates ASCII, so an
    /// unsupported set degrades to deterministic plain text instead of leaving the previous
    /// set in place to translate later output.
    init?(designationFinal final: UInt8) {
        switch final {
        case 0x30: self = .decSpecialGraphics
        case 0x41: self = .british
        case 0x42: self = .ascii
        default: return nil
        }
    }

    /// The SCS final byte that designates this set, the inverse of `init?(designationFinal:)`.
    ///
    /// State synchronization spells a designation with it, so the serialized form reads as the
    /// protocol character a program would have sent.
    var designationFinal: UInt8 {
        switch self {
        case .decSpecialGraphics: 0x30
        case .british: 0x41
        case .ascii: 0x42
        }
    }

    /// Maps one GL byte to the scalar it prints as. Bytes outside 0x20...0x7E pass through.
    ///
    /// Every scalar this can return must be narrow and grapheme-break-class `.other`, because
    /// the bulk run path stamps the result straight into a cell without classifying it.
    /// `TerminalCharsetTests.translatedScalarsAreNarrowAndBreakOther` pins that premise.
    @inline(__always)
    func translate(_ byte: UInt8) -> Unicode.Scalar {
        switch self {
        case .ascii:
            return Unicode.Scalar(byte)
        case .british:
            return byte == 0x23 ? "\u{00A3}" : Unicode.Scalar(byte)
        case .decSpecialGraphics:
            guard byte >= 0x60, byte <= 0x7E else { return Unicode.Scalar(byte) }
            return Self.decSpecialGraphicsTable[Int(byte) - 0x60]
        }
    }

    /// DEC Special Graphics for 0x60...0x7E, from
    /// `references/ghostty/src/terminal/charsets.zig#dec_special`.
    ///
    /// `references/xterm/charsets.h#map_DEC_Spec_Graphic` agrees on every entry here. The two
    /// diverge only on 0x5F, which xterm's wide build maps to U+2426 and this table leaves
    /// identity, following ghostty. Not adopted: kitty's Linux-console divergences (arrows on
    /// `+ , - .`, U+2588 for `0`, U+00A0 for `_`, U+2409 for `h`) and libvterm's slanted
    /// U+2A7D/U+2A7E for `y`/`z`.
    private static let decSpecialGraphicsTable: [Unicode.Scalar] = [
        "\u{25C6}", "\u{2592}", "\u{2409}", "\u{240C}", "\u{240D}", "\u{240A}",
        "\u{00B0}", "\u{00B1}", "\u{2424}", "\u{240B}", "\u{2518}", "\u{2510}",
        "\u{250C}", "\u{2514}", "\u{253C}", "\u{23BA}", "\u{23BB}", "\u{2500}",
        "\u{23BC}", "\u{23BD}", "\u{251C}", "\u{2524}", "\u{2534}", "\u{252C}",
        "\u{2502}", "\u{2264}", "\u{2265}", "\u{03C0}", "\u{2260}", "\u{00A3}",
        "\u{00B7}",
    ]
}

/// One of the four slots a character set can be designated into.
enum TerminalCharsetSlot: UInt8, Equatable, Sendable {
    case g0
    case g1
    case g2
    case g3

    /// Reads the first intermediate of an SCS sequence -- `(`, `)`, `*`, `+` -- as its slot.
    init?(designationIntermediate intermediate: UInt8) {
        switch intermediate {
        case 0x28: self = .g0
        case 0x29: self = .g1
        case 0x2A: self = .g2
        case 0x2B: self = .g3
        default: return nil
        }
    }
}

/// Exactly the charset state the VT420 manual says DECSC saves, and nothing more.
///
/// Kept as one value so the saved-cursor slot copies it wholesale and a reset is one
/// assignment of the default. The default *is* the reset state, which is what lets
/// `resetControlState()` cover RIS and DECSTR with a single line.
struct TerminalCharsetState: Equatable, Sendable {
    var g0 = TerminalCharset.ascii
    var g1 = TerminalCharset.ascii
    var g2 = TerminalCharset.ascii
    var g3 = TerminalCharset.ascii

    /// The slot the locking shifts point at. SI/SO and LS2/LS3 write it; DECRC restores it.
    var invokedSlot = TerminalCharsetSlot.g0

    /// The slot SS2 or SS3 armed, spent by the next printed graphic character.
    var pendingSingleShift: TerminalCharsetSlot?

    subscript(slot: TerminalCharsetSlot) -> TerminalCharset {
        get {
            switch slot {
            case .g0: g0
            case .g1: g1
            case .g2: g2
            case .g3: g3
            }
        }
        set {
            switch slot {
            case .g0: g0 = newValue
            case .g1: g1 = newValue
            case .g2: g2 = newValue
            case .g3: g3 = newValue
            }
        }
    }

    /// The set that translates the next printed GL byte, single shift included.
    var activeCharset: TerminalCharset { self[pendingSingleShift ?? invokedSlot] }
}
