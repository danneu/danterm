# Product Contract

## Problem and desired outcome

DanTerm currently depends on libghostty for terminal semantics, PTY ownership,
input, and rendering. Waiting for upstream releases delays fixes, and upstream
runtime behavior can conflict with DanTerm's macOS power requirements.

DanTerm will own a terminal engine whose supported behavior is explicit,
testable, and independently releasable.

## Decision

The engine is a DanTerm component for macOS, not a general-purpose terminal
framework or cross-platform product.

The replacement compatibility target, in priority order, is:

1. zsh, bash, and fish
2. ssh
3. tmux
4. vim and neovim
5. fzf
6. more and less
7. btop and htop
8. lazygit
9. Claude Code
10. Codex

Apple frameworks are allowed. A third-party dependency is admitted only when
its concrete benefit outweighs its release, security, maintenance, and
integration costs.

Existing terminal implementations may inform the design and serve as test
references, but no implementation is normative. DanTerm remains free to choose
the behavior and architecture that best satisfy this contract.

## Invariants

- Product behavior outside the terminal surface, including tabs, groups,
  splits, alerts, persistence, and IPC, remains owned by DanTerm.
- The supported terminal contract is finite and documented; unsupported legacy
  behavior is not silently treated as a future requirement.
- The engine is replaceable at the DanTerm runtime boundary without making the
  pure DanTerm model depend on terminal implementation details.
- A pane that cannot create its terminal process fails through DanTerm's
  existing pane lifecycle rather than leaving a ghost pane.
- Untrusted terminal output cannot grow retained per-pane state or pending work
  without an explicit bound.

## Proof obligations

- The prioritized compatibility applications complete the minimum daily-use
  workflows in [Testing and conformance](12-testing-conformance.md) without
  display, input, resize, or teardown failures.
- Existing DanTerm tab, split, alert, persistence format, and IPC routing remain
  unchanged when the terminal backend changes; observable terminal text and
  event-driven checkpoint freshness follow the explicit inspection and recovery
  contract.
- Unsupported control sequences fail safely and do not corrupt subsequent
  terminal parsing.
- Oversized control strings, metadata, semantic-event bursts, replies, and damage
  are discarded or coalesced within the end-to-end resource policy without
  corrupting later terminal input.

## Non-goals

- Cross-platform support.
- A reusable public terminal-engine API.
- Complete emulation of every historical DEC, xterm, or vendor extension.
- Ghostty config, theme, keybinding, or implementation compatibility.
- Bidirectional or RTL layout, terminal image protocols, VoiceOver, ligatures,
  or preserving or reconnecting to child processes across DanTerm restarts.

## Accepted risks

- The initial support matrix is narrower than mature terminal emulators. This
  is accepted because explicit compatibility can grow from measured needs.
- Apple-framework reliance limits portability. Portability is not a product
  objective.

## Implementation discretion

- Internal package count and source layout.
- The process for proposing and admitting future compatibility features.
