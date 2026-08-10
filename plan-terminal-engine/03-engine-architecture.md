# Engine Architecture and Testability

## Problem

Terminal correctness spans a high-volume byte stream, large mutable screen and
history state, process lifecycle races, AppKit input, rendering, and macOS side
effects. Routing all of that through DanTerm's top-level model would make the
application data path expensive, while callback-driven or ambient behavior
would make failures difficult to reproduce.

## Decision

The engine uses a functional-core, imperative-shell architecture and applies
Elm-style reduction at control boundaries.

Terminal semantics and pane-lifecycle decisions are synchronous deterministic
transitions over explicit inputs. They may mutate exclusively owned state in
place, but perform no IO, consult no ambient state, and invoke no external
callbacks. Each transition produces ordered effects or system commands as
values.

One serialized owner per pane applies lifecycle and terminal-state transitions
and interprets their results. Read-only render state may cross to AppKit;
mutable terminal state never has multiple owners. DanTerm's existing top-level
model receives product-level events such as title, cwd, bell, notification,
process exit, and creation failure. PTY byte batches, grid state, and render
damage remain within the pane session.

Effectful boundaries separate deterministic policy from system mechanism when
meaningful policy exists:

| Boundary | Deterministic policy | System mechanism |
|---|---|---|
| Keyboard | Normalized input and terminal modes determine encoded bytes | AppKit event and text-input translation |
| Paste | Text and terminal mode determine sanitized, bracketed bytes | Pasteboard access |
| Mouse | Position and modes determine reporting or local selection | AppKit pointer events |
| PTY | Lifecycle events determine ordered process and IO commands | macOS PTY and process APIs |
| Rendering | Snapshot, geometry, style, and damage determine drawing work | CoreText/CoreGraphics glyph and drawing operations |
| Power | Visibility, focus, activation, and damage determine scheduled work | AppKit timers and redraw requests |
| Links | Terminal data determines a validated link target | System URL opening |

Framework adapters normalize inputs or execute decisions; they do not silently
redefine engine policy. A direct system operation with no meaningful policy
does not require an artificial abstraction solely for mocking.

## Invariants

- Identical initial state and ordered explicit inputs produce identical final
  state and ordered effects.
- A state transition runs to completion before another input can observe or
  mutate that state.
- Each pane has one mutable terminal and lifecycle owner; renderers and app
  consumers receive read-only state.
- Deterministic policy performs no IO and reads no ambient clock, process,
  AppKit, font, display, clipboard, or workspace state.
- Effects remain explicit and ordered until interpreted at the system boundary.
- High-volume PTY, grid, and damage data does not enter DanTerm's top-level Elm
  model or command loop.

## Proof obligations

- Canonical terminal and lifecycle traces replay to identical final state and
  ordered effects.
- Launch, readiness, resize, EOF, exit, failure, and close orderings cannot
  expose partial state, duplicate effects, or leave ownership behind.
- Each effectful boundary proves its deterministic policy without the system
  mechanism and separately proves the real macOS adapter behavior that pure
  tests cannot establish.
- Concurrent runtime stress preserves the single-owner contract and never lets
  rendering or teardown observe partially applied state.
- App integration proves that terminal output and render damage stay on the
  pane data path while product-level terminal events still reach the DanTerm
  model.

## Non-goals

- Immutable copying of the screen or scrollback after every transition.
- Routing terminal bytes or cell mutations through DanTerm `Msg` values.
- Concurrency inside the terminal semantics reducer.
- A protocol or mock wrapper around every system call.

## Accepted risks

- Pure policy tests cannot prove macOS framework behavior. Narrow real-system
  integration tests remain required at every Apple-framework and PTY seam.

## Implementation discretion

- The concurrency primitive and read-only snapshot-transfer mechanism that
  realize the single-owner contract.
- Internal reducer, effect, render-plan, package, and storage representations.
