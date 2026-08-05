# Fast, deterministic shell-prefill test

## Problem and outcome

The interactive shell-prefill test takes about 14 seconds despite doing little
work. Profiling attributes roughly 10 seconds to fish waiting for a Primary
Device Attribute response that Expect's minimal PTY does not provide, plus two
intentional one-second waits used to infer that prefilled commands have not run.

Keep the behavioral coverage while removing successful-path elapsed-time waits.
The targeted test should normally finish in well under one second, but runtime
is an observation rather than a timing assertion.

## Decision

- Disable fish's terminal-query feature only in the spawned test process. Fish
  >= 4.1 supports this through `fish_features=no-query-term`; both the local
  reference version (4.7.1) and the Nix-pinned version (4.5.0) satisfy that
  premise.
- Give fish its deterministic test prompt before the first prompt instead of
  discovering and then replacing its default prompt interactively.
- Replace the negative sleeps with a line-editor redraw barrier: a second render
  of the same buffered command proves the editor processed input without running
  that command; Enter remains the action that executes it.
- Treat every required Expect match as an assertion. Timeout or premature EOF
  must fail with context instead of allowing the script to continue, and the
  fish first-prompt assertion must reject its DA-timeout warning.
- Retain a generous timeout solely as a bounded failure ceiling; it must add no
  latency to a passing run.

## Invariants

- I1: zsh and fish both render the restored command in their editable line
  buffer without executing it.
- I2: a line-editor redraw preserves and re-renders that buffered command without
  producing its execution marker.
- I3: the command runs only after the harness sends Enter.
- I4: the test does not exercise or emulate terminal capability negotiation;
  that behavior belongs to terminal-engine coverage.
- I5: the packaged Nix check and the source-tree test exercise the same script
  and retain their existing cross-platform shell resolution through `PATH`.
- I6: no production shell integration, environment contract, or shipped behavior
  changes.

## Proof obligations

- PO1 (I1-I3): the interactive PTY cases for zsh and fish observe the initial
  prefill, a non-executing redraw of the same buffer, and execution after Enter.
- PO2 (I4): fish's first-prompt wait fails if the DA-timeout warning arrives
  before the prompt, proving that terminal-query waiting did not silently
  return; the test contains no synthetic terminal-query responses.
- PO3 (I1-I5): missing prompts, redraws, execution markers, or shell EOF cause a
  prompt diagnostic and nonzero exit rather than a silent timeout.
- PO4 (I5, I6): the targeted source test, the packaged shell-integration Nix
  check, and `just test` pass.
- PO5: time the targeted test for evidence that the fixed waits are gone; do not
  add a wall-clock threshold to the test suite.

## Rejected ideas

- RI1: Lowering the existing timeout only makes the unrelated fish negotiation
  delay shorter and risks machine-dependent failures.
- RI2: Setting `TERM=dumb` changes broader interactive-shell behavior than this
  test intends to isolate.
- RI3: Emulating fish's terminal query protocol couples a shell-prefill test to
  behavior outside its contract.

## Implementation discretion

- The Expect assertion helpers and diagnostic wording may be structured however
  keeps the single embedded script readable while preserving I1-I5.
