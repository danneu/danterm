# Decisions -- logical-line scrollback (doc 31)

Auditable decision log for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md).

### D1 -- go/no-go for the logical-line store

- Status: **rule frozen 2026-08-04 at `de17e95`, before the F1 probe existed in
  the tree and before any comparison number was produced.** Verdict pending
  below. The rule is stated in full here -- instrument, comparison target,
  validity gates, thresholds and their derivations, and what the simplification
  inequality must show -- so that no threshold can be chosen after seeing a
  result.
- Evidence used (planned): F1 (read-path probe), F2 (counting pass), F3
  (admission probe), F4 (edge-case inventory -- specifically whether any edge
  case requires stored width, which rejects H4 and the premise).
- Candidate solutions: go (open Phase 2 design), no-go (fall back to the
  hybrid recorded in Rejected / `28/H7`), or narrow-go (viable but with a
  named condition, e.g. a search index requirement discovered in F1).

#### The frozen rule

**Scope.** D1 has two parts. Part A is the read path and is decided by F1
alone, because H1 names `retained-browse` parity as the go/no-go and F1 is its
falsifier. Part B is everything else -- F2, F3, F4, and the simplification
inequality -- and D1 does not close until all of it is in. **F1 can therefore
produce a `no-go` outright (the premise dies), or a `go`/`narrow-go` *on the
read path* with Part B still owed.** No F1 result licenses a production
storage change; `28/H7` stays the fallback until D1 closes.

**Instrument (Part A).** A standalone two-arm microbenchmark in
`lib/TerminalCore/Tests/TerminalCoreTests/`, release configuration, headless,
gated behind an environment variable so it is not part of `just test`'s timed
gate. Arms are interleaved ABBA within one process at a round count frozen
here: **5 measured rounds per (content class, access pattern)**, statistic =
**median over rounds of nanoseconds per display-row read**, min and max
reported alongside. It reuses the `28/F23` harness's conventions (commit
`e5da63f`): a real `Terminal` at 179x66 supplies the stimulus, every aggregate
is printed with its sample count, and the probe reports distributions rather
than verdicts.

**Comparison target.** The current retained-row read path: an array of
`Terminal.PackedRetainedRow` values produced by `PackedRetainedRow.pack` from
the `GridRow`s a real `Terminal` retained after being fed the same stimulus at
179x66, addressed by the same O(1) display-row-index-to-row mapping
`ScrollbackBuffer`'s subscript performs, and read through the same
`forEachKind` + `forEachContentCell` readers the browse path uses (`28/F17`).
`ScrollbackBuffer` itself is `private` to `Terminal`; the arm reproduces its
element type, its readers and its index arithmetic rather than calling it, and
that substitution is a stated fidelity limit of F1, not a silent one.

**Candidate.** Contiguous byte arena of variable-length logical-line records
(header carrying cell count + flags, then C1-shaped 8-byte cells), plus the
derived block index: per-line record offsets, blocked at ~256 lines, one cached
display-row total per block at the current width; display-row lookup is a
binary search over block totals then an in-block scan. Nothing width-dependent
is stored.

**Stimulus classes, both at ~10,000 display rows and 179 columns.**

1. `mix` -- reproduces `28/F23`'s measured content distribution: display-row
   cell counts with **median in [119, 154] and p95 = 179**.
2. `full` -- full-width content: every display row 179 cells
   (`28/F23`'s `bound/wide-full-width-saturation` class).

**Access patterns.**

1. `sequential browse` -- the retained-browse pattern: one display-row index
   lookup per frame, then 66 consecutive display rows read forward, each read
   doing both walks (`forEachKind` for geometry, `forEachContentCell` for
   render), which is what `28/F17` left the frame path doing.
2. `random seek` -- a point read at a uniformly random display-row index:
   lookup plus the same two walks, one row per operation.

**Validity gates. Any failure voids the invocation, and a void invocation is
not a verdict and does not become one by re-running.**

1. **Cross-arm equivalence.** Both arms accumulate a checksum over every
   scalar, style id and kind they read. The checksums must be identical for
   every measured pattern. A difference means the arms are not reading the same
   content and no timing from that run may be quoted.
2. **Stimulus calibration.** The `mix` class's measured median and p95 must
   land in the band above. Out of band -> the probe reports the achieved
   distribution and the run is void for `mix`.
3. **Instrument resolution (A/A control).** A baseline-vs-second-identical-
   baseline control runs in the same session at the same round count, for every
   pattern. Its |median difference| is the instrument's resolution. **A
   candidate-vs-baseline difference smaller than the A/A resolution is reported
   as below resolution and is not read as an effect in either direction.** If
   the A/A control itself exceeds 5%, the instrument is too noisy and the whole
   invocation is void.
4. **Host conditions**, as `28/F15` gated them: AC power, low-power mode off,
   one-minute load average below 2.5 read before and after.
5. **Coverage.** Every aggregate is printed beside its sample count, and a
   quantity that could not be measured is reported absent rather than as 0
   (`agent-docs/measurement-discipline.md`).

**Thresholds, and where each number comes from.**

- `sequential browse`, **both** content classes: candidate median
  **<= 1.20x** baseline.
  *Derivation:* `28/F17` measured the two retained-row read walks at 302 + 205
  self samples of ~9,750 in `planFrame` -- **~5.2% of frame-planning time** --
  and that same decode delta read as +3.27% on `retained-browse`. At a 5.2%
  share, a 20% regression of the read walk is ~1.04% at the frame, which sits
  at `retained-browse`'s frozen 1.05% directional threshold
  (`agent-docs/terminal-performance.md`). A candidate above 1.20x therefore
  predicts a `slower` verdict on the workload H1 named as its falsifier.
- `random seek`, **both** content classes: candidate median **<= 3.0x**
  baseline **and** candidate absolute **<= 5.0 us** per point read.
  *Derivation:* random seek is not on the frame path, so a frame-share
  threshold does not apply to it; the latency budget is doc 21's. `21/F2`
  measured a `.character` drag-move at **92-101 us** deep, with roughly six
  projection reads per query plus its application (`21/F1`). A point read at
  <= 5.0 us keeps the whole read component under ~30 us -- a minority of the
  cost the indexed-read direction was funded to remove, rather than its new
  dominant term. The 3.0x ratio is the separate guard that a structurally O(1)
  lookup is not traded for a walk whose constant merely happens to be small at
  this depth.

**Verdicts (Part A), applied exactly once to the frozen statistics.**

- **no-go** -- `sequential browse` exceeds 1.20x on either content class. H1 is
  falsified, the premise of the design fails at the acceptance dimension the
  README makes primary, and `28/H7` (the hybrid) is the direction. Phase 2 does
  not open.
- **narrow-go** -- `sequential browse` passes on both classes, `random seek`
  fails either of its two bounds. Phase 2 may open only with the named
  condition that the index be refined (smaller blocks, or per-line display-row
  counts stored beside the offsets) and re-measured against **this same rule**
  before any production storage change. Disposition is a human decision.
- **go (read path)** -- both patterns pass on both classes. Part A is
  satisfied; D1 remains open on Part B.

**What the simplification inequality must show (Part B, at D1's close).** The
deletion list must actually contain: history reflow mutation,
`productionScrollbackCellCap`, `productionScrollbackRowCap`, the `28/D8`
cost-model derivations and their tests, narrow-then-widen eviction machinery,
and continuation-flag bookkeeping in retained history. The addition list --
arena, block-summed wrap index, open-line rule, forced-split rule -- must be
pure, unit-testable, and free of any width-dependent persisted state. **If F4
surfaces one edge case that genuinely requires storing wrap or width state,
D1 is no-go regardless of F1**, because that entry breaks the property every
other deletion on the list descends from.

#### Verdict

- Selected direction: **pending F1.** Nothing has been measured at the time
  this rule was written and committed; this section is filled in only after
  F1's numbers exist, by applying the rule above exactly once.
</content>
</invoke>
