# Plan-time metric and warm arms

Research started: 2026-08-27.

- [findings.md](findings.md) -- the append-only evidence chain.
- [decisions.md](decisions.md) -- the auditable decision log.

## Purpose

Own the two harness defects that made `benchmark-quick` and `benchmark-confirm`
call `slower` on code that had not changed: a plan-time quantity that summed
plans of different classes, and a first block per persistent arm that was
colder than every block after it. The doc preserves the A/A evidence a human
needs to freeze a plan-time rule on the replacement quantity, and the
reopening condition for the warm-up.

## Investigation rules

- Every claim about the instrument comes from an A/A series -- one tree bound to
  both arms -- never from a candidate comparison. A candidate run can show a
  symptom; only an A/A can attribute it to the harness.
- Frozen rules move by a human reading a calibration report. This doc collects
  the report and records the proposal; it does not edit `DECISION_RULES`.
- Machine idle for every measurement, per the performance guide.

## Trigger and current evidence

Commit `42d4eef2` (delete `row` from the render run types) read the quick
content-churn plan line `slower` at +5..+6.5% on every candidate variant while
the headless `retained-browse` cell (a pure `planFrame` loop) read
`equivalent`. `F1` reproduces the plan-line reading on identical binaries.
`F2` shows the first draw block of a persistent arm 6-8% above the rest.

## Current hypotheses

### H1 -- the per-draw plan sum measures PTY chunking, not planner cost

Supported by `F1`: the full-plan median is flat across arms while the count of
partial plans per block differs by up to 14. Confirmed by the same reading on
one binary. Falsified if the full-plan median moved with the partial count.

### H2 -- the first block per process is cold, not the first block per run

Supported by `F2`: block 0 is high; block 1, the other process's first block,
is not. Rejected in `F3` if the other arm's first block is also high once the
schedule alternates, or if a warm-up block does not flatten block 0.

## Task ledger

- [x] T1 Record the per-draw-sum defect with an A/A series. `F1`.
- [x] T2 Record the cold first block. `F2`.
- [ ] T3 Replace the quantity with the median full-viewport plan. `D1`.
- [ ] T4 Warm each persistent arm once per process; phase the quick quartet.
      `D2`.
- [ ] T5 Collect the plan A/A on the new quantity and the draw A/A on the
      warmed harness. `F3`, `F4`.
- [ ] T6 A human freezes or refuses a plan rule from `F3`.

## Rejected ideas

- Nanoseconds per replanned row over every plan: a partial plan pays the same
  fixed cost over fewer rows, so the ratio still moves with the mix (`D1`).
- Widening the per-draw rule until an A/A passes: at 2 pairs no threshold clears
  the gates, and a threshold wide enough would not see the 5% effect the line
  exists for (`F1`).
- Alternation alone for the cold block: it moves the cost between arms instead
  of removing it (`D2`).

## Open questions

- Whether `style-churn`'s partial-plan mix has the same cause; its quick plan
  line moved the same way (`F1`), and the new quantity applies to it unchanged.

## Outcome

Open.
