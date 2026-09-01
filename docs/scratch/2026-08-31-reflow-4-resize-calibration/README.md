# REFLOW-4's resize decision rule, and the A/A series it came from

`REFLOW-4` lands only if it makes a width resize cheaper. This folder is the frozen
rule that decides it, the evidence the rule was calibrated from, and the run it
decided. The two A/A series were measured before any candidate existed: both arms are
the same baseline binary, so what they describe is the machine's noise and nothing
else.

## Files

| File | What it is |
|---|---|
| `aa-select.json.gz` | 40-pair A/A series. Selected the pair count and thresholds. |
| `aa-confirm.json.gz` | A second, disjoint 40-pair A/A series. Confirmed them. |
| `selected-rule.json` | The rule as selected, before confirmation. |
| `confirmed-rule.json` | The rule to decide with. `decide` accepts no other stage. |
| `decision.json.gz` | The 24-pair A/B series REFLOW-4 landed on. |
| `decision-verdict.json` | What the frozen rule made of it. |

A series keeps every timed sample of every probe run, so a later reader can
re-reduce it under a different statistic without measuring again. That is what the
compression is for; `scripts/terminal-resize-probe-compare.py` reads either shape.

## The rule

24 pairs, and per-estimator thresholds on the symmetric paired percentage
difference:

| Estimator | Threshold | A/A rate, selection | A/A rate, confirmation |
|---|---|---|---|
| narrowing median | 0.5% | 0.000 | 0.001 |
| narrowing p95 | 2.0% | 0.048 | 0.018 |
| widening median | 0.5% | 0.000 | 0.001 |
| widening p95 | 4.0% | 0.002 | 0.047 |

A candidate passes when both narrowing statistics improve by at least their
threshold and neither widening statistic regresses by its own. Narrowing is the
direction that reflows content; widening mostly re-pads it, so the direction with
little work to remove is held to "not worse" rather than to "better".

Four estimators rather than the two the plan names, because the probe alternates
narrow and wide and the two directions cost very differently: on this recipe the
narrowing resizes centre on 2.59 ms and the widening ones on 1.45 ms. Every quantile
of the combined samples therefore sits inside one group and moves between the two
for reasons that are not cost -- the combined median's paired A/A spread was 4.7-7.7%,
against 0.4-0.8% once the groups are read apart. So the probe now reports each
direction's samples separately, and the rule decides on the four numbers that mean
one thing each.

## How it was produced

On an idle machine, in one session, from one release build of `TerminalResizeProbe`
used as both arms:

```
just terminal-resize-probe-compare "measure --baseline B --candidate B --pairs 40 \
    --label aa-select --out aa-select.json.gz"
just terminal-resize-probe-compare "measure --baseline B --candidate B --pairs 40 \
    --label aa-confirm --out aa-confirm.json.gz"
just terminal-resize-probe-compare "select --series aa-select.json.gz \
    --out selected-rule.json"
just terminal-resize-probe-compare "confirm --rule selected-rule.json \
    --series aa-confirm.json.gz --out confirmed-rule.json"
```

The two stages are separate because a threshold picked from one series is selected,
not verified: a bound set at the observed extreme of n replications is exceeded by a
fresh run about one time in n+1. `confirm` refuses a series that selected the rule,
and refuses the rule outright if its false-positive rate on the fresh series exceeds
the limit declared in the script before either series existed.

## What it decided

`decision.json.gz` is that run: the baseline binary built from `5a01bbdd` against a
candidate built from the revision that resolves resize targets during the pack walk.
Both arms reflowed the same content -- 10700 retained rows and 1915200 retained cells
-- and the control moved by 0.06% to 0.95%, so the session holds. The verdict is
`improved`, and by far more than the rule asks: the narrowing median falls from
2.60 ms to 0.37 ms and the widening median from 1.45 ms to 0.33 ms. The per-cell heap
traffic the change deletes was most of what a width resize cost.

## Using it

Build a baseline binary from the revision before `REFLOW-4` and a candidate binary
from the revision with it, then, in one sitting:

```
just terminal-resize-probe-compare "measure --baseline B --candidate C --pairs 24 \
    --label reflow-4-decision --out decision.json.gz"
just terminal-resize-probe-compare "decide --rule confirmed-rule.json \
    --series decision.json.gz"
```

`decide` changes nothing about the rule. It refuses a series of any other size, a
series whose arms are one binary, and any pair whose arms disagree on retained rows
or retained cells. It reports `void` rather than a verdict when the control series --
the baseline binary against itself, measured beside every decision pair -- moved by
more than a threshold, because a session that moved cannot attribute a difference to
the candidate.
