# Terminal Core

## Problem

Terminal semantics must remain deterministic and thoroughly testable without a
PTY, AppKit, rendering, clocks, or platform callbacks.

## Decision

Under [Engine architecture and testability](03-engine-architecture.md), the
terminal core is a synchronous state machine. It consumes byte-stream input and
explicit state-change inputs, updates exclusively owned terminal state, and
produces ordered output bytes, damage, and semantic effects. PTY IO, scheduling,
rendering, and AppKit interaction live outside it.

The core owns the supported ANSI/ECMA-48, DEC, xterm, and selected modern
extension behavior required by the product contract, including:

- primary and alternate screens
- cursor movement, wrapping, tabs, margins, and scrolling regions
- insertion, deletion, erasure, and background-color erase semantics
- saved cursor and terminal modes
- 16-color, 256-color, and RGB presentation attributes
- bold, dim, italic, underline styles and color, reverse, hidden, and strike
- cursor style and application-requested blinking
- synchronized updates
- device, cursor, and mode queries needed for feature detection

Unknown, malformed, canceled, or truncated sequences are handled without
poisoning subsequent input.

## Invariants

- Identical input bytes and explicit inputs produce identical terminal state,
  output bytes, semantic events, and damage.
- Input chunk boundaries do not change behavior.
- The core performs no IO and reads no ambient time, process, AppKit, font, or
  display state.
- A core transition runs synchronously to completion and invokes no external
  callback.
- A cell mutation cannot leave invalid cursor, margin, wrap, or wide-cell state.
- Alternate-screen use does not add its transient content to normal scrollback.
- Synchronized updates suppress intermediate presentation without suppressing
  final state changes.

## Proof obligations

- Every supported control and mode has logical-state tests independent of
  rendering.
- Every parser behavior is invariant across representative and exhaustive split
  points in the input stream.
- Arbitrary byte input cannot crash, hang, or prevent later valid text from
  being processed.
- Query replies report only capabilities the engine actually implements.
- Full-screen application entry and exit restore the correct primary-screen
  state and scrollback.

## Non-goals

- PTY creation, child-process supervision, keyboard event interpretation, font
  shaping, pixel rendering, or user configuration parsing.
- VT52, printer, Tektronix, or terminal graphics emulation for the initial
  replacement.

## Implementation discretion

- Parser table structure and state representation.
- Damage representation and storage layout, provided the observable invariants
  hold.
