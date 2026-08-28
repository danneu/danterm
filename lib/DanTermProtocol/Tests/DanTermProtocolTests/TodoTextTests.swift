// Behavioral coverage for the validated todo text shared by every carrier.
import Foundation
import Testing
@testable import DanTermProtocol

struct TodoTextTests {
    @Test("blank todo text is not constructible", arguments: ["", "  ", "\t", "\n"])
    func blankTodoTextIsNotConstructible(_ input: String) {
        #expect(TodoText(input) == nil)
    }

    @Test("todo text trims surrounding whitespace and newlines")
    func todoTextTrimsWhitespaceAndNewlines() throws {
        let text = try #require(TodoText(" \nx \n"))

        #expect(text.value == "x")
    }

    @Test("todo text validates while decoding")
    func todoTextValidatesWhileDecoding() throws {
        let decoder = JSONDecoder()

        #expect(try decoder.decode(TodoText.self, from: Data("\" x \"".utf8)).value == "x")
        #expect(throws: DecodingError.self) {
            try decoder.decode(TodoText.self, from: Data("\"  \"".utf8))
        }
    }
}
