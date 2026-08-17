# Replace the whole-AppModel golden snapshot with a replay-determinism test

## Context

`GoldenMasterTests.swift` drives a fixed `Msg` sequence under a deterministic
`CoreEnv` and then calls `assertSnapshot(of: model, as: .customDump)` on the
entire `AppModel`. The commit that introduced it (`df3f7608`) states its
purpose: "catch future ambient UUID or Date leaks."

It does not do that reliably, and it charges rent for the attempt.

- **It pins field shape, not determinism.** The recorded file is a
  field-by-field dump of `AppModel`, `PaneModel`, and `SessionModel`. Any pure
  data-model move breaks it, and the fix is always to re-record. `8c34a41f
  "refactor(sidebar): interaction path reads the applied projection"` changed
  the snapshot by exactly one line, `+ sidebarRenameTarget: nil` -- a sidebar
  refactor re-recording a core determinism golden with zero determinism signal.
  23 commits have rewritten the file, 5 of them in the four days to 2026-08-14,
  after the audit named the problem.
- **Re-recording is how a real leak would get blessed.** The test detects an
  ambient `UUID()` leak only as an unfamiliar id inside a 191-line diff that
  the author has been trained to accept as routine. The failure mode it exists
  to catch looks exactly like the churn it produces.
- **It contradicts a written project rule.** AGENTS.md, Tests: "Assert
  observable behavior and architecture boundaries, never the structure of a
  private helper: a refactor that keeps the behavior must keep the test
  passing."
- **It is the only reason `swift-snapshot-testing` is in the graph**, and that
  package is the only path by which `swift-syntax` reaches `lib/DanTermCore`.
  Both compile on every run of `swift test --package-path lib/DanTermCore` --
  the ~1-2s inner loop the pure-core ADR treats as a feature.

This is finding S36 of `docs/scratch/2026-08-11-simplification-audit.md`, a
symptom of its theme T2.

**Intended outcome.** The determinism property is asserted directly, in a form
that cannot be re-recorded and does not move when a field moves; the golden
file and both dependencies go away; and the replacement covers strictly more of
the seam than the golden did -- including the second clock site the golden
never reached.

## The contract

The golden's real property is: **the model is a pure function of (messages,
env).** That is testable without naming a single field.

### D1. Replay determinism

Drive one message sequence twice, each run against its own freshly built but
identically parameterized test env, and assert the resulting models are equal.
An ambient `UUID()` or `Date()` read anywhere in the reducer makes the runs
differ.

This subsumes the golden's stated purpose and is stronger: it catches a leak
into *any* field, including fields added after the test is written, because
`AppModel: Equatable` is compiler-synthesized (`Model.swift:473`; no
hand-written `==` exists anywhere in the core sources). Equality automatically
tracks the field list that the snapshot had to be re-recorded to track. There is
nothing recorded, so there is nothing to bless.

Failure diffs must stay readable, so compare with swift-custom-dump's
`expectNoDifference` rather than a bare equality check. That dependency stays
(`TreeOwnsPanesTests.swift` already imports `CustomDump`).

Two obligations make this arm correct rather than accidentally green:

- **Each run gets its own env value.** The test env's id cursor is state held
  inside the env value, so replaying against the same value continues the cursor
  and the models diverge on ids alone.
- **Both runs start from the same base model value.** The env-free model builder
  mints a random seed group id per call, so building the base twice makes the
  runs differ for a reason unrelated to the property.

### D2. Sensitivity, per axis

Vary the env and assert the model changes -- so D1 cannot go vacuous if the
sequence later stops exercising the seam.

- Runs must start from a **base model built without the env**. The env-taking
  model builder mints the seed group id, so a run starting there differs
  whenever the id sequence differs, even if every `update()` has stopped reading
  or forwarding `env`. Starting env-free means any observed difference is
  attributable to the reducer.
- The **id axis and the clock axis vary in separate comparisons**. Varying both
  at once lets a difference on one axis mask the total loss of the other.

### D3. Provenance, order-free

D1 and D2 prove the model is a function of the env. They do not prove the values
came from the *injected* env rather than some other deterministic source. Assert
that:

- The ids of the entities the exercised actions **create** -- pane, session,
  split, tab, group, alert -- are drawn from the injected id sequence.
  **Assert membership, not sequence position.** Which of pane, session, and
  split is minted first is not observable behavior -- all three are opaque
  UUIDs -- so pinning that order would recreate exactly the ratchet this plan
  removes. A reordering of the mints must keep this test passing; an ambient
  `UUID()` must fail it.

  Scope this to created entities only. Two id sources in the model are
  legitimately not from the sequence, and an assertion over *every* id in the
  model fails against correct behavior today: the base model's seed group id,
  which `D2` requires be minted env-free, and the request id the test itself
  puts in an IPC message, which the reducer stores in `pendingSessionCreations`.

  `D3` does not need to be exhaustive over entity kinds, and a later handler
  that mints a kind not listed here does not weaken the plan. `D1` is the total
  guard against ambient reads -- it covers every field including ones nobody
  enumerated. `D3`'s narrower job is only to show the values come from the
  *injected* sequence rather than another deterministic source, and a
  representative set of created entities settles that.
- Each of the two clock call sites writes the injected `now` into both fields it
  feeds: the alert's `createdAt` and `model.lastNotificationTime[paneId][kind]`.
  The sites are `Update.swift:676` (`case .sessionBell`) and `Update.swift:1943`
  (`desktopAlertCommands`, reached from `case .sessionNotification`); those two
  are the only `env.now()` reads in the core. No test in the suite asserts a
  `createdAt` against an injected clock today, and the golden covered only the
  first site.

### D4. Path coverage the driver must reach

The sequence must exercise: top-level mints, recursive `update()` forwarding
(`createGroup` -> `createTab`, `Update.swift:930`), IPC dispatch,
`navigateToPane` (`Update.swift:1772`, which forwards `env` into a nested
`update()`), and the alert clock read. The golden's existing message sequence
already covers all of these and is the obvious starting point.

Two coverage obligations:

- **The driver forwards `env` on every `update()` call.** Several
  `TestSupport.swift` helpers (`createTab`, `confirmPending`, `cancelPending`)
  call `update` with the ambient default, so routing through them silently
  drops the seam under test.
- **Drive IPC by constructing the request message directly.**
  `UpdateIpcTests.swift`'s `sendIpc` helper is private to that file, and using
  it would *lose* coverage: it auto-fires `sessionProcessStarted` for every
  `createSession` command it sees. The golden is the only test that observes
  `pendingSessionCreations` in its mid-flight state, and driving the raw message
  keeps that under D1.

## Work

Two commits. The second is a follow-on the first makes possible; it can be
dropped without harming the first.

### Commit 1 -- retire the golden

1. Add D1-D3 to `DeterminismSeamTests.swift`, driven by a shared helper meeting
   D4. That file is the right home: its header already claims the seam's three
   axes -- "home, ids, time" -- while 5 of its 7 tests cover the home axis, 1
   covers restore-path ids, and none touches the clock. Its
   `idLessRestoreMintsFromInjectedSequence` is the direct sibling of D3's id
   assertion (same property, restore path instead of `update()`).
2. Delete `GoldenMasterTests.swift` and the `__Snapshots__/` directory -- the
   golden is the repo's only snapshot test.
3. Drop `swift-snapshot-testing` and its products from
   `lib/DanTermCore/Package.swift`, along with the test target's
   `__Snapshots__` exclusion. **Keep** `swift-custom-dump`.
4. Rewrite the two places that record the golden as live: the
   `modelStaysHomeCleanUnderAmbientHome` preamble in `DeterminismSeamTests.swift`,
   which cites it as the beneficiary of the home-clean premise, and the
   Consequences bullet at `docs/design/2026-05-28-pure-core-support-split.md:345`
   ("`GoldenMasterTests` was already home-clean ... and needed no change").
   `scripts/docs-lint.py` checks cited paths, not symbol names, so neither fails
   the gate -- they just go quietly wrong, which is the failure mode S08 and S10
   were about.

Nothing outside this package is affected: no `Package.resolved` is tracked, and
the root `Package.swift` does not depend on `lib/DanTermCore` at all -- the app
compiles those sources through the `app/DanTermCore` symlink. Leave the
historical plan records under `plans/impl/` alone; they are dated accounts, not
live claims.

### Commit 2 -- a controllable test clock, and the throttle tests that need it

D3 asserts the clock's value but cannot reach both sides of the throttle
boundary, because the test env freezes `now` to one constant: with a single
`now`, `timeIntervalSince(last) == 0 < notificationThrottleInterval`
(`Update.swift:1918`, currently `1`), so a second notification for a (pane,
kind) pair is *always* throttled. The golden's throttle coverage was that
accident rather than a choice.

The two tests that own this behavior inject no clock at all:
`UpdateSessionEventTests.testBellThrottling` and
`testDesktopNotificationThrottlesIndependentlyFromBell` assert
`model.lastNotificationTime[...][kind] != nil` -- presence, never value -- and
pass only because their two `update()` calls land inside the 1-second window in
ambient wall-clock time. Not an observed flake, but a real wall-clock dependency
inside a suite whose whole premise is a pure core.

1. Give the test env a clock the test can advance, concurrency-safe under
   `CoreEnv`'s `@Sendable` seams. The existing constant-`now` call signature
   must keep working -- every current caller passes a `Date` or nothing.
2. Convert both throttle tests to the injected clock: assert
   `lastNotificationTime[...][kind]` **by value**, and pin both sides of the
   boundary -- throttled at `+0s`, delivered at `+notificationThrottleInterval`.
3. Delete the dead `model.lastNotificationTime[paneId] = [.bell: Date.distantPast]`
   line in `UpdateAlertTests.testAlertHistoryCappedAt100`. It is a no-op: the
   test appends its 100 alerts to `model.alerts` directly and never runs a
   `sessionBell` first, so `lastNotificationTime` is empty and
   `throttledNotification` already takes its `shouldNotify = true` branch
   (`Update.swift:1973-1978`). The test asserts nothing about notifications;
   it needs no clock.

## Verification

1. **Watch D1 fail for the right reason** (AGENTS.md TDD: write it first).
   Temporarily change one `env.newId()` call site to a bare `UUID()` and
   confirm the arm fails with a structural diff naming that id. Then
   temporarily change `Update.swift:676` to a bare `Date()` and confirm it
   fails on `createdAt`. Revert both. This is the check the golden was supposed
   to provide, and the one thing that proves the replacement replaces it.
2. **Watch each D2 axis fail for the right reason.** Hold the varied axis
   constant and confirm that comparison fails; revert. Do this per axis -- that
   is what proves the axes are independent.
3. **Watch D3's id assertion survive a reordering.** Swap two `env.newId()`
   calls within one handler and confirm every test still passes. If one fails,
   it is pinning allocation order and must be loosened.
4. **Watch the throttle assertions fail for the right reason** (commit 2).
   Temporarily set `notificationThrottleInterval` to `0` and confirm the
   throttled-at-`+0s` side fails.
5. **Run the package suite once, into a file, and grep it:** `swift test
   --package-path lib/DanTermCore > .build/core.log 2>&1`. Expect the new tests
   passing and no `GoldenMasterTests`.
6. **Confirm the dependency is out of the graph** -- structural, not timing:
   `swift package --package-path lib/DanTermCore show-dependencies` must list
   neither `swift-snapshot-testing` nor `swift-syntax`.
7. **Run the full gate:** `just test`.

## Non-goals and accepted risks

- **AR1. No build-time claim.** `swift-syntax` is genuinely compiled in this
  package today (`SwiftSyntax.build` is present under
  `lib/DanTermCore/.build/`), so a cold-build improvement is likely, but the
  removal is justified by the retirement rule and the ratchet, not by a number.
  Per `agent-docs/measurement-discipline.md`, any figure quoted in a commit
  message needs a before/after cold build behind it.
- **AR2. `D3` is loose by construction.** It pins neither mint order, nor mint
  count, nor the full set of entity kinds, so a handler may mint one more id, one
  fewer, or one of a kind `D3` does not name, without failing. That is
  deliberate on all three counts: none of them is observable behavior, `D1`
  already guards ambient reads totally, and the test env records an issue when a
  sequence is over-consumed. Tightening `D3` toward exhaustiveness would buy a
  ratchet, not a guarantee.

## Implementation discretion

Reserved for the implementer; deciding these differently changes no behavior,
invariant, or architectural direction:

- The driver helper's name, signature, and whether the arms share one helper or
  several.
- The exact message sequence, so long as it meets D4.
- How the controllable clock carries its state, and how a test advances it.
- Test-local id values and prefixes, assertion and unwrap style, and the
  arrangement of new tests within the file.

## On the two "Settle these first" blockers

Neither gates this work.

- **The seam rule** -- constructor-injected collaborators yes, conditional
  test-only branches no -- governs S12, S20/S33, and S21: the production PTY
  actor and the AppRuntime `Ports` split. Stating it explicitly for this plan:
  *nothing here adds a production seam or a test-only branch.* The `CoreEnv`
  seam is already constructor-injected -- `update(_:_:env:)` takes it as a
  parameter with a `.live` default (`Update.swift:7-11`) -- and every change,
  including commit 2's clock, lives inside the test target. The rule is
  satisfied by construction.
- **Probe files / research/31/D4** governs S37, the next row in the table.
  `D4` freezes the scrollback eviction-comparison probe arms in
  `lib/TerminalCore` (`docs/research/31-logical-line-scrollback/README.md`,
  frozen 2026-08-04 at `de17e95`). It says nothing about DanTermCore, the
  golden snapshot, or `swift-snapshot-testing`. No frozen research artifact
  covers anything this plan touches.

S36 and S37 both sit in the `tests` area and both edit a `lib/*/Package.swift`
test target, but in different packages. They do not conflict and can land in
either order.

## Implementation notes

- **The driver adds `.sessionNotification` to the golden's sequence.** The golden
  reached only the `sessionBell` clock site. `D3` requires both, and
  `desktopAlertCommands` is reachable only through `.sessionNotification`, so the
  driver fires one on the same pane after the bell. Per-kind throttling keeps the
  two independent, so both alerts are delivered and both write
  `lastNotificationTime`.
- **The `D2` sensitivity arms compute the `Bool` before `#expect`.** A bare
  `#expect(a != b)` captures both operands, so a failure prints two whole
  `AppModel` dumps (~10 KB each) and buries the message. `let differs = a != b`
  keeps the failure to one line plus the comment. Verified by watching each axis
  fail both ways.

## Commit progress
- [x] 1. test(core): assert replay determinism instead of a whole-model golden
- [ ] 2. test(core): give the test env an advanceable clock and pin the throttle boundary
