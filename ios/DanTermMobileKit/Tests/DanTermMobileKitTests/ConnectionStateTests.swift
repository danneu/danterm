// Table-driven tests for the complete user-facing connection-state vocabulary.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Testing

@Test("Every transport failure maps to one named remedy")
func transportFailureMapping() {
    let cases: [(TCPSocketTransportError, MobileConnectionState)] = [
        (.unresolvedHost(host: "mac"), .hostNotFound),
        (.connectFailed(reason: "refused", target: "mac:9"), .serverUnreachable),
        (.connectTimedOut(target: "mac:9"), .serverUnreachable),
        (.configureFailed, .deviceSetupFailure),
        (.configureTimeoutFailed, .deviceSetupFailure),
        (.timedOut, .connectionLost),
        (.readFailed, .connectionLost),
        (.writeFailed, .connectionLost),
        (.peerClosed, .connectionLost),
    ]
    for (failure, expected) in cases {
        #expect(MobileConnectionState.failure(failure) == expected)
    }
}

@Test("Every conversation failure maps without a generic fallback")
func conversationFailureMapping() {
    let cases: [(DanTermClientError, MobileConnectionState)] = [
        (.cancelled, .disconnected),
        (.closedBeforeHello, .connectionLost),
        (.invalidHello, .connectionLost),
        (.notAdmitted, .refusedByMac(.notAdmitted)),
        (.identityUnresolved, .refusedByMac(.identityUnresolved)),
        // The bound a capacity refusal carries is scheduling input, not a remedy, so both
        // spellings present the one state. The state vocabulary stays free of policy.
        (.connectionLimit(.standard), .refusedByMac(.connectionLimit)),
        (.connectionLimit(nil), .refusedByMac(.connectionLimit)),
        (.auditUnavailable, .refusedByMac(.auditUnavailable)),
        (.unsupportedProtocol(7), .versionMismatch(7)),
        (.oversizedLine, .connectionLost),
        (.peerSilent, .connectionLost),
    ]
    for (failure, expected) in cases {
        #expect(MobileConnectionState.failure(failure) == expected)
    }
}

@Test("Only silence changes meaning while a connection is still being established")
func establishmentFailureMapping() {
    // Intent: a stream that never answered presents "Server unreachable", while the same
    //   silence on a working connection presents "Connection lost". Every other failure
    //   words the same in both phases.
    // Why it exists: the phone's state vocabulary has to stay total without growing a
    //   state, and the two remedies are different: one is "the Mac is not there", the
    //   other is "reconnect to the Mac that was".
    #expect(MobileConnectionState.establishmentFailure(.peerSilent) == .serverUnreachable)
    #expect(MobileConnectionState.failure(.peerSilent) == .connectionLost)
    for error in [
        DanTermClientError.cancelled,
        .closedBeforeHello,
        .invalidHello,
        .notAdmitted,
        .identityUnresolved,
        .connectionLimit(.standard),
        .auditUnavailable,
        .unsupportedProtocol(7),
        .oversizedLine,
    ] {
        #expect(
            MobileConnectionState.establishmentFailure(error)
                == MobileConnectionState.failure(error)
        )
    }
}

@Test("Ordinary stream endings and request refusals remain distinct")
func serviceEndStates() {
    #expect(MobileConnectionState.streamEnded(reason: "paneClosed") == .streamEnded("paneClosed"))
    #expect(MobileConnectionState.requestRefused(reason: "pane not found") == .requestRefused("pane not found"))
}
