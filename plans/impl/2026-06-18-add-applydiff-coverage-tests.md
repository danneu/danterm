# Add two coverage-gap tests for `applyDiff`

## Context

`applyDiff` is the generic diff/apply/prune primitive backing every keyed
reconcile pass in the view reconciler. It has three existing unit tests, but
each one feeds the function a *delta* (a changed key, a new key, or a
disappeared key) and exercises only one facet in isolation. Two real,
behavioral coverage gaps remain:

1. **Steady state (no delta).** When `desired` exactly equals `cache` -- the
   overwhelmingly common reconcile-sweep case where nothing changed -- nothing
   currently asserts that neither `apply` nor `remove` fires and the cache is
   left untouched. This is the single most-executed input to the primitive and
   the one branch none of the existing tests reach.

2. **Combined delta in one pass (change + add + drop together).** The existing
   tests never feed change, new, and disappearance in a single call. That is
   the realistic single-sweep shape, and it is the only case where the two
   internal loops *interact*: a brand-new key written into the cache by the
   apply loop then flows into the disappeared-collection loop and must **not**
   be treated as "disappeared." A regression that spuriously pruned a
   freshly-applied key would pass all three current tests.

This change adds exactly those two tests. It is **test-only**: no production
code changes. Both tests are characterization tests -- they pass against the
current `applyDiff` unchanged. Their job is to close the coverage gaps and lock
the apply/remove/prune contract (so any future refactor of `applyDiff` trips a
wire), not to drive a code change. They are pure, fast, and structure-
insensitive: they assert only observable `apply`/`remove` calls (which keys,
and how many times) and the final cache value -- never allocations, dictionary
identity, or internals.

## Function under test (for reference -- do not modify)

`lib/DanTermCore/Sources/DanTermCore/Projections.swift`, function `applyDiff`
(~lines 300-307). Current body:

```swift
func applyDiff<K: Hashable, V: Equatable>(
  _ desired: [K: V], _ cache: inout [K: V],
  apply: (K, V) -> Void, remove: (K) -> Void = { _ in }
) {
  for (k, v) in desired where cache[k] != v { apply(k, v); cache[k] = v }
  for k in cache.keys where desired[k] == nil { remove(k) }   // teardown disappeared keys
  cache = cache.filter { desired[$0.key] != nil }
}
```

Leave this function untouched.

### Existing coverage (stays green, unchanged)

All three live in the `// MARK: - applyDiff` section of the test file below:

- `applyDiffAppliesOnlyChangedOrNewKeys` -- change + new key, no removal.
- `applyDiffInvokesRemoveAndPrunes` -- one disappeared key: remove fires once,
  then prune.
- `applyDiffDefaultNoOpRemoveStillPrunes` -- disappeared key with the default
  no-op remove closure still prunes.

## The exact edit

File: `lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift`
Suite: `@Suite struct ReconcileTests` (imports already present: `Foundation`,
`Testing`, `@testable import DanTermCore`; `applyDiff` is reachable directly,
no module prefix -- the existing tests call it that way).

Insert both `@Test` methods into the `// MARK: - applyDiff` section,
immediately after `applyDiffDefaultNoOpRemoveStillPrunes()` and before the next
`// MARK: - Command.isPostReconcile` section. The `// Intent / Why it exists /
Scenario` preambles follow the repo's test-preamble convention and are part of
the code to paste.

### Test 1 -- steady-state no-op

```swift
@Test("applyDiff in steady state invokes neither apply nor remove and leaves the cache unchanged")
func applyDiffSteadyStateIsNoOp() {
    // Intent: when desired's keys and values equal the cache's, applyDiff
    //   invokes neither apply nor remove and leaves the cache unchanged.
    // Why it exists: pins the idempotent steady-state path -- the
    //   overwhelmingly common sweep case where no key changed or disappeared,
    //   and the one branch none of the existing tests reach (each feeds a delta).
    // Scenario: spec-first steady-state diff (no delta between desired and cache).
    var cache: [String: Int] = ["a": 1, "b": 2]
    var applied: [String] = []
    var removed: [String] = []
    let desired: [String: Int] = ["a": 1, "b": 2]
    applyDiff(desired, &cache,
        apply: { k, _ in applied.append(k) },
        remove: { k in removed.append(k) })

    #expect(applied.isEmpty, "no key changed or is new, so nothing applies")
    #expect(removed.isEmpty, "no key disappeared, so nothing is removed")
    #expect(cache == desired, "the cache is unchanged and still equals desired")
}
```

### Test 2 -- combined delta in one pass

```swift
@Test("applyDiff in one pass applies the changed and new keys, removes only the dropped key, and ends equal to desired")
func applyDiffCombinedDeltaInOnePass() {
    // Intent: a single call that changes a key, adds a key, and drops a key
    //   applies the changed+new keys, removes only the dropped key exactly once,
    //   and ends with cache == desired.
    // Why it exists: pins that the apply loop and the remove/prune loop compose --
    //   a key the apply loop adds (c) must not then be seen as "disappeared," and
    //   removing the dropped key (b) must not disturb the surviving (a) or new (c)
    //   keys. The three existing tests each exercise change/new/remove in isolation,
    //   so this interaction -- the realistic single-sweep shape, and the property
    //   any two-loop refactor is most likely to break -- is currently uncovered.
    // Scenario: spec-first combined diff (change + add + drop in one pass).
    var cache: [String: Int] = ["a": 1, "b": 2]
    var applied: [String] = []
    var removed: [String] = []
    let desired: [String: Int] = ["a": 9, "c": 3]
    applyDiff(desired, &cache,
        apply: { k, _ in applied.append(k) },
        remove: { k in removed.append(k) })

    #expect(Set(applied) == Set(["a", "c"]), "the changed key (a) and new key (c) apply")
    #expect(applied.count == 2, "each applies exactly once -- no key is applied twice")
    #expect(removed == ["b"], "only the dropped key (b) is removed, exactly once")
    #expect(cache == desired, "cache ends equal to desired -- c was not spuriously pruned")
}
```

## Out of scope / do not add

- **No production code change.** Do not touch `applyDiff` in `Projections.swift`
  or any other source file. This is purely additive test coverage.
- **No empty-`desired` test.** "Tear down every key" is just N independent
  repetitions of the already-covered `applyDiffInvokesRemoveAndPrunes` behavior;
  `applyDiff` has no emptiness special-case, so it adds no distinct branch.
- **No struct-valued `V` variant.** `applyDiff` is generic over `V: Equatable`
  and only ever uses `!=`; the `Int`-valued tests already exercise that one
  operation, so a `PaneConfigKey`-valued copy catches nothing new and only
  couples the test to a type.
- These are characterization tests, not red-green TDD steps: they pass against
  the current code and will not fail if reverted. Do not try to make them fail
  first.

## Verification

Fast loop (asserts both new tests pass and the three existing ones stay green):

```
swift test --package-path lib/DanTermCore --filter ReconcileTests
```

Expected: all `applyDiff` tests pass -- the two new ones
(`applyDiffSteadyStateIsNoOp`, `applyDiffCombinedDeltaInOnePass`) plus the three
existing ones.

Full local gate before commit:

```
just test
```

(protocol XCTest + core Swift Testing + DanTermSupport Swift Testing +
core-purity lint + the shell self-tests.)
