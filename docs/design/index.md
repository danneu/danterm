# Design Decisions

DanTerm design notes record durable architecture and lifecycle decisions. They
use a lightweight ADR shape so future changes can see the context and tradeoffs
behind the current behavior.

## Format

Design note filenames use:

```text
YYYY-MM-DD-slug.md
```

Each note should include:

- Title
- `Status`
- `Date`
- `Context`
- `Decision`
- `Consequences`
- `References`

Default statuses are:

- `Accepted`
- `Superseded`
- `Draft`

## Notes

- [2026-03-05: Display Scaling](2026-03-05-display-scaling.md)
- [2026-05-27: Terminal Focus and Display Link Recovery](2026-05-27-terminal-focus-display-link.md)
- [2026-05-27: Model-Driven View Reconciliation](2026-05-27-model-driven-view-reconciliation.md)
- [2026-05-28: Pure Core Compiled Same-Module via Symlink, Tested via Nested Package](2026-05-28-core-module-via-symlink.md)
- [2026-05-28: Pure Core / Portable Support / Platform Runtime: a Purity-Enforced Three-Layer Split](2026-05-28-pure-core-support-split.md)
- [2026-06-09: AppKit / Ghostty Lifetime Safety](2026-06-09-appkit-lifetime-safety.md)
