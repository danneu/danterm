# Launch policy stops asking the embedder which paths work

Source: snag 4 in
[docs/scratch/2026-08-26-terminal-engine-reusability.md](../../docs/scratch/2026-08-26-terminal-engine-reusability.md).

## Problem

`TerminalPaneLaunchFacts` (and `LaunchPolicyInput` under it) carry two fields,
`executablePaths` and `accessibleDirectories`, documented as "already verified
by the app adapter". The engine consumes them as membership sets against a
candidate ladder it owns (`LaunchPolicy.swift:202`, `:216`). So the seam asks
the embedder to guess which paths the engine will query and to answer correctly
for each.

Evidence:

- `app/SwiftTerminalBackend.swift:184-200` restates both ladders verbatim and
  probes them. A ladder change in the engine leaves DanTerm silently
  unverifying the new candidate; no compile error, no failing test.
- `examples/MiniTerm/.../MiniTerminalView.swift:70` passes
  `["/bin/zsh", "/bin/bash", "/bin/sh"]` unchecked. Because the set is a
  positive answer, a missing `/bin/zsh` is still selected, the spawn fails at
  exec, and the reducer stops with `.systemError(ENOENT)` -- the `/bin/sh`
  fallback the ladder exists for never runs.

Load-bearing premise: the host already turns a staged bootstrap failure into a
retry. `PTYSessionBootstrap/main.c` runs `chdir` then `execve` and reports
`(stage, errno)` for whichever fails; `PTYSpawner.swift:147-157` maps the cwd
stage to `SpawnFailure.workingDirectoryUnavailable`; the reducer
(`PaneProcessLifecycle.swift:266-279`) advances through `plan.attempts` on that
failure. The cwd pre-check is therefore a probe in front of a retry loop that
would handle the failure anyway. Only the shell is a hard stop today.

## Decision

Delete the question. The plan carries two independent ordered ladders and the
spawn is the only test.

- `ResolvedLaunchPlan` holds a shell ladder `[accountShell, /bin/zsh, /bin/sh]`
  and a cwd ladder `[requested cwd, home, /]`, nil entries dropped, duplicates
  removed keeping first position. Shell candidates are absolute paths; an
  account shell that is not absolute is dropped from the ladder, so exec
  viability never depends on cwd.
- The reducer tracks one index per ladder. A cwd-stage bootstrap failure
  advances the cwd index only. An exec-stage bootstrap failure becomes a
  distinct `SpawnFailure` and advances the shell index only; the cwd that
  already passed `chdir` is kept. Every other bootstrap stage and every host
  failure stays terminal, as today.
- `noUsableShell` is reported when the shell ladder is exhausted, never
  predicted before a spawn.
- `executablePaths` and `accessibleDirectories` are deleted from
  `TerminalPaneLaunchFacts` and `LaunchPolicyInput`. The facts keep only what
  the embedder alone can answer: `accountShell`, `homeDirectory`,
  `inheritedEnvironment`, `localeFallback`, `productIdentity`,
  `productEnvironment`.
- `SwiftTerminalBackend.launchFacts` and MiniTerm lose their probe blocks
  outright. Nothing in either call site touches the filesystem for launch.

Why this and not "pass the probe" (closures in the facts): a probe still lets a
fake or a careless embedder answer wrongly, only moves the TOCTOU window, and
adds an injection seam. With the ladders in the plan there is no answer to get
wrong, the check and the use are the same syscall, and `LaunchPolicyInput` stays
plain `Equatable` data.

Why two ladders and not their product: `chdir` and `execve` are reported as
separate stages, so each failure identifies exactly one ladder to advance. No
rejected cwd or rejected shell is ever retried, the first viable pair is found
in at most five spawns, and exhaustion names the ladder that ran out.

## Invariants

- I1. Given the same `LaunchPolicyInput`, `resolveLaunchPlan` is deterministic
  and needs no filesystem: the ladders are a pure function of the account
  shell, the home, and the requested cwd.
- I2. The child that ends up running is the first shell in ladder order that
  `execve` accepts, in the first cwd in ladder order that `chdir` accepts. An
  embedder cannot skip a fallback.
- I3. Only a cwd-stage or exec-stage bootstrap failure retries, and only while
  its own ladder has a candidate left. A cwd failure never advances the shell;
  an exec failure never advances the cwd. Exhaustion reports
  `workingDirectoryUnavailable` (cwd ladder spent) or `noUsableShell` (shell
  ladder spent, carrying the final exec errno). Every other bootstrap stage and every host failure is terminal
  on the first occurrence, as today.
- I4. Pending input and pending grid submitted while spawning survive every
  retry, whichever ladder advanced (existing behavior, now across both).
- I5. A close while spawning still converges without a further retry (existing
  behavior).
- I6. `/bin/sh` and `/` are always the last candidates of their ladders, so
  neither ladder is empty.
- I7. DanTerm's child environment, argv, and chosen shell on a healthy machine
  are unchanged: the first attempt is the account shell in the requested cwd,
  exactly what runs today.

## Proof obligations

- PO1 (I1, I6): `resolveLaunchPlan` produces both ladders from facts alone,
  deduplicated, ending in `/bin/sh` and `/`; a nil or non-absolute account
  shell and a nil requested cwd shorten a ladder without reordering it.
- PO2 (I2, I3): reducer walks: exec failure -> next shell, same cwd; cwd
  failure -> next cwd, same shell; a cwd failure followed by an exec failure
  followed by success runs the second shell in the second cwd; exhaustion of
  each ladder reports its matching `LaunchFailureReason`, `noUsableShell`
  carrying the final exec errno; a non-retryable
  bootstrap stage reports `systemError` with no further spawn.
- PO3 (I4): buffered input and a pending grid are delivered after a retry
  driven by exec failure, not only by cwd failure.
- PO4 (I5): the existing race permutations in `LifecycleInterleavingTests`
  cover the new failure case as well as the old one.
- PO5a (I3, real host): a host launched through the system spawner with a
  nonexistent absolute account shell reaches a running `/bin/zsh`, the next
  candidate on a macOS host.
- PO5b (I3, injected spawner): a host or controller whose injected
  `TerminalPTYSpawning` returns exec-stage failure for every candidate is
  offered each shell in ladder order and then reports `noUsableShell`
  carrying the final attempt's errno, with no recording captured
  (mirrors the existing `noUsableShell` controller test, now without a
  pre-check).
- PO6 (I7): the existing launch-assembly tests in
  `TerminalPaneSessionPolicyTests` still pass with the two fields removed and
  assert the first attempt's program and cwd.
- PO7: MiniTerm and both `TestSupport` runners compile with the new facts.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: `localeFallback` keeps its candidates-plus-probe shape (a product
  switch and `Locale`-derived; revisit separately, per the scratch doc).
- Non-goal: a shared "live facts" target for the environment snapshot, `HOME`,
  and `getpwuid` lookup. Worth doing, separate change.
- AR1: up to five spawns before a failure report. Each is a `posix_spawn` of
  the bootstrap helper on the failure path only; accepted.
- AR2: the engine can no longer say `noUsableShell` without spawning. No
  consumer uses the early answer.
- AR3: a relative account shell in the passwd database is silently ignored
  rather than searched. `getpwuid` shells are absolute in practice; the
  alternative (cwd-dependent exec viability) reintroduces coupling between the
  ladders.
- RI1: classify exec errnos (`ENOENT`, `EACCES`, ...) into "next shell" vs
  "system error". Rejected: the child has not run at any exec-stage failure, so
  trying the next shell is harmless and the errno list would be a new policy
  with nothing to justify each entry. Any exec-stage failure advances; the
  errno of the last attempt is carried in the report when the ladder is spent.
- RI2: `TerminalLaunchProbes` closures in the facts. Rejected, see Decision.
- RI3: a single shell-major ladder of (shell, cwd) pairs. Rejected: it retries
  cwds the kernel already rejected, costs up to nine spawns, and needs a
  skip-ahead rule to avoid re-trying a rejected shell, which is exactly the
  coupling the two-stage bootstrap report makes unnecessary.
- RI4: reference terminals (ghostty, kitty) pick one shell up front with
  `/bin/sh` as a static default and do not retry on exec failure. Not adopted:
  they also do not pre-verify, so they cannot produce the MiniTerm defect, but
  they lose the fallback outright instead of making it unbreakable.

## Critical files

- `lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift` -- ladder
  construction, field removal.
- `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift` --
  `SpawnFailure`, `SpawnContext`, retry step, exhaustion report.
- `lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift` -- map the
  bootstrap's exec stage (stage 9 in `PTYSessionBootstrap/main.c`) to the new
  failure.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift` --
  facts struct and assembly.
- `app/SwiftTerminalBackend.swift`, `examples/MiniTerm/Sources/MiniTerm/MiniTerminalView.swift`,
  `lib/TerminalPTY/TestSupport/*/main.swift` -- call sites.
- Tests listed under proof obligations: `LaunchPolicyTests`,
  `LifecycleReducerTests`, `LifecycleInterleavingTests`,
  `TerminalPaneSessionControllerTests`, `TerminalPaneSessionPolicyTests`,
  `TerminalPTYHostTests` (injected `TerminalPTYSpawning` already exists for
  this), plus the remaining `LaunchPolicyInput(` constructors in
  `TerminalFlightRecorderTests`, `TerminalPTYExternalTests`,
  `TerminalPanePublishDeadlineTests`.
- `docs/scratch/2026-08-26-terminal-engine-reusability.md` -- mark snag 4 done
  in the same style as snags 3 and 8.

No tape or wire format changes: the flight recorder and `DanTermProtocol` carry
no launch fields.

## Verification

1. TDD per proof obligation: `swift test --package-path lib/TerminalPTY`
   (targeted filters during the loop), then `just lint`.
2. `swift build --package-path examples/MiniTerm` compiles the embedder.
3. `just test` before commit.
4. Live check on a slot is optional; PO5a covers the real spawner.

## Implementation notes

- `ResolvedLaunchPlan` holds the two ladders plus the shared environment and
  geometry, and vends one attempt through
  `spec(shell:workingDirectory:)`. The plan named the ladders but not how a
  `PTYLaunchSpec` is built from a pair; a stored matrix of specs would have
  duplicated the environment for every pair and re-introduced a single flat
  index for the reducer to walk.
- `LaunchPolicyError.noUsableShell` is deleted, not kept unused. Nothing can
  reach it any more: both ladders are non-empty by construction (I6), so
  `resolveLaunchPlan` has no shell verdict left to give.
- `LaunchFailureReason.noUsableShell` gained an `Int32` payload to carry the
  final exec errno the plan asks for in I3 and PO5b.
- `SwiftTerminalBackend.launchFacts` lost its `requestedWorkingDirectory`
  parameter along with the probe blocks. It existed only to build
  `accessibleDirectories`; the requested cwd already reaches policy through
  `TerminalPaneLaunchRequest`.
- `TerminalPTYHostTests.makeLaunchInput` used a deliberately unusable
  `accountShell` and cwd that the old probe fields filtered out before the
  spawn. With the probe gone those would make every host test spend two failed
  spawns, so the fixture now names the shell and cwd it always meant to run
  (`/bin/sh` at `/`), and the two tests that exercise a fallback set their own
  unusable candidate.
