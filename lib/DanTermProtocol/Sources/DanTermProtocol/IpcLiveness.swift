// The silence bound that governs a remote IPC connection, and the hello that states it.
//
// This file holds the bound as wire vocabulary: the server states one number and the
// client derives everything from it, so the two ends cannot be tuned apart. The field
// name and its reader live on the bound itself, because more than one server-first
// frame states the number. What does not belong here is either end's enforcement --
// the server's receive deadline and the client's ping cadence live with the code that
// owns those sockets.
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

    /// Names the wire field carrying the bound, in seconds.
    ///
    /// It lives on the bound rather than on any one frame because more than one
    /// server-first frame states the number: the hello, and the capacity refusal that
    /// names the deadline by which a slot is reclaimed. One key means one reader.
    public static let wireKey = "silenceSeconds"

    /// States the bound as the wire carries it.
    public var wireValue: JSONValue { .number(seconds) }

    /// Reads a bound back, or nil when the peer stated none this client can use. A
    /// missing or unusable value is not a broken frame on its own: only the end that
    /// needs the number decides that.
    public static func read(from params: JSONValue?) -> IpcLivenessBound? {
        guard let seconds = params?[wireKey]?.asNumber else { return nil }
        return IpcLivenessBound(seconds: seconds)
    }
}

/// The one protocol number both ends of the handshake name, so a shape change cannot move
/// on one side alone.
///
/// It moves whenever a peer that speaks the previous number would behave incorrectly rather
/// than merely miss a feature -- a changed pane-tape record shape is exactly that. Skew in
/// either direction is refused at hello, before any stream starts.
public let danTermIpcProtocolVersion = 3

/// Builds and reads the server's opening hello, so its shape is stated once for the end
/// that writes it and the end that parses it.
public enum IpcHello {
    /// States the complete hello parameter object the server sends before service.
    public static func params(
        protocolVersion: Int,
        appVersion: String,
        livenessBound: IpcLivenessBound
    ) -> JSONValue {
        .object([
            "protocol": .number(Double(protocolVersion)),
            "app": .string(appVersion),
            IpcLivenessBound.wireKey: livenessBound.wireValue,
        ])
    }
}
