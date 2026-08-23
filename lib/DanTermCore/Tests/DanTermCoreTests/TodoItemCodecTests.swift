// Behavioral coverage for the todo codec that now delegates identity encoding
// to the canonical TypedId representation.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct TodoItemCodecTests {
    @Test("Todo items keep their bare UUID wire shape through the shared identity codec")
    func todoItemWireShapeRoundTrips() throws {
        let uuid = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
        let item = TodoItem(id: TodoId(rawValue: uuid), text: "Ship it", isDone: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(item)

        #expect(String(decoding: data, as: UTF8.self) ==
            "{\"id\":\"12345678-90AB-CDEF-1234-567890ABCDEF\",\"isDone\":true,\"text\":\"Ship it\"}")
        #expect(try JSONDecoder().decode(TodoItem.self, from: data) == item)
    }
}
