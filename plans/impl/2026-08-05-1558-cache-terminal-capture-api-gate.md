# Cache the terminal capture API gate

## Problem

`scripts/tests/terminal-capture-api-gate_test.sh` proves that transition-capture
APIs are unavailable to an ordinary app client and available to a
characterization build. It currently performs two clean TerminalPTY builds in
temporary directories and deletes both afterward, so every `just test` run pays
the full compilation cost. The step measured about 37 seconds in the parallel
gate and 23 seconds alone; the compiler probes themselves took less than a
second.

The proof also matches exact Swift diagnostic text. That wording is not part of
the boundary being protected and can change independently of the behavior.

## Decision

Retain separate persistent SwiftPM build artifacts for the normal and
characterization configurations under the repository's ignored root `.build/`
area, which `just clean` removes.
Every gate invocation still asks SwiftPM to validate both configurations and
still runs external-client compiler probes; it caches compilation, not the test
result.

Guard the persistent artifacts with a content fingerprint covering the
TerminalCore manifest and sources. Changed TerminalCore inputs invalidate both
configurations before the next proof because TerminalCore layout changes have
previously left TerminalPTY clients linked against stale value layouts.
TerminalPTY's own inputs remain SwiftPM's incremental-build responsibility,
matching the existing TerminalPTY test-cache precedent. Publish the accepted
fingerprint only after the complete gate succeeds.

Replace exact diagnostic matching with paired behavioral proof: a normal client
can compile against an ordinary public API but cannot compile either capture
probe, while the same capture probes compile in the characterization
configuration. Keep the probes independent so each capture surface is proved
separately.

## Invariants

- **I1 -- API boundary.** Normal app clients cannot reach the capture initializer
  or recording accessor; characterization clients can reach both.
- **I2 -- proof on every run.** An unchanged warm run executes the compiler
  probes rather than skipping the gate based on its cache state.
- **I3 -- fresh cross-package inputs.** A content or path change under
  TerminalCore's manifest or sources invalidates both configurations before
  either can be blessed against the new inputs.
- **I4 -- failure is not accepted.** A failed build or compiler probe does not
  publish the new fingerprint, so the next run retries from invalidated build
  state.
- **I5 -- gate ownership.** The two configurations live under root `.build/`
  and do not share artifacts with each other or with another parallel `just
  test` step; the existing ignore and `just clean` rules therefore own both.
- **I6 -- warm latency.** In one controlled machine session, the targeted gate's
  warm post-change median is at least 4x faster than its warm pre-change median.
  Absolute targeted and in-pool timings are recorded as observations, not
  acceptance bounds.

## Proof obligations

- **PO1 (I1/I2).** Compiler-level tests establish that the ordinary public
  client compiles, both normal capture clients fail, and both characterization
  capture clients pass on cold and unchanged warm runs.
- **PO2 (I3/I4).** A fake-driver cache contract test proves warm preservation,
  invalidation for TerminalCore source and manifest content changes and a source
  rename or deletion, and that build or probe failure cannot advance the
  accepted fingerprint.
- **PO3 (I5).** The cache contract test proves distinct configuration paths
  rooted under `.build/`; the existing test-runner contract continues to pass
  with the new independent gate step.
- **PO4 (I6).** Position-balanced warm pre-change and post-change measurements
  in one controlled session establish the ratio, while targeted absolute time
  and the warm parallel-gate step are recorded for orientation.

## Non-goals

- Sharding or otherwise changing the TerminalCore test pole.
- Moving this proof to CI only, making capture APIs public in production, or
  reducing the number of capture surfaces proved.
- Making the first run, a TerminalCore input change, or a run after `just clean`
  avoid its required clean compilation.

## Accepted risks

- **AR1 -- disk use.** Two persistent configuration caches currently require
  about 370 MB. This is accepted for the repeated warm-run reduction because the
  artifacts are ignored and owned by `just clean`.
- **AR2 -- cold latency.** TerminalCore input changes still trigger two clean
  builds. This is accepted to preserve the established cross-package
  layout-safety guard; TerminalPTY edits retain SwiftPM's incremental behavior.

## Rejected ideas

- **RI1 -- one shared build directory.** Alternating the characterization flag
  would invalidate the same artifacts on every run and would not provide a warm
  steady state.
- **RI2 -- skip when unchanged.** Skipping would cache the verdict rather than
  compilation and violate the requirement that the boundary is proved on every
  run.
- **RI3 -- narrow or merge the probes for speed.** The probes contribute
  negligible time, while independent results identify and protect both API
  surfaces.

## Implementation discretion

- Exact cache descendants under root `.build/`, fingerprint helper structure,
  and test-only command injection seams are implementation choices as long as
  I2-I5 hold.
- The compiler-facing mechanism for proving failure may change in the future if
  it remains behavioral and does not depend on exact diagnostic wording.

## Implementation notes

- Position-balanced same-session warm timings were 22.05s, 22.28s, and 23.85s
  before the change versus 3.56s, 3.71s, and 5.62s after it: a 22.28s-to-3.71s
  median reduction, or 6.0x. The cached step took 10s in the five-worker full
  gate; the full 75-step gate passed in 50s.
