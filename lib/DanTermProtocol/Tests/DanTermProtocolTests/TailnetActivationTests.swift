// Behavioral proofs for the one rule that turns config plus identity into this
// instance's tailnet endpoint, and for the frozen shape of its status object.
import Testing

@testable import DanTermProtocol

struct TailnetActivationTests {
    private static let base = "100.100.1.2:7777"

    private static func config(
        listen: String = base,
        admitted: [String] = ["node-abc"]
    ) -> DanTermTailnetConfig {
        DanTermTailnetConfig(listen: listen, admittedNodeIds: admitted)
    }

    @Test("the port offset table is fixed per identity")
    func portOffsetTableIsFixedPerIdentity() throws {
        // Intent: the offset an identity contributes to the base port is a constant
        //   table, not a search.
        // Why it exists: the phone saves one endpoint per instance forever, so an
        //   offset that moves silently breaks every saved target.
        // Scenario: production, both ends of the development pool, and a bundle
        //   identifier outside the scheme.
        #expect(DanTermInstanceIdentity.production.tailnetPortOffset == 0)
        #expect(try #require(DanTermInstanceIdentity(developmentSlot: 0)).tailnetPortOffset == 1)
        #expect(try #require(DanTermInstanceIdentity(developmentSlot: 8)).tailnetPortOffset == 9)
        let harness = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-tests")
        #expect(harness.tailnetPortOffset == nil)
    }

    @Test("an activated instance binds the base address at the base port plus its offset")
    func activatedInstanceBindsBasePortPlusOffset() throws {
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 3))

        let activation = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: slot,
            optedIn: true
        )

        let endpoint = try #require(activation.endpoint)
        #expect(endpoint.base == Self.base)
        #expect(endpoint.offset == 4)
        #expect(endpoint.address == "100.100.1.2")
        #expect(endpoint.port == 7781)
        #expect(endpoint.text == "100.100.1.2:7781")
    }

    @Test("production and the canonical dev app activate without being asked")
    func productionAndCanonicalDevActivateWithoutOptIn() throws {
        let devSlotZero = try #require(DanTermInstanceIdentity(developmentSlot: 0))

        let production = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: .production,
            optedIn: false
        )
        let development = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: devSlotZero,
            optedIn: false
        )

        #expect(production.endpoint?.text == "100.100.1.2:7777")
        #expect(development.endpoint?.text == "100.100.1.2:7778")
    }

    @Test("a pool slot stays closed until it is launched with the flag")
    func poolSlotStaysClosedWithoutOptIn() throws {
        // Intent: a launcher pool slot ignores the shared config's tailnet block
        //   unless the launch asked for it.
        // Why it exists: eight agents share the pool and the config, so every slot
        //   opening a socket by default is eight unwanted listeners per machine.
        // Scenario: the same config and slot, launched each way.
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 5))

        let closed = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: slot,
            optedIn: false
        )
        let opened = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: slot,
            optedIn: true
        )

        #expect(closed == .disabled(reason: "this slot was launched without --tailnet"))
        #expect(opened.endpoint?.text == "100.100.1.2:7783")
    }

    @Test("every closed activation names a distinct reason")
    func everyClosedActivationNamesADistinctReason() throws {
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 1))
        let harness = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-tests")

        let unconfigured = DanTermTailnetActivation.resolve(
            config: nil,
            identity: .production,
            optedIn: true
        )
        let noAdmittedNodes = DanTermTailnetActivation.resolve(
            config: Self.config(admitted: []),
            identity: .production,
            optedIn: true
        )
        let noOffset = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: harness,
            optedIn: true
        )
        let malformed = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2"),
            identity: .production,
            optedIn: true
        )
        let overflow = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2:65535"),
            identity: slot,
            optedIn: true
        )

        #expect(unconfigured == .disabled(reason: "no tailnet endpoint is configured"))
        #expect(noAdmittedNodes == .disabled(reason: "no admitted node ids are configured"))
        #expect(noOffset == .disabled(reason: "this instance has no tailnet port offset"))
        #expect(malformed == .disabled(
            reason: "configured listen `100.100.1.2` is not an address and port"
        ))
        #expect(overflow == .disabled(
            reason: "port 65535 plus offset 2 exceeds the maximum port 65535"
        ))
    }

    @Test("a zero base port is malformed rather than a wildcard bind")
    func zeroBasePortIsMalformed() {
        let activation = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2:0"),
            identity: .production,
            optedIn: true
        )

        #expect(activation == .disabled(
            reason: "configured listen `100.100.1.2:0` is not an address and port"
        ))
    }

    @Test("each status state serializes to its frozen object")
    func eachStatusStateSerializesToItsFrozenObject() throws {
        // Intent: the JSON of each state carries exactly the documented keys.
        // Why it exists: this object is the external surface of `tailnet.status`,
        //   the CLI subcommand, and the slot launch handle, so an added or null
        //   field is a break for every reader.
        // Scenario: the three states an instance can report.
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 2))
        let endpoint = try #require(
            DanTermTailnetActivation.resolve(
                config: Self.config(),
                identity: slot,
                optedIn: true
            ).endpoint
        )

        #expect(DanTermTailnetStatus.disabled(reason: "closed").json == .object([
            "state": .string("disabled"),
            "reason": .string("closed"),
        ]))
        #expect(DanTermTailnetStatus.waiting(endpoint: endpoint, reason: "no route").json == .object([
            "state": .string("waiting"),
            "base": .string("100.100.1.2:7777"),
            "offset": .number(3),
            "endpoint": .string("100.100.1.2:7780"),
            "reason": .string("no route"),
        ]))
        #expect(DanTermTailnetStatus.listening(endpoint: endpoint).json == .object([
            "state": .string("listening"),
            "base": .string("100.100.1.2:7777"),
            "offset": .number(3),
            "endpoint": .string("100.100.1.2:7780"),
        ]))
    }
}
