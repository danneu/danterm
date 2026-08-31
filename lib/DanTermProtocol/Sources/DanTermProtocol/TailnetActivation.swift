// The single rule that turns the config an instance was given plus its process
// identity into that instance's tailnet endpoint, and the status value every
// surface reports.
// Pure derivation only: the tailnet-range and local-interface checks stay with
// the bind, which re-proves them on every attempt.

/// The one address and port a given instance may bind, and the base it came from.
///
/// Carries the base text and offset as well as the result so every status surface
/// can show how the endpoint was derived without re-deriving it.
public struct DanTermTailnetEndpoint: Equatable, Sendable {
    /// The launch-frozen `tailnet.listen` text the config named.
    public let base: String
    /// This identity's fixed contribution to the base port.
    public let offset: Int
    /// The base address, unchanged: only the port is derived.
    public let address: String
    /// The base port plus this identity's offset.
    public let port: UInt16

    /// The `address:port` form a listener binds and a client saves.
    public var text: String { "\(address):\(port)" }

    /// Creates one derived endpoint. Callers normally get this from `DanTermTailnetActivation`.
    public init(base: String, offset: Int, address: String, port: UInt16) {
        self.base = base
        self.offset = offset
        self.address = address
        self.port = port
    }
}

/// Decides whether this instance opens a tailnet listener at all, and where.
///
/// Closed by default: every path that does not produce an endpoint names the
/// reason, because that reason is what the user reads in the status surfaces.
public enum DanTermTailnetActivation: Equatable, Sendable {
    case active(DanTermTailnetEndpoint)
    case disabled(reason: String)

    /// The endpoint to bind, or nil when this instance opens no listener.
    public var endpoint: DanTermTailnetEndpoint? {
        guard case .active(let endpoint) = self else { return nil }
        return endpoint
    }

    /// Applies the closed-by-default gate and the offset table in one place.
    ///
    /// The config this instance was given and its own identity are the whole
    /// answer: every instance owns its config file, so a slot that names no
    /// endpoint falls out at the first guard and needs no gate of its own.
    public static func resolve(
        config: DanTermTailnetConfig?,
        identity: DanTermInstanceIdentity
    ) -> DanTermTailnetActivation {
        guard let config else {
            return .disabled(reason: "no tailnet endpoint is configured")
        }
        guard config.enable else {
            return .disabled(reason: "the config sets `tailnet.enable` to false")
        }
        guard config.admittedNodeIds.isEmpty == false else {
            return .disabled(reason: "no admitted node ids are configured")
        }
        guard let offset = identity.tailnetPortOffset else {
            return .disabled(reason: "this instance has no tailnet port offset")
        }
        guard let separator = config.listen.lastIndex(of: ":") else {
            return .disabled(reason: malformedReason(config.listen))
        }
        let address = String(config.listen[..<separator])
        let portText = config.listen[config.listen.index(after: separator)...]
        guard address.isEmpty == false, let basePort = Int(portText), basePort > 0,
              basePort <= Int(UInt16.max)
        else {
            return .disabled(reason: malformedReason(config.listen))
        }
        guard let port = UInt16(exactly: basePort + offset) else {
            return .disabled(
                reason: "port \(basePort) plus offset \(offset) exceeds the maximum port 65535"
            )
        }
        return .active(DanTermTailnetEndpoint(
            base: config.listen,
            offset: offset,
            address: address,
            port: port
        ))
    }

    private static func malformedReason(_ listen: String) -> String {
        "configured listen `\(listen)` is not an address and port"
    }
}

/// What this instance's tailnet listener is doing right now.
///
/// One value authored by the app and reported verbatim by the preferences pane,
/// the `tailnet.status` reply, and a slot launch handle, so the three can never
/// disagree.
public enum DanTermTailnetStatus: Equatable, Sendable {
    /// This instance will never open a listener during this run, and why.
    case disabled(reason: String)
    /// The endpoint is derived but not bound yet, and why the last attempt failed.
    case waiting(endpoint: DanTermTailnetEndpoint, reason: String)
    /// The endpoint is bound and serving admitted peers.
    case listening(endpoint: DanTermTailnetEndpoint)

    /// The endpoint this instance derived, or nil when it opens no listener.
    public var endpoint: DanTermTailnetEndpoint? {
        switch self {
        case .disabled: return nil
        case .waiting(let endpoint, _), .listening(let endpoint): return endpoint
        }
    }

    /// The frozen wire object. Fields are absent when they do not apply, never null.
    public var json: JSONValue {
        switch self {
        case .disabled(let reason):
            return .object([
                "state": .string("disabled"),
                "reason": .string(reason),
            ])
        case .waiting(let endpoint, let reason):
            var object = Self.endpointFields(endpoint)
            object["state"] = .string("waiting")
            object["reason"] = .string(reason)
            return .object(object)
        case .listening(let endpoint):
            var object = Self.endpointFields(endpoint)
            object["state"] = .string("listening")
            return .object(object)
        }
    }

    private static func endpointFields(_ endpoint: DanTermTailnetEndpoint) -> [String: JSONValue] {
        [
            "base": .string(endpoint.base),
            "offset": .number(Double(endpoint.offset)),
            "endpoint": .string(endpoint.text),
        ]
    }
}

extension DanTermInstanceIdentity {
    /// This identity's fixed offset from the configured base port, or nil when it
    /// gets no endpoint at all.
    ///
    /// Production is the base, and each development slot follows it in slot order,
    /// so every instance on one Mac owns a distinct, predictable port a client can
    /// save once. Harness and unknown bundles have no place in that table and open
    /// no listener.
    public var tailnetPortOffset: Int? {
        if self == .production { return 0 }
        guard let developmentSlot else { return nil }
        return 1 + developmentSlot
    }
}
