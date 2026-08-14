// The bind-address guard: the one place that decides whether this process is
// allowed to open a listener at all.
//
// This file exists to make the research doc's investigation rule structural
// rather than conventional. That rule permits an unauthenticated listener only
// when it is bound to the tailnet interface, so the ideal shape is one in which
// a wrongly bound listener cannot be created -- not one where a reviewer must
// notice the wrong flag. The bridge therefore resolves its address here, refuses
// everything that is not a tailnet address on a local interface, and reports the
// interface it matched so the finding can name it.
//
// Nothing about authentication belongs in this file. T6 owns the auth model.
import Darwin
import Foundation

/// A listen address the bridge has proved is a Tailscale address on a local
/// interface, carrying the interface name so a run can be audited.
///
/// It has no public initializer on purpose: the only way to obtain one is
/// `resolve`, so holding a value of this type *is* the proof that the check ran.
struct TailnetBindAddress {
    let address: String
    let port: UInt16
    let interfaceName: String

    enum Rejection: Error, CustomStringConvertible {
        case malformed(String)
        case wildcard(String)
        case notTailscaleRange(String)
        case notLocal(String)

        var description: String {
            switch self {
            case .malformed(let value):
                "`\(value)` is not an addr:port pair"
            case .wildcard(let value):
                "`\(value)` is a wildcard address; the bridge binds one explicit"
                    + " tailnet address so it cannot be reached off the tailnet"
            case .notTailscaleRange(let value):
                "`\(value)` is not in 100.64.0.0/10, so it is not a Tailscale"
                    + " address; this listener is unauthenticated and may only"
                    + " exist on the tailnet"
            case .notLocal(let value):
                "`\(value)` is a Tailscale address but is not assigned to any"
                    + " interface on this machine; run `tailscale ip -4`"
            }
        }
    }

    /// Parses `addr:port` and refuses anything the doc's rule does not cover.
    ///
    /// The two checks are separate claims and both are load bearing. The range
    /// check says the address is Tailscale's; the interface check says it is
    /// *this machine's* Tailscale address, which is what stops a typo from
    /// producing a listener bound to nothing or, worse, a bind that silently
    /// succeeds against a different local address.
    static func resolve(_ value: String) throws -> TailnetBindAddress {
        guard let separator = value.lastIndex(of: ":") else {
            throw Rejection.malformed(value)
        }
        let host = String(value[value.startIndex..<separator])
        guard let port = UInt16(value[value.index(after: separator)...]), port > 0 else {
            throw Rejection.malformed(value)
        }
        if host.isEmpty || host == "0.0.0.0" || host == "::" || host == "*" {
            throw Rejection.wildcard(value)
        }
        guard isTailscaleRange(host) else {
            throw Rejection.notTailscaleRange(host)
        }
        guard let interfaceName = localInterface(carrying: host) else {
            throw Rejection.notLocal(host)
        }
        return TailnetBindAddress(address: host, port: port, interfaceName: interfaceName)
    }

    /// 100.64.0.0/10, the CGNAT block Tailscale assigns from.
    private static func isTailscaleRange(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              let second = UInt8(parts[1]),
              parts[2].allSatisfy(\.isNumber), parts[3].allSatisfy(\.isNumber)
        else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// The name of the interface holding `host`, or nil if no interface does.
    private static func localInterface(carrying host: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let resolved = buffer.withUnsafeBufferPointer { text in
                text.baseAddress.map { String(cString: $0) } ?? ""
            }
            guard resolved == host else { continue }
            return String(cString: entry.pointee.ifa_name)
        }
        return nil
    }
}
