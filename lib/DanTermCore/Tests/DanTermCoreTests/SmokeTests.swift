// Scaffold smoke test for the DanTermCore nested test package. Proves that the
// package compiles, links swift-custom-dump, and that `@testable import
// DanTermCore` reaches `internal` core symbols. Lives in Commit 1 only as a
// placeholder so `swift test --package-path lib/DanTermCore` has something green
// to run before the real suites land; Commit 2 replaces it with TestSupport.swift
// + the first migrated suite (ScrollbarMathTests).
import CustomDump
import Testing

@testable import DanTermCore

@Suite struct SmokeTests {
    @Test func debouncerStartsIdle() {
        // Intent: a freshly constructed Debouncer reports no pending fire.
        // Why it exists: gives the nested package a green @Test to run while the
        //   real suites migrate in Phase 2, so the local `just test` gate that
        //   runs `swift test --package-path lib/DanTermCore` is never bare-empty.
        // Scenario: spec-first scaffold check -- exercises an internal core
        //   symbol to prove `@testable import DanTermCore` resolves and
        //   swift-custom-dump's `expectNoDifference` is wired up.
        let debouncer = Debouncer(queue: .main)
        expectNoDifference(debouncer.isPending, false)
    }
}
