# Coalesce reconcile() for bell, desktop-notification, and command events

## Context

A latency investigation found two related triggers that fire one full,
unthrottled whole-model `reconcile()` sweep per event while a background pane is
busy:

- **#1 -- bell.** A background pane emitting `BEL` repeatedly (progress spinners,
  a `printf '\a'` loop, a misbehaving TUI) fires one inline `reconcile()` per
  bell. This is currently the only *unbounded* inline-reconcile trigger.
- **#2 -- command events.** DanTerm's shell integration emits
  `__DANTERM_EVT__:` events on the title channel, translated to
  `.commandStarted` / `.commandEnded`, on every command. A command loop
  (`for i in ...; do cmd; done`) produces one inline sweep per iteration.

Neither delays the user's keystroke (the key path emits no `Msg`), but both pile
`O(panes x tabs x alerts)` main-thread reconcile work onto the runloop while
panes are busy, competing with input.

The fix reuses the existing coalesced (~75 ms) view-sweep path: keep the model
mutation **inline** (so alerts / last-command / agent state are never lost) and
defer only the whole-model view sweep, exactly as `title` / `cwd` / `progress`
already do. This is the single-switch change the design doc's "Projection Scan
Cost" section names as the sanctioned response to "a credible high-pane or
high-tab performance report."

**Scope decisions** (see Safety argument for the verification behind each):

- **Include `.commandEnded`** -- its cleared fields (`isRemote`, `remoteSession`,
  `agentSession`, `remoteThemeOverride`) feed only cosmetic projections
  (`desiredPaneToolbar`, `desiredPaneConfig`), never `ContainerShape`. Verified.
- **Include `.desktopNotification`** -- identical handler shape and cost to bell;
  including it keeps the two alert paths consistent.
- **No new classification tier** -- reuse the single `Msg.coalescesReconcile`
  switch. The existing post-reconcile guard already makes opt-in safe.

Out of scope and explicitly *not* done here: the `O(panes x alerts)` per-sweep
alert-tally optimization (finding #3), clipboard / `supports_selection_clipboard`
(unrelated finding), and any change to the coalesce interval, `TickCoalescer`,
checkpoint/IPC, or AppKit executors.

## The change (one switch + its doc)

`lib/DanTermCore/Sources/DanTermCore/Msg.swift`, `var coalescesReconcile`. Add
two case groups before `default`, mirroring the existing grouped-by-why comment
style:

```swift
        // Background-pane alert badges. A bel/notify storm (spinner, `printf '\a'`
        // loop, OSC 9 burst) fires one full sweep per event; the alert is inserted
        // into the model inline (badge never lost) and the desktop notification
        // rides a non-post-reconcile .sendNotification, so only the cosmetic badge
        // sweep (reconcileSidebar / reconcileWindowChrome / reconcileFocusBorders /
        // reconcilePaneChrome unread-alert counts) defers.
        case .surfaceBell, .desktopNotification:
            return true
        // Shell-integration command events, one per prompt in a command loop.
        // commandStarted only sets pane.lastCommand, which no projection reads --
        // an empty view diff; its persistence rides .scheduleCheckpoint. commandEnded
        // clears agent/remote/theme, which feed only the pane toolbar
        // (desiredPaneToolbar) and per-pane theme (desiredPaneConfig) -- cosmetic,
        // never ContainerShape.
        case .commandStarted, .commandEnded:
            return true
```

Also rewrite the property's `///` doc comment. It is the contract, and one of its
sentences becomes false: today it claims the runtime "evaluat[es] this on the
translated message, keeping title-channel IPC events on the inline path" -- but
`.commandStarted` / `.commandEnded` *are* the translated title-channel events and
now opt in. Replace the enumeration and that sentence:

```swift
    /// Whether this message is eligible to defer its reconcile() sweep so bursts
    /// coalesce. A message opts in when its sweep is either empty (split-ratio:
    /// ContainerShape drops ratios; commandStarted: no projection reads
    /// lastCommand) or merely cosmetic and safe to throttle to ~13 Hz (title/cwd/
    /// progress, live search match count, background-pane alert badges, the
    /// remote/agent toolbar + per-pane theme a command event clears). update()
    /// still runs immediately, so the model stays current and the final value is
    /// never dropped; only the whole-model view sweep is deferred -- and the
    /// side-effecting commands these emit (.sendNotification, .scheduleCheckpoint)
    /// are not post-reconcile, so they still run inline. The runtime evaluates this
    /// on the translated message, so a title-channel `__DANTERM_EVT__:` event's
    /// eligibility is its translated case's: commandStarted/commandEnded opt in
    /// here; remoteSession start/report events stay inline. Eligibility is necessary
    /// but not sufficient: reconcileDecision still forces an inline reconcile when
    /// update() emitted a post-reconcile command, so opting a message in here is
    /// always safe.
```

No other source *logic* changes -- `reconcileDecision`, `translateMsg`, the four
`update()` arms, `send()`, and the coalesce-timer glue are all unchanged. Two
in-source *comments* that enumerate the coalesced set as "title/cwd/progress" do
go stale and are updated (comment-only) under Docs below.

## Safety argument

The change touches **only** the scheduling classification consulted *after*
`update(&model, translatedMsg)` runs in `send()`
(`app/AppRuntime.swift`, `func send`). The model mutation is therefore always
inline; `coalescesReconcile` cannot affect it. What defers is the cosmetic
whole-model view sweep. Per message:

| Message | Inline mutation (unchanged) | Inline command (not post-reconcile) | Deferred sweep reads -> pass | Touches `ContainerShape`? |
|---|---|---|---|---|
| `.surfaceBell` | insert `AlertModel` at 0, ack prior pane alerts, cap 100 | `.sendNotification` (throttled) fires inline | `model.alerts` unread counts -> `reconcileSidebar`, `reconcileWindowChrome`, `reconcileFocusBorders`, `reconcilePaneChrome` | No |
| `.desktopNotification` | same as bell | `.sendNotification` fires inline | same as bell | No |
| `.commandStarted` | `pane.lastCommand = command` | `.scheduleCheckpoint` runs inline | nothing -- no projection reads `lastCommand`; **empty diff** | No |
| `.commandEnded` | clear `isRemote`/`remoteSession`/`agentSession`/`remoteThemeOverride` | `.scheduleCheckpoint` (if had agent) runs inline | `agentSession`/`isRemote`/`remoteSession` -> `desiredPaneToolbar`; `remoteThemeOverride` -> `effectiveTheme` -> `desiredPaneConfig` -> `reconcilePaneConfig` | No |

Three load-bearing facts, each verified in source:

1. **`ContainerShape` excludes everything these messages touch.** Its definition
   (`ModelOperations.swift`, `struct ContainerShape`) is `{ tree:
   ContainerShapeNode, isZoomed: Bool, zoomedLeaf: PaneId? }`, where
   `ContainerShapeNode` is `leaf(PaneId)` / `split(id, direction, first, second)`
   -- pane *ids* and tree structure only, with the doc comment stating "Ratios and
   pane payloads are excluded." None of `lastCommand` / `agentSession` /
   `isRemote` / `remoteSession` / `remoteThemeOverride` / `alerts` appears in it.
   So a deferred sweep cannot desync AppKit container teardown -- the one failure
   mode the design doc warns about for coalescing.

2. **`commandEnded`'s theme revert is a cosmetic per-pane config apply.**
   `remoteThemeOverride` is read only by `effectiveTheme(for:)`
   (`ModelOperations.swift`: `pane.remoteThemeOverride ?? pane.theme`), consumed by
   `desiredPaneConfig` into `PaneConfigKey{theme, generation}` and applied by
   `reconcilePaneConfig()` (`app/Reconcile.swift`). That is a Ghostty per-surface
   theme apply -- visual only, no view teardown. A <=75 ms delay on a theme revert
   is imperceptible. (Note: `desiredThemeBrowser` deliberately reads `pane.theme`,
   not `effectiveTheme`, so the theme browser is unaffected either way.)

3. **The functional side effects do not defer.** `.sendNotification` and
   `.scheduleCheckpoint` are both in `Command.isPostReconcile`'s `return false`
   set (`Command.swift`; only `.makeFirstResponder` / `.focusSearchField` are
   post-reconcile), so `send()` performs them in its pre-reconcile command loop
   regardless of the decision. Desktop notifications still fire immediately and
   checkpoints still schedule immediately; only badge/toolbar/theme *chrome*
   waits. And because none of the four arms ever emits a post-reconcile command,
   `reconcileDecision` never force-inlines them -- they always coalesce.

**Delivery guarantee.** The coalesced sweep is a real `DispatchSourceTimer`
(`scheduleCoalescedReconcile`) that fires its own `reconcile()` after 75 ms even
with zero further traffic, so badges/toolbar/theme appear within ~75 ms of the
first event independent of any later message. Separately, any later inline-
reconcile message cancels the timer and flushes the sweep early
(`.reconcileNow` -> `cancelCoalescedReconcile(); reconcile()`), so a coalesced
change is never stranded. Both behaviors are existing runtime glue, unchanged.

## Tests (TDD: write the failing test first, watch it fail for the right reason, then edit `Msg.swift`)

**Primary -- the classification regression guard.** Update the existing decision
test in
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateGhosttyTests.swift`,
`@Test("reconcileDecision coalesces only eligible high-frequency messages")`
(`func reconcileDecisionCoalescesOnlyEligibleMessages`). Move `.surfaceBell` and
`.commandStarted` out of the `inlineMessages` array into `coalescedMessages`, and
add `.desktopNotification` and `.commandEnded` to `coalescedMessages`:

```swift
    let coalescedMessages: [Msg] = [
        .surfaceTitle(paneId: paneId, title: "vim"),
        .surfaceCwd(paneId: paneId, cwd: "/tmp"),
        .surfaceProgress(paneId: paneId, state: .set(percent: 50)),
        .splitRatioChanged(splitId: SplitId(), ratio: 0.3),
        .ghosttySearchTotal(paneId: paneId, total: 42),
        .ghosttySearchSelected(paneId: paneId, selected: 3),
        .surfaceBell(paneId: paneId),
        .desktopNotification(paneId: paneId, title: "build", body: "done"),
        .commandStarted(paneId: paneId, command: "make test"),
        .commandEnded(paneId: paneId)
    ]
    // ... existing 4-axis assertions (scheduleCoalesced / coalesceIntoPending /
    // reconcileNow-when-post-reconcile, for coalescedSweepPending true & false) ...

    let inlineMessages: [Msg] = [
        .preferencesOpened(ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14")),
        .preferencesClosed
    ]
```

`.preferencesOpened` / `.preferencesClosed` stay as inline controls so the test
still proves the classification is selective. The existing loop already asserts
both `coalescedSweepPending` true and false, plus the post-reconcile force-inline
axis -- no new assertion shape is needed, just the moved/added cases. Refresh the
test's Intent/Why/Scenario preamble to name the new coalesced triggers (bell,
desktop notification, command events).

This is the red->green step: before the `Msg.swift` edit these four cases hit
`default -> false` and the test fails asserting `.scheduleCoalesced`; after, it
passes.

**Second -- the "no post-reconcile command" durability guard.** The whole
performance win rests on safety fact #3 (these arms never emit a post-reconcile
command, so `reconcileDecision` never force-inlines them). The decision test does
*not* pin this -- it passes `emitsPostReconcile:` as a literal, so it only proves
`coalescesReconcile == true`. A future edit that adds, say, `.makeFirstResponder`
to the bell arm would silently force it back inline (defeating this change) with
no red test. Pin it by extending the existing property test
`@Test("surface metadata updates stay coalesce eligible")`
(`surfaceMetadataUpdatesStayCoalesceEligible`, `UpdateGhosttyTests.swift`), which
already asserts `commands.allSatisfy { !$0.isPostReconcile }` over a
`scenarios: [(Msg, AppModel)]` array. Add the four new messages, driven on the
*unfocused* pane (the existing `unfocusedPane` / `unfocusedModel` -- a pane left
unfocused after `.splitPane`) so bell/notification run the alert-creating path,
not the focused-pane `return []` suppression:

    (.surfaceBell(paneId: unfocusedPane), unfocusedModel),
    (.desktopNotification(paneId: unfocusedPane, title: "build", body: "done"), unfocusedModel),
    (.commandStarted(paneId: unfocusedPane, command: "make"), unfocusedModel),
    (.commandEnded(paneId: unfocusedPane), unfocusedModel)

Broaden the test's `@Test` title and Intent/Why preamble from "surface metadata
(title / cwd / progress)" to "coalesce-eligible messages" so the name stops
under-describing the set. Note `commandEnded` on a fresh pane returns `[]` -- a
vacuous-but-still-protective pass that still catches a future post-reconcile
addition; seed an `agentSession` on that scenario's pane first if you want the
assertion to also exercise its `.scheduleCheckpoint`-emitting branch.

**Inline-mutation guarantee -- already locked; do not duplicate.** The "model
still mutates inline despite the deferred sweep" guarantee is structurally
independent of this change (the mutation runs in `update()`, which is untouched),
and is already pinned by named tests that call `update(&model, msg)` and assert on
the model -- none of which reference reconcile scheduling, so all stay green:

- bell inserts an unread alert + notification: `testBellOnBackgroundPaneCreatesUnreadAlert`
  (`UpdateGhosttyTests.swift`)
- desktop notification inserts an unread alert: `testDesktopNotificationOnBackgroundPaneCreatesUnreadAlert`
  (`UpdateGhosttyTests.swift`)
- `commandStarted` sets `lastCommand`: `@Test("commandStarted sets lastCommand")`
  (`ExportTests.swift`)
- `commandEnded` clears remote + agent state: `@Test("commandEnded clears remoteSession too")`
  and `@Test("commandEnded clears agentSession and checkpoints local pane")`
  (`UpdateRemoteTests.swift`)

**Suppression + throttle -- already locked, unchanged.** Focused-pane suppression
(`testBellOnFocusedPaneIsIgnored`, `testBellOnFocusedPaneWhileInactiveCreatesAlertAndNotification`,
and the `DesktopNotification` equivalents) and per-kind notification throttling
(`testBellThrottling`, `testDesktopNotificationThrottlesIndependentlyFromBell`)
live in `UpdateGhosttyTests.swift` -- the same file as the decision test --
alongside `testThrottleIsPerPanePerKind` in `UpdateAlertTests.swift`. All exercise
only `update()`, so they remain valid.

This mirrors the precedent set by
`plans/impl/2026-05-27-coalesce-reconcile-split-search.md`, which added no second
test and justified it by existing coverage. Extend rather than duplicate: if the
implementer judges the coupling under-documented, the lightest touch is a single
sentence in the decision test's preamble cross-referencing the mutation tests
above -- not a new test that re-asserts an already-pinned mutation.

The ~6-line `switch reconcileDecision(...)` glue in `send()` stays manual-QA
territory (it has no pure-core seam), same as the prior coalesce plans noted.

## Docs

Update `docs/design/2026-05-27-model-driven-view-reconciliation.md` -- both
sections currently name title/cwd/progress as the *only* coalesced triggers:

- **"Scheduling And External Invalidation"** -- the set of coalesced "high-
  frequency cosmetic surface metadata" now also includes background-pane alert
  badges (bell / desktop notification) and shell-integration command events. State
  the cosmetic-not-structural justification: these feed only sidebar/window/
  focus-border/toolbar badge chrome and the per-pane theme (`desiredPaneConfig`),
  never `ContainerShape`, so the section's structural-message caveat does not
  apply.
- **"Projection Scan Cost"** -- change the parenthetical "the only rapidly-firing
  triggers (title, cwd, and progress)" to include bell/notification and command
  events.

Two in-source comments enumerate the same "title/cwd/progress" coalesced set and
must be updated to match (the `Msg.swift` doc rewrite above is the third), so the
codebase doesn't carry three disagreeing enumerations:

- `app/AppRuntime.swift`, the `///` doc on `scheduleCoalescedReconcile` ("Defer
  the whole-model reconcile() sweep while title/cwd/progress messages arrive at
  high frequency") -- broaden the enumeration to include background-pane alert
  badges (bell / desktop notification) and command events.
- `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, the "View Reconciler"
  header comment whose `O(panes x alerts)` justification reads "rapidly-firing
  title/cwd/progress updates are coalesced to about 75ms" -- broaden it the same
  way. This one *strengthens* its own argument: the alert-derived sweeps it names
  as the largest cost are now themselves coalesced, and its "inline reconciles are
  human-paced" claim becomes strictly truer (this change removes the two
  non-human-paced inline triggers). Comment-only; it does not perform the finding
  #3 tally optimization, which stays out of scope.

## Verification

- `just test` -- the local gate: protocol XCTest + core Swift Testing +
  DanTermSupport Swift Testing + core-purity lint (the `Msg.swift` change is pure
  core, no inject/ambient impact) + the five shell self-tests.
- While iterating: `swift test --package-path lib/DanTermCore --filter UpdateGhosttyTests`
  (covers the decision test *and* the bell/desktop-notification mutation,
  suppression, and throttle tests, which share that file) plus the alert suite
  (`swift test --package-path lib/DanTermCore --filter UpdateAlertTests`, for
  `testThrottleIsPerPanePerKind` and the alert-walk/manual-mode coverage).

**Acceptance.** `reconcileDecision` returns `.scheduleCoalesced` /
`.coalesceIntoPending` for all four messages (and `.reconcileNow` only when a
post-reconcile command is emitted, which these never do); the extended
coalesce-eligibility property test pins that all four `update()` arms emit no
post-reconcile command; each `update()` arm still mutates the model inline
(existing suites green); focused-pane suppression and notification throttling
unchanged; design doc plus the two stale in-source coalesced-set comments
updated.

## Non-goals / boundaries

- Not the `O(panes x alerts)` per-sweep alert-tally optimization (finding #3) --
  separate change, same hot path.
- No clipboard / `supports_selection_clipboard` changes.
- No change to `reconcileCoalesceInterval` (0.075), `TickCoalescer`,
  checkpoint/IPC, or any AppKit executor.
- Implementation only -- this is the plan. The eventual implementation **must
  branch first**: the current branch is `master`, and per `AGENTS.md` work is not
  committed directly to it.
- Ignore the unrelated untracked `plans/wip/*`, `research/`, `self-notes/` files
  in the tree; never `git add .`.

## Implementation notes

- Implemented directly on `master` after explicit user instruction, overriding
  the plan's branch-first boundary for this run.
