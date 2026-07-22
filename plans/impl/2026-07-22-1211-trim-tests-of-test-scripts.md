# Trim the tests-of-test-scripts layer

## Context

Three shell tests under `scripts/tests/` exercise our own bash orchestration
rather than terminal behavior, and they cost ~196 lines plus test-only code
paths in the production harness scripts:

- `terminal-workflows-harness_test.sh` (83 lines) and
  `terminal-protocol-probes-harness_test.sh` (78 lines) run the harness with a
  *fake runner* that `touch`es the artifacts the harness then asserts exist.
  They pin harness-level choreography -- preflight refusal, run-directory
  isolation, failure classification, missing-artifact rejection -- but nothing
  about terminals. The terminal proofs live in `lib/TerminalPTY/Tests` and in
  the opt-in live recipes (`just test-terminal-workflows`,
  `just test-terminal-protocol-probes`).
- `native-shell-events-retirement_test.sh` (35 lines) is grep-as-test: it
  asserts legacy identifiers (`__DANTERM_EVT__`, `PaneTokenStore`, ...) never
  reappear in a hardcoded list of paths, including two plan markdown files. It
  rots as those names lose meaning, hardcodes paths that drift, and is not even
  enforced uniformly -- it runs from the justfile but the Nix leg
  (`flake.nix:206`) runs only `shell-integration_test.sh`. The behavior that
  matters (each shell integration emits the native protocol) is already covered
  by `shell-integration_test.sh`.

Supporting the two fake-runner tests, both production harness scripts carry a
`DANTERM_*_RUNNER` injection seam whose only caller is those tests. Deleting the
tests makes those branches dead, so they go too.

Outcome: `just test` gets shorter and stops asserting things about itself; the
two opt-in harness scripts lose their test-only branches.

## Changes

### 1. Delete the three test files and their `just test` entries

- `scripts/tests/terminal-workflows-harness_test.sh`
- `scripts/tests/terminal-protocol-probes-harness_test.sh`
- `scripts/tests/native-shell-events-retirement_test.sh`

Remove the matching three lines from the `test` recipe in `justfile`.
`shell-integration_test.sh` stays -- it is a real integration-asset test and is
the one the Nix leg also runs.

### 2. Production harness scripts always use the real runner

`scripts/terminal-workflows.sh` and `scripts/terminal-protocol-probes.sh` must
unconditionally build and invoke their real runner and `PTYSessionBootstrap`
products; no environment variable can substitute a different runner, and no
placeholder bootstrap path remains. `DANTERM_WORKFLOW_RUNNER` and
`DANTERM_PROTOCOL_PROBE_RUNNER` disappear entirely.

Leave the other env overrides alone -- `DANTERM_WORKFLOW_RUN_ROOT`,
`DANTERM_WORKFLOW_PATH`, `DANTERM_PROTOCOL_PROBE_RUN_ROOT`,
`DANTERM_PROTOCOL_PROBE_SOURCE_ROOT`, `DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION`
are operator-facing knobs for the opt-in runs, not test-only seams.

### 3. Fix the two docs that link the deleted workflow harness test

Both currently link `scripts/tests/terminal-workflows-harness_test.sh`, which
would become a dead link:

- `docs/evidence/2026-07-21-terminal-workflow-compatibility.md` ("Deterministic
  coverage and regressions"): the paragraph credits `just test` with covering
  prerequisite refusal, isolated home/SSH configuration, failure artifact
  preservation, and lifecycle cleanup. Rewrite so the deterministic proofs cite
  the TerminalPTY controller/lifecycle suites (`lib/TerminalPTY/Tests`) only,
  and attribute the harness-level behaviors to the opt-in recipe
  `just test-terminal-workflows` where they are actually exercised. Do not
  rewrite the evidence doc's observation sections -- only the coverage claim
  changes.
- `plan-terminal-engine/14-roadmap.md` (Slice 3 checkbox): drop the harness
  link, leave the TerminalPTY citation.

No other file references these three tests.

## Non-goals / Accepted risks

- **AR1: `just test` no longer fails on a harness-choreography regression.**
  Wrong preflight exit status, dropped failure diagnostics, accepted-but-
  incomplete artifact sets, a leaked user SSH configuration, or missing cleanup
  evidence would now surface only when someone runs the opt-in recipe, not in
  the fast gate. Accepted: these are properties of two opt-in scripts an
  operator runs interactively and whose failures are loud and local, and the
  ~161 lines of fake-runner scaffolding needed to keep pinning them was judged
  not worth its weight.

## Rejected ideas

- **RI1: Keep the two harness contract tests (and their runner seams), delete
  only the retirement grep test.** Rejected: the intent of this change is to
  remove the tests-of-test-scripts layer, and the harness suites are that
  layer's largest members. Their value is acknowledged and recorded as AR1
  rather than dissolved by retaining them.

## Verification

Searches below exclude `plans/` -- this plan file legitimately names every
removed identifier.

1. `rg -n 'terminal-workflows-harness_test|terminal-protocol-probes-harness_test|native-shell-events-retirement' -g '!plans/**'`
   returns nothing.
2. `rg -n 'DANTERM_WORKFLOW_RUNNER|DANTERM_PROTOCOL_PROBE_RUNNER' -g '!plans/**'`
   returns nothing.
3. `just test` passes and its output no longer mentions the three removed
   suites.
4. Execution proof for the workflow harness, whose seam removal is otherwise
   unverified: run `just test-terminal-workflows`. On a machine with all
   prerequisites it must reach and pass the real `TerminalWorkflowRunner`;
   on one missing `fish`/`asciinema` it must still exit 2 with
   `status=preflight-failed` in the run directory's `result.txt`.
5. Execution proof for the probe harness: run
   `just test-terminal-protocol-probes` and confirm it builds
   `TerminalProtocolProbeRunner` + `PTYSessionBootstrap` and reaches the real
   runner (a probe-level pass/fail is fine; what must not happen is a failure
   in the harness's own runner/bootstrap invocation). Syntax checks are not a
   substitute here -- a wrong runner path or argument list stays green under
   `bash -n` and under `just test`.
6. Markdown links in the two edited docs resolve (no path to a deleted file).
