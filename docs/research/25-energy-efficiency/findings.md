# Findings -- append-only evidence chain

Code findings F1-F5 are from inspection at commit `1eff9b7` (2026-07-31,
dirty worktree; none of the uncommitted changes touch the cited paths except
`app/AppRuntime.swift`, whose cited symbols were verified present). F6 is an
external-guidance survey; every claim in it carries the URL it came from.

### F1 -- rendering is event-driven with no display link or poll

- Status: established (code inspection, not yet corroborated by wakeup
  measurement -- that is T1).
- Date and investigator: 2026-07-31, agent session with Dan.
- Commit and worktree state: `1eff9b7`, dirty (cited paths unaffected).
- Observation:
  - PTY output is read via a level-triggered dispatch read source on the host
    queue (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readSourceFired`,
    source installed near `#readReady`), in 16 KiB turns.
  - The Swift session view draws only on damage: frames arrive via
    `controller.onFrame`, and `draw(_:)` clips the plan to rows intersecting
    the dirty rect (`app/SwiftTerminalSessionView.swift#draw`,
    `#terminalDamageRowsWithGlyphHalo`).
  - `setDisplayID` is an intentional no-op for the Swift backend
    (`app/SwiftTerminalSessionView.swift#setDisplayID`); the per-surface
    CVDisplayLink machinery (`app/AppRuntime.swift#syncSurfaceDisplayID`)
    exists for the libghostty backend only.
  - Cursor-blink state (DECSET 12) is modeled in
    `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` but nothing in the
    app animates it; grep for `blink` finds no timer. No periodic timer exists
    on the render path at all.
- Inference: an idle terminal produces zero render-driven wakeups; the engine
  matches Apple's "absolutely idle when not in use" rule and its "dispatch
  sources instead of timers/polling" recommendation (see F6) by construction.
- Uncertainty: idle wakeup *rate* is unmeasured; other subsystems (IPC server,
  benchmark observers in dev builds) could still wake the process. T1 decides.
- Next action: T1.

### F2 -- hidden panes skip planning and drawing but keep parsing

- Status: established (code inspection; behavior also exercised by the
  characterization harness's visibility recording).
- Date and investigator: 2026-07-31, agent session with Dan.
- Commit and worktree state: `1eff9b7`, dirty.
- Observation:
  - Per-pane visibility is computed in the pure core: visible iff the window
    is non-occluded AND the pane's tab is selected AND the pane is not hidden
    behind a zoomed sibling
    (`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#effectiveSurfaceVisibility`).
  - `app/AppRuntime.swift#syncSurfaceVisibility` pushes changes to sessions,
    re-triggered by `app/AppDelegate.swift#windowDidChangeOcclusionState` --
    the exact API Apple recommends for visibility response (F6).
  - In the controller, `setVisible(false)` gates *planning only*
    (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#setVisible`);
    the consume path still parses, updates the cached terminal, and
    accumulates damage (`#consume`: `pendingDamage.formUnion`, then
    `if isVisible { planIfNeeded(...) }`).
  - On reveal, one complete frame is planned from accumulated damage.
  - Characterization builds log every visibility transition
    (`app/AppRuntime.swift#recordTerminalCharacterizationVisibilityChange`).
- Inference: the engine already implements Apple's "don't update content the
  user can't see" (F6) at the render level, while preserving the app's
  notification and recovery goals. Occlusion state also covers screen saver
  and inactive Mission Control spaces for free (F6).
- Next action: none; boundary input to T8/T9.

### F3 -- hidden-pane main-actor deliveries are coalesced but unthrottled

- Status: established (code inspection).
- Date and investigator: 2026-07-31, agent session with Dan.
- Commit and worktree state: `1eff9b7`, dirty.
- Observation:
  - `TerminalPaneDeliveryBoundary.scheduleFrame`
    (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneDeliveryBoundary`)
    permits one pending main-queue delivery; under sustained output the main
    thread re-arms immediately after each consume, so deliveries run as fast
    as main-thread turns allow regardless of visibility.
  - Each delivery is a synchronous cross-queue drain
    (`#consumeHostUpdate` -> `performAccountedFence(kind: .delivery, ...)`).
    The `readReady` doc comment
    (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readReady`)
    records a measured ~0.15ms fixed floor per fence and a ~10 MB/s parse
    rate, and itself suggests the future lever: "throttle the consumer's
    drain cadence" rather than shrinking turns.
  - Frame state is *pulled* at fence time (`drainedFrameState` runs when the
    fence executes), so deferring a delivery also skips snapshot production --
    a throttle would not queue anything.
  - Delivery counts are already observable without code changes:
    `#TerminalPaneFenceMetrics` exposes `delivery.count` per pane.
- Inference: for a hidden flooding pane, all main-thread wakeups, fence
  stalls, and snapshot drains feed a `planIfNeeded` that is skipped -- this is
  the discretionary work Apple says to suspend proactively on visibility loss
  (F6). Whether it is *material* is H1 vs H2; unmeasured.
- Uncertainty: the 0.15ms/10 MB/s figures are the comment's prior
  measurements, not re-measured at this commit.
- Next action: T2, T3, T6.

### F4 -- the PTY host queue carries no QoS class

- Status: established (code inspection).
- Date and investigator: 2026-07-31, agent session with Dan.
- Commit and worktree state: `1eff9b7`, dirty.
- Observation: the host queue is created as
  `DispatchSerialQueue(label: "com.danneu.danterm.terminal-pty-host")` with no
  `qos:` argument
  (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#queue`);
  read/write/process sources and the teardown timers all target it.
- Inference: parse work runs unclassified, so the scheduler cannot make the
  speed-vs-efficiency (P-core vs E-core) placement Apple's QoS guidance calls
  "very important" (F6). This is the doc's one clear non-compliance. Fixed
  `.utility` may be viable even for visible panes because the main actor's
  synchronous fences propagate a QoS boost to the queue while the UI waits on
  it -- but that is exactly the latency risk T5 must gate with the paired
  benchmark harness.
- Next action: T5, T7.

### F5 -- nothing prevents App Nap; power-state signals are observed but unused

- Status: established (code inspection).
- Date and investigator: 2026-07-31, agent session with Dan.
- Commit and worktree state: `1eff9b7`, dirty.
- Observation:
  - No `ProcessInfo.beginActivity`, no `IOPMAssertion`, no
    `NSAppSleepDisabled`/`LSAppNapIsDisabled` in `app/Info.plist` (grep over
    `app/` and `lib/`).
  - Benchmark builds subscribe to `ProcessInfo.thermalStateDidChangeNotification`
    and `NSProcessInfoPowerStateDidChange`
    (`app/TerminalBenchmark.swift#TerminalBenchmarkObserver`) -- but only to
    annotate benchmark samples; the app never adapts behavior.
  - The benchmark observer also carries a per-draw tripwire asserting draws
    happen only while the window is visible
    (`app/TerminalBenchmark.swift`, visibility-contract check).
- Inference: DanTerm trips none of Apple's documented nap disqualifiers
  (foreground, recent visible drawing, audio, assertions, OpenGL, incoming
  XPC/Apple events -- F6) when hidden, so it should be nap-eligible; T1
  verifies via Activity Monitor's App Nap column. The unused thermal/LPM
  plumbing is the cheap entry point for T12.
- Uncertainty: nap engagement and its effect on the PTY drain (H3) are
  unmeasured; XPC note -- DanTerm's IPC is a unix socket, not XPC, so IPC
  traffic should not block nap, but this is inferred, not tested.
- Next action: T1, T4.

### F6 -- Apple guidance survey (all claims URL-cited)

- Status: established (documentation survey, 2026-07-31; fetched via search +
  page reads in-session).
- Sources and the claims taken from each:
  - [Energy Efficiency Guide for Mac Apps](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/index.html)
    -- the umbrella document for everything below. Archived (~2016) but still
    Apple's most complete macOS energy reference.
  - [Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html)
    -- checklist: be absolutely idle when not in use (down to between-keystroke
    scale); eliminate non-user-driven work; don't update content the user
    can't see; limit main-thread work to bounded operations; minimize timers;
    batch and prioritize work; let the system schedule discretionary tasks.
  - [Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
    -- nap triggers when ALL hold: not foreground, no recent visible drawing,
    not audible, no power assertions, not using OpenGL, no incoming XPC/Apple
    events. Nap regulates CPU, I/O, and timers. "Don't rely on App Nap to get
    your app to fully idle" -- reduce activity proactively on visibility loss.
    Assertions (`NSProcessInfo` activities) are for user-initiated work,
    scoped to the operation. Nap status is visible in Activity Monitor's
    Energy tab ("App Nap" column) and Xcode's Energy Impact gauge.
  - [Notify Your App When Visibility Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html)
    -- `windowDidChangeOcclusionState`/`applicationDidChangeOcclusionState`
    are the recommended suspend/resume hooks; occlusion includes screen saver
    and unused Mission Control spaces; menu-bar-only visibility counts as
    occluded.
  - [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
    -- prefer event-driven APIs and dispatch sources over timers/polling;
    when a timer is unavoidable set tolerance >= 10% of interval so timer
    coalescing can batch wakeups; invalidate timers ("probably wastes more
    energy than anything else in OS X" when forgotten); idle target <= 1 idle
    wakeup/s (Activity Monitor "Idle Wake Ups" column); debug with
    `sudo timerfires -p <pid>`.
  - [Prioritize Work at the Task Level](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)
    -- QoS classes on dispatch queues/sources; "it is very important that you
    have your work correctly classified"; lower QoS lets the system trade
    speed for energy (E-core placement on Apple Silicon).
  - [Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)
    -- observe `NSProcessInfoThermalStateDidChangeNotification`; shed
    discretionary work at elevated thermal states.
  - [NSBackgroundActivityScheduler](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler)
    -- the sanctioned API for deferrable periodic maintenance, letting the
    system batch it with existing wakeups. Applies to any future housekeeping
    (history trimming, catalog refresh); current recovery checkpointing is
    mutation-debounced, already the right shape.
  - [ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo)
    -- `beginActivity(options:reason:)`, `thermalState`,
    `isLowPowerModeEnabled` and their change notifications.
  - [WWDC15 session 718, Building Responsive and Efficient Apps with GCD](https://asciiwwdc.com/2015/sessions/718)
    -- QoS propagation and boosting semantics for `dispatch_sync` from a
    higher-QoS thread (the mechanism T5's `.utility` shape relies on).
  - [WWDC19 session 422, Designing for Adverse Network and Temperature Conditions](https://developer.apple.com/videos/play/wwdc2019/422/)
    -- design-for-degradation guidance behind T12.
  - [OS X Power Efficiency Technology Overview (Apple, 2013, PDF)](https://www.apple.com/media/us/osx/2013/docs/OSX_Power_Efficiency_Technology_Overview.pdf)
    -- system-level background on App Nap and timer coalescing.
- Observation: the engine's architecture matches the two highest-weight rules
  (idle-by-construction, F1; no unseen updates, F2) using the exact APIs the
  guide names. The gaps map to: QoS classification (F4), proactive
  hidden-work reduction beyond rendering (F3), nap-vs-drain verification
  (F5/H3), and unused thermal/LPM adaptation (F5).
- Inference: one comparative point -- Apple documents OpenGL use as
  disqualifying an app from App Nap entirely, so a CPU/CoreGraphics renderer
  is *structurally* nap-eligible in a way a GL-based backend was not. (Whether
  the libghostty backend's Metal + CVDisplayLink pipeline also blocked nap is
  not documented; claim scoped accordingly.)
- Next action: feeds every ledger task; no direct follow-up of its own.
