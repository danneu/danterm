// Fixture coverage for turning a Tailscale peer address into stable caller facts.
import Foundation
import Testing

@testable import DanTermSupport

struct TailnetWhoisResolverTests {
    @Test("the recorded whois shape yields stable node, user, and machine facts")
    func recordedFixtureParses() throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "tailscale-whois",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: fixtureURL)

        let identity = try TailnetWhoisResolver.parse(data)

        #expect(identity == TailnetPeerIdentity(
            nodeId: "nYLVaWdKL811CNTRL",
            user: "owner@example.com",
            machineName: "iphone-13-mini.tail11347d.ts.net"
        ))
    }

    @Test("the resolver passes the accepted peer host to its injected query")
    func resolverUsesInjectedQuery() throws {
        let expected = TailnetPeerIdentity(nodeId: "node", user: "user", machineName: "machine")
        let resolver = TailnetWhoisResolver { host in
            #expect(host == "100.98.63.67")
            return expected
        }

        #expect(try resolver.resolve(peerHost: "100.98.63.67") == expected)
    }

    @Test("missing stable identity fields fail closed")
    func missingFieldsAreRejected() {
        #expect(throws: TailnetWhoisResolver.Error.self) {
            try TailnetWhoisResolver.parse(Data("{\"Node\":{}}".utf8))
        }
    }
}
