# PTY and Process Lifecycle

## Problem

Each terminal pane needs a correctly configured macOS pseudo-terminal and child
process whose ownership, resize behavior, exit, and teardown are independent of
the pure terminal core.

## Decision

DanTerm owns one local PTY session per live terminal pane. The PTY layer is a
macOS side-effect boundary responsible for child launch, byte IO, terminal
geometry, process-group behavior, exit observation, and cleanup.

Lifecycle decisions are deterministic transitions over explicit events that
produce ordered system commands. A single serialized owner per pane applies
those transitions and terminal-core inputs; the macOS boundary executes the
commands and returns their outcomes as new events.

The initial architecture keeps the current recovery process model: a DanTerm
restart creates new processes and may replay saved scrollback under the
event-driven freshness contract in
[Inspection, search, and recovery](06-inspection-recovery.md). DanTerm does not
preserve or reconnect to child processes across a restart.

An ordinary interactive pane launches the user's account shell from the macOS
account database as a login shell, with `/bin/zsh` and then `/bin/sh` as
fallbacks when the account shell is unavailable. Its `argv[0]` has the login
shell form and it receives no additional shell arguments. DanTerm's existing
`--cmd` and restore behavior still send initial input to that shell rather than
silently changing the pane into a different process-launch mode.

The child working directory is the pane's requested directory when it exists
and is accessible, otherwise the account home directory, otherwise `/`. The
child inherits the app process environment, with the advertised terminal
variables and pane-scoped `DANTERM_*` values set by DanTerm overriding inherited
values.

The shell starts in a new session with the slave PTY as its controlling
terminal, standard streams attached to that slave, and its process group in the
foreground. Closing a pane never deliberately detaches the session: DanTerm
hangs up the PTY and terminates every process that remains in the owned session,
including foreground, background, stopped, and hangup-resistant jobs,
escalating from ordinary hangup/termination to forced termination after bounded
grace periods. A process that deliberately daemonizes out of the owned session
is outside this contract. Orderly application termination applies the same
bounded teardown to every live pane. After an abrupt DanTerm crash, macOS closes
the PTY master and ordinary terminal hangup applies, but no in-process
escalation can run.

When the shell exits on its own, the PTY layer reports its status once and the
existing `surfaceClosed` pane lifecycle decides the resulting pane, tab, and
last-window behavior. The terminal surface does not remain as a new
process-exited holding state.

## Invariants

- A pane has at most one live PTY session and process owner.
- PTY reads preserve byte order presented to the terminal core.
- Geometry changes update PTY rows and columns and notify the child according
  to macOS terminal behavior.
- Closing a pane terminates its owned PTY session without detaching it or
  affecting sibling panes.
- Orderly application termination performs bounded teardown for every owned PTY
  session.
- Process exit is reported once and cannot race into a torn-down pane host.
- Background and occluded panes continue consuming PTY output even when they do
  not render it.
- No observer can see a partially applied lifecycle or terminal-core
  transition.

## Proof obligations

- Controlled child processes observe shell selection and login argv, cwd
  fallback, inherited and DanTerm-specific environment, controlling-terminal
  and foreground-process-group ownership, rows, columns, resize notification,
  input bytes, EOF, and exit status.
- Lifecycle traces cover launch, readiness, resize, EOF, exit, failure, and
  close orderings without duplicate commands, detached ownership, or partial
  state.
- Pane close and orderly application termination prove hangup and bounded
  escalation for a shell, foreground job, background job, stopped job,
  hangup-resistant job, ssh, and tmux without leaving any non-daemonized process
  in a targeted session alive; pane close does not touch a sibling session.
- A controlled app/PTY seam proves that `--cmd`, restore prefill, restore
  execute, and recovery replay are delivered to the ordinary interactive login
  shell exactly once, with their specified execute-versus-prefill newline
  behavior, rather than being dropped, duplicated, or used as a direct process
  launch mode.
- Rapid create/close and resize/close races leave no live file descriptors,
  child owners, or callbacks into deallocated state.
- Large and fragmented output reaches the terminal core in order without
  deadlock or unbounded buffering.
- Sleep/wake and app activation changes do not lose PTY data or duplicate
  process-exit events.

## Non-goals

- A process broker, daemon, or session-survival service.
- Cross-platform PTY APIs.
- Shell integration semantics, which are terminal protocol and DanTerm concerns.

## Accepted risks

- Abrupt-crash orphan risk: without an external process broker, a
  hangup-resistant background process may be reparented and survive after
  DanTerm crashes; this is accepted to keep session supervision outside the
  product.

## Implementation discretion

- The macOS launch and IO APIs used.
- The concurrency primitive that realizes the required single ordered owner and
  transfers read-only render state safely to AppKit.
- Exact grace-period durations and process-observation mechanism, provided
  close remains bounded and satisfies the termination contract.
