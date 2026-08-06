# Granularity mismatch

A structural smell to check for when reviewing, optimizing, or simplifying:
**work executed at the granularity of iteration rather than the granularity of
variation.** A computation runs once per element of a fine-grained structure
(cells, rows, records), but its inputs are constant across long stretches of
that structure -- so the cost is O(elements) while the information content is
O(changes). The fix is structural, not a cache: lift the computation to the
coarsest granularity at which its inputs are actually constant.

The deeper form of the smell: the coarse structure usually already exists in
the program. The inputs arrive as ranges, runs, spans, or piecewise-constant
fields, and the code flattens them to per-element form (`range.contains(i)`
asked per `i`) only to re-derive runs from the per-element output afterward.
Flatten, compute, re-coalesce: the middle step destroyed and the last step
rebuilt the same information, paying per-element compute in between.

## The worked example

Found 2026-08 in the overlay color work
(`plans/impl/2026-08-06-1431-background-adaptive-overlay-colors.md`).
`RenderFramePlanner` resolved overlay colors per cell via `resolveOverlayStyle`
-- allocating avoidance arrays and running a brightness-ladder search for every
overlaid cell -- even though every input varies at run granularity: selection
and match are per-row `Range<Int>`s (at most ~5 state segments per row), and
backgrounds are coalesced into runs by the same planner. The per-cell outputs
were then run-length encoded back into overlay runs. The scaffolding was the
tell: parallel `[[PlannedOverlay?]]` arrays that were nil almost everywhere,
dual per-cell code paths, and a branch-free optional-row-storage trick added to
claw back a 7.79% regression that per-cell overlay storage had caused.

The structural fix is to intersect the input partitions -- state segments
crossed with background runs -- and resolve once per fragment. Output runs
become canonical by construction instead of by post-hoc coalescing, the
per-cell scaffolding is deleted rather than optimized, and the cost model
matches the output size instead of the domain size.

## Detection heuristics

1. **Loop-invariant-in-stretches calls.** A pure function called inside a
   per-element loop whose arguments change rarely between iterations. Classic
   loop-invariant code motion is the degenerate case where they never change;
   the hoisting discipline in `RenderFramePlanner` is this repo's precedent.
2. **Compute-then-dedupe.** A per-element pass whose output is immediately
   run-length encoded, grouped, or deduplicated. If outputs coalesce, inputs
   almost certainly did too -- coalescing belongs before the expensive step.
3. **High-hit-rate caches and memos inside a single pass.** A memo whose key
   changes orders of magnitude less often than it is consulted. Caches earn
   their keep across time (frames, requests); within one computation they are
   usually compensating for a granularity mismatch. A near-total hit rate is
   not a fix -- it is the diagnosis: the cache dynamically rediscovers, on
   every lookup, structure that was statically knowable from the inputs.
4. **Ranges downgraded to membership tests.** Inputs held as ranges or spans,
   consumed as per-index `contains` instead of intersected as ranges.
5. **Mostly-empty parallel structures.** A per-element array of Optionals that
   is nil almost everywhere, or a per-element flag constant almost everywhere
   -- evidence the property lives at a coarser granularity than it is stored.
6. **Per-element branches deciding a per-group question.** A conditional
   inside the hot loop whose outcome is fixed for the whole row, batch, or
   section.

## The fix pattern

Compute at the coarsest granularity at which all inputs are constant:
intersect the partitions of the inputs, compute once per resulting fragment,
and let per-element consumers read from the fragment. Prefer this structural
lift over a cache; treat a cache as the fallback for when the coarse structure
genuinely cannot be recovered statically.

Report the mismatch even where current cost is acceptable: the same mismatch
is usually also a complexity smell, and the flatten/compute/re-coalesce code
plus its dedup/memo/optional-array scaffolding disappears with the fix. That
scaffolding is the structure apologizing.

## The exception

When the fine-grained pass is already required for other reasons and the
per-element work is trivial -- an integer compare, a field copy -- lifting it
buys complexity, not speed. The smell is strongest when the per-element work
allocates, searches, or calls something nontrivial, or when compensating
scaffolding has already grown around it. And any claimed speedup still needs
the paired measurement discipline in
[terminal-performance.md](terminal-performance.md); a complexity-class
argument justifies the refactor, not a percentage.
