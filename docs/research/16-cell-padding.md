# Cell padding

Research started: 2026-07-29. **Status: CLOSED 2026-07-29 -- implemented,
measured, and rejected.** The change reached stride 24 and bought 19-49% more
history, and it was reverted because it made the incremental draw workload
measurably slower. Read `F3` and `D1` before proposing it again.
Continues: [15-memory-footprint.md](15-memory-footprint.md) (`15/F16`).

## Purpose

Doc 15 closed with the cell at 32 bytes and one thing it had priced but not
attacked: **10 of those 32 bytes are padding** (`15/F16`), which made padding the
largest single line item in the cell -- larger than any real field, and worth
3.02 MB at a full 179-column history. `15/F16` recorded two candidate directions
and deliberately promoted neither, on the grounds that since `15/F10` it is the
malloc bucket rather than the stride that decides whether a cell shrink reaches
the user, and the steps on offer were smaller than any taken so far.

This file owns that residue and nothing else. It exists because `15/F16`'s
framing turned out to be too pessimistic in one specific way -- it evaluated
candidates that changed *where fields sit* and not the one that changes *what the
fields are* -- and it closes because the change that framing missed turned out to
be blocked by something neither file had considered: the cell's stride is also
its cache-line alignment.

## Investigation rules

- Inherited from doc 15 and non-negotiable here: **size wins in malloc buckets,
  not strides.** A stride change is a prediction; `Array.capacity` is the result.
  Measure both 179 and 80 columns -- `15/F12` was worth -26% at one and cost
  1.8 MB at the other.
- Any layout claim is measured with `MemoryLayout`, never derived by hand. Doc 15
  got this wrong twice by reasoning about it (`15/F15`).
- CPU is verified per `10/F9` with a paired benchmark before any claim of
  neutrality. This rule is the one that decided the file.

## Trigger and current evidence

`15/F16` measured the shipped cell's layout exactly:

| field | offset | bytes |
| --- | ---: | ---: |
| `scalars` | 0 | 9 |
| `kind` | 9 | 1 |
| *padding* | 10 | **2** |
| `styleId` | 12 | 4 |
| `hyperlinkId` | 16 | 3 |
| *padding* | 19 | **1** |
| `contentIdentity` | 20 | 5 |
| *tail padding* | 25 | **7** |

Size 25, stride 32. `15/F16` concluded that 25 is the floor "for the current
field types" and that the interior 3 bytes are unrecoverable by reordering. Both
statements are true. The gap they leave is that `hyperlinkId` and
`contentIdentity` are 3 and 5 bytes rather than 2 and 4 **only because they are
`Optional`**, and each tag byte does not merely cost its own byte -- it pushes the
following 4-byte field to the next aligned offset, so it costs the padding behind
it too.

## Current hypotheses

### H1 -- the `Optional` tags are the padding, and both ids can reserve zero instead

**Confirmed as a layout and memory result (`F1`, `F2`), then rejected on CPU
(`F3`, `D1`).** `UInt16?` is 3 bytes and `UInt32?` is 5; stored as bare integers
with zero reserved to mean absent they are 2 and 4, and the fields then pack with
no interior padding at all. Stride 24, against 32.

What made it cheap rather than merely possible is that **`contentIdentity`
already reserved zero before this file existed**: `allocateContentIdentity` wraps
to 1, never 0 (`15/F14` made it skip zero so a reissued identity could not
satisfy an armed Cmd-click). Its tag byte was buying nothing. `hyperlinkId`
needed one line.

## Task ledger

### Phase 1 -- measure and take it

- [x] Measure the candidate layouts against the shipped one, and measure what the
      row's allocation actually does at both widths. **Done -- `F1`.**
- [x] Implement, with the zero-reservation guarded by a behavioral test that
      fails against the unguarded version. **Done -- `F2`.**
- [x] Verify CPU on the paired harness. **Done -- `F3`. This is the step that
      closed the file: a reproduced regression on `incremental-mixed`.**

### Phase 2 -- close

- [x] Record where the residue now stands, and whether anything is left.
      **Done -- see Outcome.** Nothing is left that is worth taking: the last
      4 bytes need a change doc 12 already reverted, and the 6 bytes this file
      reached are blocked by `F3`.

## Findings log

### F1 -- the `Optional` tags cost six bytes, not two, and the row's bucket moves at both widths

- Status: recorded. Layout and allocation measurement that promoted `H1`.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: `6ff35f9`, clean tree.
- Method: a scratch `MemoryLayout` probe in the core test target, comparing the
  shipped cell against two candidates, plus `Array.capacity` on a real row array
  at both canonical widths. Deleted after measuring, per doc 15's practice.
- Measurements:

  | variant | size | stride | interior padding |
  | --- | ---: | ---: | ---: |
  | shipped | 25 | 32 | 3, plus 7 tail |
  | both ids as reserved-zero sentinels | 22 | 24 | 2, plus 2 tail |
  | ...plus `hyperlinkId` moved into the gap after `kind` | **20** | **24** | **0**, plus 4 tail |

- Resulting layout, with nothing interior wasted: `scalars` @0-8, `kind` @9,
  `hyperlinkId` @10-11, `styleId` @12-15, `contentIdentity` @16-19.
- Observation 1: **the two tag bytes were worth six bytes of cell, not two.**
  Removing them removes the 2-byte gap after `kind` and the 1-byte gap before
  `contentIdentity` as well, because each tag pushed the next 4-byte field past
  an aligned offset. This is the same lesson `15/F10` recorded about
  `hyperlinkId`'s `Int?` -- a field's cost is its alignment consequence, not its
  width -- reappearing one level down, and doc 15 did not notice it applied to
  `Optional` tags too.
- Observation 2: **the row's malloc bucket moves at both widths**, which is the
  test `15/F12` failed.

  | width | row bytes at stride 32 | at stride 24 | |
  | --- | ---: | ---: | ---: |
  | 179 | 6,112 | 5,088 | **-17%** |
  | 80 | 3,040 | 2,016 | **-34%** |

- Inference: `15/F16` was right that reordering cannot recover the interior
  padding and right that a 4-byte stride step is too small to trust. It was
  looking at the wrong lever. Changing the field *types* moves the stride by 8,
  and the allocator honors it at the canonical geometry.
- Uncertainty, and in hindsight this is where the file's answer was hiding: the
  probe measured what a row *costs*, and nothing here measured what a row is like
  to *read*. See `F3`.
- Next action: implement under `H1`.

### F2 -- stride 24 works, and buys history at both widths

- Status: recorded. Implementation result, superseded as a recommendation by
  `F3`. The measurements below stand; the conclusion "take it" does not.
- Date and investigator: 2026-07-29, Claude (agent).
- Commit and worktree state: working tree against baseline `6ff35f9`. **Reverted,
  not committed** -- see `D1`.
- Implementation: `GridCell` stores both ids as bare integers with zero reserved,
  in the order `F1` measured. `Optional`-typed computed accessors and an explicit
  memberwise `init` keep every call site reading and writing `nil`, so the
  compiler still separates "no link" from "link 0" and the sentinel is not a
  convention anyone has to remember. `allocateHyperlinkId` skips zero on wrap.
- Correctness detail worth keeping even though the change was reverted: the
  capacity guard has to move from `<=` to `<`. Reserving zero costs one id, so at
  `HyperlinkId.max` live targets every non-zero id is taken and the old bound
  would let the scan spin forever. Anyone reattempting this must carry that.
- Behavioral verification: `linkIdCursorSkipsReservedZero` primed the cursor to
  the end of its range and opened links across the wrap. **Verified failing
  against the unguarded implementation first** -- the second link after the wrap
  received id 0 and read back as `nil`, silently unlinked -- then passing with the
  skip. Full core suite 670 passing, 1 pre-existing known issue.
- Memory, `terminal-memory-probe`, one process per payload, production budget:

  | geometry | rows before | rows after | footprint before | footprint after |
  | --- | ---: | ---: | ---: | ---: |
  | 179x66 `scrollback-plain` | 1,768 | **2,107** (+19%) | 11.31 MB | 11.03 MB |
  | 80x66 `scrollback-plain` | 3,461 | **5,146** (+49%) | 12.05 MB | 12.52 MB |

- Observation: at a fixed byte budget it buys **history, not memory**, the same
  shape as `15/F10`. Per-row overhead splits by width in the now-familiar
  direction: 551 -> 167 B at 80 columns, but 456 -> 858 B at 179, because
  `48 + 179 * 24` = 4,344 sits further inside its size class than
  `48 + 179 * 32` = 5,776 did. The total still falls, because the rows are
  smaller.
- Next action: paired CPU verification, per the investigation rules.

### F3 -- stride 24 is also cache-line misalignment, and the draw path pays for it

- Status: recorded. **The finding that closed the file.**
- Date and investigator: 2026-07-29, Claude (agent).
- Commands: `just benchmark-confirm baseline=HEAD`, run twice against baseline
  `6ff35f9`, candidate arms rebuilt independently.
- Measurements, two independent confirm runs:

  | workload | run 1 | run 2 | verdict |
  | --- | ---: | ---: | --- |
  | `incremental-mixed` | **+1.95%** | **+3.39%** | **slower, both runs** |
  | `scrollback-stream` | -2.53% | -4.98% | faster, both runs |
  | `terminal-feed` | -2.24% | -2.10% | inconclusive, consistent sign |
  | `content-churn` | -0.42% | +1.15% | within noise |
  | `style-churn` | +1.09% | +0.64% | within noise |

  `incremental-mixed` plan time: +4.03% then +1.40%.
- Observation 1: **the regression is decided and it reproduces.** Two independent
  6-pair runs against a calibrated 1.85% threshold, both `slower`, the second
  larger than the first. This is the first memory change across docs 15 and 16
  that costs CPU; every earlier one was neutral or positive.
- Observation 2: **the sign splits by access pattern, not by workload family.**
  Bulk sequential work got faster -- `scrollback-stream` decided faster in both
  runs, `terminal-feed` consistently negative -- which is what a 25% smaller
  working set should do. Scattered per-cell reads got slower.
- Inference, and the mechanism: **a cell's stride is also its cache-line
  alignment.** At stride 32 a 64-byte line holds exactly two cells and every cell
  is line-aligned, so reading two fields of one cell touches one line. At stride
  24 cells start at 24, 48, 72... and straddle line boundaries, so the same read
  sometimes touches two. This is intrinsic to the stride and cannot be recovered
  by reordering fields or by inlining.
- Competing interpretation, tested and refuted: that the regression came from the
  new `Optional` computed accessors failing to inline on the draw path. Refuted
  by inspection rather than by benchmark, which was sufficient --
  `forEachViewportCell`, the call plan time brackets, reads only `cell.styleId`
  and `cell.scalars` (`Terminal.swift:3311-3315`). Both are stored properties.
  The accessors are never called on that path, so they cannot explain a plan-time
  change.
- Uncertainty: the cache-line mechanism is inferred from the stride arithmetic
  and the access-pattern split, **not** confirmed directly on an on-CPU
  instrument. A `just benchmark-trace incremental-mixed` capture showing
  memory-stall cycles in the plan path would confirm it. That was not run,
  because the decision did not depend on which mechanism was right -- the
  regression reproduces either way. Anyone reattempting this should run it first.
- Next action: `D1`.

## Decision log

### D1 -- store the cell's ids as reserved-zero sentinels rather than `Optional`s

- Status: **rejected and reverted**, by the user, 2026-07-29.
- Evidence used: `F1`, `F2`, `F3`.
- Candidate solutions: (1) leave the cell at 32 bytes; (2) reserve zero in both
  ids and reorder, reaching stride 24; (3) additionally flatten `TerminalScalars`
  to 4-byte alignment for stride 20.
- Tradeoffs and correctness risks: (2) is a straight exchange of interactive draw
  time for scrollback depth -- +19% history at 179 columns and +49% at 80, for a
  reproduced +2-3.4% on `incremental-mixed`. It also trades a compiler-enforced
  `Optional` for a reserved value, though that risk was containable and was
  contained (`F2`). (3) is rejected separately; see Rejected below.
- Recommendation at the time: take it, on the grounds that `11/F7`/`11/F8`
  established the draw path fits the 60Hz budget with headroom, so plan time that
  is not the bottleneck costs the user nothing while history is directly visible.
- Selected direction: **(1), leave the cell at 32 bytes.** The workload that
  regressed is the interactive one and the workloads that improved are throughput,
  which inverts the usual argument for spending latency on capacity. It also
  follows the `12/F8` precedent, which rejected the POD cell on a CPU regression
  after it had already been implemented and measured.
- Decision and rationale: scrollback depth is not currently a user complaint,
  and doc 15 already took the pane from ~810 honest rows to ~1,768 at the same
  budget. Spending measured interactive time to extend it further is buying
  something nobody asked for with something everybody feels.
- Reopening condition: a live scrollback-depth complaint, **or** a trace under
  `F3`'s uncertainty that attributes the regression to something other than the
  stride, since that would make it fixable rather than intrinsic.

## Rejected

### Flattening `TerminalScalars` to reach stride 20

Would remove the last 4 bytes of tail padding by dropping the cell's 8-byte
alignment, which requires the spill array to leave `TerminalScalars`. Doc 12
implemented row-owned cluster storage and reverted it (`94a1528`; rejection
recorded in `685e1e7`), so the prerequisite is a change already tried and
withdrawn. Reopen only with evidence that addresses why that revert happened.

Note that `F3` now supplies a second, independent objection: stride 20 is not a
divisor of 64 either, so it carries the same straddle penalty that rejected
stride 24 -- and unlike stride 24 it has no malloc-bucket win at 179 columns to
weigh against it.

## Outcome

**Closed. Nothing further to take here, and the cell stays at 32 bytes.**

The file found a real 8-byte saving that doc 15 missed, confirmed it moved the
allocator's bucket at both canonical widths -- the bar `15/F12` set and failed --
and then found it was blocked by a constraint neither file had considered.
`F3` is the durable result: **a cell's stride is also its cache-line alignment,
and 32 is a divisor of 64 while 24 and 20 are not.** That makes 32 bytes a
natural resting point rather than an accident, and it retires `15/F16`'s two
recorded candidate directions along with `H1` -- all three land on non-dividing
strides.

Findings F1 through F3 are recorded; the next free ID is **F4**. Decision D1 is
recorded and rejected; the next free ID is **D2**. The implementation is measured
and described in `F2` in enough detail to reproduce, including the `<=` -> `<`
capacity-guard correction that a reattempt would otherwise have to rediscover.
