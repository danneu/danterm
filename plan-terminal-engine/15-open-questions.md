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
- Should OSC 52 reads ever gain an explicit permission path?
- When should file paths and source locations become link targets?
- What evidence would justify a Metal renderer or a custom `danterm` terminfo
  entry?
