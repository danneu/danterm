// Placeholder test so DanTermSupportTests compiles and `swift test --package-path
// lib/DanTermSupport` passes before the real suites (DebouncerTests,
// CLIPathInstallerTests, RecoveryStoreTests) move in at Phases 3-4. Delete once a real
// suite lands (plan Phase 3). Also proves the module links via `@testable import`.
import Testing
@testable import DanTermSupport

@Suite struct PlaceholderTests {
    @Test("DanTermSupport module links")
    func moduleLinks() {
        _ = DanTermSupportModulePlaceholder.self
    }
}
