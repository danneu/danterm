# Findings

### F1 -- the per-draw plan sum reads +7.33% on one binary against itself, because it counts how many plans were partial (2026-08-27)

`planNanosecondsPerDraw` was a block's cumulative `planFrame` time over its 50
accepted draws. Per-draw samples in every content-churn artifact on disk were
bimodal: ~320 us where one plan replanned the whole 66-row viewport, ~110-200 us
where a plan replanned part of it. Across sixteen candidate runs the full-plan
median was flat between arms (for the `42d4eef2` candidate: 320.7/331.0 us
baseline, 321.2/321.4 us candidate) while the baseline role drew 9-14 partial
plans per block against the candidate's 0-7.

A one-quartet A/A at `HEAD` (`d3206af7`, tree `310a8352d7ad`) with
`scripts/terminal-benchmark-plan-calibration.py --metric plan --revision HEAD
--workload content-churn --quartets 1` read:

    content-churn: 2 A/A pairs, median +7.33%, SD 2.80%, range +5.35%..+9.31%
    quick: no threshold clears the gates at its 2 pairs
    confirm: no threshold clears the gates at its 4 pairs

with partial counts 12/9 (role A) against 4/2 (role B). Artifact:
`.build/terminal-benchmark-plan-calibration/310a8352d7ad-0000`. A later
two-quartet draw A/A on the same tree had the split the other way (`F2`), so
the skew is between-process variance, not a property of the role. The frozen
quick rule (2 pairs at +/-2.5%) was calibrated on a 12-quartet series whose
ABBA/BAAB alternation averaged it out; a quick run is one quartet and cannot.

`style-churn` showed the same shape on the same candidate: draw equivalent
-0.95%, plan +2.92% `slower`, partial counts 10/1 against 5/0.

### F2 -- the first block of a persistent arm draws 6-8% above every block after it (2026-08-27)

`scripts/terminal-benchmark-plan-calibration.py --metric draw --revision HEAD
--workload content-churn --quartets 2` (artifact
`.build/terminal-benchmark-draw-calibration/310a8352d7ad-0000`):

    block  role  draw us   plan/draw us   partial plans
    0      A     3325      311            6
    1      B     3279      309            9
    2      B     3228      315            4
    3      A     3122      323            6
    4      B     3087      310            11
    5      A     3084      329            8
    6      A     3104      315            10
    7      B     3138      319            10

    content-churn: 4 A/A pairs, median +0.61%, SD 1.98%, range -1.39%..+3.33%

Both roles here are one process, so "block 0" is the process's first block and
block 1 its second: the cold cost is per process, not per role, and a
persistent arm in a real comparison pays it on its own first block. Quick mode
is one ABBA quartet, so the baseline always owns block 0. The plan quantity
did not move with it (311 us against 309-329), so the cold cost is in the draw
path -- raster and glyph caches, not the planner.

### F3 -- the median full-viewport plan is unbiased on one binary, and its A/A spread is between-block drift the 2- and 4-pair schedules cannot absorb (2026-08-27)

`scripts/terminal-benchmark-plan-calibration.py --metric plan --revision HEAD
--workload content-churn --workload style-churn` at `4952aef1` (tree
`56c2faba823b`), 12 quartets, warmed arms, 20,000 resampling trials:

    content-churn: 24 A/A pairs, median -0.35%, SD 2.79%, range -5.59%..+6.53%
    style-churn:   24 A/A pairs, median -0.04%, SD 3.48%, range -6.38%..+5.70%
    quick:   no threshold clears the gates at its 2 pairs
    confirm: no threshold clears the gates at its 4 pairs

Artifact: `.build/terminal-benchmark-plan-calibration/56c2faba823b-0000`.

The per-plan samples confirm the model behind `D1`. Every content-churn block
held 35-48 full-viewport plans and 6-20 others, and the others were what the
row counts said they would be: split updates at 20-58 rows (the PTY read
boundary landing mid-screen) and 1-2 row plans from the shell. Their median
cost, 68-227 us, is the half-cost mode the old sum was counting.

The remaining spread is not the mix. Within a block the full-plan samples sit
tight (20th percentile to mean 3-4%), while the block medians walk from 326 us
in the first quartet to 349 us in the last and adjacent blocks differ by up to
3%. That is clock and thermal drift over a 96-block session, which the draw
metric on the same blocks also carries (F4). The old quantity's series (SD
1.48% at `e72190b4d542`) was collected in another session on another day, and
a cross-session SD comparison is exactly what
`agent-docs/measurement-discipline.md` says not to make; the like-for-like
statement is that the new quantity centers on zero where the old one sat at
+7.33% (`F1`).

What a human can freeze from this: nothing at the frozen pair counts. The
plan line stays descriptive. If a rule is wanted, the honest routes are a
longer plan-only schedule (plan time rides the draw blocks today and cannot
buy pairs) or a per-block estimator less exposed to drift than the median,
chosen on a fresh series rather than tuned on this one.

### F4 -- with warm arms the first block sits inside the pack, and today's draw A/A is wider than the series the frozen content-churn rules came from (2026-08-27)

`scripts/terminal-benchmark-plan-calibration.py --metric draw --revision HEAD
--workload content-churn` at `4952aef1` (tree `56c2faba823b`), 12 quartets,
warmed arms, 20,000 trials:

    content-churn: 24 A/A pairs, median -0.76%, SD 1.71%, range -3.01%..+2.78%
    quick:   2 pairs at +/-2.75% (A/A false positives 0.0000, detection 0.9165 at 5%)
    confirm: no threshold clears the gates at its 4 pairs

Artifact: `.build/terminal-benchmark-draw-calibration/56c2faba823b-0000`.

The first measured block drew at 3061 us against a median of 3101 us for the
47 after it (-1.3%), where `F2` had it at +6-8%: the warm-up block absorbed
the cold cost, and `H2` stands. The warm-up blocks themselves are recorded in
`run.json` as `warmupBlocks` from commit 3 on; the calibration collector keeps
only paired blocks, so this series does not show them.

The spread is the other result. The frozen content-churn draw rules are 2
pairs at 2.0% (quick) and 4 pairs at 1.5% (confirm), from research/33/F28's
series (SD 1.34%, range -3.55%..+2.40%). Today's series proposes 2.75% for
quick and clears nothing for confirm. Same caveat as `F3`: a cross-session
comparison of two A/A series is a machine-state comparison, not a harness
one, and it does not by itself say the frozen rules are wrong. It does say
that on this machine today a confirm `slower` at +3.43% on content-churn
(the `42d4eef2` candidate's reading) sits inside a range an identical
binary produces. A human deciding whether to re-freeze the draw rules should
collect a second series on another day before moving them.
