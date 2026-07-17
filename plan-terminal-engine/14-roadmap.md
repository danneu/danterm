# Incremental Roadmap

## Status

This is the canonical high-level progress checklist for the terminal-engine
replacement. Check a milestone only when its behavioral exit criteria are met;
component proof obligations remain the source of truth for what those behaviors
mean.

## Roadmap

- [x] **1. Isolate the experiment and establish the terminal backend boundary**
  - Engine work begins on `experiment/swift-terminal-engine`; normal DanTerm
    development does not depend on the experiment before its viability decision.
  - The DanTerm-facing contract in
    [Migration and app boundary](02-migration-and-boundary.md) covers the
    lifecycle, input, output, inspection, config, and event capabilities the app
    consumes.
  - The ownership and effect boundaries in
    [Engine architecture and testability](03-engine-architecture.md) are in
    place without routing PTY bytes, grid state, or render damage through the
    top-level DanTerm model.
  - The existing Ghostty backend runs through that boundary without changing
    DanTerm pane, tab, split, alert, persistence, or IPC behavior.
  - Characterization fixtures record the current inspection and recovery
    behavior in [Inspection, search, and recovery](06-inspection-recovery.md)
    before the Swift backend replaces runtime text extraction.

- [ ] **2. Build the foundational headless terminal core and Unicode model**
  - The pure state machine in [Terminal core](04-terminal-core.md) handles the
    control, screen, mode, and style behavior required by the viability slice.
  - Its behavior is deterministic, independent of input chunking, and proven
    without a PTY, AppKit, or renderer.
  - The foundational contracts in
    [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md) pass for
    Spanish text, Chinese wide text, basic emoji, wide-cell mutations, hard and
    soft line identity, and primary-screen resize reflow.
  - Reflow preserves logical content, hard line boundaries, cursor attachment,
    and live/scrolled viewport anchors across the slice's width and height
    changes.

- [ ] **3. Integrate PTY process lifecycle**
  - [PTY and process lifecycle](07-pty-process-lifecycle.md) proves launch,
    ordered IO, environment, resize, EOF, exit, cancellation, and teardown with
    controlled child processes.
  - A headless pane can run a shell session without leaking resources or
    depending on rendering.

- [ ] **4. Prove the interactive viability slice**
  - One Swift-engine pane launches zsh, renders a recognizable prompt, accepts
    ordinary and dead-key-composed text, displays the required foundational
    Unicode cases, runs `ls`, `cat`, and `less`, and resizes with basic reflow.
  - Shell exit and pane closure release resources; idle and sleep/wake behavior
    satisfy the experiment gate in
    [Migration and app boundary](02-migration-and-boundary.md).
  - The slice is reproducible and its terminal-core behavior has deterministic
    proof at the lowest practical layer.

- [ ] **5. Make the experiment decision**
  - Evidence from the viability slice records whether the architecture is
    pleasant to extend and whether Unicode/reflow, PTY ownership, rendering,
    concurrency, lifecycle, and power behavior are tractable.
  - Explicitly choose to abandon the experiment, continue it, retain only
    independently useful infrastructure, or commit to the remaining replacement
    roadmap.

- [ ] **6. Complete required terminal behavior and interaction**
  - [Terminal core](04-terminal-core.md) completes the accepted baseline control,
    screen, mode, style, query, and recovery behavior.
  - [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md) completes
    selection/search/viewport anchors, primary- and alternate-screen resize
    behavior, and the fixed 10 MiB scrollback contract.
  - [Inspection, search, and recovery](06-inspection-recovery.md) preserves the
    characterized viewport/full-history, logical-line, selection, search, pane
    read, export, recovery text, and event-driven recovery-freshness behavior
    across reflow.
  - [Input and interaction](08-input-interaction.md) and
    [Renderer](09-renderer.md) provide an interactive pane with macOS text
    composition, terminal keys, mouse reporting, selection, safe paste,
    local wheel/scrollbar history navigation, clipboard writes, links, font
    fallback, colors, cursor behavior, and correct display scaling.
  - Logical damage and full redraw produce the same visible state.

- [ ] **7. Reach shell and baseline application compatibility**
  - zsh, bash, fish, ssh, fzf, more, and less complete the minimum workflows in
    [Testing and conformance](12-testing-conformance.md).
  - [Protocols and shell integration](10-protocols-shell-integration.md) proves
    the advertised terminal environment, current DanTerm shell events, title,
    cwd, notifications, progress, links, clipboard policy, capability manifest,
    bell behavior, and cross-component protocol limits.

- [ ] **8. Reach tmux, editor, and advanced TUI compatibility**
  - tmux, vim, neovim, btop, htop, lazygit, Claude Code, and Codex complete the
    minimum workflows in [Testing and conformance](12-testing-conformance.md).
  - Relevant workflows pass both directly and through tmux or ssh where those
    layers materially change terminal behavior.

- [ ] **9. Pass the replacement quality gates**
  - Every required component invariant has the behavioral proof required by
    [Testing and conformance](12-testing-conformance.md).
  - [Power and performance](13-power-performance.md) passes idle, hidden-pane,
    visible-output, recovery-freshness, sleep/wake, responsiveness, and teardown
    gates.
  - The Swift backend is suitable for sustained daily use without a required
    fallback to Ghostty.

- [ ] **10. Remove libghostty**
  - No required runtime, build, config, test, documentation, or release path
    depends on Ghostty.
  - The Swift engine is the sole terminal backend and the full DanTerm test gate
    remains green.

## Direction

Implementation must remain incremental and green. The experiment first proves a
narrow vertical slice rather than completing isolated subsystems to parity.
Each slice proves behavior at its lowest layer and carries the integration
evidence needed for any boundary it crosses. Temporary Ghostty coexistence is
allowed so the Swift backend can receive real-use feedback before cutover.

## Dependency constraints

- The product support matrix and DanTerm-facing backend boundary precede
  replacement cutover.
- Pure terminal semantics remain independently testable before renderer or PTY
  integration can count as proof of those semantics.
- Deterministic policy and lifecycle decisions remain independently testable at
  every effectful boundary before its system integration counts as proof.
- Unicode width, wide-cell invariants, hard/soft line identity, and reflow are
  foundational contracts rather than late rendering polish.
- Security policies for clipboard, links, paste, and terminal string limits are
  part of their first supported behavior.
- Power and teardown proofs travel with the first runtime integration; they are
  not post-parity optimization work.
- Passing the experiment viability gate permits a continuation decision but
  does not satisfy any omitted replacement proof obligation.
- Ghostty is removed only after the Swift backend satisfies every replacement
  proof obligation and the prioritized application gate.

## Replacement gate

The Swift backend can replace Ghostty when:

- all component invariants have behavioral proof
- the required compatibility applications complete the minimum workflows in
  [Testing and conformance](12-testing-conformance.md)
- direct, tmux, and ssh use work where relevant
- DanTerm's existing pane, tab, split, alert, persistence format, and IPC routing
  are unchanged, and the inspection/recovery text and event-driven freshness
  contracts pass
- idle, visibility, sleep/wake, and teardown requirements pass
- no required behavior depends on Ghostty at runtime or build time

## Non-goals

- Low-level task checklists or commit sequencing in this roadmap.
- Calendar estimates.
- Treating line count or feature count as progress independent of behavioral
  proof.

## Implementation discretion

- The implementation slices and commit boundaries within each milestone.
- Which compatible application first becomes the daily-use development host.
