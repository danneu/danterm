// Pins what the phone does with the target it launches with, over the ways the environment
// and the store can name one.
import DanTermMobileKit
import Foundation
import Testing

@Test("An environment host connects the launch without asking")
func launchConnectsToEnvironmentHost() {
    // Intent: the host the process was started with is the one the launch dials.
    // Why it exists: the runner installs the host that way for `--slot`, and a simulator
    //   run has no way to answer a prompt, so a launch that stalled would fail the probe.
    // Scenario: `just ios-app --slot 4`, which launches the client with the slot's host.
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
    // Why it exists: an empty string can never name a server, and a launcher that
    //   installs the variable unconditionally would otherwise leave the launch dialing
    //   nothing while a good stored host sat unused.
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

@Test("An environment host does not borrow the stored port")
func launchEnvironmentHostDoesNotBorrowStoredPort() {
    // Intent: a host and a port are one target. A launch host that names no port gets the
    //   default port, never the port saved beside a different host.
    // Why it exists: the two halves used to resolve separately, so a launch against one
    //   Mac could be dialed at the port saved for another and fail with no explanation.
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(
        environmentHost: "100.64.0.7",
        storedHost: "mac.tailnet",
        storedPort: "9000"
    ))
    #expect(plan.draft.host == "100.64.0.7")
    #expect(plan.draft.port == MobileLaunchPlan.defaultPort)
}

@Test("A stored host does not borrow an environment port")
func launchStoredHostDoesNotBorrowEnvironmentPort() {
    // Intent: with no launch host, the saved target is used whole -- an ambient port
    //   cannot be spliced onto it.
    // Why it exists: the runner once installed port 7420 on every launch, which replaced
    //   the custom port the user had saved beside their own host.
    let plan = MobileLaunchPlan(inputs: MobileLaunchInputs(
        environmentPort: "7420",
        storedHost: "mac.tailnet",
        storedPort: "9000"
    ))
    #expect(plan.draft.host == "mac.tailnet")
    #expect(plan.draft.port == "9000")
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
