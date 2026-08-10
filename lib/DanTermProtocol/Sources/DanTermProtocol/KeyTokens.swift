// Argv-token classifier for `danterm pane input -- <token>...`.
// Each token is classified as either a literal text run or a structured key
// event. The rule is deterministic -- no fall-through that contradicts itself
// -- and accepts Shift only for named keys whose terminal encoding can use it.
import Foundation

public enum KeyTokenError: Error, Equatable {
    case unknownKey(String)
}

public func parseKeyTokens(_ tokens: [String], literal: Bool = false) throws -> [InputEvent] {
    var events: [InputEvent] = []
    events.reserveCapacity(tokens.count)
    for token in tokens {
        events.append(try classifyKeyToken(token, literal: literal))
    }
    return events
}

private func classifyKeyToken(_ token: String, literal: Bool) throws -> InputEvent {
    // Step 1: literal mode — everything is text, no exceptions.
    if literal {
        return .text(token)
    }

    // Step 2: modifier-prefixed token (e.g. C-c, M-x, C-M-Up).
    if let prefixSplit = stripModifierPrefix(token) {
        // Modifier-prefixed Space is out of scope for v1.
        if prefixSplit.base == "Space" {
            throw KeyTokenError.unknownKey(token)
        }
        // Resolve the base: known keyname or single ASCII letter (either case,
        // normalized to lowercase before going on the wire).
        if let key = KeyName(wireName: prefixSplit.base) {
            if case .letter = key, prefixSplit.mods.contains(.shift) {
                throw KeyTokenError.unknownKey(token)
            }
            return .key(key, prefixSplit.mods.toKeyMods())
        }
        if prefixSplit.mods.contains(.shift) {
            throw KeyTokenError.unknownKey(token)
        }
        if prefixSplit.base.count == 1,
           let c = prefixSplit.base.first,
           c.isASCII, c.isLetter {
            let lowered = String(c).lowercased()
            if let key = KeyName(wireName: lowered) {
                return .key(key, prefixSplit.mods.toKeyMods())
            }
        }
        throw KeyTokenError.unknownKey(token)
    }

    // Step 3: function-key shape (F\d+ exactly).
    if isFunctionKeyShaped(token) {
        if let key = KeyName(wireName: token) {
            return .key(key, [])
        }
        throw KeyTokenError.unknownKey(token)
    }

    // Step 4: bare Space → literal single space, routed through the text path.
    // This sidesteps the question of how surface_key encodes a bare Space
    // keycode with no UTF-8 text and reliably emits 0x20.
    if token == "Space" {
        return .text(" ")
    }

    // Step 5: known special keyname.
    if KeyName.namedAliases[token] != nil, let key = KeyName(wireName: token) {
        return .key(key, [])
    }

    // Step 6: anything else is literal text.
    return .text(token)
}

// Modifier-prefix scanner. Walks `<L>-` segments where L is C, M, or S,
// returning the accumulated mods plus the remaining base string. Returns nil
// when the token has no modifier prefix at all (so step 2 doesn't trigger).
private struct PrefixSplit {
    var mods: ModSet
    var base: String
}

// Internal mod-set distinguishes CLI prefixes before lowering them to stable wire bits.
private struct ModSet: OptionSet {
    let rawValue: Int
    static let ctrl  = ModSet(rawValue: 1 << 0)
    static let alt   = ModSet(rawValue: 1 << 1)
    static let shift = ModSet(rawValue: 1 << 2)

    func toKeyMods() -> KeyMods {
        var out: KeyMods = []
        if contains(.ctrl) { out.insert(.ctrl) }
        if contains(.alt)  { out.insert(.alt) }
        if contains(.shift) { out.insert(.shift) }
        return out
    }
}

private func stripModifierPrefix(_ token: String) -> PrefixSplit? {
    var rest = Substring(token)
    var mods: ModSet = []
    var consumedAny = false
    while let prefix = nextModPrefix(rest) {
        switch prefix.letter {
        case "C": mods.insert(.ctrl)
        case "M": mods.insert(.alt)
        case "S": mods.insert(.shift)
        default: break
        }
        rest = prefix.rest
        consumedAny = true
    }
    guard consumedAny, !rest.isEmpty else { return nil }
    return PrefixSplit(mods: mods, base: String(rest))
}

private func nextModPrefix(_ s: Substring) -> (letter: Character, rest: Substring)? {
    guard s.count >= 2 else { return nil }
    let i0 = s.startIndex
    let i1 = s.index(after: i0)
    let letter = s[i0]
    guard letter == "C" || letter == "M" || letter == "S" else { return nil }
    guard s[i1] == "-" else { return nil }
    return (letter, s[s.index(after: i1)...])
}

private func isFunctionKeyShaped(_ token: String) -> Bool {
    guard token.count >= 2, token.first == "F" else { return false }
    let tail = token.dropFirst()
    return tail.allSatisfy { $0.isASCII && $0.isNumber }
}
