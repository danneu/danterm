// Pure, versioned JSON configuration boundary with lossless unknown-number retention.
import Foundation

/// Owns one writable v1 config tree so Preferences can mutate known leaves without
/// dropping future fields or changing untouched number tokens.
struct DanTermConfigDocument: Equatable {
    /// Canonical writable v1 seed used whenever DanTerm authors a new config file.
    static let seedData = Data(
        """
        {
          "schemaVersion": 1
        }
        """.utf8
    )

    var config: DanTermConfig { Self.projectConfig(from: root) }

    private var root: ConfigJSONValue
    private let originalData: Data
    private var isDirty: Bool

    private init(root: ConfigJSONValue, originalData: Data) {
        self.root = root
        self.originalData = originalData
        self.isDirty = false
    }

    /// Accepts only syntactically valid objects carrying the exact integer schemaVersion 1.
    static func decode(_ data: Data) -> Self? {
        var parser = ConfigJSONParser(data: data)
        guard let root = parser.parse(),
              case .object(let object) = root,
              object["schemaVersion"] == ConfigJSONValue.number("1")
        else { return nil }
        return Self(root: root, originalData: data)
    }

    /// Sets or clears the explicit local theme while preserving unmodeled theme siblings.
    mutating func setDefaultTheme(_ theme: String?) {
        setNestedValue(theme.map(ConfigJSONValue.string), parent: "theme", key: "default")
    }

    /// Sets the remote theme while preserving unmodeled theme siblings.
    mutating func setRemoteTheme(_ theme: String) {
        setNestedValue(.string(theme), parent: "theme", key: "remote")
    }

    /// Sets or clears the explicit font size without rewriting an equivalent number token.
    mutating func setFontSize(_ size: Double?) {
        if let size {
            guard size.isFinite, size > 0 else { return }
        }
        if let size,
           case .number(let token)? = nestedValue(parent: "font", key: "size"),
           Double(token) == size
        {
            return
        }
        setNestedValue(size.map { .number(Self.numberToken(for: $0)) }, parent: "font", key: "size")
    }

    /// Sets the alert policy while preserving unmodeled UI siblings.
    mutating func setAlertClearMode(_ mode: AlertClearMode) {
        setNestedValue(.string(mode.rawValue), parent: "ui", key: "alertClearMode")
    }

    /// Applies the complete modeled settings set as one document transaction.
    mutating func apply(_ config: DanTermConfig) {
        setDefaultTheme(config.defaultTheme)
        setRemoteTheme(config.remoteTheme)
        setFontSize(config.fontSize)
        setAlertClearMode(config.alertClearMode)
    }

    /// Returns original bytes until a semantic edit occurs, then stable sorted JSON.
    func encoded() -> Data {
        guard isDirty else { return originalData }
        return Data((ConfigJSONEncoder.encode(root) + "\n").utf8)
    }

    private mutating func setNestedValue(_ value: ConfigJSONValue?, parent: String, key: String) {
        guard case .object(var rootObject) = root else { return }
        var parentObject: [String: ConfigJSONValue]
        if case .object(let existing)? = rootObject[parent] {
            parentObject = existing
        } else {
            parentObject = [:]
        }

        if let value {
            guard parentObject[key] != value else { return }
            parentObject[key] = value
        } else {
            guard parentObject.removeValue(forKey: key) != nil else { return }
        }
        rootObject[parent] = .object(parentObject)
        root = .object(rootObject)
        isDirty = true
    }

    private func nestedValue(parent: String, key: String) -> ConfigJSONValue? {
        guard case .object(let rootObject) = root,
              case .object(let parentObject)? = rootObject[parent]
        else { return nil }
        return parentObject[key]
    }

    private static func projectConfig(from root: ConfigJSONValue) -> DanTermConfig {
        guard case .object(let rootObject) = root else { return .default }
        var config = DanTermConfig.default
        if case .object(let theme)? = rootObject["theme"] {
            if case .string(let name)? = theme["default"], name.isEmpty == false {
                config.defaultTheme = name
            }
            if case .string(let name)? = theme["remote"], name.isEmpty == false {
                config.remoteTheme = name
            }
        }
        if case .object(let font)? = rootObject["font"],
           case .number(let token)? = font["size"],
           let size = Double(token), size.isFinite, size > 0
        {
            config.fontSize = size
        }
        if case .object(let ui)? = rootObject["ui"],
           case .string(let rawMode)? = ui["alertClearMode"],
           let mode = AlertClearMode(rawValue: rawMode)
        {
            config.alertClearMode = mode
        }
        return config
    }

    private static func numberToken(for value: Double) -> String {
        let token = String(value)
        return token.hasSuffix(".0") ? String(token.dropLast(2)) : token
    }
}

/// Represents JSON without converting source number tokens through a lossy numeric type.
private indirect enum ConfigJSONValue: Equatable {
    case object([String: ConfigJSONValue])
    case array([ConfigJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

/// Parses strict JSON while retaining each valid number token exactly as authored.
private struct ConfigJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func parse() -> ConfigJSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func parseValue() -> ConfigJSONValue? {
        guard let byte = current else { return nil }
        switch byte {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseString().map(ConfigJSONValue.string)
        case 0x74: return consumeLiteral("true") ? .bool(true) : nil
        case 0x66: return consumeLiteral("false") ? .bool(false) : nil
        case 0x6E: return consumeLiteral("null") ? .null : nil
        case 0x2D, 0x30...0x39: return parseNumber().map(ConfigJSONValue.number)
        default: return nil
        }
    }

    private mutating func parseObject() -> ConfigJSONValue? {
        index += 1
        skipWhitespace()
        var object: [String: ConfigJSONValue] = [:]
        if consume(0x7D) { return .object(object) }
        while true {
            guard let key = parseString(), object[key] == nil else { return nil }
            skipWhitespace()
            guard consume(0x3A) else { return nil }
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            if consume(0x7D) { return .object(object) }
            guard consume(0x2C) else { return nil }
            skipWhitespace()
        }
    }

    private mutating func parseArray() -> ConfigJSONValue? {
        index += 1
        skipWhitespace()
        var array: [ConfigJSONValue] = []
        if consume(0x5D) { return .array(array) }
        while true {
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipWhitespace()
            if consume(0x5D) { return .array(array) }
            guard consume(0x2C) else { return nil }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> String? {
        guard consume(0x22) else { return nil }
        let tokenStart = index - 1
        while let byte = current {
            if byte == 0x22 {
                index += 1
                let token = Data(bytes[tokenStart..<index])
                return try? JSONDecoder().decode(String.self, from: token)
            }
            if byte < 0x20 { return nil }
            if byte == 0x5C {
                index += 1
                guard let escaped = current else { return nil }
                if escaped == 0x75 {
                    index += 1
                    for _ in 0..<4 {
                        guard let hex = current, Self.isHexDigit(hex) else { return nil }
                        index += 1
                    }
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) else {
                    return nil
                }
            }
            index += 1
        }
        return nil
    }

    private mutating func parseNumber() -> String? {
        let start = index
        _ = consume(0x2D)
        if consume(0x30) {
            if let byte = current, Self.isDigit(byte) { return nil }
        } else {
            guard consumeDigit(in: 0x31...0x39) else { return nil }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consume(0x2E) {
            guard consumeDigit(in: 0x30...0x39) else { return nil }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consume(0x65) || consume(0x45) {
            _ = consume(0x2B) || consume(0x2D)
            guard consumeDigit(in: 0x30...0x39) else { return nil }
            while consumeDigit(in: 0x30...0x39) {}
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consumeLiteral(_ literal: StaticString) -> Bool {
        let literalBytes = Array(String(describing: literal).utf8)
        guard bytes[index...].starts(with: literalBytes) else { return false }
        index += literalBytes.count
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard let byte = current, range.contains(byte) else { return false }
        index += 1
        return true
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// Emits one stable, sorted representation while copying stored number tokens verbatim.
private enum ConfigJSONEncoder {
    static func encode(_ value: ConfigJSONValue, indentation: Int = 0) -> String {
        switch value {
        case .object(let object):
            guard object.isEmpty == false else { return "{}" }
            let childIndent = indentation + 2
            let entries = object.keys.sorted().map { key in
                String(repeating: " ", count: childIndent)
                    + encodeString(key) + ": "
                    + encode(object[key]!, indentation: childIndent)
            }
            return "{\n" + entries.joined(separator: ",\n") + "\n"
                + String(repeating: " ", count: indentation) + "}"
        case .array(let array):
            guard array.isEmpty == false else { return "[]" }
            let childIndent = indentation + 2
            let entries = array.map {
                String(repeating: " ", count: childIndent) + encode($0, indentation: childIndent)
            }
            return "[\n" + entries.joined(separator: ",\n") + "\n"
                + String(repeating: " ", count: indentation) + "]"
        case .string(let string): return encodeString(string)
        case .number(let token): return token
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func encodeString(_ string: String) -> String {
        var encoded = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x08: encoded += "\\b"
            case 0x0C: encoded += "\\f"
            case 0x0A: encoded += "\\n"
            case 0x0D: encoded += "\\r"
            case 0x09: encoded += "\\t"
            case 0x00...0x1F:
                let digits = Array("0123456789ABCDEF".utf8)
                encoded += "\\u00"
                encoded.append(Character(UnicodeScalar(digits[Int(scalar.value >> 4)])))
                encoded.append(Character(UnicodeScalar(digits[Int(scalar.value & 0xF)])))
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }
}
