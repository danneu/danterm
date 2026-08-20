# RUNTIME-4: one owner per armed scheduled resource

## Context

Audit item RUNTIME-4 in `docs/scratch/2026-08-18-construction-audit.md`
(confirmed verbatim against `master` at `f079a56a`; the same finding was S24
in `docs/scratch/2026-08-11-simplification-audit.md`). `AppRuntime` stores
each scheduled resource as two fields kept in step by hand: a handle
(`DispatchSourceTimer`, `NSEvent` monitor, `IpcServer`) and its
`AppRuntimeSchedulingToken`. Five pairs live in `app/AppRuntime.swift`
(light checkpoint timer, enriched checkpoint timer, coalesced reconcile
timer, switcher event monitor, IPC server) and a sixth in
`app/PaneHost.swift` (`searchDebouncer` / `searchDebounceToken`). The
guards read the handle (`lightCheckpointTimer == nil`,
`coalescedReconcileTimer != nil`) while cancellation goes through the token;
each timer handler hand-clears both halves inside `schedulingLifecycle.run`;
the cancel triplet `cancel(token); token = nil; handle = nil` is written at
nine sites; and `shutdown()` ends with a ten-line nil block after
`schedulingLifecycle.shutdown()` has already fired every cancel closure.

Desired outcome: a live handle with no census entry, and a census entry whose
handle is gone, stop being representable. The census (`AppRuntimeSchedulingLifecycle`)
keeps its contract and stays the only window tests have onto runtime
ownership.

Premises verified on the current tree:

- No test reads any of the twelve fields; every test observes this code
  through `captureOwnerCensus()`.
- `applyRecoveryAction(.schedule)` re-arms the enriched timer from inside the
  handler that just consumed its own token.
- Fail-closed behavior is uneven today. The three `DispatchSourceTimer` arm
  sites cancel the fresh timer and store nothing when `arm` returns nil. The
  search needle schedules its reusable `Debouncer` before it calls `arm`, so a
  refused registration leaves that fire scheduled (inert, because the fire
  guard re-reads the token). The switcher monitor and the IPC server are armed
  in `init`, before shutdown is reachable, so they have no such path. I3 makes
  the retirement uniform across all six boxes.
- The search debouncer is `Debouncer`'s only production caller.
- RUNTIME-3, RUNTIME-2, RUNTIME-6 and PERSIST-2 have landed, so the audit's
  sequencing caveats no longer apply. No worktree or uncommitted change
  touches these files.

## Decision

Introduce one census-owned box type beside `AppRuntimeSchedulingLifecycle`:
a main-actor reference type generic over the concrete handle that owns the
handle, its census token, and the retire closure together. Each of the six
pairs becomes one field of that type. The box is parameterized on the
census category, so it covers the event monitor, the IPC server and the pane
search debouncer as well as the three timers -- a timer-only type would leave
half the pairs hand-paired and weaken the by-construction claim.

Decisive constraints:

- D1. The census owns an armed box. Arming registers the box with the
  lifecycle and that registration retains it until cancel, fire, or
  `shutdown()` removes it; the box's route back to the lifecycle is
  non-owning. Dropping every external reference to an armed box therefore
  cannot strand a census entry whose handle is gone -- the entry is the
  handle's owner.
- D2. Every arm carries an identity, and a fire callback names the arm that
  created it. A callback from a superseded or cancelled arm does nothing: it
  consumes no census entry, clears no box state, and runs no handler.
- D3. The retire closure the box registers in the census clears the box
  itself. `schedulingLifecycle.shutdown()` therefore empties every box, and
  the nil block in `shutdown()` is deleted, not translated into per-box
  cancels.
- D4. The pane search box owns a one-shot main-queue timer, not a
  `Debouncer`. `Debouncer` reuses one dispatch source across fires, so its
  lifetime is wider than any single census arm and it would be the one
  resource in the refactor still holding a live source with no census entry.
  Re-arming cancels the previous one-shot timer and arms a fresh one (D2,
  I4), which is the same trailing-edge coalescing the search needle has
  today. `Debouncer` and `DebouncerTests` are deleted with their last caller.
  The `.debouncer` census category keeps its name; it names the purpose, and
  changing the census surface is a non-goal.
- D5. Owners that retire their token with `run` rather than `cancel` because
  the cancel closure would close a client's socket (`RosterSubscriber`,
  `PaneTapeBroker.FollowTransport`) are not this shape and stay as they are.
- D6. `ipcServerStartToken` is a token-only one-shot, not a pair; it stays a
  bare token.
- D7. `AppRuntime` still has no `deinit`, and the box adds none: no box
  reaches the runtime strongly, so releasing the runtime off the main actor
  stays safe (`docs/design/2026-06-09-appkit-lifetime-safety.md`).

Critical files: `app/AppRuntimeSchedulingLifecycle.swift` (new type, or a
sibling file added to the explicit source list in `test-ui.sh`),
`app/AppRuntime.swift` (field block, init IPC arm, switcher monitor install,
`dispatchInFrame`, `stopIpcServer`, `shutdown`, the `.terminate` arm, the
search-needle arms, the three timer arm sites and their cancel sites),
`app/PaneHost.swift` (search debounce pair and `tearDown`),
`lib/DanTermSupport/Sources/DanTermSupport/Debouncer.swift` and its test file
(deleted).

## Invariants

- I1. Arming a box adds exactly one census entry in its category; cancelling
  it, firing it, or shutting the lifecycle down removes that entry and leaves
  the box unarmed. "Armed" as the box reports it and "present in the census"
  never disagree, and while armed the census entry owns the box, so no
  external release can separate them.
- I2. A box's retire mechanism runs at most once per arm, on whichever of
  cancel or lifecycle shutdown comes first, and never on fire.
- I3. Arming while the lifecycle is shut down retires the offered handle
  immediately and leaves the box unarmed and the census empty (fail closed).
- I4. Arming a box that is already armed retires the previous owner first;
  the census count for that box never exceeds one.
- I5. A fire consumes the box's census entry before the handler runs, so a
  handler may re-arm the same box; after such a handler the census holds
  exactly the new entry.
- I6. A fire callback belonging to a superseded or cancelled arm is inert. It
  cannot consume the current arm's census entry, clear the current arm, or
  deliver its own stale payload.
- I7. Runtime behavior is unchanged: the coalesced reconcile window, both
  checkpoint tiers, the enriched rescheduling loop, the switcher monitor, IPC
  start/stop, search debounce (an empty needle and one of 3 or more
  characters deliver immediately; 1-2 characters deliver on a 300 ms
  trailing edge, and any new needle retires a pending one first, so a
  superseded short needle is never delivered), `.terminate`, and
  `shutdown()` all arm and retire the same census categories at the same
  moments as today.
- I8. A runtime released off the main actor after `shutdown()` still
  deallocates.

## Proof obligations

- PO1 (I1, I2, I3, I4, I5): box-level tests against a real
  `AppRuntimeSchedulingLifecycle` in `app-tests/`, observing
  `captureOwnerCensus()`, the box's armed state, and a retire counter. Include
  the handler-re-arms case and the arm-after-shutdown case.
- PO2 (I1 ownership): arm a box, drop every external reference to it, and
  prove the census still holds the entry and still retires the handle on
  `shutdown()`.
- PO3 (I6): two scenarios, because a superseded arm and a cancelled arm are
  different states -- one leaves a new identity installed, the other leaves
  none.
  - Supersede: arm a box, keep its fire callback, re-arm it, then invoke the
    stale callback -- the new arm and its census entry survive untouched and
    no handler runs.
  - Cancel: arm a box, keep its fire callback, cancel it, then invoke the
    stale callback -- the census stays empty, the box stays unarmed, and no
    handler runs.
- PO4 (I1 for timers): a box armed as a real main-queue timer fires once and
  the census returns to empty; the wait is a hang guard, not a threshold
  (30 s under a one-minute backstop, expiry throws `POSIXError(.ETIMEDOUT)`).
- PO5 (I7): existing characterization tests stay green untouched --
  `AppRuntimeSchedulingLifecycleTests`, the enriched arm/retire assertions in
  `AppRuntimeAmbientCommandTests`, the `.debouncer` / `.subscription`
  assertions in `AppRuntimeSessionCommandTests`, `AppRuntimeRosterPushTests`,
  `PaneTapeBrokerRuntimeTests`, `IpcServerRemoteTests`. Three tests are added,
  because no current test covers these paths:
  - a coalescing `Msg` arms one `.timer`, a non-coalescing `Msg` retires it,
    and a later coalescing `Msg` arms again -- asserted as a delta, because
    the light-checkpoint timer may also be armed in the same frame;
  - the search needle contract in I7, covering a burst of 1-2 character
    needles (the `.debouncer` census holds one entry and only the last needle
    is delivered, once), and both immediate transitions out of a pending short
    needle -- short then empty, and short then 3 or more characters. Each
    proves the immediate needle is delivered at once, the `.debouncer` census
    is empty afterwards, and the superseded short needle never arrives. This
    is the coverage `DebouncerTests` used to carry, restated at the behavior
    the runtime actually promises;
  - a runtime constructed with application services started shows one
    `.ipcServer` and one `.eventMonitor` entry; `stopIpcServer()` removes the
    `.ipcServer` entry and releases the control socket; `shutdown()` empties
    the remaining `.eventMonitor` entry.
- PO6 (I8): `AppRuntimeDeallocationTests` stays green.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing `AppRuntimeSchedulingLifecycle`'s surface or the census
  categories.
- Non-goal: folding `RosterSubscriber` / `FollowTransport` or any `run`-retired
  token into the box.
- Accepted risk: an owner that drops the runtime without calling `shutdown()`
  runs no retire closure, so native registrations armed at the time -- the
  local event monitor, an un-cancelled dispatch source, the listening socket
  -- survive the release. The boxes themselves do not leak: the runtime owns
  the census, so they are freed with it. This is the lifetime contract the
  runtime already has (`docs/design/2026-06-09-appkit-lifetime-safety.md`);
  the app always shuts down before release.
- Accepted risk: the search needle allocates one dispatch timer per debounced
  keystroke instead of rescheduling a shared source. `Debouncer` existed to
  avoid that churn; at typing rates over 1-2 character needles the cost is
  not measurable, and uniform ownership is worth it.
- Rejected: a timer-only `ScheduledTimer` type (the audit's name). It covers
  three of six pairs and leaves the rest hand-paired.
- Rejected: a value type for the box. Timer and census callbacks must reach
  back into the box to clear it, which a struct cannot offer.
- Rejected: the box reaching the census weakly and the external field owning
  the box. Releasing an armed box then leaves a census entry whose retire
  closure does nothing -- exactly the state this plan removes.

## Implementation discretion

- Box name, file placement, and whether timer construction is a convenience
  on the box or a free helper.
- How arm identity is represented (generation counter, per-arm token
  comparison, or a per-arm callback object).
- Which target the application-services census test lands in, if installing a
  local event monitor turns out to need a WindowServer connection.

## Verification

- `swift test --package-path lib/DanTermSupport` loses `DebouncerTests` with
  `Debouncer`; the app-tests target carries the new tests. Run the gate once
  into a file: `just test > .build/test.log 2>&1`, then grep the file.
- `just test-ui > .build/ui.log 2>&1` to confirm the UI harness still
  compiles (relevant if the box lands in a new `app/` file).

## Commit progress

- [x] 1. refactor(runtime): give each scheduled timer one census-owned owner
- [ ] 2. refactor(runtime): put the event monitor and the IPC server in owners
- [ ] 3. refactor(pane): own the search debounce timer through the census

## Implementation notes

- Commit slicing: the owner type lands with the three `DispatchSourceTimer`
  pairs rather than on its own, so no commit adds a type with no caller. The
  ten-line nil block in `shutdown()` loses its timer half here and disappears
  with the last two pairs in commit 2.
- The owner keeps a `weak` route to the lifecycle. A `PaneHost` box can outlive
  the runtime's release path, and an `unowned` read would trap there. A nil
  lifecycle retires the current arm directly, which is the same observable
  outcome as the census route.
- A fired one-shot timer is released, not cancelled (I2). `libdispatch` only
  refuses to release a *suspended* object, and only file-descriptor and mach
  port sources need a cancel handler to retire safely (the pinned `libdispatch`
  checkout, `man/dispatch_source_create.3`), so dropping the last reference
  to a resumed timer that already fired is safe. The old code cancelled it from
  inside its own event handler.
