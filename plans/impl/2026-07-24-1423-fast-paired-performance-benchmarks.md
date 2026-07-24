# Fast paired performance benchmarks

Extracted from research done in: /Users/dan/Code/danterm-terminal-engine/docs/research/7-fast-performance-benchmarks.md

## Problem and desired outcome

DanTerm's current performance commands repeatedly launch one app and compare
today's measurements with compatible historical records. That workflow takes
10-15 minutes for the redraw suite, exposes optimization decisions to machine
drift between sessions, and measures at the obsolete 80x24 geometry.

The replacement answers the routine question, "Did this code change make the
relevant terminal path faster or slower?", by comparing immutable baseline and
candidate builds within one machine session. One selected `quick` workload
must finish in under 60 seconds once the exact build products are cached. A
complete five-workload `confirm` must finish in under five minutes on the same
boundary.

The frozen design is calibration-backed at 179x66 on the user's MacBook. It
does not claim independently held-out-certified error rates. The retired
1,560-attempt certification manifest is preserved as research evidence and is
not part of this implementation.

## Decision

The production comparison workflow has two stable surfaces:

- `just benchmark-quick baseline=<revision> workload=<workload>` compares one
  selected workload between the explicit baseline revision and the candidate
  snapshot.
- `just benchmark-confirm baseline=<revision>` compares all five routine
  workloads with the same paired design.

Comparison commands require the operator to name the baseline; they never
infer it from `HEAD`, merge-base, history, or the candidate. The candidate
defaults to an immutable Git tree snapshot of the complete current working
tree: tracked changes and all non-ignored untracked files, without changing
the caller's index. Before either build begins, the command shows the resolved
baseline commit and tree identity, the candidate base commit and tree identity,
and every candidate path captured relative to that base. Both arms build only
from their exported immutable trees in disjoint source and build directories.

Build products are cached persistently by source tree identity, build
configuration, toolchain, and ignored-prerequisite digests. A comparison reuses
an exact cache hit without rebuilding; a cache miss is populated and verified
before the timed comparison begins. The under-60-second quick and under-five-
minute confirm budgets cover the complete cached comparison path, including
cache checks, bundle assembly, launch, warm-up, measurement, and teardown.
Snapshot/export and cache-population time are reported separately, as is total
command wall time, but a cold compilation is not part of the frozen D4 budget.

Both comparison modes materialize each source snapshot once, then measure short
baseline/candidate blocks in a position-balanced, interleaved schedule. The
apps use isolated runtime state but the same stable benchmark bundle namespace,
because calibration found that distinct stable bundle identifiers introduced
a repeatable arm bias. Setup, reset, focus changes, arm switches, and teardown
remain outside the timed blocks.

The routine workload ladder is:

| Workload | Performance question |
| --- | --- |
| Terminal feed | Pure parsing, grid mutation, Unicode handling, and damage policy |
| Scrollback stream | PTY backpressure, actor hops, snapshots, scrolling, and retention |
| Screen-sized content churn | Glyph lookup, shaping, text-run construction, and content replacement |
| Screen-sized style churn | Attribute, color, and style-only replacement |
| Screen-sized incremental mixed updates | Localized content/style damage without full-window work |

Every canonical run uses a fully visible and unoccluded 179x66 window. The
runner rejects measurements when it cannot establish the target geometry,
complete draw acknowledgment and expected damage, AC power, acceptable thermal
state, low-power-mode state, source/binary identity, or complete window
containment.

The obsolete `terminal-app.jsonl` and `terminal-redraw.jsonl` histories are
deleted when the paired workflow replaces their active readers and writers.
They are not migrated or archived: their 80x24, unpaired measurements cannot
answer the new workflow's optimization question. No replacement benchmark
history is created. Every invocation retains its complete evidence in a
per-run artifact directory: source and binary identities, normalized and raw
block measurements, schedule, fixed decision rule, decision, detected
outliers, invalidations, and phase and total wall times. When a result justifies
an engineering change, the change's commit or plan document records the
decision-bearing values inline -- mode, workload, both tree identities, the
median symmetric estimate, and the classification -- with the artifact path as
a supplementary pointer rather than the record itself, because artifacts live
under the disposable `.build/` tree.

Production extracts or reuses the research collector's tested workload block
runners, persistent lifecycle ownership, machine-state validation, balanced
scheduling, workload correctness collectors, and fixed decision function.
Held-out certification machinery remains research-only: manifest generation,
opaque collection indices, append-only ledgers, replacement schedules,
blinding, held-out evaluation, and the retired `collect-one` campaign do not
back `benchmark-quick` or `benchmark-confirm`.

Any invalid block makes the complete command invocation non-decision-eligible:
the runner reports no directional or equivalence decision, preserves every raw
block and invalidation reason, and requires a fresh complete invocation for a
new decision. Routine quick and confirm commands have no individual-block
replacement, partial-evidence continuation, or replacement schedule.

The existing `benchmark-loop`, `benchmark-sample`, and `benchmark-trace`
recipes remain the profiling surface. They build from the local checkout, run
one isolated sustained workload, and publish the PID, executable SHA-256, and
Mach-O UUID used for attachment. They remain diagnostic-only and cannot write
benchmark history.

The old unpaired `benchmark`, `benchmark-one`, `benchmark-core`, and
`benchmark-redraw` recipes are deleted with their history readers and writers.
`benchmark-draw` and `benchmark-draw-app` remain non-history microbenchmarks:
their output is diagnostic and cannot form a cross-session regression claim.

The first production use is the next profiling-backed terminal optimization:
select the workload at the measured bottleneck's narrowest valid boundary, run
`quick` against the pre-change snapshot, and use that paired result to accept,
reject, or revise the experiment. Run `confirm` when the quick result is close,
the change crosses workload boundaries, or the engineering decision warrants
the stronger five-workload evidence.

## Invariants

- I1: Every directional claim compares the intended immutable baseline and
  complete-working-tree candidate binaries in the same valid machine session;
  the baseline is explicit, and history-vs-now never decides a quick result.
- I2: Every completed comparison uses the frozen workload-specific fixed-N
  median rule. There is no early stopping, optional peeking, silent outlier
  deletion, or selective rerun of statistically valid blocks.
- I3: Source assignment cannot be confounded with physical arm position, block
  order, runtime state, or a stable bundle-namespace difference.
- I4: Each workload preserves its named stimulus, timed boundary, normalization,
  reset behavior, and correctness evidence. Speed never makes an invalid
  workload eligible for a decision.
- I5: No durable benchmark history exists. The old unpaired histories are
  absent, and no paired, quick, microbenchmark, or profiled result can form a
  cross-session regression claim.
- I6: Benchmark and profiling commands own only the processes, windows, files,
  and runtime namespaces they create.
- I7: The production claims are limited to the frozen calibration evidence.
  Independent certification is optional future research, not a runtime or
  graduation gate.
- I8: An invalid block invalidates the complete routine invocation. Its
  evidence is retained, but no partial result or replacement block can produce
  a decision.

## Frozen decision contract

Each adjacent source-oriented pair becomes the symmetric percentage
`200 * (candidate - baseline) / (candidate + baseline)`. The decision statistic
is the median of all valid fixed-N pairs.

| Mode | Feed | Scrollback | Content | Style | Incremental |
| --- | ---: | ---: | ---: | ---: | ---: |
| `quick` pairs / threshold | 2 / 4.50% | 2 / 4.05% | 2 / 4.05% | 2 / 4.05% | 2 / 3.80% |
| `confirm` pairs / threshold | 2 / 2.50% | 4 / 1.85% | 4 / 2.15% | 4 / 2.00% | 6 / 1.85% |

`quick` uses a closed +/-1.00% equivalence band. `confirm` uses a closed
+/-0.75% equivalence band. A negative estimate at or beyond the workload's
directional threshold is `faster`; a positive estimate at or beyond it is
`slower`; an estimate inside the closed equivalence band is `equivalent`; and
an estimate between the equivalence band and either directional threshold is
`inconclusive`. MAD scores above 3.5 flag outliers for reporting only. Every
pair count contains complete position-balanced quartets.

Draw blocks contain 50 exact completed draws. Terminal feed measures a
duration-stable fresh 179x66 terminal batch of at least one second. Scrollback
measures one fixed 25,000-line replay through its completed final draw in a
fresh app/session.

## Proof obligations

- PO1 (I1, I3): observable tests prove an explicit baseline is required and
  resolved once; the candidate snapshot includes tracked changes and
  non-ignored untracked files without mutating the real index; both tree
  identities and captured candidate paths are reported before building; each
  suffixed bundle contains its intended immutable source snapshot; the arms
  have isolated runtime state while sharing the same stable bundle identifier;
  source assignment is balanced across physical positions and block order; the
  final report remains source-oriented; a build-product cache hit requires an
  exact match on every key component, so changing the source tree identity,
  build configuration, toolchain, or any ignored-prerequisite digest
  repopulates instead of reusing; and a reused bundle's recorded executable
  SHA-256 and Mach-O UUID are re-verified before the timed comparison begins.
- PO2 (I2): deterministic sample fixtures prove every frozen quick and confirm
  classification, threshold/equivalence boundary, fixed pair count, outlier
  reporting behavior, and the absence of early or partial decisions.
- PO3 (I4): each workload proves untimed reset and settling, exact measured
  stimulus, fresh-state requirements, completed-frame identity, expected final
  state, and workload-specific damage before its timing is decision-eligible.
- PO4 (I4, I6): a GUI contract run proves canonical geometry, complete
  containment and non-occlusion throughout measured blocks, process-scoped
  activation, machine-state invalidation, interruption cleanup, and that an
  unrelated DanTerm instance remains untouched.
- PO5 (I5): the old JSONL files and every active reader, writer, and operator
  instruction tied to them are removed atomically with the replacement, and
  no benchmark or profiling command writes a durable history file.
- PO6 (I6): profiling tests prove attachment uses the published candidate PID
  and binary identity and remains diagnostic-only.
- PO7 (I1-I8): the first real optimization records its pre-change baseline,
  relevant quick decision inline with its decision-bearing values, raw artifact
  paths as supplementary pointers, invocation attempts and
  invalidation reasons, and resulting engineering decision. If confirm is
  invoked, its complete suite result is recorded as well.
- PO8: production timing reports snapshot/export, cache population, cached
  comparison, and total command wall time separately. The cached comparison
  remains under 60 seconds for every quick workload and under five minutes for
  the complete confirm suite on the calibrated machine; the first real use
  also records attempts and invalidations so effective time-to-decision is
  visible.
- PO9 (I8): behavioral tests inject an invalid block at every schedule position
  and prove the whole invocation reports no decision, retains all evidence and
  reasons, and performs no replacement or partial continuation.
- PO10: command-contract tests prove the two stable comparison recipes accept
  the documented inputs, quick selects exactly one workload, confirm runs all
  five, and no comparison, profiling, or surviving microbenchmark command
  reads or writes benchmark history.

All hermetic coverage for PO1, PO2, PO5, PO6, PO9, and PO10 runs in `just
test`. GUI-dependent PO3/PO4 coverage runs through the stable opt-in `just
test-terminal-benchmark-gui` recipe alongside the existing
`test-terminal-viability` surface.

## Non-goals

- No CI performance gate, cross-machine comparison, portable geometry, or
  absolute frame-time target.
- No Ghostty parity requirement. A shared-boundary Ghostty reference remains
  severable future work.
- No adaptive stopping or independent held-out certification.
- No automatic search for optimization ideas. Profiles identify a concrete
  bottleneck, and the user reviews candidate solutions before code changes.

## Accepted risks

- AR1: Calibration is not independent held-out certification. This is accepted
  because raw paired evidence remains inspectable, confirm exists for close or
  consequential decisions, and the estimated 10.4-hour certification campaign
  is disproportionate to local engineering use.
- AR2: The fixed geometry and thresholds are machine-specific. This is the
  intended single-MacBook scope; changes to the machine, geometry, workload
  contract, or decision rule require recalibrating the frozen thresholds before
  directional claims resume.
- AR3: The build-product cache has no contractual retention bound, so a long
  optimization session accumulates one entry per candidate tree. This is
  accepted because the cache lives under the disposable `.build/` tree that
  `just clean` removes, and its failure mode is disk use rather than a wrong
  decision; bounding or evicting entries is left to implementation.

## Rejected ideas

- RI1: Preserve history-vs-now as the quick decision. Same-session pairing is
  the architectural reason the new workflow cancels slow machine drift.
- RI2: Give the two live arms different stable bundle identifiers. Calibration
  demonstrated a repeatable bundle-namespace bias; runtime isolation is
  provided by paths, homes, temporary roots, sockets, and process identity.
- RI3: Resume the partial held-out manifest. Selectively extending an observed
  campaign would not provide the predeclared independent certification claim.
- RI4: Archive or migrate the old JSONL histories. Their method and geometry
  are incompatible with the paired runner, so retaining the data adds
  maintenance surface without supporting a future decision.
- RI5: Add a durable paired-history schema. No decision path reads it and
  ad-hoc-baseline deltas do not compose into a trend; per-run artifacts plus
  contextual commit or plan notes preserve useful evidence without a
  write-only subsystem.

## Implementation discretion

- Internal Python entry points, type and file boundaries, artifact directory
  layout, build-product cache layout and retention/eviction policy, profiler
  duration/template defaults, and workload value spelling are
  implementation choices. The two comparison recipe names and their argument
  roles, the retained profiling recipes, and the existing diagnostic
  microbenchmark names are stable operator-facing contract.

## Commit progress
- [x] 1. Immutable source snapshot and verified build-product cache
- [x] 2. Paired quick/confirm comparison runner and frozen decision report
- [x] 3. Replace the unpaired benchmark surface with the paired recipes

## Implementation notes

- The build-product cache entry *is* the arm root. `terminal-benchmark.sh`
  compiles into `$REPO_ROOT/.build/terminal-benchmark-swiftpm` relative to its
  own location, so a persistent exported source root carries its SwiftPM build
  directory with it and the harness's own `swift build` becomes a no-op on a
  cache hit. This avoids a separate bundle-copying cache layer, at the cost of
  duplicating the harness's build flags in Python;
  `HarnessBuildContractTests` pins those flags against the harness source so
  the two cannot silently diverge.
- Ignored prerequisites (`lib/GhosttyKit.xcframework`, `lib/ghostty-themes`)
  are copied into each arm root with `cp -Rc` (APFS clone, falling back to
  `cp -R`) rather than symlinked. A symlink would leave a populated cache entry
  pointing at mutable repository content whose digest the key already claims;
  a clone keeps the entry genuinely immutable for near-zero cost.
- The candidate snapshot's scratch index lives in a `tempfile` directory, not
  under `.git/`. This branch is developed in a linked `git worktree`, where
  `.git` is a file and any path beneath it fails to open.
- The runner owns its own `make_schedule` instead of reusing the research
  collector's `make_collection_plan`. That function is built around held-out
  machinery the plan scopes to research -- predeclared trials and replacement
  seeds -- and I8 removes replacement from the routine path entirely. The
  production schedule alternates ABBA/BAAB deterministically per quartet rather
  than drawing them from a seed: both are inside the space the calibration
  resampled, and the deterministic form is exactly balanced rather than balanced
  in expectation, and reproducible without seed bookkeeping.
- The physical slot holding the candidate is derived from the candidate tree's
  own identity (`int(tree, 16) & 1`). Both arms launch once per invocation, so
  the slot cannot alternate within a run without relaunching the persistent
  apps; deriving it keeps the assignment reproducible, reported, and varying
  across candidates instead of pinning the candidate to one slot forever.
- The collectors receive the *baseline* arm root as their `repository_root`, so
  the stimulus fixtures and producer script come from a named immutable
  revision. Both arms are then driven by the same stimulus, and a working-tree
  edit to a fixture cannot silently redefine a workload mid-comparison.
- `build_arm` gained a fourth product: `TerminalCoreBenchmark` in
  `lib/TerminalCore`. The terminal-feed workload runs that package through
  `swift run` at SwiftPM's default build path, which the app-bundle prebuild
  never touched -- so before this, a "cache hit" still compiled TerminalCore
  inside the timed comparison phase and charged it to PO8's 60-second quick
  budget. `FeedPrebuildContractTests` pins the prebuild against the feed
  runner's invocation, including the absence of `--build-path`.
- A comparison whose baseline and candidate resolve to the same tree is
  refused rather than run. Both arms would key one cache entry, so every block
  would measure the identical binary and the command would answer `equivalent`
  with full confidence for a change it never contained.
- The two comparison recipes take `just`'s named positional parameters and
  strip the `baseline=`/`workload=` prefix with `trim_start_matches`, mirroring
  how the profiling recipes strip theirs in shell. The command-contract test
  asserts the composed command line through `just --dry-run` rather than
  grepping the recipe body, so it proves the documented spelling actually
  reaches the runner.
- `just test-terminal-benchmark-gui` drives the same `production_collectors`
  binding `benchmark-quick` uses, with both physical arms pointed at the working
  checkout. The GUI-dependent contract (PO3/PO4) is about workload evidence and
  process ownership, not about comparing two sources, so one tree is enough and
  the recipe produces no decision.
- PO4's "an unrelated DanTerm instance remains untouched" needs a second live
  instance the run does not own. The harness's bundle-suffix allowlist gained a
  fourth reserved value, `.bystander`, rather than being opened to a pattern:
  the closed set is what keeps the measured arms inside the calibrated
  namespace, and the proof needs exactly one namespace outside it.
- The GUI proof immediately earned its keep: the persistent draw runner sent the
  block-starting `Enter` as `danterm pane input --pane <id> Enter`, which the CLI
  grammar rejects without a `--` separator, so every draw workload failed on the
  real path. The hermetic suite could not see it because it mocks `send_input`.
  Fixed in `make_persistent_draw_runner` with the mocked expectation updated to
  match.
- `benchmark-draw-app` keeps only its localized draw path. The serialized
  redraw workloads it also drove existed to write `terminal-redraw.jsonl` at
  80x24; the paired `content-churn`, `style-churn`, and `incremental-mixed`
  workloads now answer that question at 179x66.

## Follow Up

- PO8's budgets are still unmeasured: no complete `benchmark-quick` or
  `benchmark-confirm` invocation has been run end to end on the calibrated
  machine, so the under-60-second and under-five-minute cached-path claims rest
  on the research timings rather than on the production commands. The first real
  optimization (PO7) should record the reported snapshot / cache / comparison /
  total phase times alongside its decision.
- `scripts/terminal-benchmark.sh` still accepts the `full-screen-symbol-churn`
  and `full-screen-sprite-coverage-churn` workloads, whose fixture identities are
  80x24 and which no recipe now reaches. Decide whether to port them to 179x66
  as paired workloads or delete them with their app-side fixtures.
- `make_scrollback_stream_runner` (`scripts/terminal-benchmark-validation.py:715`)
  launches each block's fresh app with a per-arm `.a`/`.b` bundle suffix, while
  the persistent draw arms share the empty namespace the calibration froze. The
  two never coexist, so the namespace bias RI2 describes should not apply -- but
  the difference is worth confirming against the calibration record before the
  next threshold refresh.
