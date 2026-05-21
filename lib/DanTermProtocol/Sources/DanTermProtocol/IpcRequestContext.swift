// Raw pane context supplied by the CLI and resolved inside pure update code.
import Foundation

public struct IpcRequestContext: Codable, Equatable {
    public let paneId: String?

    public static let paramsKey = "_ctx"

    public init(paneId: String? = nil) {
        self.paneId = paneId
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let paneId { object["paneId"] = .string(paneId) }
        return .object(object)
    }

    public static func from(params: JSONValue?) -> IpcRequestContext {
        guard case .object(let object) = params,
              case .object(let context)? = object[paramsKey]
        else {
            return IpcRequestContext()
        }
        return IpcRequestContext(
            paneId: context["paneId"]?.asString
        )
    }

    public static func strippingContext(from params: JSONValue?) -> JSONValue {
        guard case .object(var object) = params else {
            return params ?? .object([:])
        }
        object.removeValue(forKey: paramsKey)
        return .object(object)
    }
}
