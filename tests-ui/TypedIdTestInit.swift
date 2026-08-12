// Test-only no-arg `TypedId` init for the AppKit UI harness. The pure core removed
// `TypedId.init()` in Phase 5 (off-seam id minting is now a compile error), but the
// UI fixtures mint throwaway ids by the dozen -- `SplitId()`, `GroupId()`,
// `TabId()`, `PaneId()` -- where the value is irrelevant. This harness shares no
// module with `DanTermCoreTests`, so it carries its own copy of the same shim (see
// `lib/DanTermCore/Tests/DanTermCoreTests/TypedIdTestInit.swift`); the harness is
// impure test code, so nondeterministic fixture ids are fine here.
import Foundation

extension TypedId {
    init() { self.init(rawValue: UUID()) }
}

extension TodoItem {
    init(id: UUID, text: String, isDone: Bool) {
        self.init(id: TodoId(rawValue: id), text: text, isDone: isDone)
    }
}
