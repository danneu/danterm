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
}
