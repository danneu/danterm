// Pure XTGETTCAP request decoding and reply construction, with no screen state. It sits
// beside `Terminal` rather than inside it because none of it reads the grid: the answers
// come from `TerminalCapabilityProjection`, which is generated from the published
// contract. Anything that has to consult live terminal state does not belong here.

/// Turns an XTGETTCAP request body into the reply DanTerm sends back.
///
/// Kept apart from `Terminal` so the contract projection has exactly one reader, and so the
/// request grammar can be read without the surrounding dispatch.
enum TerminalCapabilityQuery {
    /// The complete reply, framing included, for one `DCS + q` request body.
    ///
    /// xterm's prefix semantics (`references/xterm/misc.c:5180`): the first name alone
    /// decides the valid/invalid digit, then name/value pairs stream in request order and
    /// processing stops at the first name that misses. The name that missed is not echoed.
    /// xterm emits its request bytes before it stops; reflecting an attacker-supplied query
    /// into the stream is CVE-2008-2383, so DanTerm ends after the last valid pair instead.
    static func reply(for body: [UInt8]) -> String {
        var pairs: [String] = []
        for field in body.split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let name = decodeHexadecimal(field),
                  let value = TerminalCapabilityProjection.values[name]
            else { break }
            // The echo is the sender's own request bytes, so a name asked for in lowercase
            // hexadecimal comes back in lowercase. Only the value is spelled by DanTerm.
            let requested = String(decoding: field, as: UTF8.self)
            pairs.append(value.isEmpty ? requested : "\(requested)=\(encodeHexadecimal(value))")
        }
        guard pairs.isEmpty == false else { return "\u{1B}P0+r\u{1B}\\" }
        return "\u{1B}P1+r\(pairs.joined(separator: ";"))\u{1B}\\"
    }

    /// The capability name a request field spells, or nil when the field is not a name.
    ///
    /// An empty field, an odd digit count, and any non-hexadecimal byte all fail rather than
    /// decoding what they can: a partially decoded name would answer a request nobody made.
    private static func decodeHexadecimal(_ field: ArraySlice<UInt8>) -> String? {
        guard field.isEmpty == false, field.count.isMultiple(of: 2) else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(field.count / 2)
        var index = field.startIndex
        while index < field.endIndex {
            let lowIndex = field.index(after: index)
            guard let high = hexadecimalValue(field[index]),
                  let low = hexadecimalValue(field[lowIndex])
            else { return nil }
            decoded.append(high << 4 | low)
            index = field.index(after: lowIndex)
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func encodeHexadecimal(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count * 2)
        for byte in value.utf8 {
            encoded.append(hexadecimalDigit(byte >> 4))
            encoded.append(hexadecimalDigit(byte & 0x0F))
        }
        return encoded
    }

    private static func hexadecimalDigit(_ nibble: UInt8) -> Character {
        Character(Unicode.Scalar(nibble < 10 ? 0x30 + nibble : 0x41 + nibble - 10))
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
