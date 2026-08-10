// Codable representation of arbitrary JSON used by DanTerm JSON-RPC messages.
import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var asString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var asBool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var asNumber: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var asObject: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var asArray: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null:
            try single.encodeNil()
        case .bool(let value):
            try single.encode(value)
        case .number(let value):
            try single.encode(value)
        case .string(let value):
            try single.encode(value)
        case .array(let value):
            try single.encode(value)
        case .object(let value):
            try single.encode(value)
        }
    }
}
