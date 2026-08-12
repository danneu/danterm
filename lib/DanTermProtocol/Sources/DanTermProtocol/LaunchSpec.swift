// Shared launch specification for IPC-created DanTerm panes.
import Foundation

public struct LaunchSpec: Equatable, Sendable {
    public let cmd: String?
    public let cwd: String?
    public let title: String?

    public init(cmd: String?, cwd: String?, title: String?) {
        self.cmd = cmd.flatMap { $0.isEmpty ? nil : $0 }
        self.cwd = cwd
        self.title = title
    }

    public var isEmpty: Bool {
        cmd == nil && cwd == nil && title == nil
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let cmd {
            object["cmd"] = .string(cmd)
        }
        if let cwd {
            object["cwd"] = .string(cwd)
        }
        if let title {
            object["title"] = .string(title)
        }
        return .object(object)
    }
}

public enum LaunchSpecParseError: Error, Equatable {
    case notObject
    case fieldNotString(field: String)
}

public func parseLaunchSpec(_ value: JSONValue?) throws -> LaunchSpec? {
    guard let value else { return nil }
    guard case .object(let object) = value else {
        throw LaunchSpecParseError.notObject
    }

    let cmd = try optionalStringField("cmd", in: object)
    let cwd = try optionalStringField("cwd", in: object)
    let title = try optionalStringField("title", in: object)
    let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
    return spec.isEmpty ? nil : spec
}

private func optionalStringField(_ field: String, in object: [String: JSONValue]) throws -> String? {
    guard let value = object[field] else { return nil }
    guard case .string(let string) = value else {
        throw LaunchSpecParseError.fieldNotString(field: field)
    }
    return string
}
