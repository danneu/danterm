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
