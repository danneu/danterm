// The synchronous witness for the PTY source-cancellation gate and master-descriptor
// release.
import Darwin

/// Tells the owner whether a lifecycle edge completed inline or will resume later.
package enum TerminalPTYLifecycleGateVerdict: Sendable {
    case proceed
    case deferred
}

/// Isolates nondeterministic source and descriptor lifecycle edges from owner policy.
package protocol TerminalPTYResourceLifecycling: Sendable {
    func gateSourceCancellationAcknowledgement(
        resume: @escaping @Sendable () -> Void
    ) -> TerminalPTYLifecycleGateVerdict

    func closeMasterDescriptor(_ descriptor: Int32)
}

/// Preserves direct production lifecycle behavior without owning mutable state.
package struct SystemTerminalPTYResourceLifecycle: TerminalPTYResourceLifecycling {
    package init() {}

    package func gateSourceCancellationAcknowledgement(
        resume _: @escaping @Sendable () -> Void
    ) -> TerminalPTYLifecycleGateVerdict {
        .proceed
    }

    package func closeMasterDescriptor(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }
}
