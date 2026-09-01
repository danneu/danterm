# Decisions -- baseline memory with ten tabs open

One entry per stable ID. `D1` is a standing rule; later entries record
direction gates and their verdicts.

### D1 -- the process total decides, attribution explains

- Status: **settled**; governs every claim in this doc.
- Evidence used: `F1` (the total is what the chart and Activity Monitor
  show), `15/F1` (the malloc heap was about a quarter of the app's footprint,
  so a heap-only reading misattributes), and
  `agent-docs/measurement-discipline.md` (every aggregate carries its count).
- Candidate solutions considered:
  - Decide on in-app counters alone. Rejected: a counter reports what the app
    thinks it released, not what the render server or the kernel kept.
  - Decide on `vmmap` class lines alone. Rejected: it cannot be read from a
    benchmark harness and is a diagnostic, not a receipt.
  - Decide on whole-process `phys_footprint` measured the way termfoot
    measures it, with class attribution and in-app counters reported beside
    it so a smaller total cannot be credited to a mechanism that did not move.
    Selected.
- Tradeoffs and correctness risks: the total is noisy across sessions and
  displays, which is why comparisons are contemporaneous and same-conditions
  only.
- Decision and rationale: a change is credited with a memory improvement only
  when the contemporaneous total moved, the attributed class moved by a
  matching amount, and tab-switch latency was reported beside both.

### D2 -- direction for hidden-pane presentation memory

- Status: **open**; gated on `F4`, `F5`, `F7`, `F8` (`T7`).
- Candidate solutions:
  - Visible-lifetime ownership: a hidden pane owns no swapchain. Largest
    saving, preserves depth-3 where it applies, costs a cold allocation and
    full render on reveal, and needs one lifecycle owner across hide, reveal,
    occlusion, scale change, and teardown.
  - Purgeable-volatile hidden chain: keep the swapchain object, mark its
    surfaces volatile on hide, force every buffer to render again on reveal.
    Cheaper to build; the saving depends on the kernel and on what
    `phys_footprint` counts.
  - One frozen surface per hidden pane: release two of three, keep the last
    frame attached. Instant-looking reveal; leaves a third of the term.
- Behavioral verification required of whichever wins: a hidden pane keeps
  consuming PTY output; reveal presents the current state, not the frame from
  hide; repeated hide/reveal leaves only the visible panes' chains live after
  Core Animation settles; a hide with an armed retry cannot recreate buffers;
  scale, color space, theme, grid, and font changes while hidden all yield a
  fresh correctly sized frame on reveal; closing a hidden pane releases
  everything; the real-AppKit test proves the detached surface becomes free.
- Selected direction: none yet.

### D3 -- the instrument is termwars' reading of one staged slot

- Status: **settled**.
- Evidence used: `agent-docs/terminal-performance.md`, "Profile memory":
  `terminal-memory-probe` is headless and cannot allocate the surfaces `F2`
  attributes; `benchmark-memory` is a leak detector that once reported a
  fixed build as larger than a leaky one because IOSurface churn was twice the
  effect (`15/F6`). termwars' `danterm_footprint` and its memory harness read
  `phys_footprint` over the slot bundle's pid set, which is the number the
  chart and Activity Monitor show, and the slot guard refuses any bundle that
  might be the app in use.
- Candidate solutions considered:
  - Extend `benchmark-memory` with a ten-tab workload. Rejected: it samples a
    sawtooth and brackets with memory graphs that suspend the target; its
    design question is growth, not level.
  - A new in-repo GUI harness. Rejected: it would duplicate the adapter
    termwars already calibrated (window geometry for 170x60 at Menlo 13,
    focus-once staging, grid readback) and split the receipts across two
    repos.
  - Two tiers over termwars' code: a scripted spot reading for the edit loop
    and the full harness for a series row. Selected.
- Tradeoffs and correctness risks: the instrument lives in another checkout
  at `~/Code/termwars`, so a series row names the receipt file by path and
  the reading is not reproducible from this repo alone. Tier 2 is GUI-driving
  and cannot run in the gate; the series is written by a person choosing the
  moment. Tier 1 runs at whatever grid the slot window gives, which is why it
  records the grid and makes no claim.
- Decision and rationale: a claim is a tier-2 pair in `series.md`; a tier-1
  reading steers the work and is written under the ledger task, never in the
  series.
