# One launch-resolved value for every identity-keyed path

Source: PERSIST-2 in docs/scratch/2026-08-18-construction-audit.md, widened
from the recovery directory to every path the process identity keys.

## 1. Problem, desired outcome, evidence

**Problem.** The process identity (`DanTermInstanceIdentity`, from
`Bundle.main`) is re-derived ambiently at six leaves, and each leaf turns it
into a filesystem path on its own: the control socket
(`lib/DanTermProtocol/.../SocketPath.swift`), the recovery directory and its
three files (`lib/DanTermSupport/.../RecoveryStore.swift`), the scrollback
replay directory (twice in `app/AppRuntime.swift`), the IPC audit log
directory (`app/IpcServer.swift` default argument), and the tailnet
activation identity (`app/IpcServer.swift` default argument). The checkpoint
tier paths take no parameter at all. Consequences:

- The lock, the checkpoints, and the audit log co-locate only because every
  leaf happens to take the same default. Nothing ties them together.
- No test can drive the real recovery flow (write both tiers and a lock,
  relaunch, detect the crash, merge), because the tier paths cannot be
  redirected and the launch-side reader is top-level code in `app/main.swift`.
- App tests that start services write into the user's real
  `~/Library/Application Support/com.danneu.danterm/Recovery/`: under
  `swift test` the bundle id is nil, the identity falls back to production,
  and `IpcServerOwnershipTests` has left an `ipc-audit.jsonl` there with
  entries naming `/tmp/dt-ipc-server-<UUID>/control.sock` peers. Any app-test
  runtime that outlives the light-checkpoint window would write
  `last-light.json` there too.
- The design rule already on record for identity -- "never re-derived at a
  leaf" (docs/design/2026-05-28-pure-core-support-split.md, "The identity
  seam") -- holds for `CoreEnv` but not for the paths.

**Desired outcome.** One value, built once at launch from one identity and
the process's root directories, owns every identity-keyed path. Everything
that reads or writes such a path is handed that value. A test can build the
same value on temporary roots and exercise the full write-relaunch-merge flow
and the audit log without touching the real Application Support tree. The
audit's PERSIST-2 becomes the recovery slice of this.

**Evidence / load-bearing premises.**

- Derived strings are external contract: `scripts/tests/danterm-cli_test.sh`
  asserts `$HOME/Library/Caches/<bundle-id>/control.sock`;
  `scripts/terminal-viability.sh` reads the app's path-probe JSON keys
  (`home applicationSupport caches temporary config recovery socket replay`)
  and asserts `<recovery>/session.json` and the socket are gone after a clean
  exit; `scripts/dev-slot-launcher.py` takes the socket path from the identity
  tool; `scripts/screenshot.sh` hardcodes the dev socket.
- `DanTermProtocol` is shared with iOS and the identity tool depends on
  Protocol only; the CLI imports Protocol and Support. The CLI is a bare
  executable, so its ambient identity is already production.
- Unix socket paths are limited to 104 bytes (`ControlSocketListener`), so a
  test value on temporary roots that actually binds a socket must use short
  roots.
- `IpcAuditLogWriter` creates its directory lazily on first append; nothing
  needs the recovery directory to exist at construction.
- `IpcServer`'s identity input feeds only tailnet activation (port offset and
  pool-slot gate); quit authorization comes from `CoreEnv.live`, which is out
  of scope.
- Swift default arguments cannot reference sibling parameters, so
  `IpcServer` cannot default its audit writer from a paths parameter.

## 2. Decision

**D1. One value in the support layer.** A `Sendable`, `Equatable` value that
stores the identity plus the three roots (Application Support, Caches,
temporary) and derives every identity-keyed path from them: recovery
directory, light and enriched checkpoint files, session lock, IPC audit
directory, control socket, scrollback replay directory. It has exactly one way
to be built: explicit identity and explicit roots. No defaulted argument,
anywhere in the chain, resolves an identity or a root. The existing free path
functions are deleted so a missed call site is a compile error.

**D2. Resolved once, in `app/main.swift`, before the characterization path
probe.** The launch code is the only place in `app/` or `lib/` that reads
`Bundle.main`, the FileManager search-path directories, or the
characterization temp-root override for these paths. It hands the value to
`AppDelegate`, which hands it to `AppRuntime`, which composes what `IpcServer`
needs. `AppRuntime` requires the value (no default; the `dialogSurfaces`
precedent) and loses its `socketPath` parameter. `IpcServer` keeps its three
existing inputs -- socket path, identity, audit writer -- and makes all three
required; the audit writer stays injectable because the remote fixture breaks
and restores the sink.

**D3. The socket layout stays in Protocol, explicit in both inputs.** One
Protocol function derives the socket from an identity and a caches root; the
CLI and the identity tool call it with an explicit identity (the CLI passes
production, which is what its ambient fallback resolves to today). The support
value composes it with its stored caches root, so the layout has one source.

**D4. The launch-recovery read becomes a named app-layer function.** The
crash-detect plus checkpoint-merge block in `app/main.swift` moves into a
function over the value, the startup policy, and whether an `--init` snapshot
was loaded (and nothing else -- no main.swift global), callable from app-tests.
The function owns the skip decision: `main.swift` calls it unconditionally and
keeps no `if`, so the "nothing is read" case is a behavioral outcome a test can
assert. Its semantics are unchanged and are pinned by I4 and PO4.

**D5. Enforced by the gate.** A lint fails `just test` when an ambient
identity resolution appears outside the launch resolver and `CoreEnv.live`.

**Ordering constraints.**

- Land after the uncommitted DialogSurfaces change commits: it edits
  `AppRuntime.init` and every app-test runtime constructor this plan also
  edits.
- Land before PERSIST-1 (existence-based lock decision, throwing lock
  writer). This plan keeps the lock decision as it is today so PERSIST-1
  stays a small swap on the new signatures.
- Sequence so each commit leaves the gate green: Protocol socket layout +
  CLI first (Protocol tests, CLI tests); then the support value plus all app
  threading and the app-test fixture in one commit (the symlink compiles
  Support into the app, so a split leaves the app uncompilable); then the
  launch-recovery lift with its tests; then the lint and the structural
  removal of the ambient identity default, plus the doc updates.

**Behavioral scope.** No user-visible behavior changes. Every derived path
string is byte-identical to today. The only observable differences are in
tests (hermetic) and in the gate (new lint).

## 3. Invariants

- **I1. One owner.** Every identity-keyed path the app reads or writes is
  derived from the single value built at launch. The lock, both checkpoint
  tiers, and the audit log live in one directory by construction.
- **I2. Strings unchanged.** `~/Library/Caches/<id>/control.sock`;
  `~/Library/Application Support/<id>/Recovery/{last-light.json,
  last-enriched.json, session.json}` (audit log `ipc-audit.jsonl` in the same
  directory); `<tmp>/danterm-scrollback/<id>/`. Production and development
  identities resolve disjoint directories. The path-probe JSON keys keep
  their names and meanings.
- **I3. No ambient identity outside launch.** `app/`, `lib/`, `cli/`, and
  `tools/` contain no identity resolution from `Bundle.main` except the
  launch resolver in `app/main.swift` and `CoreEnv.live`. No initializer or
  function in the chain defaults an identity, a root, or a derived path.
- **I4. Launch-recovery semantics preserved.** The read runs only when no
  `--init` snapshot was given and the startup policy prompts for recovery.
  Crashed means the session lock is present and decodes (today's rule;
  PERSIST-1 changes it later). Restore is: both tiers validate -> merged
  (light is authoritative for structure, enriched supplies scrollback for
  matching panes); only light validates -> light; only enriched validates ->
  enriched; neither -> none. A corrupt or unsupported-version tier behaves as
  absent. Crashed and restore are independent; the lock is not deleted by the
  read.
- **I5. Tests are hermetic.** No test in any target creates or reads a file
  under the real Application Support or Caches trees for these paths.
- **I6. Layering holds.** Support never imports Core; Protocol gains no
  macOS-only layout beyond the socket; the CLI and the identity tool stay
  buildable against Protocol for the socket path.

## 4. Proof obligations

- **PO1 (I1).** Support test, written first: build the value on a temporary
  root, write both checkpoint tiers and the lock through the production
  entry points, assert all three files exist under that root and the lock
  reads back. Fails today by not compiling.
- **PO2 (I2).** Support and Protocol tests assert the exact suffixes for a
  production and a development identity, and that they differ; a Protocol
  test pins that the composed socket path equals the explicit-identity
  convenience the CLI uses. Out of suite: `scripts/tests/danterm-cli_test.sh`
  and `scripts/terminal-viability.sh` must still pass (the latter is the
  path-probe consumer).
- **PO3 (I3).** The lint rejects both ambient identity forms
  (`DanTermInstanceIdentity()` and `DanTermInstanceIdentity(bundle:`) and
  direct Application Support / Caches root resolution, anywhere outside the
  named launch resolver and `CoreEnv.live`. It has its own test (a fixture with
  a stray occurrence of each banned form fails; the allowlisted sites pass) and
  is a step in `scripts/run-test-suite.sh`.
- **PO4 (I4).** App tests over the lifted function with a temporary-rooted
  value: empty directory -> not crashed, no restore, no file created; lock
  only -> crashed, no restore; light only; enriched only; both valid ->
  structure from light, scrollback from enriched for the shared pane, none
  for light-only panes; one tier corrupt -> the other; unsupported version
  behaves as corrupt; lock plus both -> crashed and merged; `--fresh` or an
  init snapshot -> nothing read. Assert on the returned snapshot and pane
  scrollback, never on helper structure.
- **PO5 (I5).** The app-test runtime/server fixtures root every runtime on a
  temporary value; the ownership suite asserts its audit log lands under the
  fixture directory. Existing suites that build runtimes
  (`AppRuntimeCommandTestSupport`, `PaneHostHeadlessTests`,
  `AppRuntimePendingIpcShutdownTests`, `IpcServerOwnershipTests`,
  `IpcServerRemoteTests`) keep passing.
- **PO7 (I1, I4).** One app test drives the whole promised flow through a
  single value: build it on a temporary root, write a valid light checkpoint, a
  valid enriched checkpoint, and the session lock through the production write
  entry points, then call the lifted launch-recovery function with that same
  value and assert it reports crashed and returns the merged restore
  (structure from light, scrollback from enriched). This is the obligation that
  ties production writers to the launch reader; PO1 and PO4 do not.

- **PO6 (I6).** `swift build` of `lib/DanTermProtocol`, the identity tool,
  and `cli/` succeeds; `scripts/core-purity-lint.sh` stays green.
- **Regression net.** `RecoveryStoreTests` (lock round-trip, namespacing,
  replay-directory isolation), `SocketPathTests`, `CheckpointTests`,
  `SnapshotTests`, `IpcServerRemoteTests` unchanged in behavior. Manual: a
  `just launch-slot` run restores a session after a forced kill, and the
  `danterm` CLI with no `--socket` from the dev Helpers path still targets
  the production socket.

## 5. Non-goals / Accepted risks / Rejected ideas

- **NG1.** `CoreEnv.live.instanceIdentity` stays ambient. It is an
  authorization seam with its own documented rationale; both it and the
  launch resolver read `Bundle.main`, so they cannot disagree.
- **NG2.** `DanTermConfigPaths` (home-keyed, shared across instances) and
  the `home`/`config`/`displayScale` probe keys are untouched.
- **NG3.** PERSIST-1 (existence-based lock decision, throwing writer) is a
  follow-up on top of this.
- **AR1.** `AppRuntime.init` and `IpcServer.init` churn touches eight runtime
  and six server construction sites; mitigated by deleting the defaults so
  every miss is a compile error, and by one shared app-test fixture.
- **AR2.** If a `danterm` CLI copy ever ran with a non-nil bundle id, the
  explicit production identity would differ from today's ambient one; checked
  manually (Regression net) and judged acceptable because the documented CLI
  contract is "production socket unless `DANTERM_SOCK`/`--socket`".
- **RI1.** RecoveryPaths only (the audit's scope): leaves the socket, replay,
  and tailnet identity as four more ambient leaves and re-admits the pattern
  this plan closes.
- **RI2.** Putting the value in `DanTermProtocol`: Protocol is shared with
  iOS and the tool; the recovery and replay layouts are macOS-app concerns
  that Support already owns.
- **RI3.** Giving `IpcServer` the whole value: forces the remote fixture to
  fabricate roots to place a socket in `/tmp`, and Swift cannot default the
  audit writer from it anyway.

## 6. Implementation discretion

- Type and property names; whether `AppDelegate` takes the value through its
  initializer or a launch-assigned property; which file in `app/` hosts the
  lifted launch-recovery function.
- Whether the lint is a new script or extends an existing one.

## Docs to update in the same change

`lib/DanTermSupport/.../RecoveryStore.swift` and `InstancePaths.swift`
headers (they defend the zero-arg design); AGENTS.md architecture paragraph
on the identity seam; docs/design/2026-05-28-pure-core-support-split.md "The
identity seam" (ambient reads are now `CoreEnv.live` and the launch
resolver); the PERSIST-2 entry in the construction audit.

## Commit progress
- [x] 1. Protocol derives the control socket from an explicit identity and caches root
- [x] 2. One launch-resolved instance-paths value threaded through the app and IPC server
- [ ] 3. Lift the launch-recovery read into a testable app function
- [ ] 4. Lint ambient identity resolution and update the docs

## Implementation notes

- Commit 1 splits the socket layout in two: `controlSocketPath(identity:cachesRoot:)`
  holds the layout with both inputs explicit, and `userControlSocketPath(identity:)`
  composes it with the user's real caches directory for the bare executables (the
  CLI and the identity tool) that own no launch-resolved value. PO2's "explicit-identity
  convenience the CLI uses" is that second function, and it is the one caches-root
  resolution the commit-4 lint must allowlist.
- The three app call sites (`AppRuntime`, `IpcServer`, the path probe in
  `app/main.swift`) still resolve an ambient identity in commit 1, now spelled out at
  the call site instead of hidden in a Protocol default. Commit 2 deletes those
  defaults when the support value arrives; keeping them here is what leaves the gate
  green at this boundary.

- Commit 2 puts the launch resolver in its own `app/LaunchInstancePaths.swift` rather
  than in `main.swift`: `danTermTemporaryDirectoryURL` moved there from `AppRuntime`,
  and it is the only reader of `Bundle.main` and the user-domain roots for a path.
  `main.swift` calls it once into `launchInstancePaths`. Commit 4's lint allowlists
  that one file plus `userControlSocketPath` and `CoreEnv.live`.
- `AppDelegate` takes the value through a new initializer rather than a
  launch-assigned property, so no code path can reach a delegate whose paths are
  not yet set. `main.swift` was already its only construction site.
- App tests share `app-tests/TemporaryInstancePaths.swift`. It creates nothing on
  disk -- the production writers make their own directories -- so a test that writes
  nothing leaves nothing behind. Its root is `/tmp/dt-<uuid>` and its identity is
  `dt.test`, both short, because the derived control socket must stay inside the
  104-byte Unix socket limit. That identity is deliberately not a real DanTerm
  identity, so no test can reach a production or development instance's files.
