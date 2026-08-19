// Behavioral coverage for the explicit startup, activation, and notification
// authorization policy selected from app launch arguments.
import Testing
@testable import DanTerm

struct AppLaunchPolicyTests {
    @Test("normal launches offer recovery and may request notification authorization")
    func normalLaunchUsesInteractivePolicies() {
        let policy = AppLaunchPolicy(arguments: ["DanTerm"])

        #expect(policy.startup == .promptForRecovery)
        #expect(policy.activation == .foreground)
        #expect(policy.notificationAuthorization == .requestIfNeeded)
        #expect(policy.notificationAuthorization.permitsRequest)
    }

    @Test("unattended launches start fresh without activation or authorization prompts")
    func unattendedLaunchUsesFreshPolicies() {
        // Intent: the programmatic launcher can select a launch that neither
        //   restores user state nor takes focus or asks for notification access.
        // Why it exists: a stale recovery lock and an undetermined notification
        //   grant must not block an agent-launched development instance.
        // Scenario: the slot launcher directly execs the app with its fresh and
        //   background arguments while valid recovery checkpoints exist.
        let policy = AppLaunchPolicy(arguments: [
            "DanTerm Dev (3)",
            AppLaunchPolicy.freshArgument,
            AppLaunchPolicy.backgroundArgument,
        ])

        #expect(policy.startup == .fresh)
        #expect(policy.activation == .background)
        #expect(policy.notificationAuthorization == .neverRequest)
        #expect(policy.notificationAuthorization.permitsRequest == false)
        #expect(policy.tailnetOptIn == false)
    }

    @Test("only --tailnet opts a launch into the tailnet listener")
    func tailnetListenerIsOptIn() {
        // Intent: the tailnet opt-in is carried by its own argument and nothing else
        //   a launch says turns it on.
        // Why it exists: every pool slot reads the one shared config, so a slot that
        //   opened a listener without being asked would race the user's own instance
        //   for a port with the user's admitted node ids behind it.
        // Scenario: an agent launches a slot to drive the iOS client against it, and
        //   the slot beside it was launched the ordinary way.
        let optedIn = AppLaunchPolicy(arguments: [
            "DanTerm Dev (3)",
            AppLaunchPolicy.freshArgument,
            AppLaunchPolicy.backgroundArgument,
            AppLaunchPolicy.tailnetArgument,
        ])
        let ordinary = AppLaunchPolicy(arguments: [
            "DanTerm Dev (4)",
            AppLaunchPolicy.freshArgument,
            AppLaunchPolicy.backgroundArgument,
        ])

        #expect(optedIn.tailnetOptIn)
        #expect(ordinary.tailnetOptIn == false)
        // The flag adds the opt-in and nothing else: recovery and activation are
        // still decided only by --fresh and --background.
        #expect(optedIn.startup == ordinary.startup)
        #expect(optedIn.activation == ordinary.activation)
        #expect(optedIn.notificationAuthorization == ordinary.notificationAuthorization)
    }

    @Test("foreground notification priming stays fresh but may prompt")
    func foregroundPrimingKeepsFreshStartup() {
        let policy = AppLaunchPolicy(arguments: [
            "DanTerm Dev (3)",
            AppLaunchPolicy.freshArgument,
        ])

        #expect(policy.startup == .fresh)
        #expect(policy.activation == .foreground)
        #expect(policy.notificationAuthorization == .requestIfNeeded)
        #expect(policy.notificationAuthorization.permitsRequest)
    }
}
