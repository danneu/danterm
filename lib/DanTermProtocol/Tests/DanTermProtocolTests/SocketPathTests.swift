// Tests for DanTerm control-socket path resolution.
import Foundation
import Testing
@testable import DanTermProtocol

struct SocketPathTests {
    @Test("control socket path uses caches bundle directory")
    func controlSocketPathUsesCachesBundleDirectory() {
        let path = userControlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        ).path
        #expect(path.hasSuffix("/Library/Caches/com.example.one/control.sock"))
    }

    @Test("distinct bundle IDs produce distinct paths")
    func distinctBundleIdsProduceDistinctPaths() {
        let first = userControlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        )
        let second = userControlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.two")
        )
        #expect(first != second)
    }

    // Intent: the explicit-roots layout is the only source of the socket path.
    // Why it exists: the app composes the socket from its own launch-resolved
    // caches root while bare executables use the user-caches convenience; a
    // second layout in either would silently split the app and the CLI apart.
    // Scenario: compose the layout against the real caches root and compare it
    // to the convenience the CLI calls.
    @Test("user convenience equals the layout composed on the real caches root")
    func userConvenienceEqualsComposedLayout() {
        let identity = DanTermInstanceIdentity(bundleIdentifier: "com.example.one")
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #expect(
            userControlSocketPath(identity: identity)
                == controlSocketPath(identity: identity, cachesRoot: cachesRoot)
        )
    }

    @Test("control socket path derives from the given caches root")
    func controlSocketPathDerivesFromGivenCachesRoot() {
        let path = controlSocketPath(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.example.one"),
            cachesRoot: URL(fileURLWithPath: "/private/tmp/roots/caches", isDirectory: true)
        ).path
        #expect(path == "/private/tmp/roots/caches/com.example.one/control.sock")
    }
}
