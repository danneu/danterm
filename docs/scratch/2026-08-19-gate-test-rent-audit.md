# Gate test rent audit

Which `just test` steps earn their place, and which we can drop one at a time.

Measured on 2026-08-19 at `cf022c76`, from one full `just test` run on a 10-core
machine: **107 steps, all passed, 360s wall.** Sum of step run-time 610s; sum of
queue-wait 825s. Raw log: `.build/gate-timing.log` (not committed; re-create with
`just test > .build/gate-timing.log 2>&1`).

This is a working document. Each candidate below is a checkbox. Tick one, drop
that thing, move on -- nothing here depends on anything else here.

## What the gate is today

| Lane | Steps | Notes |
|---|---|---|
| Product (`swift test` / `swift build`) | 10 | 63s, 55s, 47s, 42s, 26s, 24s, 14s, 10s, 9s, 4s |
| Lints and lint self-tests | 44 | almost all 1-5s |
| Perf / measurement tooling tests | 28 | 1-5s |
| Other tooling tests | 25 | 1-23s |

Ten of 107 steps test the terminal. The other 97 test the scaffolding around it.
The individual steps are mostly well written, which is why this reads as
accumulation rather than neglect.

## Prune for rent, consolidate for time

These are two separate jobs and the numbers say so.

| | run | queued |
|---|---|---|
| The 4 bundle steps, each rebuilding `DanTermBundleLayoutTool` | 74s | 105s |
| The 86 steps that take <= 5s | 122s | 559s |
| `core-purity-lint.sh` x 11 | 7s | 10s |
| Frozen perf-instrument cluster x 12 | 14s | 35s |

Deleting the frozen perf cluster saves 14s of run time. Its case is rent -- 249
fewer tests to keep alive -- and not speed. Say that out loud when proposing it,
because "it will make the gate faster" would be false.

The gate waits longer than it runs (825s queued against 610s run). Every trivial
lint pays a full CPU-token round trip, so batching beats deleting for wall clock.

---

## A. Clean cuts -- done 2026-08-19

No judgment call needed. Each is one step or one test. All four are cut; the
gate is 104 steps and one full `just test` run passed all of them.

- [x] **`scripts/tests/terminal_recording_research_producers_test.py`** (1 step, 1s)
      Tests `capture-fish-drag.py` and `capture-fish-sweep.py`, which live inside
      `docs/research/24-osc-133-dialect/`. That research is settled (F1 says so).
      These are one-shot capture producers that will not run again.

- [x] **`scripts/tests/terminal-benchmark-commands_test.sh`** (1 step, 1s)
      Asserts literal command strings appear in the `justfile` *and* that literal
      lines appear in `agent-docs/terminal-performance.md`
      (`just benchmark-sample btop-scroll 20`, and two more). Renaming a recipe
      breaks it with nothing actually broken. This is a gate step violating
      "a refactor that keeps the behavior must keep the test passing."

- [x] **`scripts/tests/watch-release-workflow_test.sh`** (1 step, 1s)
      Shims `gh` and `sleep`, then asserts the shim was called with the right
      string, plus a `just --dry-run release patch` output-contains check. The
      mock is most of the test, and the real failure mode -- release CI watching
      breaks -- is loud and harmless.

- [x] **`lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift:869`**
      `"removed legacy commands are unknown"` over `new-tab`, `send-keys`,
      `read-pane`. It asserts that deleted things stay deleted. Nothing can
      reintroduce them.

## B. Decided -- both resolved on evidence, 2026-08-19

Both of these turned out to be answerable by reading the code rather than by
making a call. The original framing in section A/B of this audit was wrong in
both cases; the corrections are recorded here rather than quietly edited away.

### B1. The two "legacy on-disk format" tests -- **no policy conflict exists**

The audit claimed these pin backward compatibility that AGENTS.md says to break.
Wrong: **neither test guards a compat shim, because no compat shim exists.**

- [x] **`lib/DanTermCore/Tests/DanTermCoreTests/SnapshotTests.swift:792`** --
      **KEEP. Rename only.** It tests the *current* wire format, not a legacy
      one. `TodoSnapshot.id` is a plain `String` (`Model.swift:799`) and the
      writer emits bare strings (`Persistence.swift:77`). It pairs with
      `"checkpoint encodes pane and tab todo ids as bare strings"` in the same
      file to pin the format in both directions. Only the word "legacy" in its
      name is stale.
      **Action:** drop "legacy" from the test name. Do not delete.

- [ ] **`lib/DanTermCore/Tests/DanTermCoreTests/CustomTitleTests.swift:332`** --
      **Drop, but it is not a policy question.** `subtitle` appears nowhere in
      the snapshot codec. The test feeds JSON carrying tab-level `title` and
      `subtitle` keys and asserts they are ignored -- which is Swift's default
      `Codable` behavior for unknown keys, not a shim we wrote. It pins one mild
      real thing (tab-level keys never override the pane-derived title) and
      nothing writes those keys any more.
      **Action:** low stakes either way. Fold into the clean-cut sweep.

**Correction:** there was never a "delete the tests but leave the shims" trap
here. The shims do not exist.

### B2. The "frozen perf cluster" -- **mostly live, prune is ~34 tests not 249**

The audit grouped these by last-touch date. That was the wrong axis: for a
stable dependency of a live path, date-frozen means finished, not dead. On
**reachability from a live recipe or a live importer**, the 12 split three ways.

**Live infrastructure -- keep all of it (9 steps, ~214 tests):**

| Script | Reached by |
|---|---|
| `terminal_btop_workload.py`, `terminal_btop_stimulus.py`, `terminal_btop_artifacts.py` | `terminal-benchmark.sh` + `terminal-benchmark-profile.sh`, backing `just benchmark-sample/trace/loop btop-scroll` |
| `terminal-benchmark-calibration.py` | imported by `terminal-benchmark-compare.py` -- the live `just benchmark-quick`/`confirm` decision surface -- plus 3 more |
| `terminal-memory-profile.py` | `terminal-benchmark-profile.sh` |
| `terminal-profile-report.py` | own justfile recipe |
| `terminal-headless-draw-compare.py` | `just benchmark-headless-draw` |
| `terminal-retained-row-shape.py` | `just terminal-retained-row-probe` |
| `terminal-benchmark-plan-calibration.py` | imported by `terminal-benchmark-candidate-screen.py` |

`btop-scroll` is a **live profiling workload**, not a closed research artifact.
The audit's "museum piece" claim was wrong for the three btop workload modules.

**Live with pending work -- keep (1 step, 4 tests):**

- `terminal-benchmark-candidate-screen.py` is the documented path for graduating
  a candidate workload, and three are currently waiting on it:
  `synchronized-frames`, `sparse-spans-few`, `sparse-spans-max`. Deleting its
  test would strand the next step of work already scoped in
  `docs/research/28-retained-row-optimizations/decisions.md`.

**Genuinely prunable (2 steps, 34 tests):**

- [ ] **`scripts/tests/terminal_btop_gui_proof_test.py`** (33 tests, 1s)
      The one real instrument-for-an-instrument. `terminal-btop-gui-proof.py` has
      a single opt-in recipe and **nothing imports it** -- unlike the three btop
      workload modules, which the profiling path depends on. Its own docstring:
      "Nothing here is decision-bearing. It proves the instrument works."
      **Still a judgment call:** it exists so an opt-in proof cannot go green on
      a broken rule. If we never run `just test-terminal-btop-gui` again, both
      the proof and its 33 tests go together. Keeping the proof while dropping
      its judges is the one combination to avoid.

- [ ] **`scripts/tests/terminal_fixed_cost_probe_test.py`** (1 test, 1s)
      `terminal-fixed-cost-probe.py` has zero justfile recipes, zero doc
      references, and zero callers outside itself. Written to motivate arena
      work that has since landed. The only truly orphaned item in the cluster --
      though at 1 test, dropping it is bookkeeping, not a win.

**Correction:** the cluster was never a 249-test prune. Nine of twelve are load-
bearing dependencies of the live benchmarking path that simply stopped needing
edits. Deleting them would break `just benchmark-quick`, `benchmark-confirm`,
and the three btop profiling recipes.

## C. Consolidations -- the actual wall-clock wins

- [ ] **Merge the four bundle steps into one.** `verify-bundle-layout_test.sh`
      (23s), `dev-build-configuration-contract_test.sh` (19s),
      `build-app-helpers-contract_test.sh` (16s), and
      `bundle-transformations_test.sh` (16s) each run
      `swift run DanTermBundleLayoutTool` into their own private scratch path --
      the same Swift tool built four times. One `&&`-joined step sharing one
      scratch is roughly a 50s saving, larger than every deletion above put
      together. `scripts/run-test-suite.sh`'s own header already sanctions the
      `&&` form for steps that must share state.

- [ ] **Collapse `core-purity-lint.sh` from 11 steps to 1.** Eleven separate
      steps, each paying a CPU-token queue wait to do 0-2s of work.

- [ ] **Batch the sub-2s lints and lint self-tests.** 86 steps wait 559s
      collectively to do 122s of work. Grouping the ~40 smallest into a handful
      of steps cuts more wall clock than removing them ever would.

## D. Improve in place, do not delete

- [ ] **`scripts/tests/terminal_benchmark_compare_test.py`** repeats the same
      four-claim block for each auxiliary metric (plan estimate, process CPU,
      drain composition): "reported for every workload", "never carries a
      verdict", "never changes the draw verdict", "no evidence -> no estimate".
      That is ~12 tests stating one invariant. One parameterized test over the
      auxiliary-metric registry is *stronger*: a newly added auxiliary metric
      gets covered automatically instead of needing four hand-copied tests.

## What we checked and found healthy

Recorded so nobody re-runs these probes.

- **No silently skipping steps.** Nothing in `scripts/tests/` calls `skipTest`
  or bails when a tool is missing. A green step really ran.
- **The lint self-tests mostly pay.** Spot-checked
  `terminal-exit-concurrency-lint_test.sh`: it pins the regex against
  comment-skipping and each forbidden construct. A lint that silently passes is
  worse than no lint, so these earn their ~1s.
- **`terminal_benchmark_workloads_test.py` is well motivated** -- it holds three
  places that each name draw workloads from drifting apart, and says so.
- **`terminal-benchmark-harness_test.sh`'s 31 commits since June are real
  co-evolution** with benchmark feature work, not change-detector churn.
- **The todo test estate is not duplicated.** `TabTodoTests` (projection rows)
  and `UpdateTabTodoTests` (reducer) cover distinct concerns. `TabTodoTests` is
  fine-grained -- one test per arrow-key delta case -- which could parameterize,
  but nothing there is wrong.

## Log

Append one line per drop: date, what went, what broke or did not.

| Date | Dropped | Result |
|---|---|---|
| 2026-08-19 | `terminal_recording_research_producers_test.py` (gate step + file) | Nothing broke. The producers themselves stay in `docs/research/24-osc-133-dialect/` as part of the settled record. |
| 2026-08-19 | `terminal-benchmark-commands_test.sh` (gate step + file) | Nothing broke. |
| 2026-08-19 | `watch-release-workflow_test.sh` (gate step + file) | Nothing broke. |
| 2026-08-19 | `CLIParserTests` "removed legacy commands are unknown" | Nothing broke; suite still 61 tests, green. |
