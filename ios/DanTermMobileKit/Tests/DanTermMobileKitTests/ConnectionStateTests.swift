// Table-driven tests for the complete user-facing connection-state vocabulary.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
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
        (.connectionLimit, .refusedByMac(.connectionLimit)),
        (.auditUnavailable, .refusedByMac(.auditUnavailable)),
        (.unsupportedProtocol(7), .versionMismatch(7)),
        (.oversizedLine, .connectionLost),
    ]
    for (failure, expected) in cases {
        #expect(MobileConnectionState.failure(failure) == expected)
    }
}

@Test("Ordinary stream endings and request refusals remain distinct")
func serviceEndStates() {
    #expect(MobileConnectionState.streamEnded(reason: "paneClosed") == .streamEnded("paneClosed"))
    #expect(MobileConnectionState.requestRefused(reason: "pane not found") == .requestRefused("pane not found"))
}

@Test("Foreground retry retains the last exact pane cursor")
func reconnectRetainsCursor() {
    var model = MobileConnectionModel()
    model.connect(to: "mac.example:9237")
    #expect(model.state == .connecting)
    model.didHandshake()
    #expect(model.state == .listingPanes)
    model.didLoadPanes()
    #expect(model.state == .ready)

    let cursor = PaneTapeCursor(
        recorderLifetimeId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        nextSequence: 8,
        feedBytesBeforeNextSequence: 21,
        writeBytesBeforeNextSequence: 5
    )
    let pane = PaneId(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let newPane = PaneId(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    model.record(cursor, forPane: pane)
    model.didEnd(with: .connectionLost)
    model.connect(to: "mac.example:9237")
    #expect(model.startPosition(forPane: pane) == .cursor(cursor))
    #expect(model.startPosition(forPane: newPane) == .now)
}
