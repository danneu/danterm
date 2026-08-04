# Decisions -- logical-line scrollback (doc 31)

Auditable decision log for
[31-logical-line-scrollback](README.md); the contract is
[../FORMAT.md](../FORMAT.md).

### D1 -- go/no-go for the logical-line store

- Status: rule not yet frozen. **The rule must be frozen -- workloads,
  verdicts, and what the simplification inequality must show -- before F1's
  comparison result is read.** Freezing it is the first act of whoever runs
  F1.
- Evidence used (planned): F1 (read-path probe), F2 (counting pass), F3
  (admission probe), F4 (edge-case inventory -- specifically whether any edge
  case requires stored width, which rejects H4 and the premise).
- Candidate solutions: go (open Phase 2 design), no-go (fall back to the
  hybrid recorded in Rejected / `28/H7`), or narrow-go (viable but with a
  named condition, e.g. a search index requirement discovered in F1).
- Decision and rationale: pending.
