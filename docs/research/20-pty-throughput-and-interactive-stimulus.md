# PTY throughput reporting and interactive stimulus coverage

Research started: 2026-07-30. **Status: OPEN -- Phase 1 done from evidence
already on disk; nothing built, no direction gate passed.**
Deliverable is a decision on what throughput quantity the benchmark system
should report (`D1`), and a judgement on whether a keypress-driven interactive
workload is worth building (`D2`).
Continues: no ancestor. Adjacent to doc 8 (benchmark variance) and doc 17
(auxiliary metrics and their calibration), whose rules are inherited rather than
re-derived.

## Purpose

This file owns two gaps that surfaced from one question -- "can we benchmark a
real app like btop under a held-down arrow key?" -- and that turned out to be
adjacent rather than identical:

1. **The benchmark system reports no throughput marker**, despite already
   measuring one. `F2` found the quantity recorded, unreported, in every
   `scrollback-stream` block ever run.
2. **No workload is driven by input.** Every stimulus this project owns is
   frozen bytes replayed into a PTY. Nothing measures the loop that starts at a
   keystroke.

The scope boundary that matters: this file is about **what the benchmark system
measures and reports**, not about making anything faster. No optimization
belongs here. A throughput number that moves when our code moves is the whole
ask -- cross-project comparability was explicitly declined by the user on
2026-07-30 and is out of scope permanently (see Rejected).

## Investigation rules

Inherited:

- **No implementation of a code candidate before a user direction gate**
  (`agent-docs/terminal-performance.md`).
- **An auxiliary metric rides the deciding metric's blocks and cannot buy more
  pairs** (`17/F15`). Any proposal to *decide* on a new metric must budget for an
  A/A screening pass, and must accept that the screen may refuse it.
- **A metric with no frozen rule reports a bare percentage and never a verdict**
  (`17/D6`).

Added here:

- **Distinguish the three brackets by name every time.** Parse+grid with no PTY
  (`feedDurationNanoseconds`), bytes-into-the-PTY (`producerWriteNanoseconds`),
  and write-through-final-draw (`finalDrawNanoseconds`) are three different
  questions, and this file exists partly because the middle one was invisible.
- **Any derived rate names its denominator.** "MB/s" is meaningless without the
  corpus byte count and the geometry; both are pinned facts (1,525,000 bytes,
  179x66) and both must appear beside any rate.
- **The instrument is the producer too.** `F3` measures the Python producer's own
  ceiling. Any claim about the app's drain rate carries that offset explicitly.

## Trigger and current evidence

Opened 2026-07-30 from a user question about benchmarking a real TUI (btop)
under a synthetic held key. Three things came out of the survey and the
evidence already on disk, in increasing order of consequence.

Provenance for everything below: 55 `scrollback-stream` comparison runs
(368 measured blocks) already present under
`.build/terminal-benchmark-comparisons/*/*/run.json`, all at 179x66, spanning
many revisions across the doc 15-18 era. These are re-readings of existing
artifacts, not a new measured run. `.build/` is disposable, so the extracted
numbers are recorded here rather than cited by path.

## Current hypotheses

### H1 -- `finalDrawNanoseconds` can hide drain-path work -- REFUTED

Proposed mechanism: a change that speeds the PTY drain but leaves the final draw
landing at the same wall clock would read `equivalent`, hiding real work, in the
same shape as the plan-time blind spot documented in
`agent-docs/terminal-performance.md`.

**Refuted by `F2` before any experiment was designed.** The two quantities are
95.7% the same number (median across 368 blocks). There is no room for one to
hide anything from the other. Recorded because the hypothesis was stated to the
user before it was checked, and because the refutation is the file's most useful
single fact: `scrollback-stream` *is* a throughput benchmark, labelled as a draw
one.

### H2 -- the producer's ~30 ms floor is additive and arm-symmetric -- REJECTED in favor of sub-additivity

Proposed mechanism: `F3`'s 30.2 ms Python write ceiling, measured against blocks
running 145-372 ms, is additive and identical in both arms -- compressing
reported percentage differences without ever fabricating a direction.

The competing explanation was that the cost is *sub*-additive, because once
`write()` blocks on a full PTY buffer the producer's syscall overhead hides
inside the wait.

**`F6` ran the distinguishing experiment and the competing explanation won
outright: 0.0 ms of producer overhead reaches the block.** So `F3`'s 30.2 ms is
an upper bound that is not approached in practice, and the reported MB/s is the
app's drain rate rather than a figure needing a mental correction. The residual
caveat is that `F6` models the consumer rather than running the app.

Note for anyone revisiting this: **do not "fix" the offset by changing the corpus
chunking** -- read chunk boundaries are part of the workload contract
(`agent-docs/terminal-performance.md`, "Choose the benchmark boundary"). `F6`
varies chunking only inside a throwaway model, never in the corpus.

### H3 -- drain would be a *better* deciding metric for `scrollback-stream` than the one in use

`F4` finds `producerWriteNanoseconds` is quieter than `finalDrawNanoseconds`
(within-arm block CV median 0.87% against 1.24%), which stands to reason: the
~9.5 ms draw tail carries most of the jitter and 4% of the signal.

This is deliberately *not* the candidate in `D1`. Replacing a frozen deciding
metric means recalibrating the rule from scratch, invalidating the thresholds
every directional claim in docs 8-18 rests on, and doing it for a metric 96%
correlated with the one already there. Parked, with its reopening condition:
take it up only if `scrollback-stream` starts returning `inconclusive` often
enough to obstruct work.

### H4 -- a keypress-driven stimulus measures something no current workload does

Still unmeasured, but **largely answered structurally by `F8`.** Every existing
workload writes bytes and waits, so none contains the key-encode -> PTY -> app ->
draw loop, and `F1` establishes that no upstream project has looked either. What
`F8` adds from source: the loop's *unique* segment is thin -- AppKit key handling
plus one enqueue -- while its expensive segments are already owned, the drain and
draw by the five existing workloads and the queue wait by doc 19. So the
hypothesis is true as stated and much less interesting than it sounded. See `D2`.

## Candidate direction, pending evidence

Provisional, pending `D1`: report the split descriptively on `scrollback-stream`
-- drain ms, derived MB/s, and the draw tail (`finalDraw - producerWrite`) --
beside the existing verdict, with no new decision rule and no calibration pass.

Rationale: the quantity is already recorded, the deciding verdict is unchanged,
and it converts one opaque number into a composition a reader can act on. The
specific thing it buys: **a change that touches only drawing can move
`scrollback-stream` by at most ~4%**, because that is the entire draw tail. That
is worth knowing before someone reads a flat verdict on a real drawing
improvement as a failure.

## Task ledger

### Phase 1 -- establish what is already measured

- [x] Survey upstream terminal projects for interactive/throughput harnesses --
      recorded in `F1`.
- [x] Determine whether any existing artifact already contains a PTY throughput
      quantity -- recorded in `F2`.
- [x] Establish whether the app or the producer is the bottleneck, without which
      no rate is quotable -- recorded in `F3`.
- [x] Characterize the drain quantity's noise and its ability to separate arms --
      recorded in `F4`.

### Phase 2 -- decide what to report

- [x] `D1` direction gate: descriptive split, calibrated auxiliary metric, or
      nothing. **Selected the descriptive split, user, 2026-07-30.**
- [x] Implement the split and verify it against a hand-computation from a real
      block series -- recorded in `F5`.
- [x] Run the live harness once and confirm the producer's byte count reaches a
      real artifact -- recorded in `F7`.
- [x] Run `H2`'s distinguishing experiment and record the honest size of the
      producer offset -- recorded in `F6`; it is 0.0 ms, and
      `agent-docs/terminal-performance.md` is corrected.

### Phase 3 -- interactive stimulus, only after Phase 2

- [x] Decompose the keypress loop and price the mechanisms a workload would need,
      so `D2` is argued rather than guessed -- recorded in `F8`.
- [x] `D2` direction gate: is a keypress-driven workload worth building, and
      which subject (`less`, vim, btop)? Sequenced after Phase 2 deliberately --
      Phase 2 is cheap and certain, Phase 3 is neither.
      **Selected the recording; the keypress workload is rejected, user,
      2026-07-30.**
- [x] Capture a real TUI session and characterize what it actually emits, against
      the same census run over the four committed fixtures -- recorded in `F9`.
- [x] `D3` admission gate, **pre-registered here before the capture runs**: a
      recording earns a sixth workload only if its emitted-sequence distribution
      reaches a path the existing corpus does not. That is not this file's
      invention -- `TerminalDrawBenchmarkSupport` already states the rule for its
      own benchmark ("any new workload should be added for the same reason -- a
      path the existing ones cannot reach -- not to add another flavor of
      content"), and the corpus manifest makes every workload declare a
      `dominantQuestion` for the same purpose. **Deciding rule: if the census
      finds no control sequence class the four fixtures leave unexercised, the
      recording is another flavor of styled TUI content and is rejected**, with
      the census kept as the finding. Pre-registered so the capture cannot be
      read backwards into a justification, the way `21/D1` pre-registers its own
      gate. **Passed: 13 novel classes, `F9`.**
- [ ] `D3` shape gate: diagnostic-only versus decidable, decided *before*
      building -- a decidable sixth workload needs an A/A screen and a frozen
      threshold in both modes, which is the same process `17/F15` ran and
      refused. **Recommendation made: admit, characterize the composition, then
      calibrate. Awaiting the user.**
- [ ] Land the fixture and a runner, with provenance recording the geometry, the
      btop version, the `--update 250` deviation, and the fact that a capture of
      live system state is not regenerable.
- [x] ~~Resolve the license question before the fixture is committed.~~
      Dismissed by the user, 2026-07-30; see `D3`.

## Findings log

### F1 -- no terminal project drives synthetic input in-process; two payload suites are borrowable

- Status: complete.
- Date: 2026-07-30.
- Sources: local `.ghostty-src/` and `references/alacritty/` checkouts; upstream
  docs for vtebench and kitty.
- Observation:
  - **Ghostty** (`.ghostty-src/src/benchmark/`) ships seven headless in-process
    micro-benchmarks -- `terminal-stream`, `terminal-parser`, `codepoint-width`,
    `grapheme-break`, `screen-clone`, `is-symbol`, `osc-parser` -- each fed from a
    `--data` file. Its only app-level entry point is
    `macos/Tests/BenchmarkTests.swift`, a suite disabled behind
    `.enabled(if: false)` with a hardcoded absolute path in a maintainer's home
    directory, documented as "run by right-clicking in Xcode and using Profile".
  - **vtebench** (alacritty) is 12 payload generators: `cursor_motion`,
    `dense_cells`, `light_cells`, `medium_cells`, `scrolling`,
    `scrolling_fullscreen`, `scrolling_{top,bottom}_region`,
    `scrolling_{top,bottom}_small_region`, `sync_medium_cells`, `unicode`.
    Benchmarks are executables whose stdout is the payload. Its README limits its
    own scope to "the speed at which a terminal reads from the PTY" and states it
    "lacks support for critical factors like frame rate or latency".
  - **kitty** ships `kitten __benchmark__`, which dumps ASCII/unicode/CSI/image
    data into the tty and *suppresses rendering by default* to isolate the parser
    (`--render` opts back in). Its energy workload is "scrolling a file
    continuously in `less`" with CPU read off htop by hand; its latency numbers
    come from dedicated hardware or Typometer, both external to the app.
- Inference: latency in this ecosystem is measured *from outside* (screen
  capture, LED rigs, high-speed camera) because no project owns both the input
  injection and the draw acknowledgment. DanTerm does own both -- the CLI injects
  through the real key encoder (`app/SwiftTerminalSessionView.swift:428`) and
  `TerminalBenchmarkObserver` timestamps accepted draws -- so the absence of
  prior art here reflects others' harness constraints, not a dead end.
- Also inferred: kitty's `less`-scroll workload is the one upstream precedent for
  a held-key stimulus, which makes `less` a better-supported first subject than
  btop. btop has no precedent anywhere.
- Uncertainty: the vtebench and kitty readings are from documentation, not from
  running either tool. The Ghostty readings are from the pinned local checkout
  and are direct.
- Next action: feeds `D2`. The vtebench payload list is a separate opportunity
  (deterministic byte generators that would drop into
  `benchmarks/fixtures/terminal-app.json`, which today holds only four workloads)
  and is logged in Open questions rather than owned by this file.

### F2 -- the throughput number is already recorded, unreported, and is 95.7% of the deciding metric

- Status: complete.
- Date: 2026-07-30. Worktree at `705244c`, clean but for unrelated files.
- Inputs: 368 `scrollback-stream` blocks across 55 comparison runs, all 179x66;
  corpus `scrollback-stream-v1-25000-lines` = 1,525,000 bytes.
- Reproduction: `scripts/terminal-benchmark-producer.py:200` brackets the write
  loop -- start-marker ack, every corpus chunk, then the completion marker --
  and `scripts/terminal-benchmark-validation.py:656` lands the result in every
  block as `producerWriteNanoseconds`. No metric table in
  `scripts/terminal-benchmark-compare.py` references it, so it is never paired,
  never reported, and never read.
- Measurements:

  | Quantity | Median | Range |
  | --- | ---: | ---: |
  | `producerWriteNanoseconds` / `finalDrawNanoseconds` | **95.7%** | 89.9 - 97.9% |
  | draw tail (`finalDraw - producerWrite`) | 9.5 ms | 4.8 - 21.3 ms |
  | derived drain rate over 1.525 MB | 6.7 MB/s | 4.0 - 10.8 MB/s |

- Observation: the producer blocks on `write()` once the PTY buffer fills, so
  with a fixed corpus this bracket is the rate at which the app drained the PTY.
- Inference: **`scrollback-stream` has been a PTY throughput benchmark all
  along** -- ~96% drain, with a ~9.5 ms draw tail on the end. Two consequences.
  `H1` is refuted. And a change touching only the draw path can move
  `scrollback-stream`'s verdict by at most ~4%, which reframes how a flat result
  on that workload should be read.
- Competing interpretation, excluded by `F3`: the bracket could be measuring the
  producer rather than the app.
- Uncertainty: the 4.0-10.8 MB/s range is **cross-revision**, not noise -- these
  blocks span many arm trees. Within-arm noise is `F4`'s subject and is far
  tighter. Do not quote the range as an error bar.
- Next action: feeds `D1`.

### F3 -- the app is the bottleneck; the producer contributes an offset of at most 30 ms

- Status: complete.
- Date: 2026-07-30.
- Reproduction: drive the identical chunk sequence (25,000 writes, median chunk
  61 bytes, 1,525,000 bytes total) from `terminal_benchmark_fixtures.iter_bytes`
  into a `pty.openpty()` pair whose master is drained by a tight reader thread,
  timed with `time.monotonic_ns`. One-off script, not committed; ~20 lines.
- Measurement: **30.2 ms, i.e. 50.6 MB/s**, against real blocks of 145-372 ms.
- Observation: the producer can push the corpus 5-12x faster than any measured
  block completes.
- Inference: the app is unambiguously the bottleneck, so `producerWriteNanoseconds`
  is a measurement of DanTerm and not of Python. But 30 ms against a 145 ms fast
  block is ~20%, so the offset is not negligible and must be stated wherever a
  rate is quoted. It is additive and identical in both arms, so it compresses
  differences and cannot manufacture a false direction.
- Uncertainty: 30.2 ms is an *upper* bound on the contribution -- see `H2` for
  the sub-additivity question and the experiment that would settle it.
- Next action: `H2`'s experiment, scheduled in Phase 2 alongside the first
  reported figure rather than before it.

### F4 -- the drain bracket is quieter than the deciding metric and separates arms reproducibly

- Status: complete.
- Date: 2026-07-30.
- Inputs: same 368 blocks; 74 arm-series with at least 3 blocks each.
- Measurements:

  | Metric | Within-arm block CV, median | p90 | max |
  | --- | ---: | ---: | ---: |
  | `producerWriteNanoseconds` | **0.87%** | 1.81% | 5.69% |
  | `finalDrawNanoseconds` | 1.24% | 2.53% | 5.83% |

  Arm separation, medians in ms (write / draw), same pair measured twice:
  run `3cff7b261691-0000` a=186.4/196.8 b=225.7/235.4; its repeat `-0001`
  a=184.7/196.3 b=227.2/236.1 -- a 21% gap reproduced. Where arms are genuinely
  equal they land within ~1-4 ms: four runs of `46df33e24dcd` put arm A at
  148.3 / 148.0 / 146.7 / 148.9 ms (~0.7% spread).
- Inference: the drain bracket is a well-behaved quantity -- quieter than the
  metric that already carries a frozen rule, and far quieter than
  `processCPUNanosecondsPerDraw`, whose 1.88-8.75% paired A/A SD is what got it
  refused a rule in `17/F15`. The draw tail carries most of the jitter and 4% of
  the signal.
- Competing interpretation: CV within an arm is not the same statistic as paired
  symmetric A/A spread, which is what `17/F15`'s gates are defined on. These
  numbers suggest a screen would pass but do not substitute for one.
- Uncertainty: not screened. No rule may be frozen on this metric without the
  A/A pass, per the inherited rules.
- Next action: feeds `H3`, which is parked, and bounds how much `D1` can claim.

### F5 -- the split is implemented and its arithmetic reproduces by hand

- Status: complete.
- Date: 2026-07-30. Implements `D1`.
- Changes: `scripts/terminal-benchmark-producer.py` counts the bytes written
  inside the timed bracket and records `bytesWritten`;
  `scripts/terminal-benchmark-validation.py` carries it and the geometry into
  every block as `producerWriteBytes` / `producerWriteGeometry`;
  `scripts/terminal-benchmark-compare.py` gains `COMPOSITION_WORKLOADS` and
  `summarize_composition`, reported by `render_decisions` and stored in
  `run.json`.
- Reproduction of the verification: replay an archived `scrollback-stream`
  series through `summarize_composition` with the pinned corpus size stamped in,
  and recompute all four quantities directly from the blocks.
- Result, against `confirm/00ed7561f48d-0000` (8 blocks, 4 per arm):

  | Arm | drain | rate | tail | tail share |
  | --- | ---: | ---: | ---: | ---: |
  | baseline | 146.406 ms | 10.416 MB/s | 8.980 ms | 5.772% |
  | candidate | 145.904 ms | 10.453 MB/s | 10.762 ms | 6.853% |

  All eight values match the hand computation exactly. Rendered form:

  ```
  scrollback-stream: equivalent (+0.10% symmetric median of 2 pairs)
      drain (baseline): 146.4 ms, 10.4 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
      draw tail (baseline): 9.0 ms (5.8% of block)
      drain (candidate): 145.9 ms, 10.5 MB/s (1.52 MB corpus at 179x66; descriptive, no verdict)
      draw tail (candidate): 10.8 ms (6.9% of block)
  ```

- Observation: this real series reads 5.8% / 6.9% draw tail, against `F2`'s
  4.3% median (95.7% drain) over 368 blocks -- consistent, and a reminder that
  the tail share varies by a couple of points between runs.
- Behavioral coverage: six tests pin the split (reported values, additivity
  against the frozen verdict, absence when an arm lacks the byte count, refusal
  when two arms disagree on the byte count, the rendered denominator and
  no-verdict labelling, and the table's confinement to `scrollback-stream`), plus
  one producer test pinning the count to the timed bracket. `just test` green.
- Uncertainty: the byte count itself is only exercised end to end by a real
  benchmark invocation, which has not been run -- the verification above stamps
  the corpus size into archived blocks that predate the counter. The first live
  `benchmark-quick` on `scrollback-stream` is what proves the producer's number
  reaches `run.json`.
- Next action: `H2`'s producer-offset experiment, then Phase 3.

### F6 -- the producer's overhead is fully absorbed: 0.0 ms reaches the block

- Status: complete. Settles `H2`.
- Date: 2026-07-30.
- Reproduction: model the app as a reader throttled to 10.4 MB/s (the rate `F2`
  measured on real blocks) and write the same 1,525,000 bytes through a real
  `pty` twice -- once as the corpus's 25,000 small chunks, once rechunked into
  373 x 4 KB writes, 5 repeats each, timing only the write loop. The large-chunk
  arm has almost no producer overhead, so the gap between the arms is the
  overhead that actually reaches the block. Script kept in the session
  scratchpad; ~90 lines, not committed.
- Measurements:

  | Consumer | 25,000 small writes | 373 large writes | gap |
  | --- | ---: | ---: | ---: |
  | unthrottled (`F3`'s control) | 29.9 ms | 9.5 ms | 20.4 ms |
  | throttled to the app's rate | 148.9 ms | 148.9 ms | **0.0 ms** |

  The throttled arms are astonishingly tight -- min and max both 148.9 ms across
  5 repeats -- against a modelled drain floor of 146.6 ms.
- Observation: producer overhead that is plainly visible against a reader which
  never blocks (20.4 ms of spread between chunkings) vanishes completely once the
  consumer is paced at the app's real rate.
- Inference: the writer spends essentially all its time parked on a full PTY
  buffer, and syscall overhead paid during a wait the writer would have taken
  anyway costs the block nothing. **`F3`'s 30.2 ms is an upper bound that is not
  approached**, so the reported MB/s is the app's drain rate and needs no mental
  correction. `H2`'s additive framing is rejected.
- Competing interpretations: a synthetic throttled reader is not the app. It
  shares the PTY and its buffer dynamics but not the app's read cadence, which is
  chunked and actor-hopped rather than smoothly paced. A bursty consumer could in
  principle leave windows where the producer is not blocked and its overhead does
  land -- but it would have to leave ~30 ms of such windows to restore `H2`, and
  the throttled result is 0.0 ms with no measurable spread.
- Uncertainty: the model, as above. Not worth a further experiment unless a rate
  is ever used for something stronger than an internal marker.
- Next action: correct the caveat in `agent-docs/terminal-performance.md`, which
  was written from `F3` alone and told readers not to quote the MB/s as the app's
  rate. Done.

### F7 -- the byte count reaches a real artifact, end to end

- Status: complete. Closes `F5`'s stated uncertainty.
- Date: 2026-07-30. Worktree carrying the `F5` changes.
- Reproduction: `./scripts/terminal-benchmark.sh scrollback-stream swift`, one
  measured block. Artifact:
  `.build/terminal-benchmark-runs/2026-07-30-100239-69332/artifacts/producer-write.json`.
- Result: `{"bytesWritten": 1525076, "elapsedNanoseconds": 147521542,
  "geometry": {"columns": 179, "rows": 66}, ...}`, and the same field present
  under `producerWrite` in the harness's emitted block artifact -- which is
  exactly where `terminal-benchmark-validation.py` reads it.
- Derived: drain 147.5 ms, **10.34 MB/s**, tail 14.5 ms, drain share 91.1%.
- Observation: `bytesWritten` is 1,525,076 -- the 1,525,000-byte corpus plus the
  76-byte completion marker, which is precisely the bracket's contents. The count
  is the bracket's, not the corpus's, as intended.
- Uncertainty, and it matters for the derived numbers only: **this block is not a
  valid measurement.** The machine was not idle (an agent session was working
  alongside it), so its 91.1% drain share sits at the low end of `F2`'s
  89.9-97.9% range and its 8.9% tail is correspondingly high. The finding is the
  field's presence and arithmetic, not the timing.
- Next action: none. The reporting leg of `D1` is complete.

### F8 -- the keypress loop decomposes into one thin new segment and two other files' subjects

- Status: complete, **from source; nothing measured.** Read as a structural
  decomposition and a build-cost estimate, not as timing. It answers `H4` far
  enough to argue `D2`, and does not close `H4`.
- Date: 2026-07-30. Read at `f076684`.
- Method: follow a keystroke from the AppKit event to a published frame, then
  check what the paired harness would need in order to bracket it.
- Result 1 -- **no synthetic-input mechanism exists anywhere in this repo.** The
  only `CGEvent` reference is `scripts/terminal-viability.sh:55`, which *reads*
  modifier-flag state and posts nothing. A keypress workload builds its driver
  from zero.
- Result 2 -- **both injection seams are bad, in opposite ways.** Above
  `SwiftTerminalSessionView.keyDown` (`app/SwiftTerminalSessionView.swift:332`)
  means posting `CGEvent`s, which needs an Accessibility grant no other part of
  the harness requires and which no CI or fresh machine has. Below it -- an
  env-gated hook calling `sendKey`/`sendText` directly -- skips
  `interpretKeyEvents`, the marked-text/IME branch, and the keypad and
  committed-text paths, which is *precisely* the segment a keypress workload
  would exist to measure. The cheap seam measures everything except the new part.
- Result 3 -- **the block-boundary contract does not transfer.** Every block
  boundary in this harness comes from in-band markers the *producer* writes,
  found in frame text by `TerminalBenchmarkMarkers` and consumed by the observer
  in `app/TerminalBenchmark.swift`. `less`, vim, and btop emit no such markers,
  so start/end detection has to be reinvented against a subject whose output we
  do not control. That mechanism is what makes the paired rule work at all.
- Result 4 -- **the subject is not a deterministic byte generator**, which is the
  contract every existing workload meets. A child process's version, terminfo
  entry, and internal timers are all inputs we neither pin nor see.
- Result 5, and this is the finding -- **the loop is mostly other files'
  subjects.** It splits into (i) AppKit `keyDown` -> `interpretKeyEvents` ->
  `controller.sendText`/`sendKey`; (ii) `TerminalPTYHost.sendKey`
  (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift:219`), which is
  a `queue.async` onto **the same serial queue doc 19 owns**; and (iii)
  everything downstream -- the child's output drained and drawn, which is what
  all five existing workloads already measure, plus queue occupancy, which
  `19/F5`-`19/F9` already measure. The segment genuinely unique to a keypress
  workload is (i) plus one enqueue, at key-repeat rate of roughly 15-30 events a
  second.
- Result 6 -- **the cheap half of the original question is already reachable.**
  `iter_bytes` already replays a `recording` workload
  (`scripts/terminal_benchmark_fixtures.py:30`), and `PTYRecordingRecorder` plus
  `NeutralTerminalRecording`'s provenance schema already exist. "Benchmark a real
  TUI's output shape" costs a recording and a fixture entry; it needs no driver,
  no permission, and no new boundary mechanism, and it stays deterministic.
- Bearing on `H4`: the hypothesis said a keypress stimulus "measures something no
  current workload does." True, but the something is thin -- an AppKit segment
  and an enqueue -- while the parts with known cost are owned elsewhere. And the
  one interactive complaint that actually exists in this corpus, `19/F9`'s
  held-Enter chop, was found and diagnosed on doc 19's occupancy axis with a
  shell script and a live session, without any of the machinery above.
- Uncertainty: segment (i) is unmeasured, so "thin" is a structural claim about
  what the code does per event, not a timing bound. If AppKit's key handling ever
  looks implicated, it is measurable directly with a `sample` under a held key --
  which is cheaper than everything in Results 1-4 combined.
- Next action: `D2`.

### F9 -- 100% of a real TUI's output arrives inside a frame-coalescing bracket the corpus never emits

- Status: complete. Clears `D3`'s pre-registered admission gate, and by a wider
  margin than the gate asked for.
- Date: 2026-07-30, at `434b90b`.
- Method: capture btop for 20s under a PTY at the canonical 179x66 with
  `TERM=xterm-256color`, writing nothing to the child, then census the
  control-sequence vocabulary of the capture and of all four committed fixtures
  with one parser. Scratch tooling, not committed: `capture-tui.py`,
  `escape-census.py`. Capture is 3,102,335 bytes in 3,091 PTY reads.
- Result -- **13 sequence classes appear in the capture and in none of the four
  fixtures.** The committed corpus's entire vocabulary is `LF`, `CSI H`,
  `CSI K`, `CSI J`, `CSI @`, `CSI P`, `CSI r`, and three SGR classes. btop adds:
  private modes `?2026h`/`?2026l` (99 each), `?1049h`, `?25l`, `?1002h`,
  `?1015h`, `?1006h`; relative cursor motion `CSI A`/`B`/`C`/`D` (42,093
  combined); `CSI f`; and `CSI SGR basic`.
- **The headline is synchronized output.** `100.0%` of the captured bytes --
  3,101,505 of 3,102,335 -- arrive *inside* a `DECSET 2026` bracket, in 99 spans
  of median 39,819 bytes. Not one byte of the committed corpus does.
- Why that is load-bearing rather than trivia:
  `TerminalPaneSession.planIfNeeded` (`lib/TerminalPTY/.../TerminalPaneSession.swift:635`)
  returns early on `presentation.isSynchronizedOutputActive`, so while the flag
  is set **the app parses the bytes and plans and draws nothing.** That is
  whole-frame suppression sitting directly in front of the two most expensive
  brackets the harness measures, and no committed workload enters it. The source
  says as much unprompted, in the comment above `pendingFenceStallNanoseconds`:
  "synchronized output is what modern full-screen TUIs use, so latching would
  understate exactly the floods worth measuring."
- Second-largest difference, and independent of the first -- **the corpus
  addresses the cursor absolutely and btop moves it relatively.** 27,571
  `CSI C` forward-skips are how btop steps over unchanged cells; the corpus has
  zero relative motion and 400k absolute `CSI H`. Different damage shape into
  the same planner.
- Third -- **byte composition inverts.** The capture is 20.3% printable ASCII
  (629,812 of 3,102,335) and 455,100 non-ASCII bytes of box-drawing and braille,
  against 80-98% printable across the four fixtures. It carries 84,989 truecolor
  SGRs against `styled-screen-redraw`'s 28,000, on 60% of the bytes. A real TUI
  is a control- and style-dominated stream, not a text-dominated one; every
  workload we authored is the opposite.
- Also unexercised: **the alternate screen.** `?1049h` is the capture's first
  meaningful sequence, `isAlternateScreenActive` is real state in
  `Terminal.swift`, and no benchmark workload has ever entered it.
- Uncertainty: the census recognizes sequence *shapes* and does not interpret
  them, so a rare class could be miscounted. That moves a number and not the
  gate, which reads only which classes appear. Separately, `--update 250` is not
  btop's default 2s cadence -- a deliberate deviation to get 99 frames into a
  20s capture rather than 10, and one that must be recorded in the fixture's
  provenance if this is committed. It changes frame *rate*, not frame *content*.
- Next action: `D3`.

### F10 -- the new workload's draw tail is a constant, so it is not the draw lever it briefly looked like

- Status: complete. This is the finding `D3`'s ordering existed to catch, and it
  **refutes the most attractive reading of the first measurement.**
- Date: 2026-07-30, at `6849c24`. Ten single blocks, machine **not idle** (an
  agent session was working alongside), so treat spreads as upper bounds.
- Method: build the fixture at two stimulus lengths and run five blocks of each,
  reading `producerWriteNanoseconds` against `finalDrawNanoseconds` exactly as
  `F2` does for `scrollback-stream`.
- Result at 40 frames (1.25 MB): median block **73.7 ms**, drain share 88.9%,
  **draw tail 11.1%** -- 2.6x `scrollback-stream`'s 4.3%. Read alone, that says
  the corpus just gained a far more draw-sensitive workload.
- Result at 95 frames (3.02 MB): median block **164.2 ms**, **draw tail 4.4%** --
  indistinguishable from `scrollback-stream`.
- **The reconciliation, and the actual finding: the tail is constant in absolute
  terms.** 8.2 ms median at 40 frames, 7.2 ms at 95, against stimulus lengths
  differing 2.4x. The tail share moved because the *denominator* grew; the
  numerator never did. So the apparent draw sensitivity at 40 frames was an
  artifact of a short block, and shrinking the stimulus further would have
  inflated the share without adding one nanosecond of measured draw work.
- Why the tail is constant, and it follows from `F9`: drawing is suppressed for
  the whole replay, so the tail brackets **one final draw**, not the sum of 95.
  Whatever intermediate draws occur land inside `producerWriteNanoseconds` while
  the producer is still writing -- which is `F2`'s composition again, reached by
  a different route.
- **Consequence for `D3`: this workload is not a draw instrument.** Its block is
  ~95% drain at any honest length, so what it decides is the speed of parsing and
  damage-tracking a real TUI's output under frame coalescing. That is a genuinely
  unexercised path (`F9`) and worth having. It is not a better handle on drawing
  than what already exists, and the corpus manifest's `dominantQuestion` should
  not imply that it is.
- Noise, and it is the open problem: block CV **3.87%** at 40 frames and
  **2.35%** at 95, against `scrollback-stream`'s 1.24% within-arm figure from
  `F4`. Longer blocks help, which is why the committed fixture is the 95-frame
  build; but 2.35% on a busy machine still forecasts a looser threshold than any
  existing workload carries. Whether it is looser than useful is what the A/A
  screen decides, and this is the number that makes running one worthwhile rather
  than a formality.
- Uncertainty: five blocks per length on a non-idle machine is a characterization,
  not a screen. The constancy of the tail is robust to that -- it is a 2.4x lever
  moving a quantity by 12% in the *wrong* direction for the alternative
  explanation -- but every CV here is an upper bound.
- Next action: `D3`'s remaining leg -- the A/A screen, now with a specific
  question to answer rather than a box to tick.

## Decision log

### D1 -- what the benchmark system should report about PTY throughput

- Status: **recommendation made, awaiting user direction gate.**
- Evidence used: `F2`, `F3`, `F4`.
- Candidate solutions:
  1. **Descriptive split** (recommended). Report drain ms, derived MB/s, and the
     draw tail on `scrollback-stream` beside the existing verdict. No rule, no
     calibration, no change to any decision.
  2. **Calibrated auxiliary metric.** Add drain to `AUXILIARY_BLOCK_METRICS`,
     run the A/A screen via `--metric pty-drain`, freeze a rule if it clears the
     gates.
  3. **Nothing.** The quantity stays in the artifact for anyone who looks.
- Tradeoffs and correctness risks:
  - (1) costs almost nothing and cannot corrupt a verdict, because it decides
    nothing. Its risk is that a reader mistakes a descriptive percentage for a
    decision -- the exact failure `17/D6` documents for process CPU, and it is
    mitigated the same way, by labelling.
  - (2) buys a second verdict on a quantity 95.7% identical to the first, which
    is double-counting evidence rather than adding any. `17/F15`'s constraint
    also applies: it would ride `scrollback-stream`'s blocks and could not buy
    more pairs.
  - (3) leaves the composition fact from `F2` undiscoverable, which is how it
    stayed invisible for the life of the harness.
- Recommendation: **(1)**. The user's stated requirement is an internal marker
  that moves when our code moves; `finalDrawNanoseconds` already decides the
  direction and the split explains where it came from.
- Direction review: user, 2026-07-30. Selected (1) as recommended.
- Selected direction: **descriptive split**. Report drain ms, derived MB/s, and
  the draw tail beside the `scrollback-stream` verdict. No rule, no calibration,
  no change to any decision. Approved output shape:

  ```
  scrollback-stream: faster (-3.20% symmetric median of 2 pairs)
      drain: 145.8 ms, 10.5 MB/s (1.525 MB corpus, 179x66)
      draw tail: 9.5 ms (6.1% of block)
  ```

- Behavioral verification: **done, `F5`.** Six tests in
  `scripts/tests/terminal_benchmark_compare_test.py` plus one in the producer
  suite; all four arithmetic quantities reproduced by hand against a real
  archived block series; `just test` green.
- Quantitative verification: not applicable. This option decides nothing, so
  there is no threshold to verify and no A/A pass to run.
- One deviation from the approved shape, taken deliberately: the split reports
  **both arms** rather than one figure. The approved preview showed a single
  drain line, which does not say which tree it describes -- and the drain rate is
  precisely the marker meant to be watched moving between revisions, so reporting
  one arm would hide the movement it exists to show. Collapsing to the candidate
  arm alone is a one-line change if the two-line form reads as noise.

### D2 -- whether to build a keypress-driven interactive workload

- Status: **recommendation made, awaiting user direction gate.**
- Evidence used: `F1`, `F8`. `H4` remains unmeasured but is largely answered
  structurally by `F8`.
- The question splits, and separating the halves is most of the decision. The
  trigger asked for "btop under a held down-arrow," which conflates **(a) measure
  a real TUI's output shape** with **(b) measure the keypress-to-draw loop**.
  They have wildly different prices.
- Candidate solutions:
  1. **Take (a) only, via a recording** (recommended). Record a real TUI session
     with `PTYRecordingRecorder`, freeze it as a neutral fixture, add it as a
     sixth workload. `F8`'s Result 6: the replay path already exists, it is
     deterministic, and it needs no input driver, no Accessibility grant, and no
     new block-boundary mechanism. btop is a *fine* subject here, because a
     recording is bytes and its self-timed redraws are baked into the capture.
  2. **Take (b) as a diagnostic-only probe.** A scratch driver under a held key,
     read with `sample`, reported as a description and never as a verdict --
     `21/D2`'s precedent for a path no calibrated workload contains.
  3. **Take (b) as a calibrated workload.** Input driver, new boundary
     detection, a real child process, then an A/A screen to earn a rule.
  4. **Nothing.** Close the file on the interactive question.
- Tradeoffs and correctness risks:
  - (3) is the expensive one and buys the least. It needs all four mechanisms in
    `F8`'s Results 1-4, and by Result 5 the thing it uniquely adds is an AppKit
    segment plus one `queue.async`; everything with known cost in that loop is
    already measured by the five existing workloads or by doc 19. It also seats
    a **nondeterministic child process** inside a contract whose every other
    member is a frozen byte generator -- and a workload that drifts with a vim
    version silently poisons the paired rule rather than failing loudly.
  - (2) is honest and cheap, but `19/F9` has *already done* the interactive
    diagnosis that motivated this, on the axis that turned out to matter
    (occupancy, not key encoding). Doing it again here would likely rediscover
    doc 19's result through a worse instrument.
  - (1) answers the half of the trigger that was always tractable. Its real risk
    is `17/F17`'s: a captured stimulus can be unrepresentative, and a
    full-screen self-redrawing TUI is exactly the shape that produced doc 17's
    retired headline. Mitigation is to capture a session that resembles use --
    and to treat any resulting number as a property of that capture, which the
    fixture provenance already records.
  - (4) is defensible but discards Result 6, where the mechanism is already
    built and unused.
- Recommendation: **(1), and explicitly reject (3).** The keypress loop is not
  where the unexplained cost lives, and `F8` says so from source; the real TUI
  *corpus* gap is real, unclaimed, and cheap. Hold (2) in reserve behind a
  specific trigger: a `sample` under a held key that implicates AppKit key
  handling, which is itself cheaper than building any of this.
- Direction review: user, 2026-07-30. Selected (1) as recommended.
- Selected direction: **the recording workload; (3) is rejected.** Capture a real
  TUI session, freeze it as a neutral fixture, add it as a sixth workload. No
  input driver is built. (2) stays in reserve behind `D2`'s stated trigger.
- Note preserved from before this was argued: if (2) or (3) is ever taken, the
  subject choice is load-bearing. btop redraws on its own timer regardless of
  input, so a keypress cannot be attributed to a draw; `less` and vim redraw only
  on input, which makes attribution clean and matches kitty's precedent (`F1`).
  Under (1) the concern evaporates -- a recording is bytes, and btop's timer is
  captured rather than raced.

### D3 -- admit the recording, and in what shape

- Status: **admitted on the pre-registered gate; shape recommendation made,
  awaiting user direction gate.**
- Evidence used: `F9`, and `F2`'s lesson about measuring a metric's composition
  before trusting it.
- Admission: **passes.** The gate asked for one sequence class the corpus leaves
  unexercised; `F9` found thirteen, and the largest is a whole-frame draw
  suppression path in front of the harness's two most expensive brackets. This is
  not another flavor of styled content.
- What the workload would actually measure, and it is not what the trigger
  imagined. 3,091 PTY deliveries arrive in 99 synchronized spans with
  effectively no bytes between them, so a conforming terminal plans and draws
  **99 times for 3.1 MB** where `scrollback-stream` plans repeatedly through
  1.5 MB. The deciding quantity is therefore **plan/draw amortization under a
  real TUI's frame discipline** -- roughly 31 deliveries coalesced per drawn
  frame. No existing workload has a coalescing ratio above 1.
- Candidate shapes:
  1. **Admit, characterize, then calibrate** (recommended). Land the fixture and
     a runner, report its drain/draw composition the way `D1` already does for
     `scrollback-stream`, and **only then** run the A/A screen and freeze a
     threshold in both modes. Decidable if and only if the composition says the
     draw bracket is worth deciding on.
  2. **Admit as decidable immediately.** Fixture, runner, A/A screen, frozen
     thresholds, in one pass.
  3. **Admit as diagnostic-only, permanently.** A sixth workload that reports and
     never decides.
- Tradeoffs and correctness risks:
  - (2) risks repeating this file's own opening mistake. `F2` is the finding that
    `scrollback-stream`'s deciding metric was 95.7% drain and nobody had checked;
    calibrating a threshold before knowing the composition is exactly how that
    happened. If a btop replay turns out to be 96% parse with 99 cheap draws,
    a frozen draw threshold on it would be a second instance of the same error --
    and a threshold, once frozen, is what later documents rest on.
  - (3) is the safe option and probably too safe. `17/F15` refused a rule to
    `processCPUNanosecondsPerDraw` because an auxiliary metric rides the deciding
    metric's blocks and **cannot buy more pairs**. A workload does not have that
    constraint: it owns its blocks and can be run at whatever pair count the
    screen demands. The reason calibration failed there does not apply here, so
    declining to try is declining for no stated reason.
  - (1) is (2) with the composition check `F2` says to do first, and it can still
    land as (2) -- the only cost is that the screen runs after a characterization
    rather than beside it.
- Recommendation: **(1)**. Ordering only; it forecloses nothing.
- **The A/A screen is cheap, which collapses most of this decision.** Written up
  first as though authorizing the screen were a real resource commitment; the
  archive says otherwise. 2,218 run directories under `.build/`, 2,095 of them
  consecutive within 3 minutes, **median gap 7s and p90 26s**. A 24-pair screen
  is 48 blocks, so **roughly 6 to 20 minutes of idle machine** -- not the
  standing cost that would justify choosing (3) to avoid it. Recorded because the
  wrong version of this estimate was briefly used to frame a user question.
- Risks to carry into implementation regardless of shape:
  - **`17/F17` is the cautionary case.** A capture is a stimulus like any other,
    and btop full-screen at 179x66 is close in shape to the stimulus whose
    headline `17/F17` retired. The fixture provenance must record the geometry,
    the subject version, and the `--update 250` deviation, and no number read off
    this workload generalizes past that capture.
  - **A recording is a frozen artifact of one machine's system state.** btop
    renders this box's cores, processes, and network. That is fine for a
    deterministic replay -- it is bytes -- but the fixture is not reproducible by
    re-running the capture, and the manifest should say so rather than imply a
    regenerable input.
  - ~~**Licensing needs a look before commit.**~~ Raised and **dismissed by the
    user, 2026-07-30**, as not worth pursuing. Recorded rather than deleted so a
    later reader knows it was considered and set aside deliberately, not missed.
    The mechanical part still stands: `NeutralTerminalProvenance.validate`
    accepts only `libvterm`, `alacritty`, and `danterm` sources, so the fixture
    declares `danterm` and describes the subject in its provenance text.

## Rejected

### Comparability with published vtebench / kitty / ghostty figures

Considered because those figures are the ones the outside world quotes.
Rejected by the user on 2026-07-30: this is an internal marker for seeing how our
own changes move our own number. Different corpus, different bracket, different
machine -- comparability is unreachable without distorting the workload contract
to match someone else's, and it buys nothing we want. Do not reopen this to make
a number look better next to a blog post.

## Open questions and caveats

- **The vtebench payload list is an unclaimed opportunity.**
  `benchmarks/fixtures/terminal-app.json` holds four workloads; vtebench's 12
  generators (`F1`) cover scroll regions, cursor-motion-heavy output, and
  synchronized output (DECSET 2026) that we have no corpus for at all. They are
  deterministic byte generators, which is the shape our pipeline already eats.
  Needs a license check and the neutral-fixture provenance treatment used by
  `scripts/import-alacritty-recordings.py`. Not owned by this file.
- **Only `scrollback-stream` has a meaningful drain bracket.** The three draw
  workloads are serialized -- write, then wait for that exact draw -- so their
  write timing measures the handshake, not throughput. Do not extend the split
  to them.
- **`F2`'s composition is a property of this corpus at this geometry.** 25,000
  short ASCII lines at 179x66 is a drain-dominated stimulus by construction. A
  heavier-per-byte corpus would shift the ratio, and no reading here generalizes
  to a workload that does not exist yet.
- **The recording path exists if a deterministic btop workload is ever wanted.**
  `lib/TerminalPTY/Tests/TerminalPTYHostTests/PTYRecordingRecorder.swift` plus
  `NeutralTerminalRecording`'s provenance schema already distinguish DanTerm
  captures from imported fixtures, and `iter_bytes` already replays a
  `recording` workload. Recording a real session and freezing it is a shorter
  path than it looks.

## Outcome

Investigation in progress. **Phases 1 and 2 are complete and shipped in
`995c8e8`; Phase 3 has not started.**

What is settled. `scrollback-stream` was already a PTY throughput benchmark and
nobody knew (`F2`), which refuted this file's own opening hypothesis (`H1`) and
retired the reason it was opened. The reporting `D1` selected is implemented,
hand-verified, and proved end to end (`F5`, `F7`), and
`agent-docs/terminal-performance.md` documents it. `H2` is rejected: the
producer's overhead is fully absorbed, so the reported rate needs no correction
(`F6`).

What is open, and why this file is not closed:

- **`D2` and the whole of Phase 3.** The question that opened this file -- can we
  benchmark a real TUI under a held key -- has an upstream survey (`F1`) and an
  unmeasured hypothesis (`H4`) and nothing else. No direction gate has been put
  to the user, and the subject choice (`less`/vim over btop, on attribution
  grounds) is a substitution that needs raising rather than assuming.
- **`H3`, parked with a reopening condition**: drain is quieter than the metric
  that carries the frozen rule (`F4`), so it would be the better deciding metric
  for this workload -- but taking it means recalibrating thresholds that docs
  8-18 rest on, for a quantity 96% correlated with the one already there. Reopen
  only if `scrollback-stream` starts returning `inconclusive` often enough to
  obstruct work.
- **The vtebench payload import**, logged in Open questions and owned by no file.

Close this file when `D2` is decided either way. Deciding *not* to build the
interactive workload closes it just as legitimately as building one -- the
rejection reason is the valuable artifact, and it belongs in Rejected.
