# Design Decisions

DanTerm design notes record durable architecture and lifecycle decisions. They
use a lightweight ADR shape so future changes can see the context and tradeoffs
behind the current behavior.

## Format

Design note filenames use:

```text
YYYY-MM-DD-slug.md
```

Each note opens with a title, then a front-matter bullet list, then the body
sections:

```markdown
# Title

- Status: Accepted
- Date: 2026-08-06

## Context
## Decision
## Consequences
## References
```

Write the front matter as a plain markdown bullet list, exactly as shown. The
field names carry no backticks.

`Status` is one of:

- `Accepted` -- the decision binds today.
- `Superseded` -- a later note replaced the decision. The note must also carry
  a `Superseded by` field that links to that note.
- `Draft` -- the decision is not settled yet.

Three optional fields link notes to each other, and each is a markdown link to
another note: `Superseded by`, `Supersedes`, and `Extended by`. A note that
retired more than one predecessor repeats `Supersedes`, one bullet per note.
`Supersedes` and `Superseded by` are two views of one fact, so both notes carry
their half.

`scripts/docs-lint.py` checks all of this, plus that the note list below names
every note exactly once with the status the note itself carries.

A note whose decision still binds, but whose body names code that is gone,
stays `Accepted` and adds an `Amended` field. The field gives the date and one
sentence; a block quote at the top of the note gives the detail. Use this
instead of `Superseded` when the mechanism died and the rule did not, because
calling such a note superseded would retire a rule that is still in force.

## Notes

Newest last. Each row gives the note's status, so you can see whether it binds
without opening it.

- [2026-03-05: Display Scaling](2026-03-05-display-scaling.md) -- Accepted.
  Amended 2026-08-06: the mechanism went with libghostty, the invariant holds.
- [2026-05-27: Terminal Focus and Display Link Recovery](2026-05-27-terminal-focus-display-link.md)
  -- Superseded by [2026-08-06: The Swift Terminal Engine](2026-08-06-swift-terminal-engine.md).
- [2026-05-27: Model-Driven View Reconciliation](2026-05-27-model-driven-view-reconciliation.md) -- Accepted.
  Amended 2026-08-13 and 2026-08-16; extended by
  [2026-08-16: Model-Owned Pane Geometry](2026-08-16-model-owned-pane-geometry.md).
- [2026-05-28: Pure Core Compiled Same-Module via Symlink, Tested via Nested Package](2026-05-28-core-module-via-symlink.md)
  -- Accepted. Amended 2026-08-06: two GhosttyKit details in the body are gone.
- [2026-05-28: Pure Core / Portable Support / Platform Runtime: a Purity-Enforced Three-Layer Split](2026-05-28-pure-core-support-split.md)
  -- Accepted. Amended 2026-08-06 and 2026-08-12.
- [2026-06-09: AppKit / Ghostty Lifetime Safety](2026-06-09-appkit-lifetime-safety.md)
  -- Accepted. Amended 2026-08-06: the Ghostty half of rule 5 is gone.
- [2026-07-20: Terminal Engine Experiment Decision (Milestone 5)](2026-07-20-terminal-engine-experiment-decision.md)
  -- Superseded by [2026-08-06: The Swift Terminal Engine](2026-08-06-swift-terminal-engine.md).
- [2026-07-27: Benchmark Routing for Damage-Scoped Render Changes](2026-07-27-damage-render-benchmark-routing.md) -- Accepted.
- [2026-07-29: Cross-Module Dispatch on Hot Value Types](2026-07-29-cross-module-value-dispatch.md) -- Accepted.
- [2026-07-31: Nix-Managed Config Location](2026-07-31-nix-managed-config-location.md) -- Accepted.
- [2026-08-01: OSC 133 Prompt Anchoring](2026-08-01-osc-133-prompt-anchoring.md) -- Accepted.
- [2026-08-05: Pane and Session Lexicon](2026-08-05-pane-session-lexicon.md) -- Accepted.
- [2026-08-06: The AppKit UI Harness Is a Whole-Module Substitution Seam, Not a Test Target](2026-08-06-ui-harness-whole-module-substitution.md) -- Accepted.
- [2026-08-06: The Swift Terminal Engine -- Migration Record and Decision Register](2026-08-06-swift-terminal-engine.md) -- Accepted.
- [2026-08-10: Terminal-Reported Pane Facts -- the Model Owns Values, the Stream Owns Lifecycles](2026-08-10-terminal-reported-pane-facts.md)
  -- Superseded by [2026-08-10: Session-Owned Terminal-Reported Facts](2026-08-10-session-owned-terminal-reported-facts.md).
- [2026-08-10: Session-Owned Terminal-Reported Facts](2026-08-10-session-owned-terminal-reported-facts.md) -- Accepted.
- [2026-08-16: Model-Owned Pane Geometry](2026-08-16-model-owned-pane-geometry.md) -- Accepted.
- [2026-08-17: The Test-Seam Rule -- a Component Never Asks Whether It Is Under Test](2026-08-17-test-seam-rule.md) -- Accepted.
