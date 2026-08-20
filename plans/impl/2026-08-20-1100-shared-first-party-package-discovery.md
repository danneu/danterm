# One owner for the first-party package set (BUILD-5)

Source: `docs/scratch/2026-08-18-construction-audit.md`, BUILD-5, verified
against `5afabffe` on 2026-08-20.

## 1. Problem

Four gate checks each carry a private copy of "where first-party Swift packages
live", and each one passes as long as its own copy resolves to something:

- `scripts/gate-test-coverage-lint.py` and `scripts/manifest-ownership-lint.py`
  both hold the tuple `("Package.swift", "lib/*/Package.swift",
  "ios/*/Package.swift")` under an identical comment.
- `scripts/ios-portability-gate.sh` holds the same list as a bash array, with
  the only written statement of the policy: `references/` and `docs/` hold
  external and throwaway trees, so a manifest there is not ours to police.
- `scripts/core-purity-lint.sh` sweeps `lib/*/Sources/*/` and
  `ios/*/Sources/*/` -- the same root list at module granularity. This copy
  appeared on 2026-08-19, one day after the audit named the first three, which
  is the drift the finding predicts.

A `Package.swift` added under any other root -- `tools/` already exists and
holds two executable-target directories -- gets no ownership check, no
test-estate coverage check, no iOS-pin check, and no purity sweep, while all
four checks keep reporting a pass over a smaller tree than they claim to
police. No check can notice, because none of them knows what the whole set of
first-party manifests is.

Load-bearing premises, checked:

- `git ls-files '*Package.swift'` returns the root manifest, eight under
  `lib/`, two under `ios/`, and three spikes under
  `docs/research/35-ios-remote-client/` that are deliberately not first-party.
  Excluding `docs/` and `references/` from the tracked set leaves exactly the
  eleven packages the four checks police today.
- All four checks re-root onto a fixture tree through an env seam
  (`GATE_TEST_COVERAGE_LINT_ROOT`, `MANIFEST_OWNERSHIP_LINT_ROOT`,
  `IOS_PORTABILITY_GATE_ROOT`, `CORE_PURITY_LINT_ROOT`). Every one of those
  fixtures is built at runtime under `mktemp -d` /
  `tempfile.TemporaryDirectory`, so any of them can be made a real git
  repository. `scripts/tests/docs_lint_test.py` already does exactly that for
  the one existing git-backed check, and says why: a fixture that is not a repo
  exercises a different code path than the tree does.
- `scripts/manifest_targets.py` is already the shared reader both Python lints
  import for "what targets does this manifest declare"; it knows nothing about
  which manifests are ours.
- `scripts/docs-lint.py` is the existing git-backed gate check (positional
  optional root, `git ls-files` at that root).
- `scripts/gate-test-coverage-lint.py` reads `scripts/run-test-suite.sh`'s
  `STEPS` array as text, so adding gate steps feeds another check.
- No script under `scripts/` uses `mapfile`/`readarray`; while-read loops are
  the house pattern.
- `docs/design/2026-08-17-package-owns-its-targets.md` O1 says "the nearest
  first-party `Package.swift`" without saying what makes a package first-party.
- `references/` is gitignored, so for a tracked-files check only the `docs/`
  exclusion does work today; the policy still states both, because it is about
  trees, not about what happens to be ignored.
- Nothing else enumerates package roots: `justfile` and
  `.github/workflows/ci.yml` name single packages; no other script globs
  `lib/*` or `ios/*` at package granularity. The four checks are the whole
  consumer set.
- `ios-portability-gate.sh` changes directory into its root before it does
  anything else, so a sibling-relative path captured after that point is wrong
  under the seam; `core-purity-lint.sh` already captures its own directory
  first.
- `ios-portability-gate.sh --package <path>` never consults the manifest list.
  It checks that `<path>/Package.swift` exists and pins iOS, then builds that
  one package: an explicit single-target hatch for someone debugging by hand,
  not an enumeration.
- There is no top-level `Sources/` directory, so the root package contributes
  no modules to a `Sources/*/`-per-package sweep.
- `core-purity-lint.sh` skips a glob that matches nothing
  (`[[ -d "$module" ]] || continue`), so its sweep succeeds over zero modules
  today.

## 2. Decision

Define a first-party package once, as a discovery rather than a list: every
file git tracks at the check's root whose basename is exactly `Package.swift`
and which is not under `references/` or `docs/`. The discovery lives in
`scripts/manifest_targets.py`; all four checks derive their package set from it
-- the Python lints through an import, the shell scripts through a list mode of
the same module. Each check's self-test fixture becomes a real git repository,
so every check runs the same discovery in test as in the tree.

Desired outcome, by construction: a first-party `Package.swift` that no gate
check looks at becomes unrepresentable. There is no root allowlist to add a
package to and no completeness reconciliation to keep honest -- a tracked
manifest outside the excluded trees is in the set for all four checks, wherever
it sits. A new tracked package under `tools/`, a future `ios/`-sibling, or
anywhere else is policed the day it is tracked.

Behavioral scope:

- The discovery carries the whole policy: tracked-only, and the two excluded
  trees. The policy sentence currently in `ios-portability-gate.sh` moves to the
  discovery and is written once.
- The four checks keep their verdicts, their seams, and their CLI surface.
  `ios-portability-gate.sh --list` / `--package` keep their stdout shape;
  `scripts/run-test-suite.sh` builds its iOS steps from `--list` and must not
  notice the change.
- `--package <path>` stays outside discovery. It answers "build this path for
  iOS", not "is this package ours", and it is the hatch for hand-checking a
  package that is not tracked yet. Only `--list` -- the form the gate itself
  runs -- enumerates, so only `--list` reads the discovery.
- The purity sweep's module set becomes "every `Sources/*/` directory under a
  discovered package" instead of its own globs -- the package directories, not
  the targets the manifests declare, because the root manifest's targets live
  in `app/`, `cli/`, and `tools/` and pulling them into the sweep would be a
  coverage change this plan does not make. The lint's header comment stops
  describing its own globs.
- Discovery never reaches an untracked manifest. `.build*/checkouts` dependency
  manifests and the synthetic `Package.swift` that
  `scripts/terminal-headless-draw-compare.py` writes into a temp tree are
  untracked, so no check enumerates them, in the tree or in a fixture. The
  `--package` hatch is the one way to reach an untracked or excluded manifest,
  and only because its caller typed that path.
- The ADR `docs/design/2026-08-17-package-owns-its-targets.md` points
  "first-party `Package.swift`" at the discovery so the term has a definition.

## 3. Invariants

- **I1 -- One discovery.** Exactly one place in the tree decides which
  manifests are first-party, and every gate check that enumerates packages or
  their modules derives its set from it. A grep for `lib/*/Package.swift`,
  `ios/*/Package.swift`, or the equivalent module globs outside that place
  finds nothing.
- **I2 -- Location is not a filter.** A tracked `Package.swift` outside the
  excluded trees is in the set for all four checks regardless of which
  directory it sits in. In particular, a package under a root none of the
  four checks knew about today is enumerated by every one of them.
- **I3 -- Excluded trees are never discovered.** A manifest under `references/`
  or `docs/` is enumerated by none of the four checks. "Enumerated" means
  reached by discovery; a path a caller names on the command line is not
  enumeration, and `--package` remains the one route to such a manifest.
- **I4 -- Discovery sees tracked files only.** Discovery's universe is every
  file git tracks at the check's root whose basename is exactly
  `Package.swift`; an untracked manifest anywhere, and a tracked
  `FooPackage.swift`, are invisible to it.
- **I5 -- Discovering nothing is a failure.** The discovery fails, rather than
  returning an empty set, when git reports no first-party manifests at its
  root. Without this a hollow pass is exactly the outcome this plan removes,
  and `core-purity-lint.sh`'s sweep today succeeds over zero modules.
- **I6 -- Seams survive.** Each of the four checks still re-roots onto a
  fixture tree through its existing env seam; that fixture is a git repository,
  and the shell scripts find the discovery module beside themselves, not under
  the fixture root.
- **I7 -- Verdicts unchanged.** Over the current tree, the three manifest
  consumers -- the ownership lint, the coverage lint, and
  `ios-portability-gate.sh --list` -- enumerate exactly the eleven packages
  they enumerate today: the root, the eight under `lib/`, and the two under
  `ios/`. The purity sweep enumerates exactly the modules it sweeps today; the
  root package joins its package set but adds no module, because the repo root
  has no `Sources/` directory.

## 4. Proof obligations

- **PO1 (I2)** -- each of the four self-tests places a tracked package under a
  root outside `lib/` and `ios/` in its fixture repo, and asserts that check
  reaches it: the ownership lint and the coverage lint report on its targets,
  the iOS gate lists it, and the purity sweep visits its `Sources/*/` module.
  This is the load-bearing proof of the refactor -- a check that kept a private
  glob passes every other case in these suites.
- **PO2 (I3, I4)** -- each fixture repo also holds a tracked manifest under
  `docs/` and an untracked manifest outside the excluded trees, and no check
  enumerates either. The iOS gate's suite additionally pins the hatch: for both
  of those packages, `--package` still builds them, so a later reading that
  routes `--package` through discovery fails a test rather than passing
  silently.
- **PO3 (I1, I6, I7)** -- the four existing self-tests
  (`gate_test_coverage_lint_test.py`, `manifest_ownership_lint_test.py`,
  `ios-portability-gate_test.sh`, `core-purity-lint_test.sh`) keep their
  current cases and verdicts once their fixtures are git repositories. They are
  the characterization suite for the refactor; none names the old tuple, so a
  verdict change is a regression, not an expected edit.
- **PO4 (I5)** -- a fixture repo with no first-party manifest makes each check
  fail with a message saying the discovery found nothing, rather than pass.
- **PO5 (I1)** -- the list mode of the discovery, pointed at a fixture repo,
  prints exactly the first-party manifests and omits the ones under `docs/` and
  `references/` and the untracked one.
- **PO6 (wiring)** -- `just test` still passes; `scripts/run-test-suite.sh`
  still derives its per-package iOS steps from `--list`.
- **PO7 (manual, from the audit)** -- add `tools/Scratch/Package.swift`
  declaring a target and a test target, track it, run the gate: it fails with
  the real coverage complaint (no gate lane runs its tests), not with silence.

## 5. Non-goals / Accepted risks / Rejected ideas

Non-goals:

- Reading purity profiles from `Package.swift` (BUILD-1's residue). The
  purity policy stays in `scripts/core-purity-policy.conf`; only the sweep's
  package enumeration changes.
- Orphaned self-test detection (BUILD-2) and scratch-tree placement (BUILD-3),
  though both touch neighbouring regions of the same files.
- Any change to what the four checks assert about a package once they have
  found it.
- Policing where a first-party package may sit. The discovery admits any
  tracked location; a misplaced package is caught by the coverage and ownership
  complaints it then earns, not by a placement rule.
- Restricting `ios-portability-gate.sh --package` to first-party packages. It
  is a manual hatch on a path its caller typed, and refusing an untracked path
  would break the case it exists for: hand-checking a package before it is
  tracked.

Accepted risks:

- **AR1** -- Two shell scripts now shell out to Python for their package list.
  Both already run under a gate whose other steps are Python; the cost is one
  interpreter start per step.
- **AR2** -- A new package is unpoliced until it is `git add`ed. Tracked-only
  is what keeps dependency checkouts and scratch manifests out, and the window
  closes at the commit that would ship the package.
- **AR3** -- All four checks now require their root to be a git checkout, so
  none of them runs over an unpacked export. The gate only ever runs in a
  checkout, and `docs-lint.py` already has this requirement.

Rejected ideas:

- **RI1 -- Declared root patterns plus a completeness check that reconciles
  them against `git ls-files`.** Two statements of the same set that can
  disagree, plus a step whose only job is to notice the disagreement; the
  discovery makes the property hold by construction instead. The earlier form
  of this plan rejected git-backed discovery on the grounds that the fixtures
  are not git repositories, which is not a constraint: they are built at
  runtime under `mktemp`, and `docs_lint_test.py` already `git init`s one.
- **RI2 -- Keep four copies and only add a completeness check.** Silent drift
  becomes loud drift, but a fifth copy is still one grep away; one owner is
  what makes the copy count stop growing.

## 6. Implementation discretion

- The discovery's Python names, the list mode's flag spelling, and whether the
  shell scripts read it with a while-read loop or otherwise.
- The discovery's enumeration order. It is a set to every consumer;
  `run-test-suite.sh` only counts the `--list` lines, and the "longest-first"
  comment there is about placing the iOS steps ahead of everything else, not
  about their order among themselves.
- Whether the discovery copies `docs-lint.py`'s eight-line `git ls-files`
  helper or the helper moves into the shared module (`docs-lint.py`'s
  hyphenated name makes it unimportable without `importlib`).
- Which root outside `lib/` and `ios/` each fixture uses for its PO1 package.

## Implementation notes

- Updated `docs/design/2026-05-28-pure-core-support-split.md` because its durable
  purity coverage contract named the module globs this change removes.
