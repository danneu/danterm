// Behavioral coverage for fixed development identities and bundle-declared capabilities.
import Foundation
import XCTest
@testable import DanTermProtocol

final class InstanceIdentityTests: XCTestCase {
    func testDevelopmentSlotsHaveStableDistinctIdentities() throws {
        let slot0 = try XCTUnwrap(DanTermInstanceIdentity(developmentSlot: 0))
        let slot3 = try XCTUnwrap(DanTermInstanceIdentity(developmentSlot: 3))

        XCTAssertEqual(slot0.bundleIdentifier, "com.danneu.danterm-dev")
        XCTAssertEqual(slot0.displayName, "DanTerm Dev")
        XCTAssertEqual(slot0.executableName, "DanTerm Dev")
        XCTAssertEqual(slot3.bundleIdentifier, "com.danneu.danterm-dev.3")
        XCTAssertEqual(slot3.displayName, "DanTerm Dev (3)")
        XCTAssertEqual(slot3.executableName, "DanTerm Dev (3)")
        XCTAssertNotEqual(slot0.bundleIdentifier, slot3.bundleIdentifier)
    }

    func testDevelopmentIdentityRejectsSlotsOutsideTheFixedPool() {
        XCTAssertNil(DanTermInstanceIdentity(developmentSlot: -1))
        XCTAssertNil(DanTermInstanceIdentity(developmentSlot: 9))
    }

    func testBundleIdentityPreservesUnrecognizedIdentifiers() {
        let identity = DanTermInstanceIdentity(bundleIdentifier: "com.example.characterization")
        let noncanonicalSlot = DanTermInstanceIdentity(
            bundleIdentifier: "com.danneu.danterm-dev.03"
        )

        XCTAssertEqual(identity.bundleIdentifier, "com.example.characterization")
        XCTAssertNil(identity.developmentSlot)
        XCTAssertNil(noncanonicalSlot.developmentSlot)
    }

    func testFlightTapeCapabilityRequiresExplicitTrueDeclaration() {
        // Intent: flight-tape recording follows the bundle capability instead of
        //   recognizing one hard-coded development bundle identifier.
        // Why it exists: every pooled development identity must retain `pane tape`,
        //   while production and bundles without the declaration remain opted out.
        // Scenario: canonical and slot clones carry true; production declares false;
        //   an older or purpose-built bundle omits the key entirely.
        XCTAssertTrue(DanTermBundleCapabilities.recordsFlightTape(
            infoDictionary: [DanTermBundleCapabilities.recordsFlightTapeKey: true]
        ))
        XCTAssertFalse(DanTermBundleCapabilities.recordsFlightTape(
            infoDictionary: [DanTermBundleCapabilities.recordsFlightTapeKey: false]
        ))
        XCTAssertFalse(DanTermBundleCapabilities.recordsFlightTape(infoDictionary: nil))
    }
}
