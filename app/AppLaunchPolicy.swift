// Explicit launch policies for recovery, activation, and notification prompts.
// Keep programmatic-launch intent here instead of inferring it from process state.

/// Decides whether startup may offer persisted state or must create a new session.
enum StartupPolicy: Equatable {
    case promptForRecovery
    case fresh
}

/// Decides whether launch and notification delivery may ask for authorization.
enum NotificationAuthorizationPolicy: Equatable {
    case requestIfNeeded
    case neverRequest

    var permitsRequest: Bool {
        self == .requestIfNeeded
    }
}

/// Decides whether startup should activate the app and make its window key.
enum LaunchActivationPolicy: Equatable {
    case foreground
    case background
}

/// Parses the app arguments shared by the dev-slot launcher and normal launches.
struct AppLaunchPolicy: Equatable {
    static let freshArgument = "--fresh"
    static let backgroundArgument = "--background"

    let startup: StartupPolicy
    let activation: LaunchActivationPolicy
    let notificationAuthorization: NotificationAuthorizationPolicy

    init(arguments: [String]) {
        startup = arguments.contains(Self.freshArgument) ? .fresh : .promptForRecovery
        if arguments.contains(Self.backgroundArgument) {
            activation = .background
            notificationAuthorization = .neverRequest
        } else {
            activation = .foreground
            notificationAuthorization = .requestIfNeeded
        }
    }
}
