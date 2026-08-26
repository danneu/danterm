# The type-check budget leaves the manifest, and the engine becomes publishable

## Context

`lib/TerminalCore/Package.swift` declares its type-check budget through
`.unsafeFlags`. SwiftPM refuses `unsafeFlags` from a versioned dependency, so the
package can only ever be consumed by path -- which is to say, only inside this
repository. That is snag 5 of
[docs/scratch/2026-08-26-terminal-engine-reusability.md](../../docs/scratch/2026-08-26-terminal-engine-reusability.md),
and it blocks the whole distribution story: no outside consumer, and no mirror
(snag 7) for anyone to depend on.

The budget itself stays. It exists because a 710 ms function body regressed and
sat unread for five days, and it is enforced by
`scripts/type-check-budget-gate.sh`, which turns a compiler warning into a red
step. What changes is where the measurement comes from.

Two premises this rests on, both verified:

- `lib/TerminalCore` is the only first-party manifest using `.unsafeFlags`. Every
  other package, `lib/TerminalPTY` included, already has the shape this one
  reverts to.
- The gate is local-only: CI runs `./build-app.sh` and never `just test`. The
  gate's worker discards a passing step's output, so the manifest-wide warnings
  in the app build, the probes, and the iOS cross-compile were never read by
  anything -- only the gate lane ever produced a verdict.

This reverses D1 of
[plans/impl/2026-08-18-0120-terminalcore-type-check-budget.md](../impl/2026-08-18-0120-terminalcore-type-check-budget.md),
under the trigger that plan wrote for itself in AR5: publishing is now on the
table, so the setting is revisited.

## Decision

**The enforcing script owns the measurement; the manifest owns nothing but the
package.**

- **D1.** The budget flags move out of the manifest and into
  `scripts/type-check-budget-gate.sh`, which supplies them to whatever build
  command it is handed. The script is then the single definition of the limit and
  the only thing that can arm or disarm it. The gate's step string does not
  change, so the two checks that parse it -- `scripts/gate-test-coverage-lint.py`
  and `scripts/build-path-policy.sh` -- are untouched.
- **D2.** Command-line flags reach dependency targets too. The budget is
  package-scoped: the verdict reads bodies in the measured package's own sources,
  and a diagnostic from a dependency target is ignored.
- **D3.** A new gate lint keeps `lib/TerminalCore` and `lib/TerminalPTY` free of
  `unsafeFlags`, so the blocker cannot return as a manifest edit nobody notices.
  The rule is scoped to the two packages the reuse story intends to publish, not
  to every first-party manifest.
- **D4.** Wide measurement is given up deliberately: the gate lane becomes the
  only build that measures type-check cost. Nothing else is taught the flags.
- **D5.** The last step of the work closes snag 5 in the reusability scratch doc,
  in the form snags 2, 3, 4, and 8 already use there: the heading marked done, a
  paragraph naming the promoted plan and saying where the shipped fix differs
  from what the snag proposed, the snag's original text kept below it, and the
  `## Sequencing` paragraph updated to the snags that remain. The distribution
  story is tracked in that doc, so a fix that lands without it leaves the next
  reader working from a closed snag.

## Invariants

- **I1.** Neither engine package declares `unsafeFlags`, so each resolves as a
  versioned dependency.
- **I2.** When the gate's build type-checks a body in the measured package over
  the limit, `just test` fails, and the failure names the function, its location,
  and its measured cost. The verdict is per diagnostic, so this holds whatever
  else the same build reported.
- **I3.** The gate cannot run a build that is not measuring: it supplies the
  flags itself, and it still refuses to run without a scratch tree no other
  command warms.
- **I4.** A breach outside the measured package's sources does not fail the gate.
- **I5.** Every consumer of the engine packages still builds and its tests still
  pass; no product behavior changes.

## Proof obligations

- **PO1 (I1).** The lint is red on a fixture manifest carrying `unsafeFlags` and
  green on the tree once the manifest is cleaned. Separately, and once by hand:
  a minimal consumer that imports a `TerminalCore` product and depends on it
  through a local *git* URL -- a source-control dependency, which SwiftPM does
  not exempt -- fails to build before this change and builds after. That is the
  snag actually closing, and it becomes a standing check only when snag 7's
  mirror exists.
- **PO2 (I2).** Through the script's existing canned-output runner seam, a breach
  fails and a clean run passes, keyed on the compiler's diagnostic identifier
  rather than its prose. Against the real tree, with the 696 ms body's reshape
  reverted, the step is red while every test passes -- the same demonstration
  that armed the budget originally.
- **PO3 (I3).** The command the script runs carries the measurement flags,
  observed through the runner seam rather than asserted about the source. The
  refusal without a scratch path keeps its existing case.
- **PO4 (I4).** A canned breach in a dependency's path leaves the step green. The
  path form the toolchain actually emits is measured on a real build first, and
  the fixture reproduces that form rather than a guessed one.
- **PO5 (I5).** `just test` green, plus a release-configured probe recipe,
  `bash ./dev-build.sh --no-install`, `./scripts/ios-portability-gate.sh`, and
  the MiniTerm build -- the five shapes of consumer the manifest edit touches.

## Non-goals

- Keeping the budget in force for the app build, the probes, the iOS
  cross-compile, or a bare `swift test`. D4 gives that up.
- Giving `lib/TerminalPTY` or any other package a budget of its own.
- Changing the 500 ms limit, or reshaping any function body other than the one
  PO2 temporarily reverts.
- Reporting breaches in dependency sources. The budget is this package's, and
  the gate discards a passing step's output, so a warning it printed on a green
  step would reach nobody anyway.
- Snags 6 and 7 -- the platform floor and the published mirror. The lint's home
  is chosen so both can add a rule to it later, and neither lands here.

## Accepted risks

- **AR1.** Only one lane measures now, so a breach in a file the gate's tree does
  not have to recompile waits for the next edit to that file. This is the
  existing window (the gate judges what it recompiles), narrowed by nothing and
  widened by nothing; what is lost is the warning a developer might have seen in
  an unrelated build first.
- **AR2.** Classifying a diagnostic turns on the path form the compiler prints. A
  toolchain that changes that form could take a real own-package breach out of the
  verdict. The mitigation is that the fixture reproduces a measured path form
  rather than a guessed one, and that PO2 re-proves the guard against the real
  tree.
- **AR3.** Editing the manifest moves SwiftPM's build-argument hash, so the first
  build after this lands is cold in every tree, the app build included.

## Rejected ideas

- **RI1.** Delete the budget and run it periodically from a `just` recipe. A
  signal nobody is forced to read is what already failed here once; a periodic
  run also has to build cold to see anything, and reports breaches detached from
  the commit that caused them. The gate step costs nothing extra -- it wraps a
  lane that runs anyway.
- **RI2.** Put the flags in the gate's step string instead of inside the script.
  Workable, but it splits the limit from its enforcer, puts the flag list where
  two other checks parse the same string, and leaves the vacuous-pass question
  alive -- a step string edited to drop the flags would pass having measured
  nothing.
- **RI3.** Make the manifest setting conditional on an environment variable. A
  manifest whose output depends on the environment is nondeterministic, and a
  consumer's build would then differ from the gate's for reasons nothing records.
- **RI4.** Strip the flags in snag 7's generated mirror. That makes the manifest
  the one file that deliberately differs between source of truth and mirror,
  which is the divergence the mirror exists to make impossible.

## Critical files

`lib/TerminalCore/Package.swift` (the shared setting and its 35 uses),
`scripts/type-check-budget-gate.sh` and `scripts/tests/type-check-budget-gate_test.sh`,
one new lint plus its self-test registered in `scripts/run-test-suite.sh`'s
`LINT_STEPS` and `STEPS`, the budget section of
[agent-docs/build-details.md](../../agent-docs/build-details.md), and snag 5 of
the reusability scratch doc.

The lint follows the shape `scripts/private-file-mode-lint.sh` establishes: a
root argument or environment seam so its self-test proves each verdict against a
fixture tree, per-violation detail on stderr, and the rule's rationale through
`scripts/lib/lint-rationale.sh`.

## Implementation discretion

- How the script reports breaches it deliberately did not judge.
- Whether the lint is bash or Python, and whether it reuses
  `scripts/manifest_targets.py`'s manifest discovery.

## Commit progress
- [x] 1. The gate script owns the type-check budget, not the manifest
- [ ] 2. A lint keeps the engine packages free of `unsafeFlags`, and snag 5 closes

## Implementation notes

- SwiftPM already hands every non-root package target `-suppress-warnings`, so a
  dependency's over-budget body never reaches the gate's output on the real lane.
  D2's path-scoped verdict is implemented and self-tested anyway: it is what makes
  the scoping a property of the gate rather than of SwiftPM's current flag choice.
  The gate lists what it did not judge, under `Implementation discretion`. That is
  a line of output, not the reporting the Non-goals rule out: nothing classifies
  the diagnostic or acts on it.
- The compiler prints a source excerpt under each diagnostic, and the excerpt's
  marker line repeats the message and the identifier. The verdict keeps only lines
  that start with a location, so an excerpt is not counted as a second breach in an
  unknown package. The previous grep matched those lines too.
- PO1's by-hand check does not reproduce as written. SwiftPM classifies a `file://`
  git URL as `localSourceControl` and exempts it from the `unsafeFlags` refusal
  exactly as it exempts a path dependency, so a consumer pinned to a tag carrying
  the old manifest still builds. The positive half was taken instead: a consumer
  that depends on the package through a local git URL and pins the tag carrying the
  cleaned manifest resolves and builds as a versioned source-control dependency.

## Follow Up

- Demonstrate the `unsafeFlags` refusal against a *remote* source-control
  dependency once snag 7's mirror exists. A `file://` git URL is exempt, so PO1's
  by-hand check cannot show the before/after difference from a local clone.
