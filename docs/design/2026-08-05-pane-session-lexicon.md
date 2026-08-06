# 2026-08-05: Pane and Session Lexicon

- Status: Accepted
- Date: 2026-08-05

## Context

DanTerm inherited `surface` from libghostty as a deliberately non-committal
name for a running terminal instance. That name suits a backend that does not
know whether its client presents a window, tab, split, or preview. DanTerm is
the higher-level runtime and does know: it places the running terminal in a
pane.

On macOS, `surface` also suggests graphics resources such as `IOSurface`, not
the PTY and child process owned by a running terminal. DanTerm's backend
boundary had already adopted `TerminalSession` and `TerminalSessionEvent`,
while core messages and runtime storage still used the inherited noun. The two
vocabularies obscured the actual model.

## Decision

A **pane** is a slot in DanTerm's split tree. It owns layout and user-facing
pane state, and it is addressed by `PaneId`.

A **session** is a running terminal: its PTY, child process, terminal state,
and host integration.

An **attached session** is bound to a pane. A **detached session** is running
without a pane. DanTerm has no durable detached sessions today.

The current steady state is one session per pane, keyed by `PaneId`. That 1:1
correspondence is a fact about the present implementation, not part of either
definition. Creation failure, close, and reconciled teardown can temporarily
leave a pane without a session or let a session outlive its pane.

DanTerm-owned identifiers use `session` for a running terminal and `pane` for
pane-scoped projections such as visibility. `surface` remains valid only for:

- graphics resources and geometry, including `IOSurfaceLayer` and bitmap test
  surfaces;
- ordinary English such as a public API surface or clipboard write surface;
- Ghostty adapter identifiers, including `ghostty_surface_t` and the bridge
  that wraps it.

## Consequences

- Core events, commands, reconciliation, runtime storage, and tests use the
  same session vocabulary as the terminal backend boundary.
- Adding multiple or detached sessions becomes an explicit model change,
  likely including a session identity, rather than another terminology pass.
- The rename does not change IPC methods or payloads, persisted snapshot
  fields, configuration keys, CLI behavior, or terminal byte output.

## References

- `lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift#TerminalSessionEvent`
- `app/TerminalBackend.swift#TerminalSession`
- `app/TerminalView.swift#SurfaceBridge`
- [Migration and app boundary](../../plan-terminal-engine/02-migration-and-boundary.md)
