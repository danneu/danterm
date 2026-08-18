# The type-check budget belongs to the package, and it fails the gate

## Context

`scripts/run-test-suite.sh` runs the engine's tests under a type-check budget:

    swift test --package-path lib/TerminalCore \
        --scratch-path lib/TerminalCore/.build-gate \
        -Xswiftc -Xfrontend -Xswiftc -warn-long-function-bodies=500

The budget was installed on purpose. Commit `228fdb36` measured three test
functions at 935 to 2,484 ms of type-check time, reshaped their expressions, and
added the flag "to keep this from regressing". Nothing reads it.

- **The signal cannot be seen.** The gate's worker writes each step's output to a
  temp log and replays it only when the step fails, so a passing step's warnings
  are discarded. A fresh `--build-tests` build with the flag emits exactly one
  budget warning today:
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift:1383`,
  `truncatingIntoAForcedSplitRecordKeepsItsSideTablesReadable()`, 710 ms against
  a 500 ms limit. `git log -L` puts it in commit `33fef5dd` on Aug 5, five days
  after the guard went in. The regression the guard exists to catch happened, and
  the guard said nothing.
- **The second build tree is recorded as an accident.** The extra `-Xswiftc`
  args change SwiftPM's build-argument hash, so the gate was given
  `lib/TerminalCore/.build-gate` (commit `ea73efc3`, reason recorded in
  `.gitignore` as a hash collision to dodge). It costs 575 MB beside
  `lib/TerminalCore/.build` at 1.4 GB, and a cold build in every fresh worktree.
  While the warnings went unread that was pure waste; it turns out to be the one
  thing making the measurement dependable, and nothing says so.
- **The budget applies to one command out of many.** A bare `swift test
  --package-path lib/TerminalCore`, the two `scripts/research/33` lanes, the
  `-c release` probe and benchmark recipes, the iOS cross-compile, and the app
  build all compile this package with no budget at all.

Type-check cost is a live concern in this package, not a hypothetical one:
`scripts/generate-terminal-unicode-tables.py` emits flat, explicitly typed arrays
precisely because nested literals at that scale drive the constraint solver into
multi-gigabyte territory.

`docs/scratch/2026-08-11-simplification-audit.md` S39 read the same code and
proposed deleting the flag and the tree. It never ran the build, so it treated
"nobody reads it" as "there is nothing to read".

## Decision

**The package owns the measurement; the gate owns the verdict.**

- **D1.** The budget moves out of the gate's command line into
  `lib/TerminalCore/Package.swift`, as one shared `SwiftSetting` value carried by
  every target. Every build of the package then measures every function body it
  type-checks, whatever command, configuration, or consumer produced it. The
  limit is written once, in that one definition. The same shared value turns on
  diagnostic names, so the breach is reported with a stable identifier and not
  only as prose.
- **D2.** The gate keeps its own build tree for this package, and gets a reason
  worth keeping. The compiler reports an over-budget body only when it
  type-checks that body, so what the gate can measure is exactly what the gate's
  own build has to recompile. A tree only gate runs touch guarantees that window:
  every file changed since the last `just test` is re-type-checked, and therefore
  measured, during the run that judges it. Sharing the developer's tree would
  hand that recompile to whoever built first and leave the gate judging a build
  that compiled nothing. `.build-gate` keeps its name, which
  `ios/DanTermMobileKit` and `lib/TerminalHostTools` already use for step
  independence, and the `.gitignore` comment is rewritten from a hash collision
  to the measurement window. The scratch path stays visible in the step string,
  where `scripts/tests/just-clean_test.sh` reads it.
- **D3.** The gate step becomes a script in the established lint shape. It runs
  the package's tests and exits nonzero when the build reports any function over
  budget, naming each function and its measured cost, and equally when a target
  in the manifest omits the budget setting. Test failure still fails the step.
  The step string keeps naming `lib/TerminalCore` literally, so the gate-coverage
  check landing with the package-ownership plan still sees the lane. The script
  takes the scratch path as a required argument and refuses to run without one,
  so deleting that path from the step string turns the gate red instead of
  quietly handing it back a tree someone else warmed.
- **D4.** The enforced limit gets a margin before it is armed. Type-check cost is
  wall-clock time inside the frontend and the gate is an oversubscribed pool, so
  a limit that a healthy function sits near is a flake waiting to happen.
  `228fdb36` recorded the worst remaining function at 427 ms against the 500 ms
  limit, which is no margin at all, and that number is two weeks stale. The
  package is measured at half the budget first, and what sits above that line is
  reshaped.
- **D5.** The 710 ms offender is fixed by the technique that fixed its three
  predecessors: the cost is expression shape, not workload, so oversized
  inference sites become annotated locals and explicit closure signatures with
  every assertion unchanged.

Feasibility is settled, not assumed. `-Xfrontend` is only expressible as
`.unsafeFlags`, which SwiftPM refuses to accept from a dependency -- except that
it inserts every `fileSystem` dependency into the allowed set
(`Workspace+Manifests.swift#unsafeAllowedPackages`), and all five consumers of
this package depend on it by path. Implementation confirms this on the real
toolchain before anything else, by loading a consumer's graph.

## Invariants

- **I1.** Every function body a build of `lib/TerminalCore` type-checks is
  measured against the budget, whichever command, configuration, or triple
  produced the build, and a target added to the manifest cannot silently opt out.
- **I2.** When a gate run type-checks a function over the budget, `just test`
  fails, and the failure names the function, its location, and its measured cost.
- **I3.** No command outside the gate warms the tree the gate judges, so a file
  edited since the last gate run is re-type-checked during the next one whatever
  the developer built in between. `just clean` still removes every tree the gate
  makes.
- **I4.** No surviving function's measured cost sits within a factor of two of
  the enforced limit.
- **I5.** Behavior is unchanged: the reshaped tests assert what they asserted
  before, and every consumer of the package still builds and runs.

## Proof obligations

- **PO1 (I1).** With an over-budget body present -- the slice-1 shape restored,
  or a throwaway one -- a build of the package with no extra flags on the command
  line reports it, in debug and in release. The script's
  self-test drives a fixture manifest whose target omits the shared setting and
  shows the script rejects it, and a fixture with no budget definition at all
  fails as a broken gate rather than passing.
- **PO2 (I2).** Three cases, all in the self-test:
  - **It catches a breach.** Canned compiler output through an explicit runner
    seam proves red and green without a compile and without depending on how
    fast anything ran. Separately, record the script failing on this repo's
    tree with the offender's fix reverted: the guard has to be seen catching
    the real case it missed.
  - **It keys on something stable.** The gate recognizes a breach by the
    compiler's diagnostic identifier, `debug_long_function_body`, which
    diagnostic names put in the output, rather than by the sentence around it.
    A reworded warning then still fails the gate, so the parser cannot be
    silently disarmed by a toolchain that changes its prose. Record what the
    current toolchain emits when the setting lands.
  - **It does not swallow a test failure.** Through the same seam, an
    underlying test run that fails while emitting no budget warning still fails
    the step, and its output survives into what the gate replays.
- **PO3 (I3).** The workflow that would hide a breach does not: restore an
  over-budget body, run a bare `swift test --package-path lib/TerminalCore` to
  completion so the developer's tree is warm, then run the gate step and watch it
  fail anyway. `scripts/tests/just-clean_test.sh` stays green, reading the gate's
  scratch path out of the `STEPS` text as it does today, and the script's
  self-test shows it refusing to run at all when it is given no scratch path.
- **PO4 (I4).** Calibration reads a cold, complete build in a disposable scratch
  tree, so that a quiet result means every function was measured and cleared the
  half-limit line rather than that SwiftPM reused what it had. Record the
  continuous quantity -- the worst function bodies and their costs -- not the
  pass or fail bit.
- **PO5 (I5).** The reshaped suites pass unchanged, and `bash ./dev-build.sh
  --no-install`, `./scripts/ios-portability-gate.sh`, and a release-configured
  probe recipe all succeed with the manifest carrying the flag.

## Non-goals

- Making the gate print output for passing steps. That was the audit's cheaper
  fallback, and it substitutes a human reading a log for a gate deciding.
- Turning every warning in the package into an error. The package has one other
  warning site, and a toolchain upgrade's new deprecation would then break the
  app build rather than a lint.
- Giving any other package a budget. The script takes the package as an argument,
  so a second adopter is a `STEPS` edit, but nothing else adopts here.
- Changing the 500 ms number as such. D4 may move it, but only against a measured
  distribution, never to make today's tree quiet.
- Reclaiming the gate's build tree. It stays, for the reason D2 gives.

## Accepted risks

- **AR1.** The gate measures what its own tree must recompile, so a body that was
  already compiled into that tree under the old limit is not re-measured until
  something touches its file. Edits are covered by I3, and a change to the limit
  is covered by AR4: editing the manifest moves the build-argument hash, so every
  tree rebuilds cold.
- **AR2.** An enforced budget is a wall-clock threshold measured under load, so
  it can fail on a busy machine rather than on a regression. I4's margin is the
  mitigation, and a failure names the function, so a false red is cheap to read.
- **AR3.** The gate's own tree costs 575 MB of disk and a cold build in every
  fresh worktree, and the gate's longest step never starts from a developer's
  warm tree. That is the price of a measurement window the developer cannot
  consume, and this plan exists because the cheaper arrangement measured nothing.
- **AR4.** Changing the manifest moves the build-argument hash of every tree that
  compiles this package, so the first build after it lands is cold everywhere,
  the app build included.
- **AR5.** `unsafeFlags` makes the package unusable as a versioned dependency.
  Every consumer here is a path dependency and DanTerm publishes none of them; if
  that changes, the setting is revisited.
- **AR6.** Budget warnings now appear in app, probe, and iOS builds, each tagged
  with its diagnostic name. That is the point of moving them there, and nothing
  in the build scripts treats a warning as a failure.
- **AR7.** A toolchain that renames or stops emitting the diagnostic identifier
  takes the gate quiet with it. Nothing catches that without a timed probe, and
  a verdict that turns on how fast a compile ran is the one thing the house test
  rules forbid outright; an identifier is the most stable thing on offer.

## Rejected ideas

- **RI1.** Delete the flag and the tree with it (S39's proposal). The flag is
  catching a live regression today; deleting it is choosing not to know.
- **RI2.** Keep the flag on the gate command line and make a wrapper script the
  one sanctioned way to test the package, backed by a lint that rejects any other
  committed invocation. That is a convention plus a second gate to defend it,
  and it still leaves an interactively typed bare command re-thrashing the shared
  tree. Putting the flag in the manifest makes the question disappear: the two
  `scripts/research/33` lanes and every future caller get the budget without
  being routed anywhere.
- **RI3.** Keep the flag on the command line and add only the grep. It fixes the
  invisible signal for the gate alone and leaves every other build of the
  package -- the developer's, the probes', the app's -- measuring nothing, so the
  first time anyone hears about a breach is a failed gate.
- **RI4.** A separate manifest-coverage lint beside the enforcing script. The
  manifest rule is the enforcing script's own precondition; splitting them lets
  the heavy step pass vacuously.
- **RI5.** Raise the limit until today's tree is clean. The 710 ms function is a
  defect of expression shape, and a limit above it stops catching the class.
- **RI6.** Let the compiler fail the build itself. Blanket `warningsAsErrors`
  breaks ordinary builds on unrelated warnings, and promoting this one
  diagnostic selectively is unsupported by the toolchain, which is why the
  verdict belongs to the gate script.

## Critical files

`lib/TerminalCore/Package.swift`, `scripts/run-test-suite.sh`, `.gitignore`,
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineStoreTests.swift`,
and one new script plus its self-test, in the shape
`scripts/ios-portability-gate.sh` and `scripts/tests/reconcile-pass-lint_test.sh`
establish. Three constraints on them are load-bearing rather than style: the
script adds no `-j`, since the PATH shim in `run-test-suite.sh` owns build
parallelism for every gate descendant; the underlying test output survives into
what the gate replays, so a failure is still diagnosable; and the self-test must
not read to the separate gate-coverage check as a second test lane for
`lib/TerminalCore`.

## Commit progress

Each slice is independently green under `just test`. Ordering is forced: the
budget cannot be armed before the tree clears it with margin.

- [x] **1. Reshape the 710 ms test.** Change one file, with its assertions
      untouched, and record the before and after cost.
- [x] **2. Establish the margin.** Measure the package cold and complete at half
      the budget, reshape what sits above that line, and record the resulting
      distribution. Nothing above the line is a legitimate outcome, and the
      distribution still gets recorded. If more than a couple of functions sit
      above it, stop and put the choice between reshaping them and moving the
      limit to the user; do not absorb it silently.
- [ ] **3. The budget becomes a package property.** Confirm a consumer's graph
      loads with the setting in place, then add it to every target, drop the
      `-Xswiftc` args from the `STEPS` entry while its scratch path stays, and
      rewrite the `.gitignore` comment so it records the measurement window
      instead of a build-argument hash.
- [ ] **4. The budget starts failing.** The enforcing script, its self-test, both
      as `STEPS` entries, and the rule written down where a reader of the build
      would meet it.
- [ ] **5. Close the audit item.** Mark S39 resolved in
      `docs/scratch/2026-08-11-simplification-audit.md`, its status column
      carrying the hashes of the four commits above, the way every settled row
      records its own.

## Verification

1. `swift test --package-path lib/TerminalCore` with no extra flags, and one
   release-configured probe recipe, both showing the budget is in force.
2. The script red on its fixtures and on this tree with slice 1 reverted, green
   after; its self-test green.
3. `bash ./dev-build.sh --no-install` and `./scripts/ios-portability-gate.sh`.
4. `just test` into a file, then grep it: the TerminalCore step passes and its
   self-test step passes.
5. Report, without turning it into a threshold, the TerminalCore step's wall
   clock from two consecutive `just test` runs with no edit between them, and
   the size of the tree it keeps, so the price of the measurement window is on
   the record next to what it buys.

## Implementation discretion

- The script's name, its exit-code vocabulary, its output shape, and how it
  reads the limit and the per-target setting out of the manifest.
- Whether the shared manifest setting is a constant or a small function.

## Implementation notes

- **Slice 1 measurement.** Measured in `lib/TerminalCore/.build-gate` with the
  file touched so the frontend re-type-checked it.
  `truncatingIntoAForcedSplitRecordKeepsItsSideTablesReadable()` cost 696 ms
  against the 500 ms limit before the reshape (the plan's Context recorded 710 ms
  from an earlier run; the two are the same breach measured on different days).
  After the reshape it does not appear at a 100 ms limit, and at a 25 ms limit it
  reports 39 ms.
- **What carried the cost.** Two inference sites, both reshaped without touching
  an assertion: the row-building `map` closure, where `UInt32(97 + (chunk * 8 +
  column) % 26)` and `Terminal.ContentIdentity(1_000 + chunk * 8 + column)` left
  the solver to pick integer overloads across a whole untyped arithmetic tree;
  and the identity comparison, where `cells.map(\.contentIdentity)` is
  `[Terminal.ContentIdentity?]` and the literal right-hand side had to be
  promoted element-wise to match. Both now use annotated locals and explicit
  closure signatures.

- **Slice 2: reshape, not a new limit.** The first cold measurement at the 250 ms
  half-budget line found four function bodies above it, which is the count the
  entry says to put to the user. The user chose to reshape all four and keep the
  500 ms enforced limit. Giving the worst survivor -- the 448 ms `@Test(arguments:)`
  generator -- a factor-of-two margin would mean raising the limit to about
  900 ms, and the 710 ms regression this plan exists to catch would then pass
  unnoticed. Moving the limit disarms the guard against its own motivating case.
- **Slice 2: what carried the cost.** The four, as measured cold at a 250 ms
  limit (log preserved at the gitignored `.build/calib-250.log`):
  - 448 ms, the `@Test(arguments:)` generator for `reconstructsUnfinishedInput`.
    The tuple array mixed bare integer literals with `Array(String.utf8)` calls,
    so the solver picked the element type across all five rows at once. It now
    carries `as [(prefix: [UInt8], continuation: [UInt8])]`. The test still runs
    five cases.
  - 395 ms, `chunkInvariantFixtureNames()`. A `flatMap`/`filter`/`map`/`filter`/
    `sorted` chain over untyped closures became a loop with annotated locals. The
    milestone-8 exclusion keyed on the last path component of the composed name,
    which is the file stem, so it now reads the stem directly.
  - 340 ms, `assert(_:against:replyBytes:inputBytes:clipboardWrites:semanticEvents:)`.
    Split into `assertSideChannels`, `assertStyling`, `assertCellContent`,
    `assertText`, and `assertScreenState`, grouped by concern, with every
    assertion moved verbatim.
  - 272 ms, `alacrittyManifestCoverage()`. Repeated `["adopted", "adapted"]`
    literals became `Set<String>` locals and the repeated `filter` became one
    local, which brought it only to 253 ms; splitting the ledger checks and the
    milestone-8 fixture-shape loop into helpers finished the job.
- **Slice 2: the assertion order moved, the assertions did not.** Splitting
  `assert` reorders a few independent `#expect` blocks -- viewport text now runs
  before `cellKinds`, history text before the cursor. The blocks share no state
  and none of them returns early, so the set of assertions a fixture makes is
  unchanged.
- **Slice 2: the resulting distribution.** A cold, complete `swift test
  --package-path lib/TerminalCore` in a disposable scratch tree at the 250 ms
  half-budget line reports nothing at all, and all 1173 tests pass. A second cold
  build at a 100 ms limit reads the top of the real distribution rather than a
  pass bit: `validateProvenance` 210 ms, `windowsTerminalManifestCoverage()`
  201 ms, `kuhnStressCorpus()` 164 ms, `assertAlacrittyLedger` 157 ms,
  `completeLegacyControlKeyMatrix()` and
  `anchorlessResizeBlanksNothingAndRecovers()` 152 ms each,
  `canonicalTopology()` 131 ms, `collectionBasics()` 124 ms, then
  `scheduleContract()` and `hardResetMatrix()` at 123 ms, with a tail of thirteen
  more between 100 and 116 ms. The worst survivor clears the 500 ms limit by
  2.4x, so I4 holds with room to spare.
- **Slice 2: the numbers move between runs.** `validateProvenance` measured
  197 ms on one cold run and 210 ms on the next with no edit in between, which is
  the wall-clock noise AR2 names. It is one more reason the margin, not the
  reading, is what makes the limit safe to arm.
