# Open Questions

These questions remain intentionally undecided. They are inputs to future
planning rounds, not permission for implementation to choose a direction
silently.

## Architecture and concurrency

- Which boundaries deserve separate packages versus internal targets?

## Protocol support matrix

- Which device and mode queries are required by the prioritized applications?
- Which OSC notification and progress variants are part of the initial accepted
  contract beyond DanTerm's current usage?
- Which non-title protocol should replace the temporary authenticated title-channel
  encoding while preserving command text, command boundaries, and remote-session
  metadata?

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
