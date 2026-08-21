# Decide crash recovery from the session lock's existence, not from decoding it

Source: PERSIST-1 in `docs/scratch/2026-08-18-construction-audit.md`. Its
stated prerequisite, PERSIST-2 (one launch-resolved `DanTermInstancePaths`
value), landed in `b4471dd2..ff818735`, so the path question is closed and
only the decision rule, the write's placement, and the writer's error
handling remain.

## 1. Problem

The session lock's contract is "present at launch means the previous exit
was unclean". Three things break it today.

**The decision reads the bytes.** `readSessionLockFile(paths:)` is
`try? Data(contentsOf:)` then `try? decode(SessionLock.self)`, and
`app/LaunchRecovery.swift#readLaunchRecovery` decides `crashed` from the
result being non-nil. A corrupt, empty, truncated, or future-format lock
reads as a clean exit. The write is atomic, so the reachable failure is a
`SessionLock` whose Codable shape changed between builds -- which this repo
permits and expects. That is exactly why the decision must not read the
bytes.

**The lock is claimed too late.** The write sits in
`AppDelegate.applicationDidFinishLaunching`, after the runtime, the menu
bar, the window, and the view tree are built. Its comment claims the atomic
overwrite closes the startup window, but that only holds when the previous
exit was unclean and left a lock behind. After a clean exit there is no
lock on disk, so a process that crashes anywhere between launch and that
line -- reading the `--init` file, loading checkpoints, constructing the
runtime, building the window -- leaves nothing behind, and the next launch
reports a clean exit for a run that crashed.

**The lock lifecycle is tangled with checkpoint policy.** The lock read
lives inside `readLaunchRecovery`, which takes `hasInitSnapshot`, so it
cannot run until `main.swift` has read and validated the `--init` file. The
lock has no business waiting on that: where it lives and whether it exists
depend only on the resolved paths.

**A failed write is silent.** `writeSessionLockFile` is three swallowed
`try?` statements, so a lock that was never created disables crash
detection with no signal. Siblings already report their failures:
`IpcAuditLogWriter.prepare()` throws, `CheckpointWriter` returns a
`failed(description:)` outcome. The lock writer is the odd one out.

Neither `pid` nor `startedAt` is read by any production code; only
`RecoveryStoreTests` asserts them.

Desired outcome: a corrupt, empty, truncated, or future-format lock file
cannot be mistaken for a clean exit; a crash at any point after launch
begins is detected on the next launch; and a lock that could not be written
is said out loud instead of silently disabling crash detection.

## 2. Decision

D1. The crash decision is file existence, and "clean" means absence was
confirmed. The reader becomes an existence query over
`paths.sessionLockFile` whose only clean answer is a confirmed "not found";
any other lookup failure (an unreadable or unsearchable recovery directory)
reports crashed, because such a directory may well hold a lock. The
decode-based reader is deleted so no call site can reintroduce a
contents-dependent decision.

D2. The lock file's contents are diagnostics only: written for a human who
inspects the recovery directory, never parsed by production. The `pid` /
`startedAt` payload stays (cheap, and it answers "which process, when"
after a crash); nothing in production reads it back.

D3. The lock handshake is its own launch step, separate from checkpoint
loading, and it is the first fallible thing launch does. It takes only the
resolved `DanTermInstancePaths`, observes whether the previous launch's
lock is there, and immediately claims the current launch's lock, returning
both answers plus the outcome of the write. It runs in `app/main.swift`
directly after `resolveLaunchInstancePaths()`, before the `--init` file is
read, before checkpoints are loaded, and before any AppKit construction.

Both halves are unconditional. The handshake does not take the startup
policy or `hasInitSnapshot`, so it has nothing to wait for -- that is what
makes the ordering structural rather than a comment asking a later reader
not to move a line. Policy applies afterward, to the facts the handshake
already captured: under `--fresh` or a loaded `--init` snapshot, launch
loads no checkpoints and reports no crash to the user, exactly as today,
but the lock was still read and still claimed.

D4. The writer reports failure to its caller instead of swallowing it. The
launch path carries that failure forward until the notice surface exists
and then reports it to the user through the existing notice mechanism
(`.noticeReported(.message(title:message:))`, the same surface
`presentPendingConfigError` uses, and the same defer-presentation-not-the-
write shape). Launch continues: a lock write failure degrades crash
detection, it does not stop the app.

D5. The delete on clean termination keeps swallowing its error: a failed
delete fails safe (the next launch prompts as crashed) and there is no one
left to tell.

Behavioral scope: `RecoveryStore`'s lock helpers, the launch lock handshake
and the checkpoint load it splits from, and their tests. No path, format, or file-name changes;
`scripts/terminal-viability.sh` already checks `session.json` by existence
and stays as is.

## 3. Invariants

I1. A launch read reports "crashed" unless the lock file's absence was
confirmed -- so it reports crashed for a file with any contents (invalid
JSON, empty, a future `SessionLock` shape) and for a lookup that fails for
any reason other than "not found".

I2. A failed lock write is observable by the caller of the write; it is
never silent.

I3. The claim is attempted before launch does any other fallible work, and
when it succeeds the lock is on disk from that point on. No code path
between the start of launch and the claim can crash and leave the next
launch reading a clean exit. A claim that fails leaves no lock -- crash
detection is degraded for this run, and I2 and I4 are what cover that case.

I4. A failed lock write surfaces to the user as a notice once the notice
surface exists, and launch proceeds normally otherwise (restore prompt,
first tab, IPC server unaffected).

I5. Existing behavior is preserved: write then read -> crashed; delete then
read -> clean; the launch read never deletes the lock; under `--fresh` or a
loaded `--init` snapshot launch loads no checkpoints and reports no crash
to the user; writers and the launch read agree through the one
`DanTermInstancePaths` value.

## 4. Proof obligations

PO1 (I1). In `app-tests/LaunchRecoveryTests.swift`, drive the lock
handshake against a recovery directory holding a `session.json` that is not
a valid `SessionLock` (invalid JSON; also empty) and assert it reports
crashed. Fails today.

PO2 (I1). Drive the handshake against a recovery directory whose contents
cannot be looked up (an unsearchable directory, or a regular file where the
recovery directory belongs) and assert it reports crashed rather than
clean. A confirmed-absent directory still reports clean, so the two answers
are distinguished behaviorally.

PO3 (I2). In `lib/DanTermSupport` tests, point the paths value at a root
under which the recovery directory cannot be created (a regular file in its
place) and assert the write reports failure. Fails today.

PO4 (I3, D3). A test drives the handshake against a directory with no lock
present and asserts that it reports a clean previous exit *and* that a lock
exists on disk when it returns -- the claim happens inside the handshake,
so no later launch code is required for the lock to be on disk. Fails
today. Ordering against the read is covered too: a lock written by a
previous session is still reported as crashed even though the handshake
overwrites it.

PO5 (D3, I5). Launch under `--fresh`, and launch with a valid `--init`
snapshot, each starting from a recovery directory with no lock: assert in
both that no checkpoint is offered for restore and no crash is reported to
the user, *and* that a lock now exists on disk. The existing skip-rule
tests all start with a lock already present, so they pass even if an
implementation skips the claim along with the read; these start from
absence, which is the case a fresh launch after a clean exit actually hits.

PO6 (I4). An app test drives the launch-time write failure through the
runtime and asserts a notice reaches the dialog surface (the pattern in
`app-tests/AppRuntimeDialogSurfaceTests.swift`) and that the runtime is
otherwise usable.

PO7 (I5, D2). The existing round trip in `RecoveryStoreTests` reshaped onto
the existence query (write -> present, delete -> absent), plus a test-only
decode of the written JSON asserting the injected `pid` and `startedAt` --
the diagnostics D2 keeps are worth nothing if the writer can silently
regress to `{}` or wrong values. That decode lives in the test; no
production decoder survives. The existing `LaunchRecoveryTests`
(`readLeavesTheSessionLockInPlace`, the skip-rule tests,
`writtenSessionSurvivesRelaunchThroughOnePathsValue`) and
`InstancePathsTests.recoveryWritersShareOneDirectory` keep passing after
their reader calls move to the existence query.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: PID-liveness checks or any inspection of the lock's contents.
- Non-goal: reporting a failed lock delete at termination (D5).
- Non-goal: reporting the *reason* an existence lookup failed. Failing to
  crashed (D1) already fails safe, and the user-facing notice is about
  writes, which are the failure they can act on.
- AR1: a stale lock from an older build with different contents now
  triggers the recovery prompt where it previously read as clean. This is
  the intended behavior; it changes only the first launch after the change
  if such a file exists.
- RI1: write an empty lock file and delete `SessionLock` entirely. Rejected:
  the human-readable `pid` / `startedAt` payload is useful when inspecting
  a crashed instance's recovery directory, and keeping it costs one
  write-only struct. It must never become something production reads.

## 6. Implementation discretion

- Whether the writer signals failure by `throws` or by a typed outcome, and
  what shape the handshake returns its three answers in.
- Whether the checkpoint load stays in `readLaunchRecovery` under its
  current name once the lock read leaves it.
- Where the deferred notice is held between the claim and the notice
  surface coming up.

## Verification

- `swift test --package-path lib/DanTermSupport --filter RecoveryStoreTests`
  and `--filter InstancePathsTests`.
- `just test` (includes `app-tests` `LaunchRecoveryTests` and the dialog
  surface tests, plus `scripts/ambient-identity-lint.sh`).
- No manual slot check: `just launch-slot` always passes `--fresh`, so a
  slot relaunch never offers the recovery prompt.
  PO1 through PO7 and the gate are the coverage.

## Implementation notes

- The existence query is `lstat` plus `errno != ENOENT`, not
  `FileManager.fileExists` or `URL.checkResourceIsReachable`. `fileExists`
  answers false for both "absent" and "cannot be inspected", which is exactly
  the distinction D1 rests on, and `checkResourceIsReachable` folds `ENOTDIR`
  into a no-such-file error, so neither can state a confirmed absence.
- `SessionLock` dropped from `Codable` to `Encodable`. D2 says production never
  decodes it; removing the conformance is what makes that structural rather
  than a rule a later reader has to remember.
- The checkpoint half kept its file but not its name: `readLaunchRecovery`
  became `loadLaunchCheckpoints` returning `ValidatedAppRestore?`, and the
  `LaunchRecovery` struct is gone. With the lock read removed the struct held
  one field, and "recovery" no longer described what the function decides.
- The deferred notice is held on `AppDelegate.sessionLockClaimFailure` and
  handed to a new `AppRuntime.reportSessionLockClaimFailure` at the point that
  already calls `presentPendingConfigError()`. `presentPendingConfigError` was
  left alone rather than folded into one "present pending launch notices" call,
  because the two failures reach the runtime by different routes: the config
  error is captured inside the runtime's own initializer, the lock failure
  happens before the runtime exists.
- `AppDelegate.previousSessionCrashed` now records the lock fact under every
  startup policy, where the old skip rule forced it to false under `--fresh`
  and `--init`. Nothing surfaces it in those cases: the crash message is inside
  the branch that requires `.promptForRecovery` and a loaded restore, and both
  skipped policies load none.

## Follow Up

- Tick `PERSIST-1` in `docs/scratch/2026-08-18-construction-audit.md` with this
  commit's hash, the way `PANE-3` was ticked in `f079a56a`. Its entry is at
  line 1233, and the item body at line 4205 still names the deleted
  `RecoveryStore.swift#readSessionLockFile`.
