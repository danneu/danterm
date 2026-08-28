# Measurement discipline

Rules for building and reading an instrument, learned from measurements this
repo got wrong. They apply to any number an agent collects here -- benchmark
metrics, profile shares, calibration screens, test wall times -- not only to the
commands in [terminal-performance.md](terminal-performance.md).

## Make an instrument report its own coverage

Every metric must be able to say "not measured" separately from "measured zero".
An instrument whose blind spot renders as `0` reports the reassuring answer
exactly when it is blind, and nothing downstream can tell the difference -- so
the failure is silent and always in the direction that ends the investigation
early. Four instances cost real time here, all the same shape:

- A mutation harness grepped for `✘`, which Swift Testing does not emit (it uses
  `􀢄`). Caught mutations rendered as clean runs.
- `cumulativePlanNanoseconds` (since replaced by per-plan samples) was
  promoted from pending to accepted only when a draw was accepted, and
  `scrollback-stream` accepts none. It read `0.00` on the one workload whose
  sustained output the number was wanted for.
- The fence-stall counter first shipped latched at drain time, so a delivery
  whose publish the synchronized-output guard suppressed lost its stall
  entirely -- understating precisely the full-screen TUI floods worth measuring.
- A flake rate sampled from single-test runs (~1 failure in 60) instead of
  full-suite runs (~3 in 14). Twenty clean runs in the wrong denominator prove
  nothing, at any sample size.

So:

- **Emit a count beside every aggregate.** `cumulative...Nanoseconds` without its
  sample count cannot distinguish "no cost" from "no samples". Assert a floor on
  that count where the number drives a decision.
- **A missing field is not a zero.** Check a new field is actually present in the
  artifact before reading its value. Both benchmark blind spots above were guards
  inherited by copying a neighbouring metric's emit site, and reading the
  fixture-replay collector's absent `drawCount` as "this workload never draws"
  was wrong -- the two collectors simply instrument different things.
- **Verify a weakened or cheapened measurement still detects what it was built to
  detect**, by reintroducing the defect and confirming it goes red.

## Read a gate from the code that owns it

Not from a reconstruction of it. The calibration gates are deliberately not all
read from the same condition: `select_candidate`
(`scripts/terminal-benchmark-calibration.py`) takes the false-positive rate from
the **A/A** condition and detection, inconclusive and wrong-direction from the
**injected-effect** conditions. Reading `inconclusive` off `aa` produces a much
larger number and manufactures failures that are not there -- it briefly indicted
every frozen rule in the table (`research/20/F15`). Call `select_candidate` on the
candidate; do not re-implement its arithmetic.

## Freezing a decision rule

- **A screen is not a freeze.** The corpus's protocol (doc 7) is two-stage:
  screen a grid at 50,000 trials to select a cell, then re-run *that exact cell*
  at 100,000 trials with disjoint fresh seeds and no parameter changed after
  screening. Freezing straight off a screen skips the confirmation the whole
  design rests on, and a cell that looks selected-and-verified may only be
  selected (`research/20/F15`). For a candidate workload both stages are one
  script: `terminal-benchmark-candidate-screen.py screen ...` selects the cell and
  `... confirm --screen <report>` re-runs it, so the confirmation cannot silently
  change a parameter the screen chose.
- **Verify a candidate cell on each series independently, not only pooled.** A
  cell can clear every gate on combined evidence and fail on two of the three
  series that fed it -- the defect that got `synchronized-frames`' confirm rule
  re-screened and then removed. Pooling hides fragility a per-series check
  surfaces.
- **A block discarded from a statistic is discarded from the whole file.** A
  screen once counted its own discarded outlier a second time as independent
  evidence for the tail it was discarded from.

## Reading a result

- **Derive nothing that one more run could measure.**
- **Two points are not a trend**, and a trend with a small-n endpoint is not even
  two points. An additive-noise model inferred from block lengths of 40 frames
  (n=5) and 95 frames survived one confirming measurement at 5x, then died when
  the intermediate 2x and 3x points were taken -- they were flat, and the model
  had the direction backwards (`research/20/F12`, `research/20/F16`). When a model predicts a
  curve, measure the middle of the curve before acting on it.
- **Prefer the continuous quantity to the thresholded one.** A pass/fail at a 60s
  time limit is one bit; the wall time underneath it shows a distribution
  shifting before any verdict flips. Across nine interleaved suite pairs, the
  read-turn cap moved the termination test from 1.073s to 0.810s with
  non-overlapping ranges -- while the pass/fail bit read 0-of-9 failures on both
  arms and carried no signal at all.
- **Give every comparison a control the change cannot reach, measured in the same
  session.** A read-turn constant in `TerminalPTYHost` cannot touch the 679 pure
  `TerminalCore` tests, so those are the control for any claim about the PTY
  suite's wall time. This is what separates an effect from a machine state: a
  9.1x PTY "speedup" read out of two archived gate logs evaporated when the
  control showed the untouched core suite had moved 13x across the same pair;
  measured interleaved and same-session, the real effect was 24%. Every
  comparative claim that survived that investigation came from contemporaneous
  interleaved arms; every one that fell came from comparing logs across sessions.
- **Measure directly against the baseline, don't subtract two comparisons.**
  Subtracting medians put the read-turn cap's cost at ~+1%; measured directly it
  was +3.69%.
