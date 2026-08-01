# Control socket ownership is not a precondition of IpcServer

## Context

The concurrent-dev-instances migration moved socket open/close into
`DanTermSupport.ControlSocketListener`, which unlinks a path only while it still
owns it. That mechanism is correct and tested. Its callers are not.

`AppRuntime` constructs `IpcServer` unconditionally and binds afterwards, so an
`IpcServer` that lost the bind race still exists and still reports a
`socketPath` it does not own. Two defects follow:

- `AppRuntime#stopIpcServer` unlinks `ipcSocketPath` unconditionally, bypassing
  the ownership check entirely. **Reproduced:** with instance A serving slot 1, a
  second same-identity process B correctly refused to bind, and quitting B
  deleted A's live socket. A stayed alive holding the slot lock and became
  permanently unreachable (`danterm: DanTerm is not running`) -- worse than the
  pre-migration behavior, because the lock keeps a useless instance in the pool.
- `AppRuntime#ipcSocketPath` falls back to the shared path and feeds
  `DANTERM_SOCK` into every pane through `terminalLaunchEnvironment`. A
  non-owner's panes therefore advertise the owner's socket, so a bare `danterm`
  inside B controls A -- the wrong-instance accident this migration exists to
  prevent.

The second defect survives deleting the stray unlink, so the fix is at the type,
not the statement.

## Decision

Make socket ownership a precondition of `IpcServer` existing: it acquires its
listener during construction and fails to construct otherwise. An instance that
did not win the bind has no `IpcServer`, so there is no path for it to delete and
no socket path for it to advertise.

Consequences that follow from that shape:

- `ipcSocketPath` becomes optional, and socket targeting for an instance that owns
  no socket is fail-closed rather than merely omitted. Omission alone is not
  enough in either direction: the launch environment overlays onto the inherited
  one, so a non-owner launched from another instance's pane would pass that
  instance's `DANTERM_SOCK` straight through; and the CLI falls back to a
  path-derived socket when the variable is absent, so an unset variable inside a
  DanTerm pane still routes somewhere. Both ends close: the final child
  environment removes inherited socket targeting, and the CLI treats a process
  marked as running inside DanTerm but carrying no socket target as "no running
  instance" instead of applying its external-process fallback.
- The listener stops being actor-isolated state. It is an immutable handle after
  construction, so holding it non-isolated makes shutdown synchronously reachable
  without a semaphore on the main thread, and `close()` runs on clean quit.
- Path removal has exactly one owner, `ControlSocketListener`.

## Invariants

- **I1** A constructed `IpcServer` owns its bound socket; losing the bind yields
  no server rather than a server without a socket.
- **I2** Only the listener that bound a path removes it; no other code unlinks a
  control socket.
- **I3** A CLI invocation reaches its own instance when that instance owns a
  socket, reports no running instance when it is inside an instance that owns
  none, and keeps the identity-derived fallback when it is outside DanTerm
  entirely. It never reaches a different instance.
- **I4** An instance that owns no socket leaves a live owner serving, both while
  running and through its shutdown.

## Proof obligations

- **PO1** (I1, I4) With a live listener already on a path, a second server fails
  to construct, and taking that second instance through shutdown leaves the first
  still serving and its socket present.
- **PO2** (I3) The pane environment: the final environment handed to a pane of an
  instance owning no socket carries no socket target even when the app process
  itself inherited one, and a pane of an owning instance carries that instance's
  socket.
- **PO3** (I3) CLI socket selection across all three cases, since the fail-closed
  branch can regress the other two silently: an explicit non-empty target is
  used as given; the in-DanTerm marker with no target reports no running
  instance; neither marker nor target resolves the identity-derived fallback, so
  `danterm` from an ordinary terminal still works.
- **PO4** (I4) Stopping an owning server returns only after its socket is
  unreachable and the path it bound is gone.
- **PO5** (I2) Existing `ControlSocketListenerTests` coverage continues to hold:
  reclaiming an abandoned path, refusing a live one, concurrent reclaimers
  yielding one listener, and closing a superseded listener leaving the newer one
  serving.

PO1 is the regression that fails on today's code. Prefer a headless test that
opens a real `ControlSocketListener` on a temp path and drives the app's shutdown
path against it -- the bug reproduces without a GUI, a second app, or an
AppleScript quit, all of which are non-deterministic when two processes share a
bundle id.

## Non-goals

- No change to `ControlSocketListener` itself; its ownership logic is correct and
  covered.
- Not fixing same-identity double launch generally. Two processes sharing a
  bundle id remains possible (manual launch of a slot bundle, `open -n` on slot
  zero); this work makes the loser harmless, not impossible.

## Accepted risks

- **AR1** A clean quit that races process exit may still leave a socket file
  behind. Permitted: reclamation already covers abandoned paths and is tested,
  and it is the measured SIGKILL behavior today.

## Rejected ideas

- **RI1** Delete the unconditional unlink and stop -- fixes the deletion but
  leaves a non-owner advertising the owner's socket to its panes.
- **RI2** Keep the listener actor-isolated and block on a semaphore during
  `applicationWillTerminate` -- adds main-thread blocking and deadlock risk to
  reach state that does not need isolation.

## Critical files

`app/AppRuntime.swift` (`#stopIpcServer`, `#ipcSocketPath`, the `IpcServer`
construction in `#start`), `app/IpcServer.swift`, `app/AppDelegate.swift`
(`#applicationWillTerminate`), `lib/DanTermCore/.../TerminalLaunchEnvironment.swift`
and its pane-spawn call sites for the inherited-target scrub, `cli/main.swift`
(`#main`) for fail-closed socket selection, and `app-tests/` for the regression,
alongside `lib/DanTermSupport/.../ControlSocketListener.swift` (read-only
reference) and its existing tests.

The CLI's documented `DANTERM_SOCK` behavior changes, so
`integrations/danterm/SKILL.md` travels with the change.

## Verification

- `swift test --scratch-path .build-app-tests` and
  `swift test --package-path lib/DanTermSupport`.
- End to end: launch a slot, directly exec the same slot bundle a second time,
  confirm the second refuses the socket, quit it, and confirm the first still
  answers `danterm ls` with its socket intact -- the sequence that reproduced the
  defect.
- `just test` before handoff.

## Implementation discretion

- How the failed-bind path surfaces (throwing initializer versus failable), and
  where the non-isolated listener handle lives.

## Implementation notes

- A non-owning pane overrides inherited `DANTERM_SOCK` with an empty value rather
  than omitting it. The pinned libghostty surface environment API only overlays
  key/value pairs and cannot delete an inherited key; the CLI treats the empty
  value as no target and fails closed because `DANTERM=1` remains present.
