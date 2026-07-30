# Open Questions

These questions remain intentionally undecided. They are inputs to future
planning rounds, not permission for implementation to choose a direction
silently.

## Architecture and concurrency

- Which boundaries deserve separate packages versus internal targets?

## Protocol support matrix

- Which additional device and mode queries, beyond the current documented
  capability contract, are required by later prioritized applications?
- Which notification or progress protocols, if any, justify extending the
  documented contract (or, if a machine-readable artifact is ever needed
  again, a new versioned artifact) beyond the bounded OSC 9 and OSC 777 forms
  currently supported?

## Terminal semantics

- Which less-common DEC modes and rectangle operations are required by the
  accepted application workflows?

## Runtime integration

- What measurable latency and throughput thresholds define "interactive" for
  the correctness-first renderer?

## Later product work

- What DanTerm-owned config, theme, and keybinding formats should be introduced
  after the baked defaults prove insufficient?
- Should per-pane command journals
  ([Semantic terminal model](16-semantic-model.md)) ever join enriched
  recovery checkpoints, and under what bounds?
- Which product consumers adopt journal queries first (exit-status-aware
  alerts, sidebar command chrome, agent debugging), and what do they need
  beyond the initial record shape?
- Should panes ever model workspace/git context (worktree root, branch,
  dirty state)? Cut from the first semantic-model release for lacking a
  consumer. Two points are settled if it returns: the shell reports its own
  repo context at prompt boundaries over the versioned envelope (the OSC 7
  cwd pattern, with honest prompt-time staleness), and app-side filesystem
  watching stays rejected -- it breaks remote panes, races cwd changes, and
  reintroduces ambient IO.
- Should OSC 52 reads ever gain an explicit permission path?
- When should file paths and source locations become link targets?
- What evidence would justify a Metal renderer or a custom `danterm` terminfo
  entry?
