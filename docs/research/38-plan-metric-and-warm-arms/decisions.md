# Decisions

## D1 -- the plan line is the median full-viewport plan (2026-08-27)

The observer records each `planFrame` call as its own sample with the number
of rows it replanned; the block quantity is the median over samples that
replanned the full viewport, with the count beside it and absent below 25.
The per-draw sum is deleted, and with it the quick rules calibrated on it. See
`F1` for why one class of plan is the invariant quantity and
`plans/impl/2026-08-27-1341-plan-metric-and-warm-arms.md` for the shape.

## D2 -- one warm-up block per persistent arm process, quick quartet phased by tree (2026-08-27)

Each persistent draw arm runs one discarded block right after it starts, at the
lifecycle seam so the calibration collector's per-quartet calls do not repeat
it. A quick invocation's single quartet starts on ABBA or BAAB by a bit of the
candidate tree, so the schedule's stated alternation holds across invocations.
See `F2`.
