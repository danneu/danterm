// Behavioral proofs for the one rule that turns config plus identity into this
// instance's tailnet endpoint, and for the frozen shape of its status object.
import Testing

@testable import DanTermProtocol

struct TailnetActivationTests {
    private static let base = "100.100.1.2:7777"

    private static func config(
        listen: String = base,
        admitted: [String] = ["node-abc"],
        enable: Bool = true
    ) -> DanTermTailnetConfig {
        DanTermTailnetConfig(listen: listen, admittedNodeIds: admitted, enable: enable)
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
            identity: slot
        )

        let endpoint = try #require(activation.endpoint)
        #expect(endpoint.base == Self.base)
        #expect(endpoint.offset == 4)
        #expect(endpoint.address == "100.100.1.2")
        #expect(endpoint.port == 7781)
        #expect(endpoint.text == "100.100.1.2:7781")
    }

    @Test("production and the canonical dev app activate from the config alone")
    func productionAndCanonicalDevActivateFromConfigAlone() throws {
        let devSlotZero = try #require(DanTermInstanceIdentity(developmentSlot: 0))

        let production = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: .production
        )
        let development = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: devSlotZero
        )

        #expect(production.endpoint?.text == "100.100.1.2:7777")
        #expect(development.endpoint?.text == "100.100.1.2:7778")
    }

    @Test("a pool slot activates on the endpoint its own config names")
    func poolSlotActivatesFromItsOwnConfig() throws {
        // Intent: being a launcher pool slot is not a refusal reason. A slot whose
        //   config names a usable endpoint opens its listener; one whose config names
        //   none stays closed for that reason alone.
        // Why it exists: the slot gate existed only because every instance read one
        //   shared config file. Each slot now owns its config, so the config it was
        //   given is the whole answer.
        // Scenario: slot 5, launched once against a seeded config and once against a
        //   config with no tailnet block.
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 5))

        let seeded = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: slot
        )
        let unseeded = DanTermTailnetActivation.resolve(
            config: nil,
            identity: slot
        )

        #expect(seeded.endpoint?.text == "100.100.1.2:7783")
        #expect(unseeded == .disabled(reason: "no tailnet endpoint is configured"))
    }

    @Test("every closed activation names a distinct reason")
    func everyClosedActivationNamesADistinctReason() throws {
        let slot = try #require(DanTermInstanceIdentity(developmentSlot: 1))
        let harness = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-tests")

        let unconfigured = DanTermTailnetActivation.resolve(
            config: nil,
            identity: .production
        )
        let noAdmittedNodes = DanTermTailnetActivation.resolve(
            config: Self.config(admitted: []),
            identity: .production
        )
        let noOffset = DanTermTailnetActivation.resolve(
            config: Self.config(),
            identity: harness
        )
        let malformed = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2"),
            identity: .production
        )
        let overflow = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2:65535"),
            identity: slot
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

    @Test("the enable flag parks an intact config without deleting it")
    func enableFlagParksAnIntactConfig() throws {
        // Intent: `enable = false` closes the listener with its own reason, while an
        //   absent flag and an explicit true both activate the same endpoint.
        // Why it exists: the only off switch used to be deleting the whole tailnet
        //   object, which threw away the listen address and the admitted node ids.
        // Scenario: the user parks the tailnet block instead of deleting it.
        let parked = DanTermTailnetActivation.resolve(
            config: Self.config(enable: false),
            identity: .production
        )
        let enabled = DanTermTailnetActivation.resolve(
            config: Self.config(enable: true),
            identity: .production
        )
        let absent = DanTermTailnetActivation.resolve(
            config: DanTermTailnetConfig(listen: Self.base, admittedNodeIds: ["node-abc"]),
            identity: .production
        )

        #expect(parked == .disabled(reason: "the config sets `tailnet.enable` to false"))
        #expect(parked != .disabled(reason: "no tailnet endpoint is configured"))
        #expect(enabled.endpoint?.text == "100.100.1.2:7777")
        #expect(absent.endpoint?.text == "100.100.1.2:7777")
    }

    @Test("a zero base port is malformed rather than a wildcard bind")
    func zeroBasePortIsMalformed() {
        let activation = DanTermTailnetActivation.resolve(
            config: Self.config(listen: "100.100.1.2:0"),
            identity: .production
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
                identity: slot
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
