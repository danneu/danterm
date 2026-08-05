# Speed Up the Fetch-References Test Suite

## Problem and desired outcome

`scripts/tests/fetch_references_test.py` constructs the same two-commit Git
origin before each of its 13 tests. That repeats roughly 156 setup-related Git
subprocesses, including for CLI and swap tests that do not mutate the origin.
A three-run standalone baseline on the measured checkout was 10.25, 10.12, and
10.34 seconds. Fixture setup accounted for 4.47 seconds (43.6%) and teardown for
0.08 seconds.

Keep all existing behavioral coverage in `just test`, while removing redundant
fixture work and total test CPU consumption without weakening test isolation.
The parallel gate may remain bounded by its longer Swift steps, so reducing its
end-to-end wall clock is not the acceptance criterion.

## Decision

Construct the immutable origin repository, its commits, tag, and pinned SHAs
once per test-suite process. Continue giving every test an independent temporary
root and `references` destination.

The shared origin becomes read-only after construction. Tests that change a
checkout's HEAD, sparse cone, cache record, Git wrapper, staged tree, or signal
state continue to operate only on test-local paths. The production fetcher and
the `just test` step list do not change.

## Invariants

- Every existing fetch, cache, CLI, failure, and interruption scenario remains
  in the default local gate.
- Mutable checkout state remains isolated between tests; test order cannot
  affect outcomes.
- The suite fails if any test changes the shared origin's HEAD or worktree.
- The interrupt-during-transfer test still controls only its child process and
  preserves its test-local prior checkout.
- Class-scoped and test-scoped temporary resources are removed at their
  corresponding lifecycle boundaries.

## Proof obligations

- Run all 13 existing tests and preserve their assertions, including failed
  fetch rollback and both interruption cases.
- Permanently verify after the suite that the shared origin remains at its
  constructed HEAD with a clean worktree, so future tests cannot introduce
  order-dependent origin mutations.
- Confirm fixture construction drops from 156 Git subprocesses per suite to 12,
  excluding the post-suite immutability guard. This directly attributable
  count, rather than whole-suite timing, is the optimization gate.
- Compare three standalone runs before and after on the same machine and report
  the median and fixture-setup share. Timing remains a measurement with no
  pass/fail threshold.
- Run `just test` to prove reliability under the bounded parallel gate, and
  report both this step's duration and the overall gate duration without
  requiring either wall-clock value to improve.

## Non-goals

- Do not remove, split, or relocate fetch-reference coverage.
- Do not change `scripts/fetch-references.py` behavior or public CLI output.
- Do not optimize the Git operations that exercise the fetcher's production
  path; only redundant test-fixture construction is in scope.

## Accepted risks

- The end-to-end `just test` wall clock may not improve because longer Swift
  steps can remain on the critical path; the accepted benefit is lower
  standalone runtime and less redundant gate work.
- The permanent guard does not detect changes outside the origin's HEAD and
  worktree, such as added or moved refs. Current tests are verified not to make
  those changes, and broader guard mechanism is not justified by a current
  failure.

## Rejected ideas

- Copying a template origin per test would remove the shared-state invariant,
  but measured 13-copy cost is 0.91 seconds versus 0.33 seconds for one shared
  construction; that cost is not justified to replace the small guard.

## Implementation discretion

- The exact unittest lifecycle helpers are discretionary provided the shared
  origin is immutable and every mutable destination remains per-test.

## Implementation notes

- Three post-change standalone runs were 3.10, 2.94, and 2.93 seconds, a
  2.94-second median versus the 10.25-second baseline. Median shared-fixture
  construction was 0.161 seconds, about 5.5% of the new suite median.
- Instrumentation counted 12 construction Git calls and 14 including the two
  post-suite guard calls. The 74-step parallel gate passed in 48 seconds, with
  the fetch-reference suite reporting 4 seconds.
