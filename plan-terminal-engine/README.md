# DanTerm Terminal Engine Plan

This directory is the planning home for the terminal engine DanTerm owns and
ships, implemented in Swift and Apple frameworks. On this branch the engine is
the only terminal backend: libghostty was removed at
[Milestone 10](14-roadmap.md), and Ghostty survives solely as an optional,
gitignored reference checkout under `references/ghostty` fetched by
`scripts/fetch-references.py`.

The documents here are still normative for ongoing engine work. The plan is
intentionally a set of component contracts rather than one large implementation
script. A claim belongs here only when changing it would alter observable
behavior, an invariant, or the architectural direction. Exact types, file
layouts, and algorithms remain implementation discretion until a later design
decision makes them load-bearing.

## What the engine is

DanTerm owns a macOS-only terminal engine that supports the shells and terminal
applications its users rely on, remains idle when no work is required, and is
developed incrementally behind a narrow DanTerm-facing boundary. The engine does
not inherit libghostty release timing, power behavior, configuration, or
architecture.

That outcome is reached rather than aspirational: DanTerm builds, runs, and
tests without libghostty, GhosttyKit, an xcframework, or Zig. What is still open
is quality work inside the engine DanTerm already ships -- Milestone 9's
power-and-performance gate is deliberately unchecked, and the component
contracts below remain the acceptance standard for every further change.

## Component plans

| Document                                                             | Scope                                                                      | Planning status            |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------- |
| [Product contract](01-product-contract.md)                           | Product scope, compatibility target, non-goals                             | Initial decisions captured |
| [Migration and app boundary](02-migration-and-boundary.md)           | DanTerm-facing terminal contract; record of the completed backend migration | Migration done; contract live |
| [Engine architecture and testability](03-engine-architecture.md)     | Reducer boundaries, ownership, effects, and pure policy seams              | Initial direction captured |
| [Terminal core](04-terminal-core.md)                                 | Pure parser, terminal state, modes, and semantic output                    | Initial direction captured |
| [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md)       | Grapheme behavior, widths, reflow, and retention                           | Initial decisions captured |
| [Inspection, search, and recovery](06-inspection-recovery.md)        | Observable terminal text, pane reads, selection/search, export, and replay | Initial decisions captured |
| [PTY and process lifecycle](07-pty-process-lifecycle.md)             | macOS child-process ownership and teardown                                 | Initial decisions captured |
| [Input and interaction](08-input-interaction.md)                     | Keyboard, IME, mouse, selection, paste, clipboard, and links               | Initial decisions captured |
| [Renderer](09-renderer.md)                                           | Correctness-first AppKit/CoreText rendering                                | Initial decisions captured |
| [Protocols and shell integration](10-protocols-shell-integration.md) | TERM contract, escape protocols, and DanTerm events                        | Initial decisions captured |
| [Configuration and themes](11-configuration-themes.md)               | Baked defaults and future DanTerm-owned formats                            | Initial decisions captured |
| [Testing and conformance](12-testing-conformance.md)                 | Behavioral proof strategy and compatibility gates                          | Initial direction captured |
| [Power and performance](13-power-performance.md)                     | Idle, visibility, sleep/wake, and responsiveness contracts                 | Initial decisions captured |
| [Incremental roadmap](14-roadmap.md)                                 | Canonical high-level progress checklist and replacement gate               | Milestones 1-8 and 10 done; 9 open |
| [Open questions](15-open-questions.md)                               | Decisions intentionally left for the next planning rounds                  | Active                     |

## Decisions already fixed

- The engine is macOS-only and DanTerm-only.
- Swift and Apple frameworks are allowed. Third-party dependencies require a
  specific justification.
- Ghostty compatibility is not a goal for config, themes, keybindings, or
  internal architecture.
- DanTerm ships exactly one terminal backend. Development ran Ghostty and the
  Swift engine behind the same narrow app boundary for a time; that coexistence
  ended when libghostty was removed, and the boundary is now a single concrete
  backend.
- Engine development began on an isolated `experiment/swift-terminal-engine`
  branch, which it had to pass an explicit interactive viability gate to leave.
  The work still lives on that branch; `master` has not taken the removal yet.
- The engine uses Elm-style reduction at control boundaries: deterministic
  terminal and lifecycle policy produces ordered effects, while one serialized
  owner per pane interprets them outside DanTerm's top-level model.
- Effectful boundaries separate deterministic policy from Apple-framework and
  PTY mechanisms wherever meaningful policy exists.
- Each pane's PTY, process lifecycle, and terminal composition have one Swift
  actor owner bound to a serial dispatch-queue executor; read-only consumers
  receive `Sendable` terminal value snapshots.
- PTY children launch through `posix_spawn` plus a tiny single-threaded
  bootstrap that establishes the child session, controlling terminal,
  foreground process group, standard streams, cwd, and final `execve` without
  forking the multithreaded app process.
- Correctness comes before rendering performance.
- `TERM=xterm-256color` is the initial advertised identity; [DanTerm's
  documented capability contract](../docs/terminal-capabilities.md) is
  normative across supported terminfo variants.
- Reflow on resize, Spanish text, Chinese text, basic emoji, links, clipboard,
  and mouse support are required before replacement.
- Bidirectional/RTL layout, terminal image protocols, VoiceOver, ligatures, and
  preserving or reconnecting to live child processes are outside the initial
  replacement.
- Scrollback has a fixed 10 MiB per-pane budget.
- The engine uses baked-in defaults first; configuration is added only for
  demonstrated needs.
- The power contract requires quiescence when no visible behavior requires
  work.

Passing the experiment gate proves that the architecture is worth extending;
it does not prove replacement readiness. Replacement still requires the full
component, compatibility, and quality gates in the roadmap.

## Performance optimization index

The engine began with intentionally straightforward implementations. This
index records the places where profiling justified additional complexity so a
future reader can distinguish deliberate performance machinery from incidental
cleverness. Percentages are approximate reductions in median duration measured
when each change landed, relative to the code immediately before it rather than
to the original naive baseline. They are historical orientation, not
reproducible measurements or permanent performance guarantees; a current claim
comes from `just benchmark-quick` / `just benchmark-confirm`.

- **[Bounded damage bitset](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 20% faster core feed.** A reusable viewport-
  row bitset replaced per-scalar `Set<Int>` allocation, hashing, and union while
  preserving the public `TerminalDamage` value. The trade-off is separate
  internal and consumer-facing damage representations, with set materialization
  deferred until drain.
- **[Packed Unicode lookup and cached look-behind class](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 31% faster core feed after the damage change.** One generated
  two-stage lookup replaced repeated binary searches for width, emoji
  properties, and grapheme-break class, and the segmenter now retains the
  preceding class. The trade-off is a larger generated table and a less direct
  classification path.
- **[Generation counters for change detection](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- no measured core-feed gain on styled redraw.** Monotonic generations
  replaced whole-`Terminal` copies for pending-work detection and repeated
  O(history) string comparisons for recovery notifications. Styled redraw was
  about 1% slower than the preceding result, within the role of this slice as a
  scrollback-specific fix. The saved results do not include an immediately
  preceding scrollback run, so no isolated scrollback percentage is claimed.
  The trade-off is explicit mutation accounting and conservative history-change
  signaling.
- **[Inline single-scalar grid cells](../plans/impl/2026-07-22-1736-terminal-core-feed-throughput-recovery.md)
  -- about 2% faster core feed than the prior best result.** Empty and
  single-scalar clusters stay inline while multi-scalar graphemes spill to an
  array. The trade-off is a specialized three-case storage representation and
  more involved upgrade and downgrade paths.
- **[Sparse AppKit damage retention](../plans/impl/2026-08-01-2219-preserve-sparse-appkit-terminal-damage.md)
  -- about 65% less direct draw time and 8% less whole-process CPU in the final
  two-distant-row acceptance run.** The view retains and merges exact engine
  damage until `draw(_:)`, then clips both the frame plan and graphics context
  to maximal contiguous sparse-row spans instead of AppKit's bounding dirty
  rectangle. Per-row clip rectangles initially doubled CPU during controlled
  btop scrolling; span coalescing restored CPU to equivalent or better than the
  parent and remained no slower at the 17-span maximum for the measured 179x66
  grid. The trade-off is an explicit view-owned full-invalidation path plus
  benchmark-only topology accounting; the percentages describe a controlled
  distant-row workload, not a calibrated general verdict.

## Branch and worktree workflow

The experiment lives on the required `experiment/swift-terminal-engine`
branch. When normal DanTerm maintenance will continue in parallel, the
recommended working arrangement is a linked Git worktree for that branch:

```text
~/Code/danterm/                  full DanTerm checkout on master
~/Code/danterm-terminal-engine/  full DanTerm checkout on experiment/swift-terminal-engine
```

The second directory is not a separate repository and does not contain only
the engine. It contains the entire DanTerm tree so the experiment can change
the engine, app boundary, AppKit integration, tests, and build together. The
two directories share Git objects, commits, branches, and tags, while each has
its own checked-out files, index, uncommitted changes, and build products.

Create the arrangement from the normal DanTerm checkout with:

```sh
git worktree add -b experiment/swift-terminal-engine \
  ~/Code/danterm-terminal-engine origin/master
```

Regular bug fixes continue in `~/Code/danterm`. After a fix lands on `master`,
merge `master` into the experiment from the engine worktree so the original
fix commits and all intervening maintenance travel together:

```sh
cd ~/Code/danterm-terminal-engine
git merge master
```

Use `git cherry-pick <commit>` only when intentionally porting one isolated
commit without the other changes on its source branch. Compare the current
trees with `git diff master experiment/swift-terminal-engine`, and compare
their commits with `git log --left-right --graph --oneline
master...experiment/swift-terminal-engine`.

Implementation proceeds incrementally through the milestones in
[the roadmap](14-roadmap.md). Check off a milestone only on the experiment
branch and only after its behavioral exit criteria and referenced proof
obligations pass. A worktree is operational convenience rather than an
architectural requirement; the isolated experiment branch is the requirement.

## Planning rule

Every component plan states behavioral proof obligations. Those obligations are
the eventual acceptance contract; they do not prescribe test file placement,
helper APIs, or case-by-case implementation choreography.
