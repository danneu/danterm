// The phone's request identity, kept narrower than the shared JSON-RPC wire vocabulary.
import DanTermProtocol

/// Makes every request the phone issues a non-null string before it reaches the wire.
public struct MobileRequestId: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The shared envelope stays broad; this conversion is the mobile wire boundary.
    public var jsonValue: JSONValue { .string(rawValue) }

    /// Only the exact string identity can match a response to a phone request.
    public func matches(_ value: JSONValue?) -> Bool {
        value == .string(rawValue)
    }
}
