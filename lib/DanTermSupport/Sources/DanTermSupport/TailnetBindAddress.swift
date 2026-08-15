// Tailnet bind-address validation. A listener can receive this value only after
// the address passed both the Tailscale-range and local-interface checks.
import Darwin
import Foundation

/// Describes one local IPv4 interface for deterministic bind-gate evaluation.
struct TailnetInterface: Equatable, Sendable {
    let name: String
    let ipv4Address: String
}

/// Proves that one explicit IPv4 listen address belongs to this Mac's tailnet interface.
struct TailnetBindAddress: Equatable, Sendable {
    let address: String
    let port: UInt16
    let interfaceName: String

    /// Keeps test-only loopback listeners possible without opening a public construction path.
    init(address: String, port: UInt16, interfaceName: String) {
        self.address = address
        self.port = port
        self.interfaceName = interfaceName
    }

    /// Distinguishes each closed-by-default rejection at configuration time.
    enum Rejection: Error, Equatable, CustomStringConvertible, Sendable {
        case malformed(String)
        case wildcard(String)
        case notTailscaleRange(String)
        case notLocal(String)
        case interfaceEnumerationFailed

        var description: String {
            switch self {
            case .malformed(let value):
                return "`\(value)` is not an IPv4 address and nonzero port"
            case .wildcard(let value):
                return "`\(value)` is a wildcard address"
            case .notTailscaleRange(let value):
                return "`\(value)` is not in 100.64.0.0/10"
            case .notLocal(let value):
                return "`\(value)` is not assigned to a local interface"
            case .interfaceEnumerationFailed:
                return "local interfaces could not be enumerated"
            }
        }
    }

    /// Resolves config text only when it names a carried address in 100.64.0.0/10.
    static func resolve(
        _ value: String,
        interfaces injectedInterfaces: [TailnetInterface]? = nil
    ) throws -> TailnetBindAddress {
        guard let separator = value.lastIndex(of: ":") else {
            throw Rejection.malformed(value)
        }
        let host = String(value[..<separator])
        let portText = value[value.index(after: separator)...]
        guard let port = UInt16(portText), port > 0 else {
            throw Rejection.malformed(value)
        }
        if host.isEmpty || host == "0.0.0.0" || host == "::" || host == "*" {
            throw Rejection.wildcard(value)
        }
        guard isTailnetIPv4Address(host) else {
            throw Rejection.notTailscaleRange(host)
        }
        let interfaces = try injectedInterfaces ?? localIPv4Interfaces()
        guard let interface = interfaces.first(where: { $0.ipv4Address == host }) else {
            throw Rejection.notLocal(host)
        }
        return TailnetBindAddress(address: host, port: port, interfaceName: interface.name)
    }
}

/// Enumerates local IPv4 addresses without giving the resolver any network side effect.
private func localIPv4Interfaces() throws -> [TailnetInterface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else {
        throw TailnetBindAddress.Rejection.interfaceEnumerationFailed
    }
    guard let first = head else { return [] }
    defer { freeifaddrs(head) }
    var result: [TailnetInterface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let socketAddress = entry.pointee.ifa_addr,
              socketAddress.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        let host = inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        guard host != nil else { continue }
        result.append(TailnetInterface(
            name: String(cString: entry.pointee.ifa_name),
            ipv4Address: String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        ))
    }
    return result
}

/// Recognizes the IPv4 CGNAT range assigned to Tailscale nodes.
private func isTailnetIPv4Address(_ host: String) -> Bool {
    let components = host.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return false }
    let octets = components.compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    return octets[0] == 100 && (64...127).contains(octets[1])
}
