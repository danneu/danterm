# Milestone 9 power and performance evidence

Date: 2026-08-06

Verdict: pass. DanTerm's Swift terminal engine satisfies the maintained idle,
hidden-pane, visible-output, recovery-freshness, system-sleep, responsiveness,
and teardown gates. The evidence establishes behavioral scheduling and
liveness; it does not claim a battery-life improvement or a numerical input-
latency bound.

## Gate evidence

| Gate | Maintained proof |
| --- | --- |
| Idle quiescence | `TerminalPaneSessionControllerTests#visibleCreationRetainsInitialFrame` and `#resultOnlyEqualSnapshotSkipsPlanning` publish no repeat frame for unchanged state. `RecoveryCheckpointPolicyTests` reaches a clean state with no scheduled checkpoint. |
| Hidden pane and reveal | `TerminalPaneSessionControllerTests#hiddenCreationDefersInitialFrame` and `#hiddenOutputAndReveal` keep terminal, semantic, inspection, and recovery state current without frames, then publish one complete reveal. |
| Visible output and bounded work | `TerminalPaneSessionControllerTests#burstConflatesToFinalPlan` proves a stalled consumer retains the final state through fewer publications than writes. `TerminalPaneDeliveryBoundary#scheduleFrame` admits at most one pending frame callback. |
| Recovery freshness | `RecoveryCheckpointPolicyTests` covers bounded freshness, failed-write retry, covering success, idle quiescence, and termination. `TerminalPaneSessionControllerTests#applicationExitFenceDrainsAcceptedOutput` pins the pane boundary. |
| System sleep and wake | `TerminalPaneSessionControllerTests#systemSleepAndVisibleWake` and `#hiddenWakeDefersUntilReveal` prove state continuity, idempotence, one visible full frame, and deferred hidden wake. The "workspace sleep and wake reach sessions until observer teardown" case in `AppPresentationLifecycleTests.swift#appPresentationLifecycleTests` proves the `NSWorkspace.shared.notificationCenter` adapter and observer lifetime. |
| Occlusion | The "window occlusion reaches session visibility and reveals once" case in `AppPresentationLifecycleTests.swift#appPresentationLifecycleTests` drives `AppDelegate#windowDidChangeOcclusionState` through `AppRuntime#syncPaneVisibility` to the session seam. This is the maintained screen-sleep suppression route. |
| Keyboard responsiveness | The "keyboard input runs before a sustained frame stream completes" case in `SwiftTerminalSessionViewTests.swift#swiftTerminalSessionViewTests` proves the real AppKit `keyDown` route reaches the controller before a bounded visible frame stream finishes. `TerminalPaneSessionControllerTests#keyboardInputDuringSustainedOutputConverges` proves the byte reaches a real PTY child while its output producer is alive, then the final marker is rendered. |
| Runtime teardown | `AppRuntimeSchedulingLifecycleTests#shutdownEmptiesEveryOwnerCategoryAndMakesCapturedCallbacksInert` arms all six production owner categories, shuts down twice, observes an empty census, proves captured callbacks inert, and proves no scheduling entry point rearms. Existing host tests remain authoritative for descriptor and process teardown. |
| Ordinary sleep | Production contains no IOPM assertion creation. The real sleep/wake observation below returned to an idle state with no DanTerm-owned `pmset` assertion. |

The sparse `sparse-spans-max` benchmark remains a descriptive topology
diagnostic, not a verdict. Three independently collected 24-pair A/A screens
produced incompatible calibration outcomes, including a controlled low-load
series that selected no candidate rule. The exact refusal and preserved results
are recorded in
[research 29](../research/29-sparse-appkit-damage-clip-topology/README.md).
DanTerm therefore makes no automated CPU-protection claim for the historical
per-row Core Animation regression.

## Real system-sleep corroboration

The 2026-07-20 interactive viability session closed the MacBook lid for more
than ten seconds with a live pane. On wake, the pre-sleep marker remained
exactly once, a post-wake marker crossed the same pane input path exactly once,
the prompt returned, and a fresh two-second idle window added no CPU time or
event-log entries. No DanTerm-owned power assertion was present. The full
environment and procedure are retained in
[Milestone 4 interactive viability evidence](2026-07-20-milestone-4-viability.md#manual-visual-and-sleepwake-observation).

That real observation corroborates the lifecycle result. Deterministic session
and AppKit adapter tests remain the maintained proof because a physical sleep
cycle alone cannot prove transition idempotence, hidden wake, or observer
teardown.

## Gate run

The local gate passed on macOS arm64 on 2026-08-06:

```sh
just test
just test-ui
```

The local gate passed all 74 steps and the UI run reported 204/204 passing
tests. Timeouts in the responsiveness tests are hang guards only; no elapsed
duration is an acceptance threshold.
