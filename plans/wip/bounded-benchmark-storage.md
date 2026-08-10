# Bounded Benchmark Storage

## Problem and desired outcome

DanTerm's performance tooling currently treats `.build/` as disposable but does
not enforce retention. Agent-driven work created 107 immutable benchmark arms
and 2,229 per-block run directories in eight days: about 89 GiB of arm caches
and 44 GiB of copied benchmark app bundles. Every new source/toolchain identity
and every measured block adds another directory, so storage is unbounded unless
an operator runs `just clean`.

Benchmark-owned storage should clean itself without invalidating a running
comparison, prematurely deleting evidence within its stated retention bounds,
or deleting ordinary SwiftPM build products.

## Decision

Performance entry points share one storage policy:

- Reusable arm and benchmark-build caches are retained for at most seven days.
  Arms use a 15 GiB least-recently-used budget; benchmark build caches use a
  2 GiB budget.
- Completed app/feed profiles and headless-draw artifacts are retained for at
  most seven days and within a combined 5 GiB budget, with oldest artifacts
  removed first.
- Comparison evidence, candidate screens, calibration/validation results, GUI
  contract results, and other retained benchmark evidence are kept for at most
  seven days and within a combined 5 GiB budget, with oldest artifacts removed
  first.
- Successful per-block run directories are transient and removed when their
  result has been captured by the enclosing comparison.
- Failed per-block logs and JSON are retained for seven days within a combined
  1 GiB budget, with completion-time oldest diagnostics removed first. Copied
  app bundles are removed after teardown even when a block fails.
- Cleanup runs automatically around benchmark activity and is also exposed as
  an explicit `just benchmark-clean` command.

The policy owns an explicit manifest of every `.build` root and top-level file
produced or retained by benchmark, calibration, screening, validation,
profiling, reporting, and headless-draw commands. Every entry belongs to
exactly one category above. A performance entry point may not introduce a new
storage root without registering it in that manifest and its finite age and
size policy.

Reusable caches update recency when used and evict least-recently-used entries.
Retained evidence, profiles, and diagnostics evict by completion time; reading
or reporting an artifact does not extend its retention.

Cleanup and benchmark use coordinate through a cross-process shared/exclusive
lease. Concurrent agents may use cached arms and profiles together; cleanup
may remove storage only when no benchmark holds a shared lease. Automatic
cleanup skips instead of delaying active work, and a later benchmark teardown
retries it.

`just benchmark-clean` also uses nonblocking exclusive acquisition. When work
is active it reports that no cleanup occurred and exits successfully without
waiting or deleting anything.

`just benchmark-clean-all` provides an explicit full purge of enumerated
benchmark-owned roots. It refuses to run while benchmark work is active and
does not use a broad `.build/*` match.

## Invariants

**I1. Finite retention after successful cleanup.** Every benchmark-owned
category satisfies both its age limit and size budget. Age eviction is
unconditional. After expired entries are removed, a single newest cache or
artifact larger than its category's whole size budget remains usable and is
reported as over budget rather than leaving the category empty.

**I2. Active-use safety.** Cleanup never removes an arm, profile, executable,
log, or evidence file that a running benchmark or profiler can still read.
Agent concurrency must not serialize benchmark execution merely to enforce
retention.

**I3. Evidence ownership.** The enclosing comparison artifact remains the
durable result of a successful comparison for up to seven days within the retained
evidence budget. Retained profiles remain self-contained, including their
copied symbol-bearing executable and identity metadata. Failed blocks retain
their lightweight diagnostics within their seven-day and 1 GiB bounds.

**I4. Cache validity is unchanged.** Retention does not weaken immutable source
capture, cache-key identity, executable SHA-256/Mach-O UUID verification, or
the rule that incomplete arm builds cannot be cache hits.

**I5. Cleanup scope is narrow.** Automatic and explicit benchmark cleanup touch
only storage in the benchmark ownership manifest. The manifest covers every
current benchmark producer and retained-artifact reader; general SwiftPM
products and unrelated `.build/` contents are not part of the policy.

**I6. Eventual cleanup after interruption.** A crashed or killed agent cannot
hold a lease after its process exits. The next cleanup removes abandoned
incomplete entries and applies normal retention to legacy run directories.
Legacy copied app bundles are reclaimable immediately; legacy diagnostics use
the same seven-day window as new failures.

**I7. Observable accounting.** Explicit cleanup reports storage and entry
counts removed by category. Automatic cleanup stays quiet when no action is
needed and emits a concise summary when it reclaims data, encounters an
over-budget singleton, or skips because work is active.

## Proof obligations

**PO1 (I1).** Behavioral tests prove every manifest category applies age
eviction before size eviction and preserves only a non-expired oversized newest
singleton with an over-budget report. Reusable caches reach their budgets in
least-recently-used order; comparison/calibration/screening/validation
evidence, app/feed/headless-draw profiles, and failed-run diagnostics reach
theirs in completion-time oldest-first order, unaffected by later reads.

**PO2 (I2, I6).** Cross-process tests prove shared users can run concurrently,
exclusive cleanup cannot delete their storage, automatic cleanup skips active
work, and cleanup succeeds after the users or an interrupted owner exit.

**PO3 (I3).** Harness tests prove successful block directories disappear only
after capture, failed app bundles disappear while logs and JSON obey both their
age and size bounds, retained comparison evidence remains readable within its
bounds, and retained profiles still contain their identity and symbol-bearing
executable.

**PO4 (I4).** Existing and new cache tests prove a retained cache hit still
re-verifies its executable identity, incomplete entries cannot be reused, and
recency changes do not change cache identity.

**PO5 (I5, I7).** Command-level tests seed every manifest category plus
unrelated `.build/` paths, prove both cleanup commands affect only their
documented scope, and verify cleanup summaries. They prove
`just benchmark-clean` returns successfully without waiting or deleting while
work is active, while full cleanup refuses.

**PO6 (I6).** Migration tests cover existing timestamped run directories and
pre-policy cache, comparison, calibration, screening, validation, profile,
headless-draw, and failed-run entries so the first automatic or explicit
cleanup reclaims the current tree without requiring `just clean`.

**PO7 (I2, I5).** Command-level behavioral tests cover each distinct
storage-producing and retained-artifact-reading entry-point family: paired
comparison, calibration/screening/validation, direct app benchmarking,
app/feed profiling, profile reporting, GUI contract capture, and headless draw.
Each proof shows protection lasts for the command's full read/write lifetime
and that the command participates in automatic cleanup.

## Non-goals and rejected ideas

- **Non-goal:** bounding all of `.build/` or SwiftPM's package-local build
  directories. This plan owns only benchmark storage.
- **Non-goal:** preserving successful per-block logs after their result enters
  the comparison artifact.
- **Rejected idea:** relying on agent instructions, cron, or manual
  `just clean`. Those paths do not make retention part of every benchmark
  lifecycle.
- **Rejected idea:** pruning with age-only filesystem scans. Age alone does not
  provide a hard bound and an unlocked scan can race concurrent agents.

## Implementation discretion

- The storage accounting mechanism and lease implementation are discretionary
  provided they enforce the observable budgets and cross-process invariants.
- Internal placement of retention code and test seams is discretionary; all
  performance entry points must share the same policy rather than reimplement
  it independently.
