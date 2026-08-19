// Differential tests for the JSONValue-backed decoder: every fixture is decoded twice --
// through the bridge, and through JSONDecoder over the same tree's bytes -- and the two
// answers must agree on the value and on whether decoding failed at all.
//
// The bar is deliberately the round trip the bridge replaces, not raw wire bytes: a number
// has already become a Double by the time either path starts.
import DanTermProtocol
import Foundation
import Testing

/// One fixture shape reaching a keyed container, an unkeyed container, nesting, optional
/// keys, and every integer width the bridge converts.
private struct Sample: Codable, Equatable {
    struct Nested: Codable, Equatable {
        let name: String
        let flags: [Bool]
    }

    let count: Int
    let big: UInt64
    let small: Int8
    let ratio: Double
    let enabled: Bool
    let label: String
    let tags: [String]
    let nested: Nested
    let optional: String?
}

@Test("The bridge and a JSONDecoder round trip agree on a fully populated value")
func bridgeMatchesRoundTripOnPopulatedValue() throws {
    let tree = JSONValue.object([
        "count": .number(7),
        "big": .number(9_007_199_254_740_992),
        "small": .number(-8),
        "ratio": .number(0.5),
        "enabled": .bool(true),
        "label": .string("hello"),
        "tags": .array([.string("a"), .string("b")]),
        "nested": .object([
            "name": .string("inner"),
            "flags": .array([.bool(true), .bool(false)]),
        ]),
        "optional": .string("present"),
    ])
    try expectAgreement(Sample.self, tree)
}

@Test("Absence and an explicit null both answer nothing for an optional key")
func bridgeMatchesRoundTripOnAbsentAndNullOptionals() throws {
    var fields = populatedFields
    fields["optional"] = nil
    try expectAgreement(Sample.self, .object(fields))

    fields["optional"] = .null
    try expectAgreement(Sample.self, .object(fields))
}

@Test("Both paths refuse the same malformed trees")
func bridgeMatchesRoundTripOnRefusals() throws {
    // Every case is a way one primitive conversion can fail: a fractional or negative
    // number for a whole type, a number past the type's range, a scalar where a container
    // belongs and the reverse, and a null against a required key.
    let refusals: [String: JSONValue] = [
        "count": .number(1.5),
        "big": .number(-1),
        "small": .number(1_000),
        "ratio": .string("half"),
        "enabled": .number(1),
        "label": .bool(false),
        "tags": .string("a"),
        "nested": .array([]),
    ]
    for (key, value) in refusals {
        var fields = populatedFields
        fields[key] = value
        try expectAgreement(Sample.self, .object(fields))
    }

    var missing = populatedFields
    missing["label"] = nil
    try expectAgreement(Sample.self, .object(missing))

    var nulled = populatedFields
    nulled["label"] = .null
    try expectAgreement(Sample.self, .object(nulled))

    var wrongElement = populatedFields
    wrongElement["tags"] = .array([.string("a"), .number(2)])
    try expectAgreement(Sample.self, .object(wrongElement))

    try expectAgreement(Sample.self, .array([]))
}

@Test("An empty array decodes to an empty collection through both paths")
func bridgeMatchesRoundTripOnEmptyArray() throws {
    var fields = populatedFields
    fields["tags"] = .array([])
    try expectAgreement(Sample.self, .object(fields))
}

@Test("A top-level scalar and a top-level array decode through their own containers")
func bridgeMatchesRoundTripOnTopLevelValues() throws {
    try expectAgreement(Int.self, .number(42))
    try expectAgreement(String.self, .string("plain"))
    try expectAgreement([Int].self, .array([.number(1), .number(2)]))
    try expectAgreement([String: Int].self, .object(["a": .number(1)]))
    try expectAgreement(Int?.self, .null)
}

private let populatedFields: [String: JSONValue] = [
    "count": .number(7),
    "big": .number(4),
    "small": .number(-8),
    "ratio": .number(0.5),
    "enabled": .bool(true),
    "label": .string("hello"),
    "tags": .array([.string("a")]),
    "nested": .object(["name": .string("inner"), "flags": .array([.bool(true)])]),
    "optional": .string("present"),
]

/// Asserts the bridge and the encode-then-JSONDecoder path give the same answer, whether
/// that answer is a value or a failure.
private func expectAgreement<T: Decodable & Equatable>(
    _ type: T.Type,
    _ tree: JSONValue,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let bridged = Result { try JSONValueDecoder().decode(type, from: tree) }
    let roundTripped = Result {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(tree))
    }
    switch (bridged, roundTripped) {
    case (.success(let left), .success(let right)):
        #expect(left == right, sourceLocation: sourceLocation)
    case (.failure, .failure):
        break
    case (.success, .failure):
        Issue.record("Bridge accepted a tree the round trip refused", sourceLocation: sourceLocation)
    case (.failure(let error), .success):
        Issue.record(
            "Bridge refused a tree the round trip accepted: \(error)",
            sourceLocation: sourceLocation
        )
    }
}
