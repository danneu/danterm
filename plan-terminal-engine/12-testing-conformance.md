# Testing and Conformance

## Problem

Terminal compatibility spans byte parsing, state transitions, Unicode, PTY
behavior, input encoding, rendering, AppKit integration, lifecycle, and power.
No single reference emulator or screenshot suite proves the replacement.

## Decision

"Fully tested" means that every behavior in the declared support matrix has a
deterministic behavioral proof at the lowest appropriate layer, with integration
and real-application evidence for the seams between layers.

The proof strategy includes:

- parser and terminal-state fixtures
- canonical ordered trace replay for terminal and pane-lifecycle inputs,
  resulting state, commands, and effects
- input-chunk boundary invariance
- invariant/property tests that validate state after each transition, plus
  arbitrary-byte fuzzing
- pinned official Unicode segmentation and width fixtures
- logical terminal snapshots rather than screenshots for semantic behavior
- differential traces against Ghostty where Ghostty behavior is intentionally
  retained
- current-backend characterization of viewport/full-history text, selection,
  search, pane reads, export, and recovery before their runtime boundary moves
- controlled real-PTY integration tests
- deterministic render-planning tests and a focused AppKit/CoreText snapshot
  suite
- deterministic policy tests at effectful boundaries plus narrow real-system
  tests for their adapters
- AppKit interaction and lifecycle tests
- representative workflows for the prioritized compatibility applications
- performance, idle, visibility, sleep/wake, and teardown regressions

TDD remains the development rule: a new supported behavior begins with a test
that fails for the expected reason.

The experiment viability gate is a narrower proof package than replacement.
It proves the end-to-end architecture with one interactive shell slice while
keeping each terminal-core behavior in that slice deterministic and headless.
Passing it does not imply protocol or application parity.

### Minimum compatibility workflows

Every named application must complete the minimum user task below. Each
workflow includes launch, representative input and output, resize while active,
and clean exit/teardown; direct, tmux, and ssh variants are required where those
layers materially change the behavior. Fixture data, automation, and scripts
remain implementation discretion, but the tasks and outcomes are replacement
gate inputs.

| Application | Minimum user task and expected outcome |
|---|---|
| zsh, bash, fish (each) | Edit and execute a pipeline, exercise completion and foreground/background/stop/resume job control, and return to a usable prompt. |
| ssh | Connect to a controlled host, run colored and Unicode terminal output, resize the remote session, and disconnect without leaving local ownership behind. |
| tmux | Create a session, split and switch panes, resize, use mouse and copy-mode history navigation, then detach or exit with the outer terminal restored. |
| vim, neovim (each) | Open, edit, and save a file containing Spanish, Chinese, and emoji text; switch modes, navigate, resize, and exit with the shell restored. |
| fzf | Filter Unicode candidates, navigate the result list, resize, and accept the intended item. |
| more, less (each) | Page and search a long file, navigate in both directions across a resize, and quit to an intact prompt. |
| btop, htop (each) | Run the updating dashboard, navigate an interactive control, resize without stale regions, and quit cleanly. |
| lazygit | Open a controlled repository, navigate panels, inspect a diff, stage and unstage a change, resize, and quit without display corruption. |
| Claude Code, Codex (each) | Edit and submit a prompt, receive streaming formatted and tool output, operate an interactive choice or approval, browse prior output, resize during activity, interrupt work, and exit cleanly. |

## Invariants

- Tests assert observable behavior and architecture boundaries, not private
  helper structure.
- Logical terminal correctness can be proven without AppKit or pixel rendering.
- Differential tests do not make every Ghostty behavior normative.
- Every externally meaningful limit and security policy has boundary coverage.
- A compatibility claim is not complete until its input, output, resize, and
  teardown behavior are exercised where applicable.

## Proof obligations

- Each invariant in every component document maps to at least one behavioral
  proof before the replacement gate passes.
- Parser fuzzing demonstrates recovery to later valid input, not only absence of
  crashes.
- PTY integration proves byte ordering, resize, exit, cleanup, and exactly-once
  initial shell input and recovery replay with controlled child processes.
- Terminal and lifecycle traces replay to identical ordered effects and final
  state; launch, resize, EOF, exit, failure, and close interleavings cannot
  produce duplicate effects or partial ownership.
- Inspection tests distinguish logical lines from visual rows and pin soft
  wraps, spaces, final newlines, selection/search, and persistence normalization
  across reflow.
- Renderer tests distinguish semantic grid failures from pixel-placement
  failures.
- Each effectful boundary proves its deterministic policy without the system
  adapter and separately proves the real adapter behavior that pure tests
  cannot establish.
- The prioritized applications complete documented workflows both directly and,
  where relevant, inside tmux and ssh.
- Power tests demonstrate quiescent idle and stopped rendering for hidden panes.
- The experiment viability slice can be reproduced without depending on
  unrecorded manual state, and failures can be assigned to the terminal core,
  PTY, renderer/input, lifecycle, or power boundary.

## Accepted risks

- Differential testing can reproduce reference bugs. Ghostty output is evidence,
  not authority; protocol specifications and the DanTerm contract decide intended
  behavior.
- Pixel snapshots can vary with system fonts. They remain narrowly scoped to
  geometry and rendering claims that logical snapshots cannot prove.

## Implementation discretion

- Test target layout, fixture serialization, fuzzing tool, and corpus storage.
- Fixture content, automation, and script mechanics for the fixed minimum
  compatibility workflows.
