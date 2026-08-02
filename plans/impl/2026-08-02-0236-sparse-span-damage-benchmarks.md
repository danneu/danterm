# Promote sparse-span damage benchmarks

## Problem

The benchmark suite does not protect both sides of DanTerm's sparse AppKit
damage optimization:

- exact sparse plan clipping must retain a material win when a small number of
  distant regions change; and
- Core Animation clip construction must remain bounded at the maximum disjoint
  topology produced by the current glyph halo.

The existing `incremental-mixed` workload changes adjacent rows and decides on
synchronous draw time. It cannot reproduce the topology that made `d378096`
double whole-process CPU during live btop scrolling, and its draw bracket ends
before Core Animation replays the recorded display list. Whole-process CPU is
reported today, but it is deliberately unclassified because it cannot buy the
pair count needed for calibration while riding another metric's schedule.

Research 29 established two deterministic shapes at 179x66:

- two distant source rows arrive at drawing as 6 damaged rows in 2 maximal
  spans and retain about a 65% direct-draw and 8% whole-process CPU win over
  bounding-union drawing; and
- writes to ANSI rows 1, 5, ..., 65 arrive as 50 damaged rows in 17 maximal
  spans, the halo-geometry maximum for 66 rows, and expose the worst compound
  clip accepted by the revised implementation.

The desired outcome is two permanent, independently calibrated workloads that
guard the sparse win and its cost bound, including proof that their frozen rules
detect the historical defects they exist to prevent.

The open sensitivity question is empirical: prior clip counts suggest the
uncoalesced maximum-span defect may raise process CPU by only 10% to 15%, much
less than btop's roughly 2x regression. That estimate does not set a threshold.
The held-out known-bad gate below decides whether the maximum-span workload is
loud enough or whether a deterministic btop-shaped third workload earns its
additional calibration cost.

## Decision

### D1 -- promote two topology-specific workloads

Add `sparse-spans-few` and `sparse-spans-max` as serialized-draw workloads at the
canonical visible 179x66 geometry:

- `sparse-spans-few` repeatedly changes two distant rows. Every accepted draw
  must have published engine damage of exactly 2 rows in 2 maximal spans,
  without full damage. The shared halo transform derives the expected 6-row,
  2-span drawing topology.
- `sparse-spans-max` repeatedly changes every fourth row. Every accepted draw
  must have published engine damage of exactly 17 rows in 17 maximal spans,
  without full damage. The shared halo transform derives the expected 50-row,
  17-span drawing topology.

Both workloads settle a dense screen before measurement, change content and
style on every measured update, serialize each update to its completed draw,
and use the existing canonical geometry and machine-state contract. They become
routine benchmark members only after D3's calibration and held-out validation
outcomes are resolved.

For these two workloads, accepted-draw selection and stimulus-topology validity
derive from the published frame's engine `TerminalDamage`, upstream of renderer
damage resolution, not from AppKit's bounding dirty rectangle. The accepted
block artifact separately carries that engine row/span/full topology and the
derived post-halo topology, renderer-resolved clip topology, and fallback flag
for the same draws as its timing and CPU series. Renderer behavior does not
change which stimulus draws are accepted. This measured-path accounting is
exclusive to the sparse-span workloads; decision runs still publish no
activity file, and the existing five workloads execute the tree their frozen
rules calibrated.

### D2 -- give each workload the metric that observes its failure mode

`sparse-spans-few` decides on `drawNanosecondsPerDraw`. Its protected regression
is loss of sparse plan clipping, which increases synchronous rendering across
the bounding union and is fully contained by that bracket.

`sparse-spans-max` decides on `processCPUNanosecondsPerDraw`. Its protected
regressions include per-row rectangle emission and changes in Core Animation's
clip replay cost, both of which can occur after the draw bracket closes. This
promotion is workload-local: existing draw workloads retain their current
primary metrics, and their process-CPU lines remain descriptive.

A topology or CPU aggregate without complete sample coverage is "not measured,"
never zero. One invalid block invalidates the whole invocation under the
existing comparison contract.

### D3 -- calibrate before granting verdict authority

Each workload begins collectable but undecidable. For quick and confirm modes,
use repeated A/A series to screen a fixed pair count, estimator, directional
threshold, and equivalence band against a predeclared minimum effect. Confirm
the selected cell on fresh disjoint series, with no parameter changes after the
screen.

The freeze is suite-level, not the union of two isolated workload decisions.
The complete seven-workload confirm set must pass the gates owned by
`assess_frozen_suite`, including its A/A false-positive union bound and projected
wall-clock limit of 300 seconds. Suite selection may reselect confirmed cells
for existing workloads when the initial combination fails; it may not loosen a
gate or use an unconfirmed cell. If no seven-workload combination passes, keep
the existing confirm contract intact and freeze the pair as a separate
renderer-damage ladder with its own controlled false-positive and runtime
budget.

After freezing, prove the workload detects its real historical defect:

- `sparse-spans-few` must reject a synthesized revision from the shipped tree
  that reintroduces pre-sparse bounding-union rendering while classifying the
  shipped implementation as equivalent to itself.
- `sparse-spans-max` must classify the shipped implementation as equivalent to
  itself, then apply its frozen rule to a synthesized revision from the shipped
  tree that emits one rectangle per damaged row, restoring the uncoalesced
  `d378096` behavior. Rejection grants the historical-defect coverage claim;
  non-rejection selects the narrowed branch below.

The known-bad runs validate the complete instrument after statistical
calibration; they do not tune the frozen rule. Each synthesized arm records its
source tree, defect-only renderer diff, and declared downstream behavior with
the frozen-rule evidence. If `sparse-spans-max` cannot cleanly detect
uncoalesced `d378096`, it retains its frozen rule and confirm membership as a
maximum-topology cost-bound guard, but its documentation cannot claim coverage
of the historical per-row regression. At that gate, admit a third btop-shaped
candidate workload only if its measured separation justifies the additional
routine calibration and run time.

### D4 -- graduate evidence and documentation together

If the seven-workload suite clears D3, both workloads participate in selected
quick runs and the complete confirm ladder with their own primary verdicts. If
the separate-ladder contingency activates, its invocation and verdict remain
distinct from the unchanged five-workload confirm claim. The benchmark guide
records the question each workload answers, its exact topology and metric, the
machine/geometry scope of its rule, and why neither workload substitutes for
the other.

Research 29 receives the calibration and known-bad results, replacing its open
benchmark-coverage handoff with links to the permanent workloads. This plan
also updates D3 of the M9 criterion-2 plan to consume the frozen
`sparse-spans-max` verdict instead of specifying or implementing its duplicate
`sparse-many-runs` instrument. This plan does not otherwise broaden the
power-and-performance milestone.

## Invariants

- **I1 -- ideal-case topology.** A `sparse-spans-few` verdict is impossible
  unless every measured draw's published engine damage has exactly 2 damaged
  rows and 2 maximal spans.
- **I2 -- maximum topology.** A `sparse-spans-max` verdict is impossible unless
  every measured draw's published engine damage has exactly 17 damaged rows
  and 17 maximal spans at 179x66.
- **I3 -- claimed sparse path.** An arm presented as the exact sparse
  implementation accepts neither full engine damage nor renderer
  dirty-rectangle fallback during a measured draw. A synthesized known-bad
  arm's declared renderer deviation is recorded in its provenance and does not
  invalidate an otherwise valid stimulus block.
- **I4 -- complete coverage.** Draw, primary metric, engine topology, and
  renderer-behavior sample counts cover the same accepted draw set; absent or
  partial coverage invalidates the block.
- **I5 -- metric authority is local.** Few-span verdicts use synchronous draw
  time; maximum-span verdicts use whole-process CPU; no other workload gains CPU
  verdict authority from this change.
- **I6 -- fixed decisions.** Pair counts, estimators, thresholds, equivalence
  bands, and schedules are fixed before a comparison begins. No valid block is
  rerun and no invocation stops early.
- **I7 -- independent and controlled freeze.** Candidate selection and
  confirmation use disjoint evidence, every selected cell satisfies its gates
  on each required series rather than only after pooling, and the authoritative
  suite or ladder passes the code-owned aggregate accuracy and runtime gates.
- **I8 -- historical sensitivity.** A workload cannot graduate as protection
  for a defect until its frozen end-to-end verdict rejects the corresponding
  known-bad implementation.

## Proof obligations

- **PO1 -- producer contract.** Behavioral tests prove that each workload is
  deterministic, changes only its intended source rows after settling, and
  produces its required engine topology at canonical geometry. The same tests
  prove that the shared halo transform derives the expected 6-row/2-span and
  50-row/17-span drawing topologies from those engine row sets.
- **PO2 -- validity gate.** Accepted-draw and topology checks read the frame's
  published engine damage rather than renderer-resolved damage or the bounding
  dirty rectangle. Missing topology, wrong engine row/span counts, full engine
  damage, an undeclared renderer fallback on an arm claiming the exact sparse
  path, mismatched sample coverage, lost geometry, occlusion, non-foreground
  state, thermal pressure, battery power, or an incomplete draw count
  invalidates the entire invocation. The declared renderer deviation in a
  synthesized known-bad arm remains measured behavior rather than a stimulus
  validity failure.
- **PO3 -- metric routing.** A paired comparison consumes the few-span draw
  quantity and maximum-span process-CPU quantity, reports their identities in
  artifacts, and refuses to classify either workload before a frozen rule
  exists.
- **PO4 -- calibration.** Saved A/A screens and fresh confirmations establish
  confirmed candidate cells, then the complete authoritative suite or separate
  ladder passes the aggregate gates read from `assess_frozen_suite`, including
  false-positive union and projected wall clock. Decision-bearing values and
  compatibility conditions are transcribed into durable documentation rather
  than existing only under `.build/`.
- **PO5 -- mutation sensitivity.** With rules frozen, synthesized shipped-tree
  bounding-union drawing fails `sparse-spans-few`, while same-revision A/A
  controls remain equivalent. The uncoalesced `d378096` per-row arm receives a
  verdict under the already-frozen `sparse-spans-max` rule; its result selects
  the historical-coverage branch in D3 without threshold adjustment or repeated
  sampling. Each synthesized arm records its defect-only diff and provenance,
  including its declared renderer deviation. The maximum-span run also reports
  descriptive synchronous draw time, without using it as a gate, so the
  evidence records whether that bracket missed the CPU regression.
- **PO6 -- suite integration.** Quick can select either workload, confirm uses
  the complete frozen workload set when the seven-workload suite passes, the
  separate contingency cannot alter the five-workload confirm claim, manifests
  and schedules include the exact required blocks, and one invalid block
  prevents a partial verdict.
- **PO7 -- existing-workload isolation.** Behavioral evidence shows the
  existing five workloads publish no activity file, perform no topology-counter
  work on their measured path, and retain the block artifact and metric contract
  their current frozen rules cover.
- **PO8 -- full gate.** The benchmark self-tests, `just test`, and `just test-ui`
  pass after the frozen rules and documentation land.

## Non-goals

- Reopening maximal-span coalescing, adding a renderer fallback, or changing
  sparse-damage semantics.
- Treating direct-draw time as a proxy for Core Animation CPU, or making
  process CPU authoritative for existing workloads.
- Claiming coverage for arbitrary grid heights, halo widths, operating systems,
  or machines from rules calibrated at 179x66 on one machine.
- Adding a live btop dependency to routine benchmarks; any third workload must
  be a deterministic producer shape admitted by D3's measured gate.
- Deriving an energy or battery-life claim from CPU time.

## Accepted risks

- The maximum exposed span count grows approximately as `ceil(rows / 4)` under
  the current one-row glyph halo. The frozen rule protects the reproduced
  179x66 contract and must be recalibrated when geometry or halo semantics
  change.
- Whole-process CPU includes benchmark instrumentation and unrelated app work
  between accepted draws. Serialization, pairing, same-session controls, and
  calibration make that aggregate useful for this workload; they do not turn it
  into latency or per-operation attribution.
- Adding two workloads increases complete-confirm duration. That cost is
  accepted only after calibration demonstrates stable verdicts; a conditional
  third workload must clear the higher bar in D3.

## Rejected ideas

- **Use only `sparse-spans-few`.** Rejected because two spans cannot expose the
  post-draw clip-construction cost that caused the btop regression.
- **Use only `sparse-spans-max`.** Rejected because its whole-process metric is
  less direct and less sensitive to loss of the ideal sparse-rendering win.
- **Borrow an existing workload's thresholds.** Rejected because workload,
  metric, pair count, and variance jointly define a rule's validity.
- **Tune after the known-bad run.** Rejected because it overfits the rule to the
  defect used to validate it and destroys the independence of the freeze.

## Implementation discretion

- The producer and artifact representation, provided the two externally named
  workloads and their exact topology contracts remain stable.
- The calibration command decomposition and saved artifact layout, provided the
  screen/confirmation split and frozen-rule provenance remain auditable.

## Commit progress
- [x] 1. Share the glyph-halo damage transform from the planning library
- [x] 2. Add the sparse-spans-few and sparse-spans-max producer stimulus
- [ ] 3. Record engine damage topology on accepted sparse-span draws
- [ ] 4. Collect the sparse-span workloads as undecidable candidates
- [ ] 5. Freeze calibrated sparse-span decision rules
- [ ] 6. Prove historical sensitivity and graduate the documentation

## Implementation notes

- Commit 1: `PO1` needs the halo transform under a headless test, so
  `terminalDamageRowsWithGlyphHalo` moved from `app/SwiftTerminalSessionView.swift`
  into `TerminalRenderPlanning/TerminalDamageSpans.swift`, beside the span
  helpers `24c3d03` had already moved for the same reason. The UI harness
  compiles app sources directly rather than linking the planning module, so
  `test-ui.sh` now compiles `TerminalDamageSpans.swift` too -- which also
  repairs a break `24c3d03` left behind: it moved
  `terminalDamageMaximalContiguousSpans` out of the app file without adding the
  new home to that list, so `just test-ui` could not compile at `HEAD`. One
  definition still serves both builds.
- Commit 1: the two-distant-row derivation test names engine rows 5 and 60 at
  66 rows. The plan fixes the topology (6 rows, 2 spans), not the row indices;
  commit 2's producer contract test is what binds the stimulus to that shape.
- Commit 2: the stimulus writes ANSI rows 6/61 and 1, 5, ..., 65, so its engine
  row sets are exactly the ones commit 1's halo derivation test runs through the
  shared transform. That is the binding between stimulus and drawing topology;
  the producer test restates the span count locally rather than importing the
  transform it is checking the stimulus against.
- Commit 2: the two names live in their own `SPARSE_SPAN_WORKLOADS` tuple rather
  than joining `REDRAW_WORKLOADS`, whose contract is "every entry the paired
  ladder schedules". Commit 4 is what makes them ladder members, so until then
  the separate tuple keeps that contract true; `redraw_screen`'s existing
  dispatch already routes them, so the settling frame, run loop, and
  serialized-draw handshake needed no change.
