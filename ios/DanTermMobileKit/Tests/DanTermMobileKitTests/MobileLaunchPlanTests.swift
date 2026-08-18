// Pins what the phone does with the target it launches with, over the four ways the
// environment and the store can name one.
import DanTermMobileKit
import Foundation
import Testing

@Test("An environment host connects the launch without asking")
func launchConnectsToEnvironmentHost() {
    // Intent: the host the process was started with is the one the launch dials.
    // Why it exists: the simulator smoke path installs the host that way and has no
    //   way to answer a prompt, so a launch that stalled would fail the whole probe.
    // Scenario: `DANTERM_IOS_HOST=mac.tailnet scripts/ios-app.sh simulator`.
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(
        environmentHost: "mac.tailnet",
        storedHost: "old.tailnet"
    ))
    #expect(plan.draft.host == "mac.tailnet")
    #expect(plan.connectsImmediately)
}

@Test("An empty environment host falls through to the stored one")
func launchFallsThroughEmptyEnvironmentHost() {
    // Intent: an empty `DANTERM_IOS_HOST` counts as absent, not as an authoritative
    //   empty host.
    // Why it exists: `scripts/ios-app.sh simulator` always installs the variable and
    //   passes an empty string when the caller names no host. Treating that as a host
    //   would leave every ordinary launch dialing nothing while a good stored host sat
    //   unused.
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(
        environmentHost: "",
        environmentPort: "",
        storedHost: "mac.tailnet",
        storedPort: "9000"
    ))
    #expect(plan.draft.host == "mac.tailnet")
    #expect(plan.draft.port == "9000")
    #expect(plan.connectsImmediately)
}

@Test("An empty environment host with nothing stored waits to be told where to go")
func launchWaitsWithNoHostAnywhere() {
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(environmentHost: ""))
    #expect(plan.draft.host == nil)
    #expect(plan.draft.port == MobileLaunchPlan.defaultPort)
    #expect(plan.connectsImmediately == false)
}

@Test("No environment variable at all leaves the stored host in charge")
func launchUsesStoredHostWithoutEnvironment() {
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(storedHost: "mac.tailnet"))
    #expect(plan.draft.host == "mac.tailnet")
    #expect(plan.draft.port == MobileLaunchPlan.defaultPort)
    #expect(plan.connectsImmediately)
}
