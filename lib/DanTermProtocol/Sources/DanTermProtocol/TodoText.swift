// The validated todo text value shared by CLI, IPC, core messages, and storage.
import Foundation

/// Makes blank todo text unrepresentable and owns its one normalization rule.
public struct TodoText: Equatable, Hashable, Codable, Sendable {
    /// Provides the normalized text to display and encode.
    public let value: String

    /// Trims user-facing whitespace and refuses text with no remaining content.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        value = trimmed
    }

    /// Decodes and validates the same single-string representation used on the wire.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let text = TodoText(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Todo text must be non-blank."
            )
        }
        self = text
    }

    /// Encodes only the normalized string so existing JSON shapes stay unchanged.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
