# Centralize disposable build-tree ownership

## Problem

Persistent gate trees use several sibling names. `just clean` and its test
already miss the iOS trees, so cleanup depends on an incomplete inventory.

Give the gate one `.build-gate/` root. Keep SwiftPM's default `.build/` trees
and the app build's `.spm-build/` root separate. Move the iOS app bundle below
`.spm-build/`. This fixes cleanup ownership without taking on the blocked
cache-sharing refactor.

## Decision and invariants

- One shared repository-root derivation owns the absolute `.build-gate/` path.
  Gate steps and helpers use it whether the helper runs inside the gate or by
  hand.
- Separate lanes continue to use separate trees. This refactor does not share
  caches or change compilation signatures.
- `just clean` removes exact directories named `.build`, `.spm-build`, and
  `.build-gate` at any depth in the checkout.
- The cleaner prunes `.git`, `references`, `.refs`, `.cmux-ref`, and
  `.cmux-src`. `.build-not-a-tree` and every build tree below those roots
  survive cleanup.
- All current special gate caches move under `.build-gate/`, including the
  type-check, app-test, iOS portability, bundle-layout, and capture-gate trees.
- Gate-adjacent iOS research build trees and their default logs move under a
  research descendant of `.build-gate/`; live executable consumers follow the
  same location. Completed research records preserve the paths used by the
  recorded run and may note the new rerun location separately.
- The iOS app runner writes its assembled product below
  `.spm-build/ios-app/<target>`, beside the macOS app build's output and outside
  SwiftPM's default scratch namespace.
- Remove obsolete `.build-*` ignore and cleanup entries after their writers
  move. Do not retain compatibility aliases for old cache paths.

## Implementation changes

- Give scripts one shared function that derives the absolute gate root from the
  repository. Do not add an environment override or a runner-only path source.
- Preserve lane isolation by assigning one descendant per purpose and, for iOS
  portability, per package. Exact descendant names are implementation detail.
- Add one executable build-path policy check. It collects every persistent path
  declared by gate steps and their path-owning helpers. Explicit gate paths must
  sit below `.build-gate/`; `.build` is allowed only as SwiftPM's implicit
  package default. The check rejects duplicate gate paths across lanes and
  permits throwaway paths.
- Simplify `just-clean_test.sh` to prove the cleaner's behavior against the
  sanctioned roots instead of maintaining a second producer inventory.
- Update comments and build documentation that name old paths or claim that
  name matching automatically covers new scratch paths.
- Delete existing obsolete cache directories once during implementation. They
  are disposable and will no longer be recognized by the final cleanup recipe.

## Proof obligations

- **PO1 -- Complete cleanup.** Persistent trees produced by the gate, nested
  package defaults at any checkout depth, the iOS app runner, and the app build
  are absent after `just clean`.
- **PO2 -- Negative boundary.** The existing `.build-not-a-tree` sentinel and a
  `.build` sentinel in each pruned external-checkout class survive unchanged.
- **PO3 -- Sanctioned roots.** An executable policy check covers the gate step
  declarations and every helper through which those steps choose a persistent
  build path. It fails when an explicit persistent gate path sits outside
  `.build-gate/`, including beneath the root package's `.build/`; implicit
  package defaults and throwaway paths remain allowed.
- **PO4 -- Isolation.** The same collection fails when two distinct gate lanes
  resolve to the same persistent build path. This includes the type-check
  budget tree, which no other lane may warm.
- **PO5 -- Existing behavior.** The iOS portability gate still compiles every
  pinned package, the iOS app still assembles the same bundle, the type-check
  gate retains its private measurement tree, cache-backed gates remain warm
  between runs, and the iOS research recipes still place every build product,
  log, and live executable consumer under one ignored disposable root without
  rewriting the artifact paths recorded by completed investigations.
- Run the affected shell contract tests and `just lint` during TDD, then run
  `just test` as the pre-commit gate.

## Boundaries and coordination

- Cache sharing and one-build-tree-per-triple are non-goals. Rebase that draft
  after this work and treat `.build-gate/` as the fixed ownership root whose
  children it may consolidate after its SwiftPM invalidation probe passes.
- BUILD-2 and BUILD-4 have no behavioral dependency, but both may edit
  `scripts/run-test-suite.sh`; land or rebase them separately.
- No CLI command, flag, stdout shape, package boundary, target, or external
  compatibility behavior changes.
- Existing unrelated plans and notes remain untouched.

## Commit progress

- [x] 1. Centralize and enforce disposable build-path ownership
- [ ] 2. Simplify cleanup around the sanctioned build roots
