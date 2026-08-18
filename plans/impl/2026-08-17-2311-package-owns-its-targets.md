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
- Changing any Swift source. Not one line of `lib/DanTermProtocol`,
  `lib/DanTermClient`, or `lib/DanTermSupport` changes.
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

## Critical files

`Package.swift`, `scripts/run-test-suite.sh`,
`lib/DanTermSupport/Package.swift`, and two new scripts plus their self-tests
modeled on `scripts/ios-portability-gate.sh` and
`scripts/tests/ios-portability-gate_test.sh`.

## Commit progress

Each slice is independently green under `just test`. Ordering is forced: the
ownership lint fails on the tree the middle slices clean up, so it lands last.

- [x] **1. Close the gate hole.** Add the coverage check, its self-test, and the
      `lib/DanTermClient` gate step. Red first: the check names
      `lib/DanTermClient` before the step exists.
- [ ] **2. `DanTermProtocol` becomes a package dependency.** One atomic manifest
      edit -- adding the dependency while the same-named target still exists puts
      two targets of one name in the graph, so the swap cannot be split across
      commits. Drop the dead `--filter` from the protocol gate step.
- [ ] **3. `DanTermClient` becomes a package dependency.** Same shape.
- [ ] **4. `DanTermSupport` becomes a package dependency,** carrying the CoreText
      link into `lib/DanTermSupport/Package.swift`.
- [ ] **5. The ownership lint, its self-test, and the written rule.** An ADR
      stating both halves of the rule -- a re-declared target is a violation, a
      symlink inside a target's own declared path is not -- indexed in
      `docs/design/index.md`, referenced from AGENTS.md, and noted in the
      symlink ADR's consequences.
- [ ] **6. Close S48 in the audit.** In
      `docs/scratch/2026-08-11-simplification-audit.md`, put the hashes of the
      slices above in the S48 row's Status column, the way every other closed
      finding records the commits that closed it, and rewrite the
      "DanTermProtocolTests ownership" bullet under "Settle these first" to
      state the decision that landed -- the nested packages own their targets
      and their tests -- so the derive-STEPS work reads a settled call rather
      than an open one.

## Verification

Per slice, and in full after slice 5:

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
