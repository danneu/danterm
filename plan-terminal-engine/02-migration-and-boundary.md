# Migration and App Boundary

> **Status, 2026-08-06: the migration described here is complete.** libghostty
> was removed at Milestone 10, so the backend coexistence and the selection
> facility this document plans for no longer exist -- there is one concrete
> backend and no `DANTERM_TERMINAL_BACKEND` variable. What remains normative is
> the narrow, product-specific terminal boundary itself and the reasoning for
> keeping it narrow. The body below is left as the record of the decisions that
> were made, not as a description of the current tree.

## Problem

A terminal replacement needs daily-use feedback before it reaches full parity,
but its feasibility is not yet proven and a permanent multi-backend product
would multiply testing and maintenance.

## Decision

Engine development begins on an isolated `experiment/swift-terminal-engine`
branch. Normal DanTerm development remains on its existing path until the
experiment passes the viability gate below and its outcome is explicitly
chosen.

DanTerm will expose a narrow, product-specific terminal boundary on the
experiment branch. Libghostty and the Swift engine may both implement that
boundary during development. Backend selection is a development facility, not
a promised user-facing feature.

The boundary covers the capabilities DanTerm consumes:

- session creation, closure, geometry, focus, and visibility
- text, key, paste, and mouse input
- selection, search, scrollback, and text capture
- theme and font application
- title, cwd, bell, notification, progress, process-exit, and render events

The boundary describes DanTerm needs rather than mirroring libghostty APIs.

Development targets an interactive vertical slice before broad protocol or
application parity. The first slice combines only enough terminal core, Unicode
grid, reflow, PTY, input, rendering, lifecycle, and power behavior to test the
architecture end to end.

## Experiment viability gate

The experiment is viable when one Swift-engine DanTerm pane can:

- launch an interactive zsh with a real PTY and working job control
- render a recognizable prompt with basic colors and cursor movement
- accept ordinary input and macOS dead-key composition
- display Spanish text, basic emoji, and Chinese wide text without corrupting
  the grid
- run representative simple commands including `ls`, `cat`, and `less`
- resize with basic reflow while preserving logical text and hard line breaks
- close the shell and pane without leaked or orphaned resources
- remain quiescent when idle and allow normal macOS sleep/wake behavior

Every terminal-core behavior used by the slice has deterministic proof at its
lowest practical layer. The slice is not required to support tmux, editors,
mouse reporting, OSC 52, hyperlinks, full xterm compatibility, or polished
rendering.

Passing this gate means the foundations are credible enough to extend. It does
not authorize replacement cutover. At the gate, the project explicitly chooses
to abandon the experiment, continue it, retain only independently useful
infrastructure, or commit to the full replacement roadmap.

## Invariants

- DanTerm model/update logic does not know which terminal backend owns a pane.
- A pane has one terminal owner at a time.
- Experimental engine work remains isolated until the viability decision.
- Terminal callbacks cannot outlive their pane host or message torn-down AppKit
  objects.
- Temporary backend coexistence does not require permanent behavioral parity
  testing after Ghostty is removed.
- Ghostty removal occurs only after the Swift backend satisfies the replacement
  proof obligations.

## Proof obligations

- The same DanTerm pane lifecycle scenarios pass against both development
  backends while both exist.
- Moving, hiding, focusing, resizing, and closing panes does not leak or
  double-own terminal resources.
- A backend creation failure follows the established DanTerm failure behavior.
- The Swift backend can be selected without changing persisted DanTerm model
  data.
- Current-backend characterization pins the inspection and recovery behavior in
  [Inspection, search, and recovery](06-inspection-recovery.md) before runtime
  text extraction moves to the Swift backend.
- The viability slice distinguishes terminal-state, PTY, renderer, lifecycle,
  and power failures well enough to make an evidence-based continuation
  decision.

## Rejected ideas

- Developing the unproven engine directly in normal DanTerm development: the
  experiment may be abandoned without destabilizing the current product.
- Completing broad protocol parity before producing an interactive slice: it
  would spend most of the project before answering the foundational viability
  questions.
- A generic abstraction over every libghostty call: it would preserve the shape
  of the dependency being removed.
- Shipping two permanent backends: there is no product requirement that
  justifies the continuing cost.

## Implementation discretion

- Whether development selection uses a build flag, environment value, or hidden
  preference.
- The concrete interface shape used by the app target.
- Whether the experiment branch uses a separate worktree and how it is kept
  current with normal DanTerm development.
- Commit boundaries within each experiment milestone.
