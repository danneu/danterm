// Behavioral coverage for the advertised silence bound and the ping method that feeds it.
import Foundation
import Testing
@testable import DanTermProtocol

struct IpcLivenessTests {
    @Test("the ping cadence is derived from the bound rather than tuned beside it")
    func pingCadenceIsHalfTheBound() throws {
        // Intent: one number produces both the deadline and the obligation cadence.
        // Why it exists: the whole contract exists to stop two independently tuned
        //   timeouts from disagreeing about one connection, and a separately stated
        //   cadence constant would reintroduce exactly that.
        let bound = try #require(IpcLivenessBound(seconds: 30))

        #expect(bound.seconds == 30)
        #expect(bound.pingInterval == 15)
    }

    @Test("a bound that cannot be enforced cannot be constructed", arguments: [
        0.0, -1.0, Double.infinity, Double.nan,
    ])
    func nonsenseBoundsAreRefused(_ seconds: Double) {
        #expect(IpcLivenessBound(seconds: seconds) == nil)
    }

    @Test("hello carries the bound and both ends read the same number back")
    func helloCarriesTheAdvertisedBound() throws {
        // Intent: the bound travels in the hello the server already sends first.
        // Why it exists: PO8 -- a client must derive its cadence and deadline from
        //   whatever the server advertises, not from a constant of its own.
        let advertised = try #require(IpcLivenessBound(seconds: 4))
        let hello = IpcHello.params(
            protocolVersion: 1,
            appVersion: "9.4.1",
            livenessBound: advertised
        )

        #expect(IpcLivenessBound.read(from: hello) == advertised)
        #expect(hello["protocol"] == .number(1))
        #expect(hello["app"] == .string("9.4.1"))
    }

    @Test("a frame without a readable bound advertises nothing", arguments: [
        JSONValue.object([:]),
        .object(["silenceSeconds": .string("30")]),
        .object(["silenceSeconds": .number(0)]),
        .null,
    ])
    func unreadableBoundIsAbsent(_ params: JSONValue) {
        #expect(IpcLivenessBound.read(from: params) == nil)
    }

    @Test("only the capacity refusal carries the server's reclamation bound")
    func capacityRefusalCarriesTheBound() throws {
        // Intent: the refusal that names an exhausted slot states the server's current
        //   bound, every other refusal states none, and each still reads back as itself.
        // Why it exists: the bound is the deadline by which the refusing server has
        //   provably reclaimed a dead peer's slot, so it is the earliest a retry can
        //   help -- and only that server knows today's number. A client that guessed it
        //   would compete for the very resource the refusal named. Carrying it on a
        //   refusal the bound does not govern would invite an equally pointless wait.
        let advertised = try #require(IpcLivenessBound(seconds: 7))

        for reason in IpcConnectionRejectionReason.allCases {
            let notification = reason.notification(livenessBound: advertised)

            #expect(IpcConnectionRejectionReason(notification: notification) == reason)
            #expect(
                IpcLivenessBound.read(from: notification.params)
                    == (reason == .connectionLimit ? advertised : nil)
            )
        }
    }

    @Test("ping is an ordinary request method with no target and no local-caller rule")
    func pingIsAnOrdinaryRemoteMethod() throws {
        // Intent: ping decodes through the same catalog as every other method, so
        //   the exhaustive classification switches force its decisions.
        // Why it exists: I3 -- a pong must prove that dispatch is servicing requests.
        //   A ping answered by a shortcut below dispatch would report a starved Mac
        //   as alive.
        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.ping.rawValue,
            params: .object([:])
        ) == .ping)
        #expect(IpcRequest.ping.params.isEmpty)
        #expect(IpcRequest.ping.targetParameterKeys.isEmpty)
        #expect(IpcRequestMethod.ping.isTargeting == false)
        #expect(IpcRequestMethod.ping.requiresLocalCaller == false)
        #expect(IpcRequestMethod.ping.terminatesInstance == false)
    }

    @Test("ping is the only method that produces no per-request audit record")
    func pingIsTheOnlyUnauditedMethod() {
        // Intent: every catalog method declares whether it earns a durable record.
        // Why it exists: a ping exercises no authority and names no target, and one
        //   every half-bound would evict the events the log exists for. A future
        //   method must not inherit that exemption silently.
        let unaudited = IpcRequestMethod.allCases.filter { $0.producesAuditRecord == false }

        #expect(unaudited == [.ping])
    }
}
