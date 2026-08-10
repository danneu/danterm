# Conditional benchmark-result saving

## Context

`just benchmark` currently appends every workload result to
`benchmarks/results/terminal-app.jsonl` unconditionally, so exploratory runs
pollute the append-only history unless the user remembers to discard the line.
`just benchmark-one` bypasses history entirely (raw single-run JSON, no
comparison). The goal: both commands always run once, print current timings
plus deltas against the latest compatible committed baseline, then save that
exact completed run only on explicit confirmation (`save=1`, or a `[y/N]`
prompt) -- never rerunning to save, and never prompting/saving for failed or
profiled runs.

Per user decision, `benchmark-one` is routed through
`scripts/terminal-benchmark-suite.py` with a workload filter and the suite's
normal multi-iteration aggregation ("one" means one workload, not one sample),
so all policy -- compatibility, deltas, prompt, save -- stays centralized in
one place. `scripts/terminal-benchmark.sh` is unchanged.

## Behavioral contract

`scripts/terminal-benchmark-suite.py` accepts the backend plus optional
`workload=<name>` (validated against the committed corpus; absent means the
full corpus) and `save=<0|1>` (absent/empty means "ask"), in just's
named-argument spelling.

1. A profiled run (`DANTERM_BENCHMARK_PROFILING=1`) exits before running,
   prompting, or staging anything -- the existing `refuse_profiled_history()`
   guard stays the first thing `main()` does.
2. Each selected workload runs, is serialized exactly once, and that serialized
   content is written to a transient staged file under
   `.build/terminal-benchmark-staged/`. Its timings and delta against the
   latest compatible committed baseline are printed as they complete.
   Nothing is written to `benchmarks/results/terminal-app.jsonl` during the run.
3. The save decision is made once, only after every selected workload has
   completed successfully. If any workload fails, the run exits without
   prompting and without touching history; already-staged content stays on disk
   for inspection.
4. `save=1` saves without prompting; `save=0` neither prompts nor saves; with
   no `save` argument the user is prompted
   `Save these results to benchmark history? [y/N]`. Only `y`/`yes`
   (case-insensitive, trimmed) saves. Enter, `n`, any other input, and EOF all
   mean no. An unsupported `save=` spelling is an argument error, not a save.
5. Saving appends the staged content verbatim to
   `benchmarks/results/terminal-app.jsonl` -- byte-identical to what was
   reported, with no rerun and no re-serialization. Declining prints the staged
   path so the user can promote it by hand later.

### Compatibility contract change

The iteration count is part of the aggregation protocol and must join the
result's compatibility key (alongside `schemaVersion`, `backend`, `workload`,
`fixture`, `machine`, `macOS`, `displayScale`, `toolchain`,
`buildConfiguration`, `geometry`, `profilingActive`). `DANTERM_BENCHMARK_ITERATIONS`
stays configurable, so without this a 2-iteration result could become the
committed baseline for a 3-iteration run and report a misleading delta. Results
recorded under different iteration counts must not produce a delta against each
other; the existing `KeyError` tolerance in `latest_compatible_lines` already
skips older records that lack the field.

## Files

- `scripts/terminal-benchmark-suite.py` -- argument parsing, staging, the save
  decision, promotion, and the compatibility-key change. Reuse the existing
  `parse_backend`, `append_result`, `latest_committed`, `report`, and
  `refuse_profiled_history`.
- `justfile` (recipes ~lines 77-84) -- both recipes gain a `save=""` parameter
  and route through the suite; `benchmark-one` keeps its `workload backend`
  positional order and passes `workload={{workload}}`. Recipe comments are the
  command-help surface and must describe the prompt / `save=1` / `save=0`
  workflow.
- `scripts/tests/terminal_benchmark_suite_test.py` -- behavioral tests (below).
- `scripts/tests/terminal-benchmark-harness_test.sh` -- assert the recipes
  forward `save` (and `workload`, for `benchmark-one`) to the suite. Do not
  grep for the prompt string or the staging directory name; serialization and
  staging semantics are covered by the Python tests.
- `agent-docs/terminal-performance.md` -- "Measure first" gains the
  run-then-confirm flow and notes saving never reruns; "Artifacts and history"
  gains the transient staged path and that only confirmed runs enter committed
  history. "Measure first" also states the intended backend workflow, which the
  existing recipe defaults already provide: omitting the backend means Swift;
  normal development runs `just benchmark` or `just benchmark-one <workload>`;
  `backend=ghostty` is run explicitly only to establish or refresh the Ghostty
  baseline, which is needed after a change to the pinned Ghostty version, the
  benchmark fixtures/protocol/schema, or any environment compatibility field.
- `benchmarks/results/README.md` -- lines land only when a run is confirmed.

## Tests (TDD: write first, watch fail)

In `scripts/tests/terminal_benchmark_suite_test.py`, matching its existing
style (imports the suite module, unittest + mock, tempdirs).

Argument and decision behavior:

- `save=1` -> save, `save=0` -> no save, absent/empty -> prompt; an
  unsupported spelling is an error.
- workload filter accepts only committed corpus names.
- prompt answers: `y`/`Y`/`yes` save; Enter, `n`, and invalid input do not;
  EOF on stdin does not.

End-to-end through `main()`, with the harness run, history path, and staging
root intercepted:

- no-`save` run answered `y` promotes the exact reported content into history;
  answered `n` leaves history untouched and keeps the staged content.
- `save=1` saves without ever prompting; `save=0` neither prompts nor writes
  history. (Assert the prompt function is not called in both.)
- full-corpus run where one workload succeeds and a later one fails: no
  prompt, history untouched, and the earlier workload's staged content still
  on disk.
- `DANTERM_BENCHMARK_PROFILING=1` exits before any prompt, run, or file write.

Compatibility:

- promotion appends to a pre-existing history without disturbing prior lines.
- a committed baseline recorded under a different iteration count produces no
  delta, while a matching one does.

## Implementation discretion

Helper decomposition and signatures, the staged filename scheme, file modes and
serialization mechanics, and where exactly the iteration count is carried in
the result JSON are left to implementation, so long as the behavioral contract
and compatibility contract above hold.

## Verification

1. `python3 scripts/tests/terminal_benchmark_suite_test.py`
2. `bash scripts/tests/terminal-benchmark-harness_test.sh`
3. `just test` (full gate).
4. Manual smoke: `just benchmark-one plain-scrolling` answered `n` (history
   unchanged, staged file present); `just benchmark-one plain-scrolling save=1`
   (saved, no prompt); `just benchmark save=0` (no prompt, no save); a
   closed-stdin invocation (EOF -> no save); and
   `DANTERM_BENCHMARK_PROFILING=1 python3 scripts/terminal-benchmark-suite.py swift`
   refusing immediately.
