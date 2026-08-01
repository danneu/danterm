# Concurrent DanTerm Dev instances

## Problem

Agents need to build and drive their own `DanTerm Dev.app` while the user runs
theirs, with notification clicks landing in the instance that posted them. Today
every dev build shares one identity, so concurrent instances collide silently.

Load-bearing premises, all verified in-tree:

- The control socket (`DanTermProtocol/SocketPath.swift#controlSocketPath`) and
  the recovery dir + session lock (`DanTermSupport/RecoveryStore.swift#recoveryDirectoryURL`)
  are already pure functions of the bundle id. Distinct ids isolate them for free.
- Notification click routing depends on **nothing but the bundle id**. The payload
  carries only an `alertId` and `AppDelegate#userNotificationCenter(_:didReceive:)`
  does no cross-checking, so the OS hands the click to whichever process owns the
  id. No directory- or HOME-based scheme can redirect it.
- `IpcServer#openListenSocket` unlinks before bind, and `#stop` unlinks
  unconditionally: a second instance steals a live socket, and the first to quit
  deletes the survivor's.
- `AppRuntime#scrollbackReplayDirectoryURL` is not identity-keyed, and
  `#cleanupStaleReplayDirectory` wipes the whole shared directory at launch.
- `SwiftTerminalBackend#init(bundle:)` enables flight-tape recording by comparing
  the bundle id to a literal, so any new identity silently loses `pane tape`.
- `dev-build.sh` kills by executable name (every instance, from any working copy)
  and installs to one shared path.
- `scripts/tests/danterm-cli_test.sh` assumes a singleton in four places.
- The dev build is signed with a real identity, so a bundle's id cannot be
  rewritten after signing: **identity must be chosen before launch.**
- macOS ships no `flock(1)` (only `lockf`/`shlock`, neither exec-preserving), and
  LaunchServices does not pass file descriptors -- so an inherited-lock claim
  requires a direct exec, not `open`.
- `fstat` on a bound listening socket never matches `stat` of its path (measured:
  distinct device and inode). Socket ownership must be recorded at bind time.
- **Measured end to end:** a bundle cloned, re-identified, re-signed, and started
  by direct `execv` registers as a notification client under its own display name,
  delivers notifications, and routes clicks to itself; the grant then survives
  replacing and re-signing that bundle in place. Direct exec costs nothing in
  notification behavior, so the inherited-lock claim is viable.
- A direct exec inherits the launching process's environment, where `open` gets
  one from launchd. DanTerm already overwrites its own pane-scoped `DANTERM`,
  `DANTERM_SOCK`, and `DANTERM_PANE` values through
  `TerminalLaunchEnvironment.swift#terminalLaunchEnvironment`, so inherited
  values for those names do not misroute pane commands. Unmanaged launcher state
  still leaks: measured `CLAUDE_CODE_CHILD_SESSION` reached a slot pane and
  silently disabled Claude Code transcript saving.
- `pgrep -x` matches an extended regex, not a literal: `pgrep -x "DanTerm Dev (3)"`
  silently matches nothing because the parentheses are a capture group.

## Decision

Identity is a **bundle id drawn from a small fixed pool**. The bare
`com.danneu.danterm-dev` is slot 0 and stays the user's personal app, never
claimed. Slot N uses bundle id `com.danneu.danterm-dev.N`. Slot instances are
named distinctly (`DanTerm Dev (3)`), including the executable name, so
process-targeted tooling can name one instance.

A launcher claims a free slot by taking an exclusive lock, then stages a signed
clone of the canonical `.build` bundle for that slot and execs it so the app
inherits the lock. The kernel releases the lock on any death, including SIGKILL,
so there is no reaping, pidfile, or garbage collection.

Decisive constraints:

- Slot state -- locks and staged bundles -- lives at a **single user-global
  location, independent of the working copy**. Worktree-local slot state would let
  two agents in two checkouts both claim slot 1, which is the collision the pool
  exists to prevent.
- Identity resolution is consolidated behind one seam in `DanTermProtocol`, the
  only module both consumers may depend on. Changing how instances are named is
  then one edit.
- Socket open/close moves out of `app/` into `DanTermSupport` (portable side
  effects, no AppKit) so its behavior is testable. Deciding a socket is abandoned
  and replacing it is one critical section, serialized per identity by an
  exclusive lock held only for its duration. This is not the slot lock: it does
  not gate whether an instance may run, only who gets to reclaim a path.
- Startup recovery is an explicit app launch policy, not inferred from the parent
  process, standard streams, activation state, bundle identity, or environment:

  ```swift
  enum StartupPolicy {
      case promptForRecovery
      case fresh
  }
  ```

  A normal app launch defaults to `.promptForRecovery`. The programmatic launcher
  passes an app argument selecting `.fresh`, which bypasses recovery loading and
  the restore modal and creates a new session. Recovery policy is independent of
  activation: the foreground notification-priming launch also starts fresh.
- `HOME` stays real and `~/.config/danterm/config.json` stays shared, so a slot
  instance behaves like the user's terminal.

## Invariants

- **I1** An instance never unlinks or rebinds a socket a live instance is serving;
  a socket abandoned by a dead process is reclaimed, and concurrent starters
  contending for one abandoned path yield exactly one serving listener.
- **I2** At most one process holds a slot; a slot whose holder died is claimable
  with no cleanup step.
- **I3** The launcher never claims slot 0.
- **I4** Socket, recovery state, and scrollback replay files are namespaced per
  instance identity, and one instance's cleanup never removes another's files.
- **I5** Flight-tape recording follows a capability the bundle declares, not a
  comparison against a known identity.
- **I6** A build kills only the instance whose bundle it is replacing, and can
  build without installing.
- **I7** An agent-launched instance explicitly uses `.fresh`, takes no focus, and
  blocks on no modal, so it always creates a new session and reaches a serving
  socket unattended even when a stale session lock and valid checkpoints exist.
  It never requests notification authorization -- at launch or on its first
  notification -- while the grant is undetermined. Only a foreground priming
  launch may prompt, and foreground activation does not change the `.fresh`
  recovery policy.
- **I8** The launcher emits a machine-readable handle (slot, bundle id, socket
  path, pid) and, when the pool is exhausted, fails with a distinct status having
  started no process.
- **I9** A notification click activates the instance that posted it.
- **I10** A launched instance starts from the environment a LaunchServices launch
  would provide, not the launcher's, so unmanaged launching-agent state does not
  leak into its shells while normal session values such as `PATH` and
  `SSH_AUTH_SOCK` remain available. DanTerm continues to inject its own
  instance-correct pane variables.

## Proof obligations

- **PO1** (I1) A second listener on a live socket refuses while the first keeps
  serving; a socket left by a dead process is reclaimed; two starters racing to
  reclaim one abandoned path leave exactly one reachable listener; closing a
  listener whose path another instance has since rebound leaves that instance
  serving.
- **PO2** (I2, I3) Concurrent launches receive distinct non-zero slots; SIGKILLing
  a holder makes its slot immediately reclaimable.
- **PO3** (I4) Two identities produce disjoint replay directories, and cleaning one
  preserves the other's files.
- **PO4** (I5) Capability declared true, declared false, and absent yield recording
  on, off, and off.
- **PO5** (I6) A kill targets only the replaced bundle's executable; a no-install
  build leaves the shared install location untouched.
- **PO6** (I7) With a stale session lock and valid checkpoints present, the
  launcher default selects `.fresh`, presents no restore modal, creates a new
  session, becomes reachable at its socket, and posts its first notification
  without requesting authorization from an undetermined grant. A normal app
  launch against the same recovery inputs selects `.promptForRecovery` and offers
  restoration. The foreground launcher option restores activation and is the path
  that may prompt for notification authorization, but still selects `.fresh`.
- **PO7** (I8) An exhausted pool exits non-zero with no process started, and every
  reported handle field is consistent with the reported bundle id.
- **PO8** (I9) **Manual, discharged by measurement:** a notification posted by a
  directly exec'd slot clone is delivered, and clicking it activates that instance;
  both still hold after the bundle is replaced and re-signed in place under the same
  identity, with no further authorization request. Re-run by hand if the signing
  identity, entitlements, or launch mechanism change.
- **PO9** (I10) A shell in an agent-launched instance has the same environment as
  one launched normally through LaunchServices, modulo DanTerm's own per-pane
  variables, and sees no unmanaged agent-session variable belonging to the
  launching process.

End-to-end check: from two checkouts concurrently, build and launch a slot each,
drive both over their reported sockets (`ls`, `tab new`, `pane tape`), confirm each
`danterm ls` sees only its own instance, post a notification from each and confirm
clicks route correctly, then SIGKILL one and confirm its slot is immediately
reusable and the survivor's socket still serves.

## Non-goals

- The `justfile` screenshot recipe stays slot-0-only; its name-keyed process
  targeting is not converted.
- No `HOME`/`CFFIXED_USER_HOME` isolation, no per-slot config file.
- Cross-instance pasteboard drag types and PTY dispatch-queue labels are
  reverse-DNS but are not identities; they stay constant.

## Accepted risks

- **AR1** Shared config is last-writer-wins: an instance that writes settings
  changes the user's. Accepted because config writes are user-initiated and rare.
- **AR2** Each slot is a separate authorization principal, so its first launch
  needs a one-time notification grant. Mitigated by priming the pool once; PO8
  measured that the grant then survives re-signing a slot in place.
- **AR3** Per-slot executable names must avoid regex metacharacters and stay within
  the 16-character process-name limit that `pgrep -x` matches, or name-based
  targeting silently stops working.

## Rejected ideas

- **RI1** `HOME`/`CFFIXED_USER_HOME` isolation -- isolates state with zero code
  change but cannot route notifications, which are keyed on bundle id.
- **RI2** A fresh identity per launch -- perfectly isolated, but a new
  authorization principal every launch means an unattended agent hits a prompt.
- **RI3** Identity derived from the working copy or directory -- collides for two
  agents in one checkout and grows identities without bound.
- **RI4** Claiming the slot inside the app -- impossible; the id is fixed at sign
  time, before the process exists.
- **RI5** Pidfile or timestamp-based reaping -- unnecessary once the lock is held
  by the app process and released by the kernel.
- **RI6** Having the app acquire its slot lock after a launcher uses `open` --
  reintroduces a race between slot selection and app lock acquisition and needs a
  second reservation handoff, while direct exec preserves the lock continuously
  and PO8 measured no notification cost.

## Critical files

`lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift`,
`lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift`,
`app/IpcServer.swift`, `app/AppRuntime.swift`, `app/SwiftTerminalBackend.swift`,
`app/main.swift`, `app/AppDelegate.swift`, `app/Info.plist`, `dev-build.sh`,
`scripts/tests/danterm-cli_test.sh`, and a new launcher plus its test.
`scripts/terminal-benchmark.sh` already implements per-identity plist rewriting,
signing, and PID-keyed process targeting -- reuse those patterns.
`app/main.swift#writeTerminalCharacterizationPathProbe` enumerates every
per-instance path and is the checklist for what must be namespaced.

## Implementation discretion

- Launcher language and handle format. macOS has no `flock(1)`, so a shell-only
  claim is not available; the claim must hold a lock across an exec.
- Pool size, and the on-disk layout of the slot root.

## Commit progress

- [x] 1. Model pooled instance identities and namespace runtime state
- [x] 2. Make control-socket ownership race-safe
- [x] 3. Add explicit fresh-start and notification policies
- [x] 4. Launch isolated development slots and update tooling contracts

## Implementation notes

- The fixed development pool is slots 0 through 8. Slot identities use the
  canonical bundle-id suffix `.N` and the app/executable name `DanTerm Dev (N)`;
  slot 0 keeps the existing unsuffixed identity and name.
- Replay files retain the shared `danterm-scrollback` parent for recognizable
  diagnostics, with one bundle-identifier leaf per instance so cleanup remains
  identity-local.
- Socket reclamation uses a persistent `<control-socket>.lock` sibling. The lock
  is held only across liveness detection plus rebind, or ownership-checked
  teardown; the listener records the bound path's device and inode at bind time.
- App launch arguments use `--fresh` for recovery policy and `--background` for
  unattended activation. Background launches never request notification
  authorization; `--fresh` without `--background` is the foreground priming mode.
- The launcher is a Python executable so it can hold a BSD `flock` descriptor
  across `execve` without adding a launcher to production bundles. Slot locks
  and staged bundles share `~/Library/Caches/com.danneu.danterm-dev-slots`,
  independent of any checkout. A development-only identity helper bridges the
  launcher to `DanTermProtocol` so the naming and path scheme remains
  single-source.
- Slot apps inherit the GUI launchd environment plus canonical account values,
  rather than the launching agent's environment. This preserves session-owned
  values such as `SSH_AUTH_SOCK` while dropping unmanaged agent state.
- A worktree-local build lock serializes canonical bundle assembly through slot
  cloning. Slot ownership stays user-global; the narrower build lock only keeps
  two launchers in one checkout from racing on its shared `.build` artifact.
- The launcher passes its slot descriptor as an app argument. DanTerm marks it
  close-on-exec at entry, retaining the claim itself without leaking it into pane
  children that could outlive a killed app and delay reuse.
