// The single activation gate for terminal-originated links: the one predicate that decides
// whether a URI a program handed us -- through OSC 8 or plain-text detection -- may be
// hovered, armed, and opened.
//
// It lives in its own file, and is public rather than private to `Terminal`, because it is the
// whole security boundary for link opening and both sides of that boundary have to agree on
// it. The app layer previously re-derived the same rule against Foundation and reached a
// stricter answer, so the terminal drew links that Cmd-click then silently refused to open.
// There is exactly one copy of this rule; the host converts an approved URI to a `URL` and
// opens it, and decides nothing.
//
// What deliberately lives elsewhere: which run of cells a link covers and how hover and arm
// state move (`Terminal`), and trailing-punctuation trimming for detected URLs, which is a
// question about surrounding text rather than about the URI itself.

/// Answers whether a program-supplied URI may be activated, which means all of: it is
/// `http`/`https`, its authority parses as RFC 3986 with a real host and an in-range port, and
/// no scalar anywhere in it is invisible, bidi-affecting, or whitespace.
///
/// The last clause covers the whole string rather than just the authority. A zero-width or
/// direction-overriding scalar in the path or query renders as nothing (or reorders its
/// neighbours) in the hover preview, so the URI the user reads is not the one they would
/// visit. Visible non-ASCII text is fine and stays activatable: a Japanese Wikipedia path is
/// an ordinary URL, not a disguise.
public func isActivatableWebURI(_ uri: String) -> Bool {
    let scalars = Array(uri.unicodeScalars)
    guard scalars.allSatisfy(isDisplaySafeURIScalar),
          let colon = scalars.firstIndex(where: { $0.value == 0x3A })
    else { return false }
    let scheme = String(String.UnicodeScalarView(scalars[..<colon])).lowercased()
    guard scheme == "http" || scheme == "https",
          colon + 2 < scalars.count,
          scalars[colon + 1].value == 0x2F,
          scalars[colon + 2].value == 0x2F
    else { return false }
    let authorityStart = colon + 3
    let authorityEnd = scalars[authorityStart...].firstIndex(where: {
        $0.value == 0x2F || $0.value == 0x3F || $0.value == 0x23
    }) ?? scalars.endIndex
    guard authorityStart < authorityEnd else { return false }
    let authority = Array(scalars[authorityStart..<authorityEnd])
    let at = authority.lastIndex(where: { $0.value == 0x40 })
    if let at, isValidURIComponent(authority[..<at], allowsColon: true) == false {
        return false
    }
    let hostPortStart = at.map { $0 + 1 } ?? 0
    guard hostPortStart < authority.count else { return false }
    let hostPort = Array(authority[hostPortStart...])
    let port: ArraySlice<Unicode.Scalar>?
    let host: ArraySlice<Unicode.Scalar>
    let isBracketedHost: Bool
    if hostPort.first?.value == 0x5B {
        guard let close = hostPort.firstIndex(where: { $0.value == 0x5D }), close > 1 else {
            return false
        }
        host = hostPort[1..<close]
        isBracketedHost = true
        if close + 1 < hostPort.count {
            guard hostPort[close + 1].value == 0x3A else { return false }
            port = hostPort[(close + 2)...]
        } else {
            port = nil
        }
    } else if let separator = hostPort.lastIndex(where: { $0.value == 0x3A }) {
        guard hostPort[..<separator].allSatisfy({ $0.value != 0x3A }) else { return false }
        host = hostPort[..<separator]
        port = hostPort[(separator + 1)...]
        isBracketedHost = false
    } else {
        host = hostPort[...]
        port = nil
        isBracketedHost = false
    }
    guard host.isEmpty == false,
          isBracketedHost ? isValidIPLiteral(host) : isValidRegName(host)
    else { return false }
    if let port {
        guard port.isEmpty == false,
              port.allSatisfy({ (0x30...0x39).contains($0.value) }),
              let value = Int(String(String.UnicodeScalarView(port))),
              (1...65_535).contains(value)
        else { return false }
    }
    return true
}

/// Rejects every scalar that can occupy a URI without being seen there: C0/C1 controls, format
/// characters (zero-width spaces, bidi overrides and isolates, the BOM, soft hyphens, tag
/// characters), and every flavour of whitespace and line separator.
///
/// ASCII decides itself without a property lookup, which keeps the common case a pair of
/// comparisons. That fast path is a strict subset of the category test below it: `0x20` is a
/// space separator and `0x7F` is a control.
private func isDisplaySafeURIScalar(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar.value >= 0x80 else {
        return scalar.value > 0x20 && scalar.value != 0x7F
    }
    switch scalar.properties.generalCategory {
    case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator:
        return false
    default:
        return true
    }
}

private func isValidRegName(_ host: ArraySlice<Unicode.Scalar>) -> Bool {
    isValidURIComponent(host, allowsColon: false)
}

private func isValidURIComponent(
    _ scalars: ArraySlice<Unicode.Scalar>,
    allowsColon: Bool
) -> Bool {
    let values = scalars.map(\.value)
    var index = 0
    while index < values.count {
        let value = values[index]
        if value == 0x25 {
            guard index + 2 < values.count,
                  isHexDigit(values[index + 1]),
                  isHexDigit(values[index + 2])
            else { return false }
            index += 3
            continue
        }
        guard isUnreservedOrSubDelimiter(value) || (allowsColon && value == 0x3A) else {
            return false
        }
        index += 1
    }
    return true
}

private func isValidIPLiteral(_ host: ArraySlice<Unicode.Scalar>) -> Bool {
    let value = String(String.UnicodeScalarView(host))
    if value.first == "v" || value.first == "V" {
        guard let dot = value.firstIndex(of: "."), dot > value.startIndex else { return false }
        let version = value[value.index(after: value.startIndex)..<dot]
        let address = value[value.index(after: dot)...]
        return version.isEmpty == false
            && version.unicodeScalars.allSatisfy { isHexDigit($0.value) }
            && address.isEmpty == false
            && address.unicodeScalars.allSatisfy {
                isUnreservedOrSubDelimiter($0.value) || $0.value == 0x3A
            }
    }
    return isValidIPv6(value)
}

private func isValidIPv6(_ address: String) -> Bool {
    guard address.isEmpty == false else { return false }
    let characters = Array(address)
    var compressionCount = 0
    if characters.count >= 2 {
        for index in 0..<(characters.count - 1)
        where characters[index] == ":" && characters[index + 1] == ":"
        {
            compressionCount += 1
        }
    }
    guard compressionCount <= 1 else { return false }
    let isCompressed = compressionCount == 1
    if isCompressed == false,
       (characters.first == ":" || characters.last == ":")
    {
        return false
    }
    let pieces = address.split(separator: ":", omittingEmptySubsequences: true)
    var groupCount = 0
    for (index, piece) in pieces.enumerated() {
        if piece.contains(".") {
            guard index == pieces.count - 1, isValidIPv4(String(piece)) else { return false }
            groupCount += 2
        } else {
            guard (1...4).contains(piece.count),
                  piece.unicodeScalars.allSatisfy({ isHexDigit($0.value) })
            else { return false }
            groupCount += 1
        }
    }
    if isCompressed {
        return groupCount < 8
    }
    return groupCount == 8
}

private func isValidIPv4(_ address: String) -> Bool {
    let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
    return pieces.count == 4 && pieces.allSatisfy { piece in
        piece.isEmpty == false
            && piece.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
            && Int(piece).map { (0...255).contains($0) } == true
    }
}

private func isHexDigit(_ value: UInt32) -> Bool {
    (0x30...0x39).contains(value)
        || (0x41...0x46).contains(value)
        || (0x61...0x66).contains(value)
}

private func isUnreservedOrSubDelimiter(_ value: UInt32) -> Bool {
    return (0x30...0x39).contains(value)
        || (0x41...0x5A).contains(value)
        || (0x61...0x7A).contains(value)
        || value == 0x2D || value == 0x2E || value == 0x5F || value == 0x7E
        || [0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D]
            .contains(value)
}
