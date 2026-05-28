# Pure Core Compiled Same-Module via Symlink, Tested via Nested Package

`Status`: Accepted
`Date`: 2026-05-28

## Context

DanTerm's pure model/update layer (the 22 files that comprise `Model.swift` /
`Update.swift` / `Persistence.swift` / `Projections.swift` / `ModelOperations.swift`
and friends) was previously tested via a hand-rolled harness in `tests/` that
hard-coded a source list and a `func fooTests()` registration list. The harness
recompiled ~75 files from scratch into a `mktemp -d` on every run -- 19.4s wall,
1.25s actual execution, ~93% wasted compilation. Two manual lists rotted silently:
forget to add a new file to `test.sh` or a `fooTests()` to `TestHarness.main()`
and the suite still reported green.

We wanted the core suite to run via `swift test` with incremental builds, parallel
execution, auto-discovery, and `--filter` -- Swift Testing's `@Test` decorator
gives all of that.

The natural design move is "extract the core to its own SwiftPM target." But a
separate module imposes a real, permanent tax: access control does not propagate
from a type to its members, so marking `struct AppModel` `package` leaves
`var groups` / `selectedTabId` / `config` (`Model.swift:188-194`) `internal`, and
the app's reads of `model.groups` would fail to compile across the module boundary
until every member of `AppModel`, `TabModel`, `PaneModel`, every `Projections.swift`
struct, etc., were individually annotated `package`. Plus explicit initializers
on every struct the app constructs. This is a one-time per-field churn AND a
permanent tax: every future model field the app reads would need annotating.

## Decision

The 22 pure files live in `lib/DanTermCore/Sources/DanTermCore/` and are
compiled by **two independent SwiftPM builds**:

1. **The root app build** (`./Package.swift`) compiles them into the app's own
   module via `sources: ["app", "lib/DanTermCore/Sources/DanTermCore"]`. There is
   no `import DanTermCore`; the core stays plain `internal` and the app reads
   `model.groups` exactly as before, with zero access annotations.

2. **The nested test package** (`lib/DanTermCore/Package.swift`) compiles the
   same files as a standalone `DanTermCore` library and runs Swift Testing suites
   in `lib/DanTermCore/Tests/DanTermCoreTests/` via `@testable import DanTermCore`.
   The nested package depends on `.package(path: "../DanTermProtocol")` and
   `swift-custom-dump`, but NOT on the `DanTerm` executable or GhosttyKit.

Two implementation details matter:

- **The `path: "."` root manifest needs a stable `exclude:` set.** With
  `path: "."` SwiftPM scans the entire repo and warns on any non-source file or
  directory it sees. The exclude list covers every non-source top-level dir and
  loose file; gitignored build artifacts under `lib/` (like `lib/ghostty-themes`)
  are appended conditionally with `FileManager.fileExists`. The acceptance bar is
  warning-free in both checkout states: bare (no `ghostty-themes`) and
  artifact-populated.

- **The pivot from the plan's original `sources: [...]` listing to the symlink
  `app/DanTermCore -> ../lib/DanTermCore/Sources/DanTermCore`.** The plan called
  for two directories in `sources:`, but practical implementation showed that
  letting `sources:` be a single tree under `app/` (with the core in via a
  symlink) keeps the exclude list flatter and makes the source layout look
  unsurprising to readers who open `app/` looking for "everything compiled into
  the executable."

The same-module design pays nothing the module-split would have given:

- **What we do NOT lose.** A module split's only *compiler-enforced* benefit is
  that core compiles without the app module or GhosttyKit -- and the nested test
  package delivers exactly that. A core file that calls an app-only symbol or
  gains `import GhosttyKit` fails to resolve under the nested `swift test`.

- **What the nested package does NOT catch.** `import Cocoa` / `AppKit` /
  `SwiftUI` are system frameworks any macOS SwiftPM target links by default, so a
  Cocoa import in the core compiles cleanly under a standalone package. A
  *separate* `DanTermCore` module wouldn't catch them either -- the compiler
  enforces Cocoa-freeness in no design. We close this gap with a local lint
  (`scripts/core-purity-lint.sh`) wired into `just test`. The lint has a self-test
  (`scripts/tests/core-purity-lint_test.sh`) so a silent regex regression is
  caught.

The hand-rolled harness, both manual lists, and the throwaway-compile loop are
retired. `tests/` is deleted; the core suite runs under
`swift test --package-path lib/DanTermCore`.

## Consequences

- **No access-control churn.** The app reads every core field as `internal`, just
  as before. Zero `package` / `public` annotations, zero explicit initializers,
  zero `@unknown default` work.
- **Incremental + parallel + auto-discovered.** A warm `swift test` completes in
  ~1-2s; cold compile is the only outlay. Adding a new `@Test` is auto-discovered;
  there's no `TestHarness.main()` registration list to rot.
- **Field-level diffs on big values.** `expectNoDifference` from
  `swift-custom-dump` (used in `TreeOwnsPanesTests` etc.) prints a structured diff
  on `AppModel` mismatch instead of `big != big`.
- **The root manifest needs the `exclude:` list.** Top-level directory churn
  (adding a non-source dir) requires extending the exclude list. The cost is
  small and stable -- top-level entries change rarely.
- **CI gating is a follow-up.** This migration kept GitHub Actions changes out of
  scope. The local gate (`just test`) now runs protocol + core + the purity lint;
  CI wiring follows in a separate pass.

## References

- The migration plan that drove this design lives at
  `plans/wip/let-s-draft-this-all-linked-journal.md`. See R1 (the
  same-module-via-symlink decision and its access-control rationale), R2 (the
  injectable recovery-path seam in `Persistence.swift` that lets
  `CheckpointTests` use a per-test temp dir), and R3 (UI tests stay local).
- The parity inventory (`test-inventory.txt`) records baseline + new
  failure-site counts per file plus the two intentional deltas allowed under the
  Phase 2 gate (`CheckpointTests`' on-disk strengthening, `ScrollbarMathTests`'
  parameterized `@Test(arguments:)` collapse).
- The local core-purity lint is at `scripts/core-purity-lint.sh`; its self-test
  is at `scripts/tests/core-purity-lint_test.sh`.
