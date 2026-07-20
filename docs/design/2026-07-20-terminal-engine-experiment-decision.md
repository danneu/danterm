# 2026-07-20: Terminal Engine Experiment Decision (Milestone 5)

- Status: Accepted
- Date: 2026-07-20

## Context

The Swift terminal engine experiment was required to pass an explicit
viability gate before DanTerm invests in the broader replacement roadmap.
[Migration and app boundary](../../plan-terminal-engine/02-migration-and-boundary.md)
defines that gate and requires a deliberate choice at it: abandon the
experiment, continue it, retain only independently useful infrastructure, or
commit to the full replacement roadmap.

Milestone 4 closed on 2026-07-20 with a pass verdict recorded in
[Milestone 4 interactive viability evidence](../evidence/2026-07-20-milestone-4-viability.md):
a Swift-engine pane ran a real interactive zsh through the AppKit input and
rendering path, handled dead-key composition, Spanish/Chinese/emoji text,
`ls`/`cat`/`less`, byte-identical narrow/wide/narrow reflow, hidden-pane
output, idle quiescence, real sleep/wake, and leak-free teardown, with the
run's artifacts preserved and its primary recording replayed
deterministically in the default test gate.

This note is the Milestone 5 decision record. It evaluates that evidence,
records the architectural lessons and remaining risks, and makes the choice
the gate exists to force.

## Evidence evaluation

The gate asked whether each foundational area is tractable under this
architecture. Judged from the Milestone 2-4 proof and the viability run:

- **Unicode and reflow.** Tractable. Grapheme clustering, emoji width,
  wide-cell atomicity, hard/soft line identity, and width/height reflow walks
  are proven headlessly (Milestone 2, Slice 8 judgments in the
  [roadmap](../../plan-terminal-engine/14-roadmap.md)), and the live run
  reproduced the marker-bounded reflow region byte-identically across
  56x25 -> 90x25 -> 56x25.
- **PTY ownership.** Tractable. The single actor owner per pane, the
  `posix_spawn` bootstrap, ordered resize, EOF/exit convergence, and the
  teardown ladder are pinned by the Milestone 3 suites, and the viability run
  confirmed no leaked descendants, sockets, or session locks after both pane
  exit paths.
- **Rendering.** Tractable for correctness. The pure render-planner boundary
  produced a recognizable prompt, correct colors, and a correctly placed
  cursor through AppKit/CoreText, and hidden panes generated no render plans.
  Rendering throughput under sustained heavy output has not been measured;
  the correctness-first ordering treats that as later work, not a gate.
- **Concurrency.** Tractable. Serialized pane owners handing out `Sendable`
  snapshots survived rapid create/close and resize/close races, hidden
  output with delayed reveal, and application termination with live and
  mid-close hosts, without data races or use-after-teardown.
- **Lifecycle.** Tractable. Non-last-pane exit, last-pane quit confirmation,
  and application termination are pinned at the policy layer and were
  exercised live.
- **Power.** Tractable. The idle window recorded 0.01 s CPU against a 0.08 s
  limit with no render-plan events and no DanTerm-owned power assertion, and
  the pane returned to quiescence after a real lid-close sleep/wake.

**Is the architecture pleasant to extend?** Yes, on the evidence of its own
construction: Milestones 2-4 landed as sequential green slices, and each new
layer (parser, presentation, scrollback/reflow, PTY, render planner, session
controller, capture) composed onto the previous ones without reworking a
lower layer's contract. The viability workflow itself was automated with the
same seams the product uses.

### Testability findings

[External terminal test research](../research/1-external-tests.md) asked four
questions to answer at this decision:

- **Do real failures reduce cleanly to the byte-replay runner?** Yes. Live
  pane recordings decode into the neutral fixture format and replay
  headlessly; the checked-in Milestone 4 capture now runs in the default gate
  under authored, bytewise, and split chunking.
- **Do public logical snapshots diagnose grid failures without pixel
  output?** Yes. The live external cross-check compared pane-read text
  against the headless replay of `state-movecursor.json` and matched exactly;
  every fixture expectation is expressed through TerminalCore's public views.
- **Did imported cases expose ambiguities or force private coupling?** They
  exposed genuine contract differences without coupling. The pinned libvterm
  manifest covers all 31 selected files and records seven declared deviations
  with rationale (C1/overlong handling, combining-mark retention, scrollback
  push policy, semantic colors, SGR 58/59, string-state termination, pending
  wrap on edits). No expectation needed libvterm's storage or callback model.
- **Does a differential runner (Termless or similar) add enough value to
  maintain?** Not yet demonstrated. No Termless or vttest experiment was run
  during Milestone 4; the native corpus plus the live/headless cross-check
  diagnosed everything the slice needed. Differential replay remains an
  option to evaluate during Milestone 6, not a maintained dependency, per the
  research note's rule that external consensus never automatically blesses
  DanTerm output.

## Architectural lessons

- The pure terminal value plus the neutral byte-replay runner is the
  load-bearing asset. It turned a live app run into a deterministic
  regression fixture and let an end-to-end check assert byte equality with a
  headless replay. Every future subsystem should keep this reduction path.
- One serialized actor owner per pane with `Sendable` snapshots is the right
  concurrency shape. Races were found and pinned at the policy layer, not
  debugged in AppKit.
- Deterministic policy seams (lifecycle traces, render planning) kept the
  system adapters thin enough that the adapters needed almost no tests of
  their own.
- Recording deviations-with-rationale in a pinned manifest is what kept
  external corpora useful without making another emulator normative; the
  classification discipline should continue through the Milestone 6 and 7
  tranches.
- Opt-in, artifact-preserving app-control tests (`just
  test-terminal-viability`) coexist cleanly with a headless default gate;
  keeping the default gate headless remains the correct default.

## Remaining risks

Carried forward deliberately; none blocks continuation, all block cutover:

- The alternate screen is deferred, so `less` and every full-screen TUI run
  on the primary screen and pollute history. Milestone 6 must add it together
  with its resize behavior.
- OSC title/cwd events, mouse protocols, scrollback UI, selection/search,
  viewport anchoring across reflow, OSC 52 writes, and hyperlinks are
  unimplemented; DanTerm's own notification and shell-event integrations
  depend on several of them.
- Rendering performance under sustained output is unmeasured. Correctness
  first is the accepted ordering, but a fundamental throughput problem would
  surface late; Milestone 6 interaction work should watch for it.
- Evidence comes from one machine, one macOS version, one keyboard layout,
  and zsh only. Broader shells and applications are Milestone 7-8 work.
- The compatibility long tail (esctest2, vttest, tmux, editors) is untouched,
  as the roadmap intends at this stage.

## Decision

**Continue the experiment into Milestone 6. Do not commit to replacement
cutover yet.**

Of the four outcomes the gate permits: abandoning is unjustified because
every foundational area proved tractable; retaining only infrastructure is
unjustified for the same reason; committing now to the full replacement
roadmap is premature because the risks above are exactly what Milestones 6-9
exist to retire. Continuation preserves the option value the experiment
structure was designed for: work proceeds on the isolated
`experiment/swift-terminal-engine` branch, Ghostty remains the production
backend, and the replacement commitment stays gated on the Milestone 9
replacement quality gates.

## Consequences

- Milestone 6 (complete required terminal behavior and interaction) is the
  next body of work, starting from the risk list above.
- The viability gate's constraints stay in force: normal DanTerm development
  does not depend on the experiment, and backend selection remains a
  development facility.
- The neutral fixture runner, the libvterm classification manifest, and the
  pane-recording capture path are confirmed as durable infrastructure that
  Milestone 6-9 evidence will build on.
- Differential replay (Termless or similar) gets a concrete evaluate-or-drop
  point during Milestone 6 instead of an open-ended maybe.
- Passing the viability gate satisfies no replacement proof obligation; the
  [roadmap](../../plan-terminal-engine/14-roadmap.md) replacement gate is
  unchanged.

## References

- [Milestone 4 interactive viability evidence](../evidence/2026-07-20-milestone-4-viability.md)
- [Migration and app boundary](../../plan-terminal-engine/02-migration-and-boundary.md)
  (experiment viability gate and outcome menu)
- [Incremental roadmap](../../plan-terminal-engine/14-roadmap.md)
- [External terminal test research](../research/1-external-tests.md)
  (Milestone 5 testability questions)
