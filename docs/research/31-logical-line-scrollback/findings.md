# Findings -- logical-line scrollback (doc 31)

Append-only evidence chain for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md). Cross-file citations are qualified (`28/F23` is
doc 28's); bare IDs are this doc's.

No findings yet. Reserved by the Phase 1 ledger:

- **F1** -- the read-path probe: prototype arena + block index vs the current
  `ScrollbackBuffer`, sequential browse and random seek at `28/F23`'s content
  mix. The go/no-go input to D1.
- **F2** -- the eager counting pass at 10,000 and 100,000 lines.
- **F3** -- the admission probe: open-line append vs row-record admission.
- **F4** -- the edge-case inventory mined from `references/`, cited
  `file#identifier`.
