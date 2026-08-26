// Behavioral coverage for fixed development identities and bundle-declared capabilities.
import Foundation
import Testing
@testable import DanTermProtocol

struct InstanceIdentityTests {
    @Test("development slots have stable distinct identities")
    func developmentSlotsHaveStableDistinctIdentities() throws {
        let slot0 = try #require(DanTermInstanceIdentity(developmentSlot: 0))
        let slot3 = try #require(DanTermInstanceIdentity(developmentSlot: 3))

        #expect(slot0.bundleIdentifier == "com.danneu.danterm-dev")
        #expect(slot0.displayName == "DanTerm Dev")
        #expect(slot0.executableName == "DanTerm Dev")
        #expect(slot3.bundleIdentifier == "com.danneu.danterm-dev.3")
        #expect(slot3.displayName == "DanTerm Dev (3)")
        #expect(slot3.executableName == "DanTerm Dev (3)")
        #expect(slot0.bundleIdentifier != slot3.bundleIdentifier)
    }

    @Test("development identity rejects slots outside the fixed pool")
    func developmentIdentityRejectsSlotsOutsideTheFixedPool() {
        #expect(DanTermInstanceIdentity(developmentSlot: -1) == nil)
        #expect(DanTermInstanceIdentity(developmentSlot: 9) == nil)
    }

    @Test("only launcher-claimed slots count as pool instances")
    func onlyLauncherClaimedSlotsCountAsPoolInstances() throws {
        // Intent: `isLauncherPoolSlot` admits slots 1 through 8 and nothing else.
        // Why it exists: it is the allowlist that decides whether an instance may
        //   be quit over IPC, so production, the canonical dev app, and any
        //   identifier outside the scheme must all fall outside it.
        // Scenario: the production bundle identifier by name, slot 0, every
        //   claimable slot, and two identifiers the scheme does not recognize.
        let production = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm")
        #expect(production.isLauncherPoolSlot == false)
        #expect(try #require(DanTermInstanceIdentity(developmentSlot: 0)).isLauncherPoolSlot == false)
        for slot in 1...8 {
            #expect(try #require(DanTermInstanceIdentity(developmentSlot: slot)).isLauncherPoolSlot)
        }
        #expect(DanTermInstanceIdentity(bundleIdentifier: "com.example.harness").isLauncherPoolSlot == false)
        #expect(DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-dev.9").isLauncherPoolSlot == false)
    }

    @Test("bundle identity preserves unrecognized identifiers")
    func bundleIdentityPreservesUnrecognizedIdentifiers() {
        let identity = DanTermInstanceIdentity(bundleIdentifier: "com.example.characterization")
        let noncanonicalSlot = DanTermInstanceIdentity(
            bundleIdentifier: "com.danneu.danterm-dev.03"
        )

        #expect(identity.bundleIdentifier == "com.example.characterization")
        #expect(identity.developmentSlot == nil)
        #expect(noncanonicalSlot.developmentSlot == nil)
    }

    @Test("every slot names its own icon so running slots differ in the switcher")
    func everySlotNamesItsOwnIcon() throws {
        // Intent: `iconName` gives production, the canonical dev app, and each
        //   claimable slot a distinct asset-catalog icon name.
        // Why it exists: the Dock and the Cmd-Tab switcher show the icon, so
        //   eight slots sharing one icon cannot be told apart. The name is
        //   derived here rather than spelled out by the bundle producer or the
        //   slot launcher, so those two cannot disagree.
        // Scenario: production by identifier, slot 0, all eight claimable slots,
        //   and one identifier outside the scheme.
        #expect(DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm").iconName == "AppIcon")
        #expect(try #require(DanTermInstanceIdentity(developmentSlot: 0)).iconName == "AppIcon-dev")
        var names: Set<String> = []
        for slot in 1...8 {
            let name = try #require(DanTermInstanceIdentity(developmentSlot: slot)).iconName
            #expect(name == "AppIcon-dev-\(slot)")
            names.insert(try #require(name))
        }
        #expect(names.count == 8)
        #expect(DanTermInstanceIdentity(bundleIdentifier: "com.example.harness").iconName == nil)
    }
}
