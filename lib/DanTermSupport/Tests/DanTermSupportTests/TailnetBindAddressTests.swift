// Swift Testing coverage for the closed-by-default tailnet bind-address gate.
import Testing

@testable import DanTermSupport

struct TailnetBindAddressTests {
    @Test("only a locally carried address in 100.64.0.0/10 resolves", arguments: [
        ("100.64.0.1:7420", true),
        ("100.127.255.254:1", true),
        ("100.128.0.1:7420", false),
        ("100.63.255.255:7420", false),
        ("0.0.0.0:7420", false),
        ("*:7420", false),
        ("100.64.0.1:0", false),
        ("100.64.0.1:65536", false),
        ("not-an-address", false),
    ])
    func resolvesOnlyCarriedTailnetAddresses(value: String, accepted: Bool) {
        let interfaces = [
            TailnetInterface(name: "utun7", ipv4Address: "100.64.0.1"),
            TailnetInterface(name: "utun8", ipv4Address: "100.127.255.254"),
        ]

        if accepted {
            do {
                let address = try TailnetBindAddress.resolve(value, interfaces: interfaces)
                #expect(address.interfaceName.hasPrefix("utun"))
            } catch {
                Issue.record("expected \(value) to resolve, got \(error)")
            }
        } else {
            #expect(throws: TailnetBindAddress.Rejection.self) {
                try TailnetBindAddress.resolve(value, interfaces: interfaces)
            }
        }
    }

    @Test("a tailnet address absent from local interfaces is refused")
    func nonlocalTailnetAddressIsRefused() {
        let error = #expect(throws: TailnetBindAddress.Rejection.self) {
            try TailnetBindAddress.resolve(
                "100.99.4.2:7420",
                interfaces: [TailnetInterface(name: "utun7", ipv4Address: "100.99.4.1")]
            )
        }

        #expect(error == .notLocal("100.99.4.2"))
    }
}
