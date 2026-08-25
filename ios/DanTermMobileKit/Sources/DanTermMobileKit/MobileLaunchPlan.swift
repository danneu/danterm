// Decides what the phone does with the target it is launched with: connect straight away,
// or wait for the user to name a host.
//
// It is a value rather than a step in the shell because the smoke path depends on it: a
// launch that stalls waiting for a host cannot be driven by `scripts/ios-app.sh`, and the
// one input that decides it -- whether the launch environment names a host at all -- is
// exactly the kind of fact a shell reads once and gets wrong silently.
import Foundation

/// The target facts a launch reads from outside the model: the environment the process was
/// started with, and what the last session stored.
public struct MobileLaunchInputs: Equatable, Sendable {
    public let environmentHost: String?
    public let environmentPort: String?
    public let storedHost: String?
    public let storedPort: String?
    /// Input the smoke run drives into the first pane, once the stream is serving.
    public let smokeInput: String?

    public init(
        environmentHost: String? = nil,
        environmentPort: String? = nil,
        storedHost: String? = nil,
        storedPort: String? = nil,
        smokeInput: String? = nil
    ) {
        self.environmentHost = environmentHost
        self.environmentPort = environmentPort
        self.storedHost = storedHost
        self.storedPort = storedPort
        self.smokeInput = smokeInput
    }
}

/// What the fields start out holding, and whether the launch connects without being asked.
public struct MobileLaunchPlan: Equatable, Sendable {
    /// The target fields as the launch leaves them.
    public let draft: MobileTargetDraft
    /// Whether the launch names a host, which is the one thing that decides whether the
    /// phone connects on its own or waits to be told where to go.
    public let connectsImmediately: Bool

    /// The port the phone offers when neither the environment nor the store names one.
    public static let defaultPort = "7420"

    /// Resolves the launch from the environment and the store.
    ///
    /// A host and a port are one target, so the host decides which source is read for both.
    /// The environment names the target only when it names a host; otherwise the stored
    /// target is used whole. Splitting them let an ambient port -- the runner used to
    /// install 7420 on every launch -- be dialed against the user's saved host.
    ///
    /// An empty environment value is absent rather than authoritative: an empty string can
    /// never name a server, and a launcher that installs the variables unconditionally
    /// would otherwise leave the launch dialing nothing.
    public init(inputs: MobileLaunchInputs) {
        let host: String?
        let port: String?
        if let launchHost = inputs.environmentHost.presence {
            host = launchHost
            port = inputs.environmentPort.presence
        } else {
            host = inputs.storedHost.presence
            port = inputs.storedPort.presence
        }
        draft = MobileTargetDraft(host: host, port: port ?? MobileLaunchPlan.defaultPort)
        connectsImmediately = host != nil
    }
}

private extension Optional where Wrapped == String {
    /// The string when it holds something, and nothing when it is absent or empty.
    var presence: String? {
        guard let value = self, value.isEmpty == false else { return nil }
        return value
    }
}
