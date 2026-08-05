# Audit: the ten long-running TerminalCore gate tests

Measured 2026-08-05 on a 10-core machine, debug builds (the gate runs no
`-c release`). The `swift test --package-path lib/TerminalCore` gate step's
test run is a plateau: ~960 of 970 tests finish by ~35s, then the ten tests
below trickle in until ~44s and set the wall clock. Total run CPU is ~290s.
Each test was read in full, with its helpers and corpora, and assessed on two
questions: is the guarantee already covered elsewhere, and can the same
guarantee be established much faster.

Headline: almost none are superfluous, but nearly all pay for their guarantee
the expensive way -- and three do not prove what their preambles claim.

Two cross-cutting cost drivers recur throughout:

- Every production-budget `Terminal` construction zero-fills a
  `budget - budget/16 = 15,728,640`-byte arena in `LogicalLineStore.init`
  (`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift:274-296`,
  `Terminal.productionScrollbackBudgetBytes = 16_777_216` at
  `Terminal.swift:711`). A ~15.7 MB memset before a byte is fed.
- Debug builds magnify per-`#expect` Swift Testing event machinery and eager
  string interpolation everywhere.

**Correction, measured while implementing row #8:** the second driver is half
wrong. A *passing* `#expect` costs roughly 0.3us, so the 100,170 of them in
`officialNormalizationCorpusMatches` accounted for ~0.03s of its 0.73s -- the
assertion count is not a meaningful cost anywhere in this plan. Eager string
interpolation at a call site *is* real (it runs whether or not the expectation
fails); the Swift Testing event machinery around a passing expectation is not.
Any remaining row whose payoff estimate rests on "N `#expect`s dominate" must
be re-derived before it is worked -- this applies to row #10's "~53,900
assertion blocks" and to the `@autoclosure` half of row #15.

## Commit progress

One commit per unchecked box, worked top to bottom. Each entry names the fix,
the file it lands in, and the **minimal** command to run immediately before and
immediately after the change. The before/after timings are informative only --
a single debug-build wall clock on a loaded machine, recorded to show the fix
moved the number in the right direction, not to establish a measurement. Record
the observed pair in the "measured" column when the box is checked.

Rules for each commit:

- TDD where the fix is behavioral (the vacuous/false-premise items): write the
  strengthened assertion first, watch it fail against today's code, then fix.
- The pure-speed items must not weaken coverage. If the guarantee changes, say
  so in the commit body.
- Stage and commit only that item's files. Update this checklist's box and
  measured column in the same commit.

| # | Fix | Test filter | Expected | Measured (before -> after) |
|---|---|---|---|---|
| 1 | [x] Bound the twin's rebase budget in `withUnlimitedScrollbackForTesting` (item "1.") | `--filter seededTwinOracleAndChunkInvariance` | 50-200x | 9.6s -> 0.7s |
| 2 | [x] Seed the hyperlink id cursor near the `UInt16` wrap (item "2.") | `--filter linksSurviveIdSpaceExhaustion` | ~280x | 10.75s -> 0.09s |
| 3 | [x] Cover the never-reached `targets.count > HyperlinkId.max` refusal branch (item "2." bonus finding) | `--filter TerminalHyperlinkTests` | correctness | 0.66s -> 0.64s (additive; new test 0.09s, runs in parallel) |
| 4 | [x] Fix the vacuous `scrollbackRowCount < recipe.lineCount` assertion, or delete the test (item "probeTerminalIsBudgetSaturated") | `--filter probeTerminalIsBudgetSaturated` | gone | 2.07s -> 0.45s (kept, retargeted + renamed `standardRecipeIsLineBoundedNotBudgetBounded`) |
| 5 | [x] `saturationReachesDepth`: charge arithmetic + a real eviction assertion; fix the stale "10 MiB budget" comment in `TerminalOccupancyProbe/main.swift` | `--filter saturationReachesDepth` | 12-15x | 14.85s -> 2.10s (test time; the real margin is ~3.0x, not the 1.55x the finding estimated) |
| 6 | [x] `widthChangeEvictsNothing`: correct the false "saturated history" premise, shrink to ~800 lines or a genuinely saturating injected budget, hoist `expectValidGrid` out of the width loop | `--filter widthChangeEvictsNothing` | 5-10x | 10.11s -> 1.13s (injected 512 KiB budget; the loop also gained a per-width history-text assertion) |
| 7 | [x] Migrate the `retainedBytesPerStoredCell` band into `censusReportsRetentionHealth` and delete `historyRespectsItsBudgetInRealBytes` | `--filter TerminalScrollbackBudgetTests` then `--filter censusReportsRetentionHealth` | 10-20x or gone | suite 14.77s -> 1.79s; census test 0.77s -> 0.44s (band added; the drop is warm-run noise, not a saving) |
| 8 | [x] `officialNormalizationCorpusMatches`: mismatch accumulator + one terminal `#expect`, UTF-8-view parsing (corpus stays exhaustive) | `--filter officialNormalizationCorpusMatches` | 5-15x | 0.732s -> 0.521s (1.4x; the 5-15x estimate was wrong -- a *passing* `#expect` costs ~0.3us, so all 100,170 of them were ~0.03s of the 0.73s. The real cost was parsing, and the residue is the 100,170 decompositions themselves, which are the coverage) |
| 9 | [x] `replayFixtures`: parameterize per fixture (`@Test(arguments: try fixtureURLs())`) | `--filter replayFixtures` | ~cores | 14.33s -> 5.71s (2.5x, not ~cores: one long-pole fixture sets the floor. `--no-parallel` on the new code is 14.36s, confirming identical work) |
| 10 | [ ] `replayFixtures`: assert chunk-invariance by checkpoint-snapshot-vector equality instead of re-running every expectation block | `--filter replayFixtures` | ~10x, stronger | |
| 11 | [ ] `saturatingRecipesReachTheBudgetCeiling`: charge arithmetic for two recipes, keep `.wideSaturating` on the observed-eviction path | `--filter saturatingRecipesReachTheBudgetCeiling` | 15-20x | |
| 12 | [ ] `blankHistoryAtTheIndexRingDoublingPointKeepsRetaining`: early stop one ring-block past a stable record count (rescaled budgets deliberately deferred) | `--filter blankHistoryAtTheIndexRingDoublingPoint` | 5-7x | |
| 13 | [ ] `tailReadCostTracksTheBudgetNotTheCapacity`: build each terminal once and sample the non-mutating read 3x; 6,400 -> 3,200; `rows: 50 -> 4` | `--filter tailReadCostTracksTheBudgetNotTheCapacity` | ~5x | |
| 14 | [ ] `primaryHistoryTextStaysLinear`: 400 vs 3,200, `rows: 50 -> 4`, share the corpus builder with #13 | `--filter primaryHistoryTextStaysLinear` | 2-3x | |
| 15 | [ ] `dialectRecordingSweep`: dedupe by injection identity, boundary-chosen injections, compute `fullHistoryText` once, `@autoclosure` the diagnostic context, hoist `expectValidGrid` to per-fixture | `--filter dialectRecordingSweep` | 3-4x | |

Base command for every filter above:

```
swift test --package-path lib/TerminalCore --filter <name>
```

except #5, whose suite lives in
`lib/TerminalCore/Tests/TerminalOccupancyProbeSupportTests/`.

After the last box, run the full `swift test --package-path lib/TerminalCore`
and record the new wall clock against the ~44s baseline in the header above,
then `just test` once as the real gate.

## Superfluous, redundant, or broken

### `TerminalScrollbackBudgetTests.historyRespectsItsBudgetInRealBytes` -- mostly redundant

`TerminalScrollbackBudgetTests.swift:614`. 20,000 separate ~55-byte feeds at
179x66 charge ~9.1 MB against a 15.7 MB arena -- **it never evicts**, so the
budget claim is proved in the easy regime. Its first three expectations are a
weaker version of `TerminalMemoryCensusTests.censusReportsRetentionHealth`
(`TerminalMemoryCensusTests.swift:152`), which feeds 1,200 lines, observes
real eviction (`sawEviction`), and asserts `peak <= capacity` and no
retained-storage overdraft at ~6% of the cost. Unique residue: only the
two-sided `retainedBytesPerStoredCell` band (`> 8`, `< cellStrideBytes / 3`),
which is depth-independent once a few hundred records exist.

**Verdict:** migrate the bytes-per-cell band into
`censusReportsRetentionHealth` and delete; or shrink to ~2,000 lines
(10-20x). Note `publicProductionBoundsCrossing`
(`TerminalScrollbackBudgetTests.swift:571`, another 20,000 feeds) sits in the
same cost class and overlaps it.

### `TerminalResizeProbeSupportTests.probeTerminalIsBudgetSaturated` -- vacuous

`TerminalResizeProbeSupportTests.swift:21-34`. Feeds `.standard` (10,000
dense lines, ~409 B/line charge = ~4.1 MB against 16 MiB -- nothing evicts)
and asserts `scrollbackRowCount < recipe.lineCount`, which passes anyway
because the last 66 lines sit in the viewport, not scrollback. 10,000 debug
feeds proving nothing.

**Verdict:** assert eviction properly or delete.

### `OccupancyCorpusTests.saturationReachesDepth` -- half redundant, half vacuous

`Tests/TerminalOccupancyProbeSupportTests/OccupancyCorpusTests.swift:51-71`.
30,000 corpus lines (~870 B/line, ~3 MB UTF-8 built by `payload += ...`) at
179x66, then a full-history `beginSearch`. Two problems:

- The assertion `scrollbackRowCount < 30_000` is satisfiable with **zero
  eviction** (viewport rows account for the difference) -- the exact defect
  its preamble accuses the earlier form of. It happens that 30,000 x ~870 B
  ~ 26 MB exceeds the 16 MiB budget, but the test never asserts that. Also
  `TerminalOccupancyProbe/main.swift:26` still says "the 10 MiB budget"; the
  30,000 constant was sized against the older budget and its margin has
  silently fallen from ~2.5x to ~1.55x.
- The "matches survive eviction" half is already covered cheaply at a small
  budget by `TerminalSearchTests.swift:249` and `:420`.

This test calibrates the probe binary's shipped defaults for
`docs/research/19-owner-queue-occupancy.md` -- a research artifact, not an
app invariant; nothing in the app imports `TerminalOccupancyProbeSupport`.

**Verdict:** shrink 12-15x via charge-rate arithmetic (feed 2,048 lines,
read `memoryCensus`, assert `perLine * 30_000 >= capacity * 1.25`) and assert
real eviction; or demote to the existing env-gated probe tier
(`DANTERM_LOGICAL_LINE_PROBE` pattern,
`TerminalLogicalLineEvictionProbe.swift:581-584`).

### `TerminalScrollbackBudgetTests.widthChangeEvictsNothing` -- premise false, oversized

`TerminalScrollbackBudgetTests.swift:224`. The preamble claims a "saturated
history", but 4,000 lines x 179 chars ~ 5.8 MB against a 15.7 MB arena --
**nothing is ever evicted**; 4,000 does no structural work beyond crossing
512 KiB chunk seams (first seam at ~360 lines). The cost is 8-10 full-history
walks: three narrow-width refolds (at width 2, ~360K display rows) each
followed by `expectValidGrid`, whose `independentScrollbackRowRecount`
(`TerminalGridAssertions.swift:20`) is a second full fold walk plus two
whole-terminal copies.

Store-level coverage already exists and is stronger:
`TerminalLogicalLineStoreTests.widthChangeIsANoOpOnRetainedStorage` (:214)
pins arena-byte and cell-for-cell equality across widths at negligible cost;
`resizePathsEnforceBudget` (:339) and `wideningDoesNotEvictCompactHistory`
(:17) cover the Terminal-level path at tiny sizes. Unique residue: the
`Terminal.resize` path at chunk-seam depth.

**Verdict:** shrink to ~800 lines (still crosses a seam), or use a small
injected budget that genuinely saturates -- cheaper and honest. Hoist
`expectValidGrid` out of the width loop. 5-10x.

## Big mechanical shrinks, guarantee untouched (ranked by payoff)

### 1. `TerminalScrollbackBudgetTests.seededTwinOracleAndChunkInvariance` -- ~50-200x

`TerminalScrollbackBudgetTests.swift:507`. The suffix-oracle fuzz (32 seeds x
96 actions at a 5x2 grid with a few-hundred-byte budget) rebuilds an
"unbounded twin" **inside the action loop** via
`withUnlimitedScrollbackForTesting()`, which calls
`history.rebased(toBudgetBytes: productionScrollbackBudgetBytes)`
(`Terminal.swift:2277`, `LogicalLineStore.swift:1271`) -- a fresh 15.7 MB
zero-filled arena per action. 3,072 constructions = **~48 GB of memset** to
hold a history that never exceeds a few hundred bytes. The actual terminal
work is trivial by comparison.

Nothing in the assertions requires 16 MB -- the twin only needs to be
unbounded relative to one action. Give `withUnlimitedScrollbackForTesting` an
optional budget (e.g. `1 << 16`) and the memset drops ~240x. The suffix-oracle
property is unique to this test; keep it.

### 2. `TerminalHyperlinkTests.linksSurviveIdSpaceExhaustion` -- ~280x

`TerminalHyperlinkTests.swift:180-221`. Feeds `70_000` distinct OSC 8 targets
solely to wrap the `UInt16` id counter (`HyperlinkId`, `Terminal.swift:175`;
`nextHyperlinkId` advance at :1680-1683) once. Per iteration the admission
path copies the whole ~500-entry target dictionary and reduces over it twice
(~10^8 operations in debug). The 480-byte padding is near-optimal already;
only the iteration count is reducible.

Make the id cursor seedable (internal setter or `_seedHyperlinkId(_:)`; tests
are `@testable`), start at ~65,400, run ~250 iterations: the wrap happens,
the allocator walks back to low ids, and must still skip id 1 held by the
pinned column-0 cell -- exactly the existing assertion at :214.

Bonus correctness finding: the `targets.count > HyperlinkId.max` refusal
branch (`Terminal.swift:1679`) named in the preamble ("running out of ids")
is **never reached** -- the table steady-states at ~500 entries. A second
cheap seeded case with short URIs would cover the untested half.

### 3. `TerminalFixtureTests.replayFixtures` -- ~10x, and stronger

`TerminalFixtureTests.swift:10-22`, driver at :443, splits at :351. 67
fixtures (51 libvterm + 20 alacritty + 1 windows-terminal, minus 5 milestone8
recordings). "All feed splits" is one two-chunk split per (feed event,
offset); with `exhaustiveThreshold = 64` the exhaustive branch is effectively
always taken -> 3,724 split strategies, ~3,843 complete replays. Byte volume
is trivial (~1.4 MB total); the cost is that **every** replay re-runs every
checkpoint's full expectation block (~53,900 executed blocks) plus 3,724
whole-`Terminal` `==` compares, all inside one serial `@Test`.

Two changes, both coverage-preserving:

- Parameterize per fixture (`@Test(arguments: try fixtureURLs())` -- the
  pattern already exists at `milestone8ApplicationReplay`, :38). Wall-clock
  factor ~ available cores on the serial tail.
- Assert chunk-invariance by state equality, not re-assertion: record a
  checkpoint snapshot vector on the authored run, assert expectations once,
  and have each split/bytewise run do a single snapshot-vector compare.
  Strictly stronger than today's final-state-only `==` (catches divergence
  that re-converges) while collapsing ~53,900 assertion blocks to ~3,800
  array compares.

Boundary-chosen offsets (escape/UTF-8-interior positions + seeded sample)
would only buy ~2x more on this corpus and carry real risk of losing a
pending-wrap/grapheme boundary; do last or not at all.

### 4. `TerminalResizeProbeSupportTests.saturatingRecipesReachTheBudgetCeiling` -- ~15-20x

`TerminalResizeProbeSupportTests.swift:36-90`. Guards three frozen recipe
constants consumed only by the `TerminalResizeProbe` binary
(`just terminal-resize-probe`, research doc 28) -- calibration, not an app
invariant. First eviction lands at 40,960 / 247,808 / 12,288 lines
(dense/sparse/wide); ~301,000 debug lines per run. The early-stop from commit
`0a3e473d` saves only 0.9% of the sparse case, which is ~82% of remaining
time.

All three payloads have deterministic per-line charge, so saturation is
arithmetic: feed a 2,048-line prefix, read
`memoryCensus.retainedChargedBytes` / `retainedArenaCapacityBytes` (public),
assert `perLineCharge * recipe.lineCount >= capacity * 1.5`. Keep one recipe
(`.wideSaturating`, cheapest) on the real observed-eviction path to anchor
the arithmetic. Alternatively demote the two expensive recipes to the
env-gated probe tier.

### 5. `CanonicalCaselessTests.officialNormalizationCorpusMatches` -- ~5-15x

`CanonicalCaselessTests.swift:9-29`. Sweeps all 20,034 data lines of
`Fixtures/unicode/NormalizationTest-17.0.0.txt` with 5 `#expect`s per line =
**100,170 `#expect` invocations**; Swift Testing's per-expect machinery
dominates, not the table lookups. Parsing adds 20,095 Foundation-bridged
`trimmingCharacters` calls. Coverage is unique (no other test touches
`canonicalDecomposition`) and the corpus must NOT be sampled -- Part 1 is the
exhaustive sweep that proves singletons/recursion/Hangul.

Fix the mechanics, not the coverage: accumulate mismatches in a plain loop
and end with one `#expect(failures.isEmpty)` (+ `Issue.record` for the first
N); parse on UTF-8 views without the Foundation bridge.

### 6. `TerminalHistoryTailTests.tailReadCostTracksTheBudgetNotTheCapacity` -- ~5x

`TerminalHistoryTailTests.swift:137`. The bounded-read cost claim is unique
(correctness is covered at :73 and :97), but `tailCost(lines:)` **rebuilds
the entire terminal for every timing sample**: 20,600 line feeds and 7
production-budget constructions to time a read that takes microseconds.
`primaryHistoryTailText` is non-mutating -- build each terminal once and take
the min of 3 reads (also a better instrument). Then 6,400 -> 3,200 keeps an
8x history ratio against a 4x threshold, and `rows: 50 -> 4` cuts scroll
shuffling. Its corpus is byte-identical to `primaryHistoryTextStaysLinear`'s
(same 200-col line, same 400/6,400 counts) -- the pair could share one
builder.

### 7. `TerminalLogicalLineStoreTests.blankHistoryAtTheIndexRingDoublingPointKeepsRetaining` -- ~5x now, ~30x later

`TerminalLogicalLineStoreTests.swift:167`. 6 budgets x 60,000 blank admits =
360,000 admits, but saturation depth is ~8,300-17,000 records -- the loop
runs 4-7x past the structural event (the index-ring doubling, doc 31/DD56)
with no early stop (commit `0a3e473d` touched only the resize-probe suite).

- Now: stop once eviction is observed and the record count is stable for one
  ring-block (64) more admits. ~4-7x, risk-free.
- Later: the doubling window (`capacity/24.25` .. `capacity/16.25`,
  documented at `LogicalLineStore.swift:2199-2213`) is scale-free, so ~8x
  smaller budgets (~17-37 KB, putting 1024/2048 in the window) cross the
  identical threshold at ~1,000-2,000 records. But the current six budgets
  were derived empirically (guard removed, budget 144,000 settles at 0
  records) -- scaled replacements must be re-derived the same way or the
  test silently stops covering DD56.

### 8. `TerminalPromptAnchorResizeSweepTests.dialectRecordingSweep` -- ~3-4x, keep in gate

`TerminalPromptAnchorResizeSweepTests.swift:53-76`. The one genuinely
gate-worthy test of the probe group: real OSC 133 prompt anchoring under a
resize landing mid-feed-chunk, with a seven-bug regression history, two of
which escaped hand-built cases. Do not demote. But:

- 5 fixtures x 8 seeds = 40 full replays, and the bash fixture has exactly
  **one** injection candidate, so 7 of 40 cases are byte-identical
  duplicates. Dedupe by injection identity: free.
- The seeds sample which follow-up resize width lands after the injection;
  boundary-chosen cases (first/last candidate chunk, widest and narrowest
  follow-resize, distinct byte offsets) give ~18 cases instead of 40 and pin
  the extremes instead of sampling them. Keep the
  `DANTERM_PROMPT_ANCHOR_SWEEP` rerun hook for arbitrary seeds.
- `fullHistoryText` is computed twice per case (:64, :67) -- compute once.
- `expectSemanticPromptInvariants` eagerly builds a ~250-char diagnostic
  string ~3,600 times; make the context parameter `@autoclosure`.
- `expectValidGrid` (two whole-terminal copies) runs per case; per fixture
  suffices -- `TerminalShellDialectTests` already runs it on two of these
  fixtures.

The un-injected per-event oracle over these fixtures is separately covered by
`TerminalSemanticPromptInvariantTests.recordingCorpus`.

### 9. `TerminalScrollbackTests.primaryHistoryTextStaysLinear` -- ~2-3x

`TerminalScrollbackTests.swift:185`. The O(N)-projection claim is unique and
cannot be replaced by operation counting -- the historical regression lived
in `String` copy-on-append inside the stdlib, invisible to `LocateCounter`.
But the separation only needs the size ratio: 400 vs 3,200 keeps an 8x
spread against the 2.5x threshold (measured 1.04x linear vs 5.5x quadratic),
and `rows: 50 -> 4` avoids gratuitous viewport scrolling. Shares its corpus
with item 6.

## Summary table

| Test | Verdict | Factor |
|---|---|---|
| `seededTwinOracleAndChunkInvariance` | shrink the twin's rebase budget | 50-200x |
| `linksSurviveIdSpaceExhaustion` | seed the id cursor near the wrap | ~280x |
| `replayFixtures` | parameterize + snapshot equality | ~10x, stronger |
| `saturatingRecipesReachTheBudgetCeiling` | charge arithmetic + one anchored eviction (or demote 2 of 3 recipes) | 15-20x |
| `officialNormalizationCorpusMatches` | mismatch accumulator, UTF-8 parsing | 5-15x |
| `tailReadCostTracksTheBudgetNotTheCapacity` | build once, sample the read | ~5x |
| `blankHistoryAtTheIndexRingDoublingPoint...` | early stop; later rescale budgets with re-derivation | 5-30x |
| `historyRespectsItsBudgetInRealBytes` | migrate bytes-per-cell band, delete | 10-20x or gone |
| `widthChangeEvictsNothing` | ~800 lines or real saturating budget; fix "saturated" claim | 5-10x |
| `dialectRecordingSweep` | dedupe + boundary-chosen injections + lazy diagnostics | 3-4x |
| `saturationReachesDepth` | charge arithmetic + real eviction assertion (or demote) | 12-15x |
| `probeTerminalIsBudgetSaturated` | fix vacuous assertion or delete | gone |

Correctness findings worth fixing regardless of speed: the vacuous
assertions in `probeTerminalIsBudgetSaturated` and `saturationReachesDepth`,
the false "saturated" premise in `widthChangeEvictsNothing`, the untested
id-refusal branch in `linksSurviveIdSpaceExhaustion`, and the stale "10 MiB
budget" comment in `TerminalOccupancyProbe/main.swift`.
