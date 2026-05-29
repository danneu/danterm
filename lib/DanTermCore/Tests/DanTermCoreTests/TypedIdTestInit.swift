// Test-only no-arg `TypedId` init. The pure core deliberately removed
// `TypedId.init()` in the determinism seam (Phase 5) so that off-seam id minting
// is a compile error -- production ids now come only from `env.newId()` or an
// explicit `rawValue:`. Fixtures, however, mint throwaway ids by the hundreds
// (`GroupId()`, `PaneId()`, ...) where the specific value is irrelevant; this
// shim restores that convenience for tests alone, keeping every fixture call site
// unchanged without reopening the no-arg mint in shipping core.
import Foundation

@testable import DanTermCore

extension TypedId {
    init() { self.init(rawValue: UUID()) }
}
