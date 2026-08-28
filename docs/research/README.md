# docs/research/ -- living research docs

A research doc is a scratchpad for a single investigation or strategy area.
It is not an ADR and not a plan: design decisions that are settled graduate to
`docs/design/`, and work that is ready to implement graduates to a plan file.
A research doc is where ideas live while they are still being discovered,
vetted, refined, or rejected.

This file is the index: what exists, what is live, and the project-local
pointers a reader needs. The format contract -- how a doc is stored, its
required shape, and how to run one -- is [FORMAT.md](FORMAT.md).

Reviewed 2026-08-05. **Table membership is the only record of liveness** -- a
doc is live iff its row sits in `## Live`, and closing it moves the row to
`## Closed`. Closed means the questions it opened have answers and nothing in it
is waiting on anyone -- not that every idea in it was implemented. Several
closed with parked backlogs; each one records its own reopening condition, and
those conditions are the right entry point, not a re-read of the evidence.

A row names what a doc owns and one clause of outcome, nothing more. The arc,
the evidence, and the reopening condition live in the doc's own `## Outcome`.

## Live

| # | Doc | Owns | Next |
| --- | --- | --- | --- |
| 18 | [CPU renderer optimization leads](18-cpu-renderer-optimization-leads.md) | The renderer bracket doc 17 never opened, lead by lead | `D7`'s variance measurement gates `L6`/`L5`; the shipped span clip moved the bracket again |
| 25 | [Energy efficiency](25-energy-efficiency/README.md) | The engine's battery/energy posture and its backlog | Phase 1 baselines: idle wakeups, hidden-flood powermetrics (needs interactive sudo) |
| 32 | [Post-resize repaint loss](32-post-resize-repaint-loss/README.md) | Rows present in the grid that no frame paints after a resize | Fixed by `D1`; owes an instrument for the resize cost that fix adds |
| 33 | [By-construction perf survey](33-by-construction-perf-survey/README.md) | Work done per iteration whose inputs vary per change, across all six verticals | Phase 2: `T8`+`T7` and `T10` landed; `T9` direction set (`D7`), unstarted |
| 35 | [iOS remote client](35-ios-remote-client/README.md) | The viable path to an iOS thin client driving a remote DanTerm | Phase 1 spikes: render execution on iOS, presentation path, Mac-to-Mac tape client |
| 37 | [SIMD opportunities](37-simd-opportunities/README.md) | Where explicit SIMD or vectorization would pay, ranked by impact x confidence | Phase 2: `appendCells` scalar rewrite; ranks 2 and 6 need an erase/scroll workload |
| 38 | [Plan-time metric and warm arms](38-plan-metric-and-warm-arms/README.md) | The plan line and the cold first block of a persistent benchmark arm | T5: A/A series on the new quantity; T6: a human freezes or refuses a rule |
| 39 | [Kitten render benchmark](39-kitten-render-benchmark/README.md) | The four text-printing `kitten __benchmark__` arms and a ladder arm for them | Phase 1: attribute the `apply` memmove and the idle half; pick the fixture source (`D1`) |

## Closed

| # | Doc | Owns | Result |
| --- | --- | --- | --- |
| 1 | [External terminal tests](1-external-tests.md) | Which external suites DanTerm should adopt | Shipped -- the M9 external-evidence package; M10 reruns it, adds nothing |
| 2 | [Wraptest coverage](2-wraptest-coverage.md) | Whether wraptest belongs in DanTerm's suite | Declined -- redundant coverage and an unclear license |
| 3 | [Serialized redraw](3-serialized-redraw-optimization.md) | Making the serialized redraw path cheaper | Shipped -- per-run glyph batching; medians -97% |
| 4 | [Fallback-glyph batching](4-fallback-glyph-batching.md) | Batching fallback-glyph draws | Superseded -- procedural sprites across eight families |
| 6 | [Sprite classification](6-sprite-classification-regression.md) | Two regressions the sprite series introduced | Shipped -- both found and fixed |
| 7 | [Paired A/B benchmarks](7-fast-performance-benchmarks.md) | A paired runner fast enough to decide verdicts | Tooling -- shipped; it decided every verdict in docs 8-13 |
| 8 | [Benchmark variance](8-benchmark-variance-regression.md) | Why paired benchmark variance blew up | Tooling -- a CPU frequency governor; D2 routes around it |
| 9 | [Plan/render allocations](9-plan-render-allocation-hotspots.md) | Allocation hotspots on the plan and render paths | Shipped -- three changes; Phase 5 parked at a ceiling |
| 10 | [`Terminal.feed` hotspots](10-terminal-feed-hotspots.md) | Where time goes inside `Terminal.feed` | Shipped -- -24.31% on `terminal-feed` |
| 11 | [Render frame budget](11-render-frame-budget.md) | Whether the draw path fits the 60Hz budget | No change -- it fits; none proposed or warranted |
| 12 | [Cell representation](12-cell-representation.md) | How a cell is represented in memory | Shipped -- erase leg; POD cell rejected, memory half to doc 15 |
| 13 | [Live-app compositing](13-live-app-compositing-and-draw-hotspots.md) | Where live-app compositing and draw time go | Shipped -- three candidates; the stall is pipeline slack |
| 14 | [Live scroll profile](14-live-scroll-workload-profile.md) | A Time Profiler trace of the live scroll workload | Shipped -- accessor inlining -20% draw, row-scoped read -16% plan |
| 15 | [Memory footprint](15-memory-footprint.md) | Resident bytes per cell, per row, and per pane | Shipped -- the same history for 57-59% less; cell 72 -> 32 bytes |
| 16 | [Cell padding](16-cell-padding.md) | The padding left in the 32-byte cell | Rejected -- stride 24 wins memory, loses cache alignment |
| 17 | [CPU profile sweep](17-cpu-profile-sweep.md) | An on-CPU profile sweep across every workload | Shipped -- POD damage snapshot -14.59% feed; A and C closed |
| 19 | [Owner-queue occupancy](19-owner-queue-occupancy.md) | How long one job holds a pane's PTY queue, and who waits | Shipped -- `C1` and `C4` landed; `C2`/`C3`/`C5` premature, reopen at 4x history |
| 20 | [PTY throughput](20-pty-throughput-and-interactive-stimulus.md) | What the drain costs, and what stimulus to replay | Tooling -- throughput reporting; block lengthening declined |
| 21 | [Selection gesture cost](21-selection-gesture-cost.md) | What a pointer-driven selection query costs | Shipped -- point-local projection; double-click 13.6 ms -> 5.5 us, flat in history |
| 22 | [Application-exit crash](22-application-exit-job-corruption.md) | A crash in the application-exit job path | Shipped -- exit path removed; the corrupting write never identified |
| 23 | [PTY benchmark alignment](23-pty-benchmark-alignment.md) | Whether the benchmarks still match the rewritten PTY | Shipped -- one atomic timed consume fence; `synchronized-frames` demoted |
| 24 | [OSC 133 dialect](24-osc-133-dialect/README.md) | The marks DanTerm's shell integrations emit | Shipped -- all three integrations emit it; `F21`'s anti-flicker prompt hold rejected |
| 26 | [External corpus expansion](26-external-corpus-expansion/README.md) | Re-adjudicating skipped external cases, and unsurveyed corpora | Shipped -- 8 cases reclassified, two corpora mined, M9's external gate passes |
| 27 | [swift-collections adoption](27-swift-collections-adoption/README.md) | Where library containers fit DanTerm storage | Rejected -- all twelve sites failed the adoption bar; no new conversion |
| 28 | [Retained-row optimizations](28-retained-row-optimizations/README.md) | Follow-on wins opened by compact retained rows | Shipped -- `C1`'s 8-byte retained cell, 10.49 -> 3.72 MB at 1.11x depth; `H5`/`H8` parked |
| 29 | [Sparse AppKit damage clip topology](29-sparse-appkit-damage-clip-topology/README.md) | Exact sparse clips across AppKit and Core Animation | Shipped -- maximal spans retain the sparse win without btop regression |
| 30 | [CG clip construction mechanics](30-cg-clip-construction-mechanics/README.md) | The shipped span clip's implementation cost and simplifications | Shipped -- one folded clip(to:) call as a simplification; no win the ladder can resolve |
| 31 | [Logical-line scrollback](31-logical-line-scrollback/README.md) | Storing history as unwrapped logical lines, wrapped at read | Shipped -- reflow of history and both caps deleted; ladder passes, resize 576 ms -> 1.58 ms |
| 34 | [Live semantic event forwarding](34-live-semantic-event-forwarding/README.md) | Transport and hook limits for live pane semantics | Tooling -- pinned supported transports and exact agent activity hooks |
| 36 | [windows-terminal corpus census](36-windows-terminal-corpus-census/README.md) | The 128 cases doc 26 pinned but never weighed | Shipped -- 5 adopted, complete 213-case ledger, ledger lint |

(There is no doc 5; numbers are never reused or renumbered. Docs 1-23 predate
the folder form and stay flat files; doc 24 onward is a folder.)

**Project notes.** The portable seam is a file boundary: [FORMAT.md](FORMAT.md)
is generic research prose meant to survive extraction as a portable skill, so no
link in it may resolve outside `docs/research/`. The DanTerm-local pointers live
here instead:

- Outside `docs/research/`, cite a finding as `research/N/ID`; within this tree,
  use `FORMAT.md`'s portable bare cross-doc form such as `9/F3`. The full rule
  lives in [AGENTS.md](../../AGENTS.md#citing-docs).
- Read [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  before measuring anything or planning against a number in one of these docs.
  It owns the benchmark, commit, and compatibility conditions a performance
  claim must name, and the cross-cutting rules these docs produced.
- The contract in [FORMAT.md](FORMAT.md) is machine-checked by
  `scripts/research-index-lint.sh`, which also holds the enumerated frozen set
  of grandfathered flat docs (1-4 and 6-23). That list never grows: a new entry
  in it would be a new flat doc.
- [FORMAT-NOTES.md](FORMAT-NOTES.md) is the change log for the contract itself:
  dated `observation -> cost -> rule changed or rejected` entries, plus the
  rules whose only support so far is performance research.
