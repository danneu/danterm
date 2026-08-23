# Make script-test gate coverage explicit

## Problem and desired outcome

The gate checks that each Swift test estate runs, but it does not make the same
claim for tracked shell and Python self-tests. A self-test can therefore exist
without any gate path reaching it, and the gate still reports success.

Every tracked `*_test.sh` and `*_test.py` is currently under `scripts/tests/`.
Most run as direct gate steps, five run through the bundle contract suite, one
Python test runs from another test, and the GUI-only `danterm-cli_test.sh` is
intentionally opt-in. The coverage check cannot distinguish these valid cases
from an orphan.

The desired outcome is that every tracked shell or Python self-test is reachable
from the headless gate at least once or declares why it is excluded. Adding an
orphan must fail the gate and name the uncovered file.

## Decision

- Discover tracked files repo-wide. A matching `*_test.sh` or `*_test.py` is a
  coverage claim regardless of its directory.
- Read the assembled gate once through `run-test-suite.sh --list-steps` and use
  that list for both Swift estates and script self-tests. Normalize the `wide: `
  scheduling marker before analyzing a step; a build or iOS portability command
  remains a mention rather than a Swift test lane.
- Count a self-test only when its path is a command word or the script operand of
  an interpreter command. A comment or inert string does not establish coverage.
- Replace the bundle contract wrapper with one sequential gate step. The step
  initializes the shared bundle-layout tool once, then runs each of the five
  contract tests as a command word. The assembled step is the sole child
  inventory.
- Run `terminal_benchmark_state_test.py` as its own gate step instead of from
  `terminal-benchmark-harness_test.sh`.
- A self-test can opt out with `# gate: opt-out -- <reason>`. The reason must be
  non-empty and stay in the excluded file.
- Enforce at-least-once coverage. Intentional repeated execution by meta-tests
  remains valid.

## Invariants

- **I1.** Every discovered script self-test is reachable from an assembled gate
  step or carries a valid in-file opt-out.
- **I2.** Only a test path used as a command word or an interpreter's script
  operand can establish coverage.
- **I3.** `danterm-cli_test.sh` remains outside the headless gate. Its opt-out
  states that it requires a GUI and `jq` and runs through `just test-cli`.
- **I4.** Existing Swift-estate coverage behavior remains unchanged, including
  wrapper-invoked package tests and the declared WindowServer exclusion.
- **I5.** An empty script-test discovery fails instead of reporting success while
  checking nothing.

## Proof obligations

- **PO1.** Prove that an orphaned shell or Python self-test fails with its path in
  the diagnostic, while a directly executed test passes.
- **PO2.** Prove that comments, inert strings, and non-executing command arguments
  do not count as coverage.
- **PO3.** Prove that the sequential bundle-contract step succeeds, executes all
  five contract tests, and builds the shared layout tool once.
- **PO4.** Prove that a matching tracked test outside `scripts/tests/` enters the
  coverage estate.
- **PO5.** Prove that a valid non-empty opt-out passes and a missing or malformed
  opt-out fails. Pin the GUI-only CLI exclusion as the production case.
- **PO6.** Keep every existing Swift package coverage verdict unchanged when both
  coverage checks consume the assembled step list.
- **PO7.** On the real tree, prove that discovery is non-empty, every discovered
  test is covered, and the opt-out set is exactly `danterm-cli_test.sh`.

Use TDD for the lint behavior. Run its targeted self-test and `just lint` during
the edit loop, then run `just test` before commit.

## Non-goals and coordination

- **Non-goal.** Do not reject repeated script-test execution. This work closes
  silent omission only.
- **Non-goal.** Do not change DanTerm behavior, the public CLI, package
  boundaries, or which tests need a GUI.
- BUILD-3 is the baseline; its assembled step-list interface is authoritative.
- BUILD-4 may overlap the gate runner but has no behavioral dependency. Land or
  rebase the changes separately.
- IPC-2 may edit `danterm-cli_test.sh`. Preserve this plan's GUI opt-out while
  keeping headless CLI assertions in gate-run Swift tests.

## Rejected ideas

- **RI1. Parse only the literal `STEPS` array.** This misses the assembled gate,
  including shared and generated steps added before BUILD-3 exposes the final
  list.
- **RI2. Count every filename token.** This accepts paths outside a command word
  or interpreter script operand that never execute the named test.
- **RI3. Keep a hardcoded exemption list in the lint.** This moves the reason away
  from the excluded test and creates another inventory that can drift.

## Implementation discretion

- Internal token parser and fixture structure are free choices subject to the
  command-position and single-assembled-list invariants.

## Implementation notes

- The visible sequential bundle-contract step exceeds BSD `xargs`'s default
  255-byte `-I` replacement limit. The runner raises that limit to 4096 bytes,
  and its self-test proves a long assembled step reaches its worker intact.
