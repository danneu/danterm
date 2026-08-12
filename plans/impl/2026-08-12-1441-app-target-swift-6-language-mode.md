# Raise the app target to Swift 6 language mode

## Problem

`f3fb30c6` put `DanTermCore`, `DanTermSupport`, and `DanTermProtocol` on
`.swiftLanguageMode(.v6)`, so the pure layers now fail the gate on new
global mutable state or unsafe captures. The app target still compiles at
`.v5`, and because `app/DanTermCore` and `app/DanTermSupport` are
symlinks, it compiles those same pure files with no strict checking at
all. `docs/design/2026-05-28-pure-core-support-split.md` records raising
the app target as the target state; this plan finishes it.

The hole is wider than the app target. The root `Package.swift` sets
`.v5` on **eight** targets, and two of them -- `DanTermProtocol` and
`DanTermSupport` -- name the very same source directories as the nested
`.v6` manifests. So `f3fb30c6`'s strict checking applies only when those
files are built through `lib/*/Package.swift`, which happens in the gate's
package suites and nowhere else. Every root build -- the app, the CLI,
the shipping binary -- recompiles them at `.v5`.

That part is free. Measured by flipping all eight and building
`--build-tests`: **six of the eight compile clean at `.v6` today with no
code change at all** -- root `DanTermProtocol`, root `DanTermSupport`,
`DanTermCLI`, `DanTermInstanceIdentityTool`, `DanTermProtocolTests`, and
`DanTermCLITests`. Only `DanTerm` and `DanTermAppTests` need work.

Measured, not estimated, and re-measured on the current tree. Flipping
`app` to `.v6` produces **7 distinct error sites in 5 files**:

| Site | Error |
|---|---|
| `app/ThemeCatalog.swift:14` | `static let shared` of a non-`Sendable` type |
| `app/SidebarView.swift:1703-1704` | two `static var` objc associated-object keys |
| `app/TodoInputView.swift:90` | `deinit` reads `textChangeObserver: Any?` |
| `app/IpcServer.swift:8`, `:42` | `nonisolated let listener: ControlSocketListener`, not `Sendable` |
| `app/SwiftTerminalSessionView.swift:63` | `NSTextInputClient` conformance crosses into main-actor code |

Most of these are smaller than they look, and one is a latent bug.
`ControlSocketListener.close()` guards on `isClosed == false` then sets
it, and then unlinks and closes outside any lock. That is a plain
check-then-act on unsynchronized state, and making the listener
`Sendable` is a promise that concurrent callers are safe -- which today
they are not. Two callers can both pass the guard and unlink and
`Darwin.close(fd)` twice.

The reachable shape is concurrent or repeated calls to the nonisolated
`close()` surface, directly or through `IpcServer.stop()`. It is *not*
`stop()` racing the listener's `deinit`: an in-progress `stop()` holds
its receiver, the receiver holds the listener, so the listener cannot
begin deinitializing until that call returns. `deinit` remains the
sequential fallback for the never-stopped case, and it must be safe to
run after an explicit `close()` -- but it is not the second racer.

## Decision

Raise the six already-clean root targets first, then fix the seven app
sites individually and flip `DanTerm` and `DanTermAppTests` to `.v6` in
the commit that makes them build. The end state is that no manifest
target selects `.v5`.

**Whole-target default isolation is rejected on evidence** (RI1).

Per-site direction:

- **`ThemeCatalog` becomes genuinely `Sendable`, not isolated.** All six
  readers of `.shared` are main-thread AppKit, so `@MainActor` would
  compile, but the only non-`Sendable` state is `colors: [String: ThemeColors]`
  -- an `NSColor` preview projection whose single consumer is the swatch
  strip at `app/ThemeSwatchViews.swift:146`. Move the projection to that
  consumer. `names` and `themesByName` (`DanTermTheme`) are already
  `Sendable`, and `renderTheme(named:)` in `app/ThemeRenderBridge.swift`
  is an existing `NSColor`-free path to reuse. The catalog then needs no
  annotation and drops `import Cocoa`.
- **`ControlSocketListener` becomes `Sendable` by serializing the whole
  close under a mutex**, not by flipping an atomic flag. A
  compare-exchange makes the unlink and the `Darwin.close` happen once,
  but it lets the *loser* return immediately while the winner is still
  inside `withReplacementLock` -- so `IpcServer.stop()` could return with
  the socket path still on disk and still connectable, which is exactly
  what its callers rely on it not doing (I4). The lock must therefore
  span the flag check, the identity-guarded unlink, and the
  `Darwin.close`, so every caller returns only after teardown is
  complete. `close()` already blocks on a `flock` today, so holding a
  mutex across it adds no new blocking character.
- **`SwiftTerminalSessionView` gets an isolated conformance, not an
  annotation.** The class is *already* `@MainActor`, inferred from its
  `@MainActor TerminalSession` conformance (`app/TerminalSession.swift:109`);
  the file carries no isolation annotation of its own and its `isolated
  deinit` at `:245` is only well-formed on an isolated type. So the
  reported error is not "this class needs to be main-actor" -- it is
  `NSTextInputClient` being a nonisolated protocol satisfied by
  main-actor members. Stating the conformance as main-actor-isolated is
  the fix, and it claims nothing new about the class.
- **`TodoInputView`'s observer token gets a real type.**
  `app/ScrollableTerminalView.swift:31` already stores tokens as
  `[NSObjectProtocol]` and removes them in `deinit` with no error; `Any?`
  is what fails. Reuse the working pattern rather than annotating around it.
- **`SidebarView`'s two associated-object keys take `nonisolated(unsafe)`.**
  Nothing reads or writes them; only `&key` is taken for a stable address.
  `app/TerminalBenchmark.swift:22` and `app/AppPresentationLifecycle.swift:9`
  are the in-repo precedent for this spelling.

## Invariants

- I1: No target in any tracked manifest selects `.swiftLanguageMode(.v5)`.
  Every root target, `DanTerm` and `DanTermAppTests` included, compiles
  under `.v6`, so the pure layers are checked strictly in the shipping
  build and not only in the nested package suites.
- I2: `nonisolated(unsafe)` is introduced only for the two objc
  associated-object key addresses. Every other site is fixed by making
  the type honestly safe or by stating its real isolation.
- I3: Checkpoint payload assembly and pane-tape-follow encoding still run
  off the main thread.
- I4: Control socket teardown stays synchronous, unlinks only the path
  this owner bound, and unlinks and closes exactly once under concurrent
  or repeated `close()`. Every `close()` call -- including one that did
  not perform the teardown -- returns only after the socket path is
  unlinked and the descriptor is closed.
- I5: Notification observers are still removed in `deinit`, per
  `docs/design/2026-06-09-appkit-lifetime-safety.md` rules 2 and 3.
- I6: No user-visible behavior change -- sidebar inline rename, theme
  browsing and swatches, pane rendering and input all behave as before.

## Proof obligations

- PO1 (I1, I2): `just test` green, and
  `git ls-files '*Package.swift' | xargs grep -l 'swiftLanguageMode(\.v5)'`
  returns nothing. Scoped to tracked manifests because the bare string
  also lives in this plan and in two historical `plans/impl/` documents,
  where it is history and must stay. The added `nonisolated(unsafe)`
  occurrences are countable and number two.
- PO2 (I3): `checkpoint-off-main-lint.sh` stays green, and
  `app-tests/CheckpointScrollbackTailTests.swift` and
  `app-tests/PaneTapeFollowEncodingTests.swift` pass. The risk is that an
  isolation change silently pulls deferred work onto the main actor; the
  lint catches that structurally and the tests behaviorally.
- PO3 (I4): `app-tests/IpcServerOwnershipTests.swift` and
  `lib/DanTermSupport/Tests/DanTermSupportTests/ControlSocketListenerTests.swift`
  pass unchanged -- together they already pin single-threaded close,
  identity-guarded unlink, and one-winner concurrent `open`. Once-only
  close is new behavior with no existing coverage and needs its own test.
  Note the suite races `open`, never `close`. The new test must pin both
  halves of I4: concurrent close attempts unlink once and close the fd
  once, *and* every one of those calls observes the socket path already
  gone by the time it returns -- the loser returning early is the failure
  a bare atomic flag would let through.
- PO4 (I5, I6): `just test-ui` passes all 258 tests. This is the only
  behavioral coverage for four of the five files -- `SidebarView`,
  `TodoInputView`, `SwiftTerminalSessionView`, and `ThemeCatalog` are in
  the harness's compile list and none appear in `app-tests/`. The gate
  excludes it, so it must be run explicitly.
- PO5 (I6): sidebar rename specifically --
  `tests-ui/SidebarRenameRecycleTests.swift` covers commit, cancel,
  pointer click-away, cell recycling, and reconcile-driven cancellation.
- PO6 (I6): swatch color projection specifically. The only assertion on
  exact swatch colors today reads `catalog.colors["Fixture"]` and checks
  the background's red component
  (`tests-ui/ThemeBrowserViewTests.swift:16`); moving the projection
  deletes the property it reads, so "the suite still passes" is not
  proof -- the assertion could be weakened or dropped just to restore
  compilation. Re-express it at the projection's new home against the
  same fixture theme, and keep it an exact-value check: the fixture's
  `#040506` background must reach the rendered swatch as red 4, green 5,
  blue 6. A broken projection otherwise leaves swatches blank or wrong
  with every named verification green.

## Non-goals

- The accept-loop fd lifetime (AR2) is not addressed.
- The `AssociatedKeys.renameTarget` duplication is not removed (RI2).
- No change to how the UI harness compiles; `test-ui.sh` invokes `swiftc`
  directly and sets no language mode.
- No new ADR. `docs/design/2026-05-28-pure-core-support-split.md` already
  carries the language-mode statement and is amended in place.

## Accepted risks

- AR1: Moving the `NSColor` projection out of `ThemeCatalog` builds swatch
  colors per cell rather than once at catalog load. Accepted: seven
  `NSColor`s per visible row in one table.
- AR2: `close()` calls `Darwin.close(fd)` while the accept queue may be
  parked in `Darwin.accept(fd)` (`app/IpcServer.swift:30`). That is not a
  defined wakeup on Darwin, and a freed fd number can be reused by a later
  in-process `socket()`/`open()`, leaving the parked thread accepting on
  someone else's descriptor. Nothing joins or signals `acceptQueue`. The
  serialized close makes the double-close impossible but does not give
  the loop a termination signal; that needs `shutdown(2)` before close,
  or a self-pipe/kqueue. Deliberately left out so socket lifecycle design
  does not ride inside a language-mode migration. No test covers close
  against a live accept loop -- `start()` is never called in any existing
  test.
- AR3: Code behind `#if DANTERM_TERMINAL_BENCHMARK` is not compiled by an
  ordinary build, so the flip does not prove it is `.v6`-clean. One known
  site is the `DispatchQueue.main.async` at
  `app/SwiftTerminalSessionView.swift:484`.

## Rejected ideas

- RI1: `.defaultIsolation(MainActor.self)` on the app target. This is the
  idiomatic Swift 6.2 answer for an AppKit target and it is wrong here,
  measured at **17 distinct error sites against 7**. The symlinks pull the
  pure layers into the target, so default isolation main-actor-isolates
  them: it reports `CheckpointCapture.encoder`'s deferred work calling
  "main actor-isolated" functions from a nonisolated context, which is
  precisely the off-main encoding `checkpoint-off-main-lint.sh` exists to
  protect. The dial cannot express "main-actor except the two pure modules
  compiled inside it." Recorded because it is the first thing a reviewer
  will reach for.
- RI2: Deleting `AssociatedKeys.renameTarget` in favor of the
  `ViewLocalState` sidecar. The two values never diverge, so this is the
  ideal end state, and it is not being dropped for diff size -- it is a
  behavioral refactor carrying its own risk and its own coverage gap. It
  requires widening the reconciler's `clearActiveRename: Bool` to carry
  the target, re-expressing recycled-cell staleness as an identity
  comparison, and moving the sidecar clear ahead of `abortEditing()` /
  `makeFirstResponder(nil)` on both finish paths so the reentrancy guard
  still fires. No test drives a *group* inline rename to commit or cancel,
  so those branches are unexercised today. Folding it in would make a
  behavior regression look like a concurrency fix. `AssociatedKeys.groupId`
  stays regardless: it is a target-action payload on a caret button, which
  the sidecar has no equivalent for.

## Critical files

- `Package.swift` -- all eight `.v5` targets, not just `DanTerm` and
  `DanTermAppTests`.
- `app/ThemeCatalog.swift`, `app/ThemeSwatchViews.swift`;
  `app/ThemeRenderBridge.swift` is the existing `Sendable` path to reuse.
  `tests-ui/ThemeBrowserViewTests.swift:9` holds the exact-color
  assertion that has to move with the projection (PO6).
- `lib/DanTermSupport/Sources/DanTermSupport/ControlSocketListener.swift`,
  `app/IpcServer.swift`.
- `app/SwiftTerminalSessionView.swift` -- conformance list only.
- `app/TodoInputView.swift`, `app/SidebarView.swift`.
- `docs/design/2026-05-28-pure-core-support-split.md` -- amend the
  strict-concurrency bullet once the app target is `.v6`. As written it
  says the nested packages build at `.v6`, which is true and incomplete:
  it reads as "these files are strictly checked" while the root manifest
  was recompiling them at `.v5`. The amendment states the invariant as
  "no target anywhere is below `.v6`."

## Verification

1. `just test` -- the gate, including `checkpoint-off-main-lint.sh` and
   the package suites.
2. `just test-ui` -- explicitly, since the gate excludes it and it is the
   only behavioral coverage for four of the five files.
3. `just launch-slot`, then drive the slot over an explicit
   `danterm --socket` to smoke what no suite covers headlessly: open a
   pane, switch theme, inline-rename a group in the sidebar, and quit
   cleanly to exercise control-socket teardown.
4. Per commit before the flip: temporarily set the app target to `.v6`,
   confirm the expected sites are gone and no new ones appeared, then
   revert the manifest. Re-measure rather than trusting the count of 7 --
   fixing one isolation error routinely reveals the next.

## Implementation discretion

- Which mutual-exclusion primitive `ControlSocketListener` uses, as long
  as one critical section spans the whole close: `Synchronization.Mutex`
  (already used in the core test helper), `NSLock`, or `os_unfair_lock`.
  A bare atomic flag is not in scope -- it cannot satisfy I4.
- Where the moved `NSColor` projection lands relative to
  `ThemeSwatchViews`.

## Commit progress

- [x] 1. `build: compile every already-clean target in Swift 6 language
  mode` -- the six root targets that need no code change, closing the gap
  between the nested manifests and the shipping build.
- [x] 2. `refactor(theme): make the theme catalog sendable` -- move the
  `NSColor` preview projection to the swatch consumer, carrying its
  exact-color assertion with it (PO6).
- [x] 3. `fix(ipc): close the control socket exactly once under a race` --
  `Sendable` listener plus a mutex spanning the whole close, with the
  concurrent-close test from PO3.
- [x] 4. `refactor(app): state observer-token and associated-key isolation`
  -- `TodoInputView` token type, `SidebarView` key addresses.
- [ ] 5. `refactor(app): compile the app target in Swift 6 language mode`
  -- isolated `NSTextInputClient` conformance, `DanTerm` and
  `DanTermAppTests` to `.v6`, design doc amended.

Commit 1 is a manifest-only change, verified green before this plan was
written. Commits 2-4 stand alone and stay green with the app target still
at `.v5`; only 5 flips it.

## Implementation notes

- Commit 2: `ThemeCatalog` declares `Sendable` conformance explicitly. The
  Decision says the catalog "needs no annotation", which holds for
  isolation annotations, but a final class never gets implicit `Sendable`
  the way a struct does, so `static let shared` still needs the stated
  conformance to satisfy I1. No `@MainActor` and no `nonisolated(unsafe)`
  were added, so I2 is intact.
- Commit 2: the moved projection is `ThemeCatalog.swatchColors(named:)`,
  an extension living in `app/ThemeSwatchViews.swift` beside its only
  caller. It builds from `theme(named:)` (already `Sendable`) rather than
  from `renderTheme(named:)`, because `RenderTheme` exposes its palette as
  a fixed `RenderANSIColors` and the swatch needs the plain 1...6 slice.
- Commit 2: PO6's assertion moved with the projection and was widened from
  the background's red channel alone to all three channels. Verified by
  ablation -- swapping green for blue in the projection fails the test
  with `(4, 6, 6)`, and restoring it passes.
- Commit 3: the primitive is `Synchronization.Mutex(false)` holding the
  `isClosed` flag, with `withLock` spanning the flag check, the
  identity-guarded unlink, and `Darwin.close`, so a caller that finds the
  work done has waited for it. The new concurrent test fails against the
  old bare-flag guard exactly as I4 predicts.
- Commit 3: the fd-once half of I4 is pinned by a repeated close, not a
  concurrent one. A racing caller cannot reserve the freed descriptor
  number mid-race, so the test closes once, takes descriptors until one
  lands on the freed number, closes again, and asserts that descriptor is
  still open. Both paths go through the same guard.
- Commit 3: re-measuring the app target at `.v6` after this commit
  confirms the two `app/IpcServer.swift` listener errors (`:8`, `:42`) are
  gone, and surfaces two the plan's table did not list, both at
  `app/IpcServer.swift:59`: `sending 'request' risks causing data races`
  and a sending-closure error on the `startReading(onRequest:)` argument.
  They were invisible when the plan was measured because root
  `DanTermSupport` still compiled at `.v5`; commit 1 flipped it, which is
  what makes `IpcConnection.startReading`'s `@Sendable` callbacks enforce
  sending at the call site. Commit 5 has to fix them to flip the target.

- Commit 4: the Decision's reading of the `TodoInputView` site is wrong on
  measurement. `Any?` is not what fails, and `app/ScrollableTerminalView.swift`
  is not a working precedent -- at `.v6` its `[any NSObjectProtocol]` deinit
  fails with the same "cannot access property ... with a non-Sendable type from
  nonisolated deinit" error. Retyping the token to `(any NSObjectProtocol)?`
  leaves the error in place verbatim. The real error is the deinit's isolation,
  not the property's type, so both sites take `isolated deinit`, which is I2's
  "stating its real isolation" -- both classes are `NSView` subclasses and so
  already main-actor, and `app/SwiftTerminalSessionView.swift:245` is the
  in-repo precedent for the spelling. The token keeps its real type anyway,
  as the Decision asks.
- Commit 4: `app/ScrollableTerminalView.swift` was not in the plan's site table
  or its critical files. It is the same observer-token slice as `TodoInputView`
  and blocks the commit-5 flip, so it is fixed here rather than deferred.
- Commit 4: re-measuring the app target at `.v6` after this commit leaves
  exactly commit 5's work -- the `NSTextInputClient` conformance at
  `app/SwiftTerminalSessionView.swift:63` and the two `app/IpcServer.swift:59`
  sending errors recorded under commit 3. No `TodoInputView` or `SidebarView`
  site remains.
- Commit 4: the plan's step-3 smoke could not drive a sidebar group rename --
  the CLI has no `group` command, so no inline rename is reachable over the
  control socket. PO5's `tests-ui/SidebarRenameRecycleTests.swift` is the
  coverage that stands. The rest of the smoke ran on a slot: new tab, split
  pane, `theme set`, `pane input`/`pane read` round trip, and a clean quit that
  unlinked the control socket.

## Follow Up

- `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift:781`
  ("owner-originated bytes cross without an origin stamp") flaked once
  during this commit's gate run: the observed writes were
  `[ESC [ 3;13R, "hi"]`, an unexpected cursor-position report ahead of the
  expected bytes. It passes on re-run and is unrelated to this plan, but
  the test admits a stray device-status reply into its event list.
- The CLI has no `group` command, so sidebar group rename -- the exact behavior
  the associated-object keys carry -- cannot be driven or verified over the
  control socket. `integrations/danterm/SKILL.md:28` lists `tab rename` with no
  group counterpart. A `danterm group rename --group <id> <name>` would close
  the gap that made commit 4's prescribed smoke unreachable.
