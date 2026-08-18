# A package owns its sources: one manifest declares a target

## Problem

The root `Package.swift` reaches into three nested packages and re-declares
targets they already own: `DanTermProtocol`, `DanTermClient`, and
`DanTermSupport`, each declared with a `path:` pointing inside
`lib/<package>/Sources/`. For two of them it also re-declares the test target
over the nested package's own `Tests/` directory.

Four consequences, all verified on the current tree:

- **The same tests run twice.** `scripts/run-test-suite.sh` runs
  `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
  and, separately, the root package, which declares `DanTermProtocolTests` over
  the identical directory. 20 files and 3,307 lines compile and execute twice
  per gate.
- **`DanTermClientTests` has no package-level runner.** Its 4 files and 1,500
  lines compile twice but run only through the root. No gate step names
  `lib/DanTermClient` at all, so the suite of the newest module in the tree is
  the one module whose own package is never tested.
- **Two declarations of one target drift.** The root's `DanTermSupport` target
  carries `.linkedFramework("CoreText")`; the nested one does not, while
  `lib/DanTermSupport/Sources/DanTermSupport/FontAvailability.swift` imports
  CoreText. Today Darwin autolinking hides the difference. Nothing prevents the
  next divergence.
- **A re-declared test target escapes the iOS gate.** `lib/DanTermProtocol` and
  `lib/DanTermClient` are pinned `.iOS(.v26)`, and
  `scripts/ios-portability-gate.sh` cross-compiles every target of every pinned
  manifest with `--build-tests`, precisely because "skipping test targets is
  exactly how a package acquires a host-bound test while its pin still says
  iOS". A test target owned instead by the macOS-only root manifest is outside
  that claim.

This was not a decision. The root declared `DanTermProtocol` in May 2026, before
the iOS pin existed; `DanTermClient` copied the shape in August the day it was
created. The `docs/scratch/2026-08-11-simplification-audit.md` finding S48
records the double run and asks for an ownership call, and its own suggested
direction -- move the tests to the root -- predates the iOS pin and would take
the protocol tests out of the portability gate.

## Decision

**A target belongs to the nearest first-party `Package.swift` above its declared
path, and no other manifest may declare it.** Nesting is normal and stays legal:
`lib/DanTermCore`'s own targets sit under the root manifest too, and the root is
simply not the nearest owner. What is illegal is an ancestor manifest reaching
past a nearer one -- the root declaring a target at
`lib/DanTermProtocol/Sources/DanTermProtocol` when
`lib/DanTermProtocol/Package.swift` stands between them. Cross-package use goes
through
`.package(path:)` plus `.product(name:package:)` -- the form the root already
uses for `lib/TerminalCore` and `lib/TerminalPTY`, and that `ios/DanTermMobileKit`
already uses for both packages at issue.

The root manifest therefore stops declaring `DanTermProtocol`, `DanTermClient`,
and `DanTermSupport`, and depends on those three packages instead. The
duplicated test targets and the two consumer-less `.library` products go with
them. The gate gains a `lib/DanTermClient` step and loses the now-meaningless
`--filter` on the protocol step.

Ownership is decided by the `path:` a manifest **declares**, never by the files
that path resolves to. That line is what keeps the rule from touching the
`app/DanTermCore` and `app/DanTermSupport` symlinks: the root target declares
`path: "app"` and claims nothing outside it, `lib/DanTermCore/Package.swift`
remains the sole manifest naming those sources, and the second compile exists to
buy same-module `internal` access, which a package dependency cannot deliver
(`docs/design/2026-05-28-core-module-via-symlink.md`). A re-declared target is
different in kind: it claims another package's directory and compiles it under
settings and platform pins the owner cannot see.

Two executed checks replace the convention, in the shape
`scripts/ios-portability-gate.sh` established -- rule stated in the script
header, fixture-tree seam through an env var, self-test under `scripts/tests/`:

- **Ownership.** No manifest declares a target that a nearer manifest owns.
- **Gate coverage.** For every first-party manifest that declares a test target,
  the gate's lanes run that package's whole test estate, and run each test once.
  A mention is not a lane: a step that only builds the package, or a wrapper
  script that names it without testing it, leaves the estate unrun. Neither is a
  lane that runs a subset -- a `--filter` or `--skip` that carves the estate down
  counts only when the package's lanes together put every test back, which is
  what `scripts/test-terminal-pty.sh` does with a `--skip X` lane beside a
  `--filter X` one. Two lanes over the same estate fail for the opposite reason.
  The gate reaches `lib/TerminalPTY` through that wrapper, so one level of script
  indirection counts. This is the check that would have caught the real damage,
  and it is red on today's tree naming `lib/DanTermClient`.

Both read only manifest text and reject a `path:` that is not a string literal,
so a computed path fails rather than slipping past.

## Invariants

- **I1.** Every first-party target is declared by exactly one manifest: the one
  whose package directory contains its sources.
- **I2.** Every first-party test target runs exactly once per `just test`, under
  the package that owns it.
- **I3.** Every module the app and CLI import resolves to the same module
  identity as before: `DanTermProtocol`, `DanTermClient`, `DanTermSupport`,
  reached by plain `import` from `app/`, `cli/`, `tools/`, and the root test
  targets.
- **I4.** The iOS-pinned packages still cross-compile whole, tests included.
- **I5.** A target's build settings live with the target: the CoreText link
  moves into `lib/DanTermSupport/Package.swift` rather than being dropped.

## Proof obligations

- **PO1 (I1).** The ownership lint passes a target declared by its nearest
  manifest, fails the same target declared by an ancestor manifest, fails a
  `path:` that is not a string literal, and passes a symlink that lives inside a
  target's own declared path. The last case is the load-bearing one: it pins
  "declared, not resolved" and is what stops a future strengthening of the lint
  from breaking the `app/DanTermCore` symlink.
- **PO2 (I2).** The coverage check fails a package with no lane, fails a package
  with two lanes over the same estate, fails a package named only by a step that
  does not run its tests, and fails a package whose only lane runs a subset of
  its estate. It passes a package whose lanes partition the estate between them,
  the shape `scripts/test-terminal-pty.sh` already uses -- so the subset case and
  the partition case must be separate fixtures, or the check will be written to
  reject the gate's own working lane. On the tree before this change it names
  `lib/DanTermClient`; after, it passes. Run the ownership lint against the pre-change tree too and record that
  it reports all five root declarations -- three source targets and two test
  targets.
- **PO3 (I3).** The app and CLI build and run: `bash ./dev-build.sh --no-install`
  (the `--build-path .spm-build` path), then a launched dev slot driven over its
  control socket and quit cleanly.
- **PO4 (I4).** `scripts/ios-portability-gate.sh` still reports building
  `lib/DanTermProtocol` and `lib/DanTermClient`.
- **PO5 (I5).** The existing `DanTermSupport` font-availability suite passes
  under the nested package, and the CLI still links and runs.

## Non-goals

- Deriving the gate's `STEPS` array from the manifests. That is a separate audit
  item; this change only supplies the precondition it needs -- one declaration
  per target -- plus the minimal executed form of its coverage claim.
- Changing what any Swift source does. The split forces exactly one
  access-level widening, at the boundary it creates: `cli/main.swift` calls
  `gatherDoctorFacts`, which `lib/DanTermSupport` declares `package`, and
  `package` no longer reaches the CLI once `lib/DanTermSupport` is a separate
  package. Only the three declarations the CLI uses become `public` --
  `DoctorProbeEnv`, its `live` value, and `gatherDoctorFacts`. The struct's
  stored properties and everything else keep the access they have now, and no
  behavior changes.
- `just clean` already matches `.build` by name, so no clean-list edit is
  needed. It does not match `.build-ios-gate`; that gap is real and belongs to
  the `just clean` finding, not here.

## Accepted risks

- **AR1.** `lib/DanTermClient/Tests/DanTermClientTests/ClientLivenessTests`
  drives real sleeps of roughly 0.8 to 2.4 seconds. Giving it a second concurrent
  runner in an oversubscribed pool may expose flakiness these tests already
  carry. Surfacing it is progress; resizing those guards to the house rule is
  separate work, not part of this change.
- **AR2.** `client-tests` does `@testable import DanTermSupport`, which after
  this change crosses a package boundary. `lib/TerminalPTY`'s tests already do
  `@testable import TerminalCore` across exactly such a boundary, so the shape
  is proven in this tree.

## Rejected ideas

- **RI1.** Keep the root test targets and delete the nested ones (the audit's
  stated ideal). It removes the double run but moves iOS-pinned packages' tests
  into a macOS-only manifest, which is the escape `ios-portability-gate.sh`
  exists to prevent.
- **RI2.** Delete the duplicated test targets only, leaving the root's
  re-declared source targets. It fixes the instance and leaves the pattern that
  produced it, which is how `DanTermClient` inherited it from
  `DanTermProtocol`.
- **RI3.** An allowlist exempting `DanTermSupport` from the ownership rule.
  `ios-portability-gate.sh` already argues this down for its own pin: an
  allowlist makes the rule mean "owned, except where a list says otherwise".
- **RI4.** Move the doctor prober into `cli/` instead of widening its access. It
  would force `CLIPathInstaller.installDiagnostics()` and `Dependencies` public
  instead, a bigger surface than the three declarations, and it would evict
  `DoctorProberTests` from the nested package's suite.
- **RI5.** A lint over `package`-access declarations instead of a cold-build
  gate lane. It would re-implement in grep a check the compiler already performs
  exactly, and it would cover one class of break while the real class is any
  break that stale incremental state masks.

## Critical files

`Package.swift`, `scripts/run-test-suite.sh`,
`lib/DanTermSupport/Package.swift`, and two new scripts plus their self-tests
modeled on `scripts/ios-portability-gate.sh` and
`scripts/tests/ios-portability-gate_test.sh`.

## Commit progress

Each slice is independently green under `just test`. Ordering is forced: slices
2 through 4 clean the tree up, and slice 5 repairs the cold build that slice 4
broke. The ownership lint fails on the tree the middle slices clean up, and
those slices are committed, so that constraint is already met and it lands at 6.
The cold-build gate lane follows at 7 because both slices edit
`scripts/run-test-suite.sh` and the lint's work is already implemented and
uncommitted in the working tree: if the lane landed first, staging that shared
file would sweep the lint's gate steps into the wrong commit. Landing the
already-implemented lint first keeps each commit's touch of
`scripts/run-test-suite.sh` clean and separate. The audit close comes last at 8,
because it records the hashes of everything above.

- [x] **1. Close the gate hole.** Add the coverage check, its self-test, and the
      `lib/DanTermClient` gate step. Red first: the check names
      `lib/DanTermClient` before the step exists.
- [x] **2. `DanTermProtocol` becomes a package dependency.** One atomic manifest
      edit -- adding the dependency while the same-named target still exists puts
      two targets of one name in the graph, so the swap cannot be split across
      commits. Drop the dead `--filter` from the protocol gate step.
- [x] **3. `DanTermClient` becomes a package dependency.** Same shape.
- [x] **4. `DanTermSupport` becomes a package dependency,** carrying the CoreText
      link into `lib/DanTermSupport/Package.swift`.
- [x] **5. Repair the cold build.** Widen the three `package` declarations in
      `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift` --
      `DoctorProbeEnv`, its `live` value, and `gatherDoctorFacts` -- to `public`.
      They are the only `package`-access declarations in the three split
      packages, and their only out-of-package user is `cli/main.swift:391`.
      Slice 4 made `lib/DanTermSupport` a separate package, so `package` access
      stopped reaching the CLI and a cold `swift build --product DanTermCLI`
      fails with "cannot find 'gatherDoctorFacts' in scope". Every warm scratch
      directory hid this, which is why slice 4 verified green. `public` is the
      right marker: the CLI is now an external consumer of the `DanTermSupport`
      product, and AGENTS.md names `public` as the `lib/` boundary marker.
      History stays append-only by the user's decision, so this is its own
      commit and does not amend d633f92e. The consequence is stated openly:
      slice 4's commit is not cold-buildable on its own, so a bisect that lands
      on that one commit hits the failure.
- [ ] **6. The ownership lint, its self-test, and the written rule.** An ADR
      stating both halves of the rule -- a re-declared target is a violation, a
      symlink inside a target's own declared path is not -- indexed in
      `docs/design/index.md`, referenced from AGENTS.md, and noted in the
      symlink ADR's consequences.
- [ ] **7. A cold-build gate lane.** Add one step to `scripts/run-test-suite.sh`
      that builds the whole root graph with tests into a per-run throwaway
      scratch (`swift build --build-tests --scratch-path "$(mktemp -d)"`, with
      cleanup), first in `STEPS`. Every existing step uses a warm per-purpose
      scratch -- `.build-app-tests`, `.build-gate`, the default `.build` -- so
      the gate structurally cannot catch a break that stale incremental state
      masks, which is exactly how slice 4 passed. The step satisfies the
      step-independence rule by construction: `mktemp -d` shares no build
      directory with anything. Cost is real: about 27s solo at high CPU, and
      inside the gate's capped pool it likely becomes the longest pole, moving
      the gate from about 75s toward about 2 minutes. State the scope limit
      where the lane is defined: it covers the root graph, where every
      cross-manifest edge this plan adds terminates, while the nested-package
      test lanes and the iOS gate still run warm. Red first: run against the
      tree before slice 5 lands, the lane fails at `cli/main.swift:391`. Slice 5
      lands first under append-only ordering, so make that demonstration against
      a checkout or scratch export of d633f92e -- record the failure there, then
      confirm the lane green on the current tree -- and put both records in the
      implementation notes.
- [ ] **8. Close S48 in the audit.** In
      `docs/scratch/2026-08-11-simplification-audit.md`, put the hashes of the
      slices above in the S48 row's Status column, the way every other closed
      finding records the commits that closed it, and rewrite the
      "DanTermProtocolTests ownership" bullet under "Settle these first" to
      state the decision that landed -- the nested packages own their targets
      and their tests -- so the derive-STEPS work reads a settled call rather
      than an open one.

## Verification

Per slice, and in full after slice 8:

0. A cold build of the whole root graph with tests, into a throwaway scratch:
   `swift build --build-tests --scratch-path "$(mktemp -d)"`. Run it first,
   because every check below reuses a warm scratch and cannot see a break that
   only a cold build exposes.
1. `bash ./dev-build.sh --no-install`.
2. `swift build --product DanTermCLI`, then run the binary from
   `swift build --show-bin-path` -- the default-`.build` path
   `scripts/tests/danterm-cli-connect-errors_test.sh` depends on.
3. `swift test --package-path` for `lib/DanTermProtocol`, `lib/DanTermClient`,
   `lib/DanTermSupport`, and the root run with `--scratch-path .build-app-tests`.
4. `./scripts/ios-portability-gate.sh`.
5. `just test`, into a file, then grep it: the client step appears in the ok
   list. "Runs once" is the coverage check's job, not the log's -- the log
   records steps, not suites.
6. `just launch-slot | tail -1`, drive the slot with an explicit
   `danterm --socket <slot-socket>` command, `quit` it, release the slot.
7. Report, without turning it into a threshold, the cold wall-clock of the root
   test step before and after -- it loses 4,800 lines of test compilation.

## Implementation discretion

- Names and language of the two new scripts, and whether the coverage check is
  its own script or an assertion inside the existing gate self-test.
- How the checks parse manifest text, given that a non-literal `path:` must
  fail rather than pass.

## Implementation notes

- **Slice 1.** The coverage check is its own script, `scripts/gate-test-coverage-lint.py`,
  rather than an assertion inside the iOS gate's self-test. It parses manifest and
  step-list text in Python because the work is text analysis, not shell driving, and
  because a self-test that runs the real step list cannot use a fixture tree.
- **Slice 1.** A package's estate is modeled as the test targets its manifest
  declares, so a `--filter` whose regex matches every one of them is a whole-estate
  lane rather than a subset. That is what makes the protocol step's dead `--filter`
  pass the check while it still exists; slice 2 removes it.
- **Slice 1.** Script indirection follows `scripts/*.sh` wrappers only, which is the
  shape `scripts/test-terminal-pty.sh` uses. A wrapper written in another language
  would have to name its package in the step string.
- **Slice 1, PO2 record.** Before the `lib/DanTermClient` step existed the check
  failed naming exactly `lib/DanTermClient` and nothing else. With the step added it
  reports 9 test estates each run once, and `just test` passed all 96 steps in 71s
  with the client lane in the ok list.
- **Slice 2.** Every root consumer of `DanTermProtocol` moved from the bare
  `"DanTermProtocol"` target name to `.product(name:package:)`, because a package
  dependency is only reachable through its product. The root also drops its
  `.library(name: "DanTermProtocol")` product, which had no consumer once the
  target it exported was gone.
- **Slice 2 verification.** The full gate passed all 96 steps in 75s, the iOS gate
  still builds both pinned packages with tests, and a dev slot launched, answered
  `ls` over its control socket, and quit cleanly. The root test step now runs 164
  tests; the protocol suite runs only under `lib/DanTermProtocol`.
- **Slice 3.** The root also drops its `.library(name: "DanTermClient")` product. Its
  only consumers outside the root -- `ios/DanTermMobileKit` and
  `ios/DanTermMobileApp` -- already reach the module through
  `.package(path: "../../lib/DanTermClient")`, so the root product exported a target
  nobody asked the root for.
- **Slice 3.** `cli-tests` imports `DanTermClient` without naming it as a dependency
  and keeps working, because `DanTermCLI` still carries the product transitively. That
  was true before this change too, so the slice leaves it alone rather than adding a
  dependency the plan did not ask for.
- **Slice 3.** No gate step changed. Slice 1 already added the `lib/DanTermClient`
  lane, so this slice only removes the second runner rather than moving a lane.
- **Slice 3 verification.** The full gate passed all 96 steps in 75s, the iOS gate
  still cross-compiles `lib/DanTermClient` and `lib/DanTermProtocol` with tests, the
  coverage lint reports 9 estates each run once, and a dev slot launched, answered
  `ls` over its control socket, and quit cleanly. The root test step now runs 121
  tests, down from 164 -- exactly the 43 the client suite contributes, which now run
  only under `lib/DanTermClient`.
- **Slice 4.** The root never declared a `DanTermSupportTests` target, so this slice
  removes a duplicate source target only. No test moves and no gate step changes: the
  `swift test --package-path lib/DanTermSupport` lane already ran the estate, and the
  root test count stays at 121.
- **Slice 4.** The CoreText link lands on the nested target with a comment naming
  `FontAvailability.swift` as the importer, so the reason survives the move (I5).
- **Slice 4.** `client-tests` keeps its `@testable import DanTermSupport` unchanged
  across the new package boundary (AR2); the root test target reaches the module
  through `.product(name:package:)` like every other consumer.
- **Slice 4 verification.** The full gate passed all 96 steps in 76s, the nested
  support suite passed 102 tests including `FontAvailabilityTests` (PO5), the iOS gate
  still cross-compiles both pinned packages with tests (PO4), the coverage lint still
  reports 9 estates each run once, and a dev slot launched, answered `ls` over its
  control socket, and quit cleanly (PO3).
- **Slice 5, red first.** On the tree at d633f92e, `swift build --product DanTermCLI`
  into a fresh scratch failed with exactly one error: `cli/main.swift:391:37: error:
  cannot find 'gatherDoctorFacts' in scope`. Widening the three declarations was
  enough; nothing else in the three split packages carried `package` access, so no
  other symbol needed a change.
- **Slice 5.** Only the three declarations named in the plan became `public`. The
  stored properties of `DoctorProbeEnv` stay `internal`, so its memberwise
  initializer stays inside the module and `DoctorProbeEnv.live` remains the only way
  an external consumer builds one -- which is all `cli/main.swift` needs.
- **Slice 5 verification.** A cold `swift build --build-tests` into a throwaway
  scratch is green, `bash ./dev-build.sh --no-install` builds, the CLI binary at
  `swift build --show-bin-path` runs `doctor` and prints its full ladder, `just test`
  passed all 98 steps in 82s, the iOS gate still cross-compiles `lib/DanTermProtocol`
  and `lib/DanTermClient` with tests, and a dev slot launched, answered `ls` over its
  control socket, and quit cleanly.
