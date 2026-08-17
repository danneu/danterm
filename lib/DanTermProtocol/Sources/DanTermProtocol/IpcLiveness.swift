// The silence bound that governs a remote IPC connection, and the hello that carries it.
//
// This file holds the bound as wire vocabulary: the server states one number and the
// client derives everything from it, so the two ends cannot be tuned apart. What does
// not belong here is either end's enforcement -- the server's receive deadline and the
// client's ping cadence live with the code that owns those sockets.
import Foundation

/// The single silence bound both ends of a remote connection apply.
///
/// It is a type rather than a bare `TimeInterval` for two reasons: the ping cadence is
/// derived from the bound here, so no caller can pick a cadence that disagrees with the
/// deadline it feeds; and a bound that could never be enforced cannot be constructed at
/// all, so holding a value is the proof that the number is usable.
public struct IpcLivenessBound: Equatable, Sendable {
    /// The shipped default, and the only place the number 30 appears.
    ///
    /// It gives roughly twice the margin the worst measured mobility stall needs at the
    /// obligation cadence, bounds a leaked connection slot well inside the connection
    /// cap, and keeps a foreground phone's wakeups cheap. Retuning it is a one-binary
    /// change because the client reads it from hello rather than repeating it.
    public static let standard = IpcLivenessBound(seconds: 30)!

    /// How long a connection may go without a single arriving byte.
    public let seconds: TimeInterval

    /// Refuses a bound no deadline could be built from.
    public init?(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return nil }
        self.seconds = seconds
    }

    /// The client's unconditional ping cadence. Half the bound, so a compliant peer
    /// feeds both ends' deadlines twice per bound and one late ping is still not fatal.
    public var pingInterval: TimeInterval { seconds / 2 }
}

/// Builds and reads the server's opening hello, so its shape is stated once for the end
/// that writes it and the end that parses it.
public enum IpcHello {
    /// Names the hello field carrying the silence bound, in seconds.
    public static let silenceBoundKey = "silenceSeconds"

    /// States the complete hello parameter object the server sends before service.
    public static func params(
        protocolVersion: Int,
        appVersion: String,
        livenessBound: IpcLivenessBound
    ) -> JSONValue {
        .object([
            "protocol": .number(Double(protocolVersion)),
            "app": .string(appVersion),
            silenceBoundKey: .number(livenessBound.seconds),
        ])
    }

    /// Reads the advertised bound back, or nil when the peer advertised none this
    /// client can use. A missing or unusable value is not a broken hello on its own:
    /// only a connection under the contract needs the number, and that end decides.
    public static func livenessBound(from params: JSONValue?) -> IpcLivenessBound? {
        guard let seconds = params?[silenceBoundKey]?.asNumber else { return nil }
        return IpcLivenessBound(seconds: seconds)
    }
}
