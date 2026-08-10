// Tests for DanTerm control-socket path resolution.
import Foundation
import Testing
@testable import DanTermProtocol

struct SocketPathTests {
    @Test("control socket path uses caches bundle directory")
    func controlSocketPathUsesCachesBundleDirectory() {
        let path = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        ).path
        #expect(path.hasSuffix("/Library/Caches/com.example.one/control.sock"))
    }

    @Test("distinct bundle IDs produce distinct paths")
    func distinctBundleIdsProduceDistinctPaths() {
        let first = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        )
        let second = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.two")
        )
        #expect(first != second)
    }
}
