// Behavioral coverage for the one Codable representation shared by every
// phantom-typed identity domain.
import DanTermProtocol
import Foundation
import Testing

struct TypedIdTests {
    @Test("Shared typed identities encode as bare UUID strings and decode in their own domains")
    func sharedDomainsUseOneCodec() throws {
        let value = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!

        try assertBareUUIDCodec(TabId(rawValue: value), uuid: value)
        try assertBareUUIDCodec(PaneId(rawValue: value), uuid: value)
        try assertBareUUIDCodec(GroupId(rawValue: value), uuid: value)
        try assertBareUUIDCodec(TodoId(rawValue: value), uuid: value)
    }

    @Test("Shared typed identities reject malformed UUID strings")
    func sharedDomainsRejectMalformedUUIDs() {
        assertRejectsMalformedUUID(TabId.self)
        assertRejectsMalformedUUID(PaneId.self)
        assertRejectsMalformedUUID(GroupId.self)
        assertRejectsMalformedUUID(TodoId.self)
    }
}

private func assertBareUUIDCodec<ID: Codable & Equatable>(_ id: ID, uuid: UUID) throws {
    let data = try JSONEncoder().encode(id)

    #expect(String(decoding: data, as: UTF8.self) == "\"\(uuid.uuidString)\"")
    #expect(try JSONDecoder().decode(ID.self, from: data) == id)
}

private func assertRejectsMalformedUUID<ID: Decodable>(_ type: ID.Type) {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(type, from: Data("\"not-a-uuid\"".utf8))
    }
}
