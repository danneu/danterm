// Tests for DanTerm control-socket path resolution.
import Foundation
import XCTest
@testable import DanTermProtocol

final class SocketPathTests: XCTestCase {
    func testControlSocketPathUsesCachesBundleDirectory() {
        let path = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        ).path
        XCTAssertTrue(path.hasSuffix("/Library/Caches/com.example.one/control.sock"))
    }

    func testDistinctBundleIdsProduceDistinctPaths() {
        let first = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        )
        let second = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.two")
        )
        XCTAssertNotEqual(first, second)
    }
}
