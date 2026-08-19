// Decodes any `Decodable` straight out of a parsed `JSONValue` tree, with no trip back
// through serialized bytes.
//
// It exists so a value that arrived inside a JSON-RPC envelope -- already parsed once into
// `JSONValue` -- can become its own typed form without being re-encoded to `Data` and
// re-parsed. The alternative every call site used before this was exactly that round trip,
// which re-materializes every nested payload (a base64 blob most of all) once per value.
//
// What does not belong here: an `Encoder` counterpart, and any knowledge of a particular
// payload's schema. This file only bridges containers; the schema stays in each type's own
// `Codable` conformance, which is the point -- there is one spelling of the wire format and
// this reads it.
import Foundation

/// Decodes a `Decodable` from an in-memory `JSONValue` instead of from bytes.
///
/// The equivalence bar is `JSONDecoder` over the same tree's serialization: every
/// conversion below is chosen to accept and refuse what that path accepts and refuses.
/// A number lives in `JSONValue` as a `Double`, so an integer beyond 2^53 has already lost
/// precision before either path runs; that loss is the parse's, not this bridge's.
public struct JSONValueDecoder: Sendable {
    public init() {}

    /// Decodes one value from a parsed tree.
    public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try T(from: JSONValueDecoderState(value: value, codingPath: []))
    }
}

/// One position in the tree, presented as a `Decoder`.
///
/// It is a struct because every container hands out fresh states for its children rather
/// than mutating a shared cursor: the only mutable cursor in the bridge is an unkeyed
/// container's index, which that container owns.
private struct JSONValueDecoderState: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    /// Nothing supplies decoding context here, so this is always empty; the property exists
    /// only because `Decoder` requires it.
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw DecodingError.typeMismatch([String: Any].self, context("Expected an object"))
        }
        return KeyedDecodingContainer(JSONValueKeyedContainer<Key>(
            object: object,
            codingPath: codingPath
        ))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch([Any].self, context("Expected an array"))
        }
        return JSONValueUnkeyedContainer(elements: elements, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        JSONValueSingleValueContainer(value: value, codingPath: codingPath)
    }

    private func context(_ description: String) -> DecodingError.Context {
        DecodingError.Context(codingPath: codingPath, debugDescription: description)
    }
}

/// Reads one JSON scalar as the Swift type a decoder asked for, and reports the mismatch in
/// the same shape `JSONDecoder` does when the tree says something else.
///
/// It is free rather than a container method so the keyed, unkeyed, and single-value
/// containers all convert through one implementation -- three copies of these rules would
/// be three chances to disagree with each other about what a number is.
private func jsonValueUnwrap<T>(
    _ value: JSONValue,
    as type: T.Type,
    codingPath: [any CodingKey]
) throws -> T {
    func mismatch() -> DecodingError {
        DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected \(type) but found \(jsonValueTypeName(value))"
        ))
    }
    switch value {
    case .null:
        throw DecodingError.valueNotFound(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected \(type) but found null"
        ))
    case .bool(let flag):
        guard let flag = flag as? T else { throw mismatch() }
        return flag
    case .string(let text):
        guard let text = text as? T else { throw mismatch() }
        return text
    case .number(let number):
        guard let converted = jsonValueConvertNumber(number, to: type) else {
            // A whole-number conversion that does not fit is a value problem, not a type
            // problem, which is the same distinction `JSONDecoder` draws for `12.5` as an
            // `Int`: the tree really does hold a number.
            guard type is any BinaryInteger.Type else { throw mismatch() }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Number \(number) is not representable as \(type)"
            ))
        }
        return converted
    case .array, .object:
        throw mismatch()
    }
}

/// Converts a parsed JSON number to one Swift numeric type, or nothing when the value does
/// not fit it exactly.
private func jsonValueConvertNumber<T>(_ number: Double, to type: T.Type) -> T? {
    if type is Double.Type { return number as? T }
    if type is Float.Type { return Float(number) as? T }
    guard let integer = type as? any FixedWidthInteger.Type else { return nil }
    return jsonValueExactInteger(number, as: integer) as? T
}

/// Rounds the exactness question back onto the concrete integer type, which is the only
/// thing that knows its own range.
private func jsonValueExactInteger<I: FixedWidthInteger>(_ number: Double, as: I.Type) -> I? {
    I(exactly: number)
}

private func jsonValueTypeName(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "a boolean"
    case .number: "a number"
    case .string: "a string"
    case .array: "an array"
    case .object: "an object"
    }
}

/// Presents one JSON object's members by key.
private struct JSONValueKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: JSONValue]
    let codingPath: [any CodingKey]

    var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        try member(for: key) == .null
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try scalar(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try scalar(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try scalar(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try scalar(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try scalar(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try scalar(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try scalar(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try scalar(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try scalar(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try scalar(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try scalar(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try scalar(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try scalar(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try scalar(type, key) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: state(for: key))
    }

    func nestedContainer<Nested: CodingKey>(
        keyedBy type: Nested.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<Nested> {
        try state(for: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try state(for: key).unkeyedContainer()
    }

    // A super decoder reads the reserved "super" key, and an absent key decodes as null
    // rather than as a missing one -- both matching `JSONDecoder`, whose behavior is this
    // bridge's whole bar.
    func superDecoder() throws -> any Decoder {
        JSONValueDecoderState(
            value: object[JSONValueSuperKey().stringValue] ?? .null,
            codingPath: codingPath + [JSONValueSuperKey()]
        )
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        JSONValueDecoderState(
            value: object[key.stringValue] ?? .null,
            codingPath: codingPath + [key]
        )
    }

    private func member(for key: Key) throws -> JSONValue {
        guard let value = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "No value associated with key \(key.stringValue)"
            ))
        }
        return value
    }

    private func scalar<T>(_ type: T.Type, _ key: Key) throws -> T {
        try jsonValueUnwrap(member(for: key), as: type, codingPath: codingPath + [key])
    }

    private func state(for key: Key) throws -> JSONValueDecoderState {
        JSONValueDecoderState(value: try member(for: key), codingPath: codingPath + [key])
    }
}

/// Presents one JSON array's elements in order, holding the only cursor in the bridge.
private struct JSONValueUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let codingPath: [any CodingKey]
    var currentIndex = 0

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool {
        // A nil that is not there must not advance the cursor: the caller reads the same
        // slot again as a value when the answer is false.
        guard try peek() == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try scalar(type) }
    mutating func decode(_ type: String.Type) throws -> String { try scalar(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try scalar(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try scalar(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try scalar(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try scalar(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try scalar(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try scalar(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try scalar(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try scalar(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try scalar(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try scalar(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try scalar(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try scalar(type) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: advance())
    }

    mutating func nestedContainer<Nested: CodingKey>(
        keyedBy type: Nested.Type
    ) throws -> KeyedDecodingContainer<Nested> {
        try advance().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try advance().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        try advance()
    }

    private func peek() throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, DecodingError.Context(
                codingPath: currentPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }
        return elements[currentIndex]
    }

    private mutating func scalar<T>(_ type: T.Type) throws -> T {
        let value = try jsonValueUnwrap(peek(), as: type, codingPath: currentPath)
        currentIndex += 1
        return value
    }

    private mutating func advance() throws -> JSONValueDecoderState {
        let state = JSONValueDecoderState(value: try peek(), codingPath: currentPath)
        currentIndex += 1
        return state
    }

    private var currentPath: [any CodingKey] {
        codingPath + [JSONValueIndexKey(intValue: currentIndex)]
    }
}

/// Presents one JSON scalar, array, or object as a single value.
private struct JSONValueSingleValueContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { value == .null }

    func decode(_ type: Bool.Type) throws -> Bool { try scalar(type) }
    func decode(_ type: String.Type) throws -> String { try scalar(type) }
    func decode(_ type: Double.Type) throws -> Double { try scalar(type) }
    func decode(_ type: Float.Type) throws -> Float { try scalar(type) }
    func decode(_ type: Int.Type) throws -> Int { try scalar(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try scalar(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try scalar(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try scalar(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try scalar(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try scalar(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try scalar(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try scalar(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try scalar(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try scalar(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: JSONValueDecoderState(value: value, codingPath: codingPath))
    }

    private func scalar<T>(_ type: T.Type) throws -> T {
        try jsonValueUnwrap(value, as: type, codingPath: codingPath)
    }
}

/// Names the reserved super-decoder position in a decoding error's coding path.
private struct JSONValueSuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }

    init() {}
    init?(stringValue: String) { nil }
    init?(intValue: Int) { nil }
}

/// Names an array position in a decoding error's coding path.
private struct JSONValueIndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? -1)" }

    init(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { nil }
}
