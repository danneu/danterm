# Decisions -- auditable decision log

### D1.1 -- drop TerminalPTYHost.recentOutput -> Deque

- Status: closed; do not prototype.
- Evidence: F2 in this investigation; research 17 F9, F14, and D5.
- Decision: keep the existing rolling Array. Complete deletion already measured
  the maximum possible benefit and found no attributable improvement. A Deque
  would preserve package-test Array projections while replacing only two lines
  of policy, so abstraction fit alone does not clear the adoption bar.
- Reopen only if new evidence identifies a changed workload or mechanism that
  invalidates research 17 F14/D5. The already-landed `DequeModule` dependency is
  not independent justification.

### D1.2 -- drop TerminalPTYHost.pendingEvents -> Deque

- Status: closed; no container prototype retained.
- Evidence: F3 and F4.
- Decision: keep the private Array FIFO. Although exit-before-EOF can
  structurally enqueue multiple committed-output chunks, every completed host
  in the 78-test representative selection observed a maximum depth of one. At
  that depth, head removal shifts no suffix, and Deque would delete no manual
  index, compaction, or ownership mechanism.
- Reopen only when an observed workload demonstrates sustained multi-event
  batches. The existing target dependency remains irrelevant to that verdict.

### D1.3 -- drop Terminal.ScrollbackBuffer -> Deque for this adoption pass

- Status: closed for this investigation; retain the prior deferred backlog.
- Evidence: F5; memory research 15 F4, D1, and its ring-buffer backlog; CPU
  research 17 F8.
- Decision: keep the current index-and-compact buffer. Deque would make the dead
  prefix unrepresentable and delete bookkeeping, but the shipped slot reset
  already removed the material memory defect, leaving about 27 KiB of row
  shells. The prior decision requires measured compaction cost or changed
  row-move economics before paying for a ring conversion, and neither exists.
  The conversion would additionally end TerminalCore's enforced import-free
  package architecture.
- Reopen on the conditions already recorded by memory research 15: a profile
  attributes material time to `compactIfNeeded`, another measurement names its
  copy, or a changed row representation materially changes move cost.

### D1.4 -- drop Terminal.tabStops -> BitSet

- Status: closed; no hot-core prototype or benchmark.
- Evidence: F6.
- Decision: keep `Set<Int>`. BitSet exactly matches ordered nonnegative tab-stop
  semantics and would remove repeated sorting, but the set is bounded by the
  terminal width, no profile names it, and the conversion alone would end
  TerminalCore's enforced import-free package architecture. That is
  disproportionate to the private mechanism removed.
- Reopen if a broader TerminalCore swift-collections dependency is independently
  justified, or if a current profile demonstrates material tab-stop navigation
  cost. Dependency plumbing shared only in a hypothetical future does not count.

### D1.5 -- drop mergedEnvironment -> OrderedDictionary

- Status: closed; prototype removed.
- Evidence: F7 and F8.
- Decision: keep the private Array merge loop. OrderedDictionary preserves the
  contract and passed the launch-policy suite, but the complete prototype was
  source-line neutral across the manifest and helper and introduced the full
  OrderedCollections module to PaneLifecycle for launch-only work. It therefore
  adds vocabulary and build surface without simplifying the repository.
- Reopen if environment merging becomes shared or materially larger, or if a
  measured launch cost makes linear lookup consequential.

### D2 -- retain all seven non-candidate rejections

- Status: closed; no prototype or implementation plan.
- Evidence: F1 and F9.
- Decision: keep the current representations for `pendingInput`,
  `TerminalDamageAccumulator`, CLI argument parsing, Kitty keyboard stacks,
  alerts, MRU tab order, and viewport/construction arrays. The detailed reasons
  differ: syscall contiguity, an already-specialized reusable bit layout,
  explicit small bounds, whole-list model operations, malformed-input repair,
  indexed access, and bulk construction. None is merely rejected because a
  dependency is absent.
- Reopen only under the site-specific conditions in README: a measured input
  retention/compaction cost with a viable segmented-write design; a current
  damage profile; materially larger parser, stack, alert, or tab scale; a model
  contract that forbids malformed MRU order at entry; or a concrete sustained
  FIFO construction site.
