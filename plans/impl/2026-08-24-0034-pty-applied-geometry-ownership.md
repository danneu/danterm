# PTY-5 Salvage: Dedupe on Applied Geometry

## Summary

The original correctness failure is unreachable. Keep PTY-5 only as
structural cleanup: remove the controller's optimistic submitted-grid mirror
and make the PTY owner dedupe against the recorder-owned applied geometry.

No public API signatures change. App-facing behavior remains unchanged; at the
host boundary, an exact repeated geometry submission becomes a no-op. The
package-only initialization fence payload also stops carrying birth geometry.

## Decision and Invariants

- `TerminalFlightRecorder.currentGeometry` remains the sole whole applied
  geometry fact, initialized from the host-owned birth geometry and updated
  only when a resize applies.
- `TerminalPaneSessionController` retains validation and teardown guards, but
  stores no submitted or applied geometry mirror.
- Every valid live geometry report reaches the host's FIFO. `applyResize` skips
  a fact only when its dimensions and pinnedness equal the applied geometry.
- Applied geometry advances only after `TIOCSWINSZ` succeeds.
- Pinnedness-only changes remain applied transitions and produce tape events.
  An exact repeat produces no ioctl, reflow, or tape event.
- The lifecycle reducer continues to retain the latest geometry received
  during spawning and applies it after spawn succeeds.

## Implementation Changes

- Expose the recorder's current applied geometry to its owner without adding
  another stored grid.
- Remove `lastSubmittedGrid` and its initialization from the session
  controller.
- Remove birth geometry from the initialization fence payload so the fence
  returns frame state alone.
- Move exact-fact deduplication to the start of the host's applied-resize
  boundary, before descriptor work.
- Update comments to distinguish submitted geometry from applied geometry.
- Keep the host's direct exact-repeat submission and change its applied-event
  expectation so only the distinct pin, release, and resize facts remain.

## Proof Obligations

- First change the direct-host applied-geometry test to require that an exact
  repeated fact records no event, and verify that it fails because the current
  host records the repeat. Its final event sequence must contain the pin,
  release, and changed-grid facts once each.
- Add a green characterization test showing that multiple geometry reports
  during spawning produce only the latest full geometry fact after spawn
  succeeds. This proves the premise that makes the audit's original failure
  unreachable.
- Keep the controller-level pinnedness and repeated-layout tests behaviorally
  unchanged. They must still prove that exact repeats produce one applied
  transition while a pinnedness change at the same dimensions is preserved.
- Keep FIFO ordering, quiet-resize publication, coalescing, and teardown tests
  green.
- Do not add the audit's closed-child/reopen regression test. The direct-host
  exact-repeat test specifies the intended ownership change; it does not claim
  that the original correctness failure is constructible.
- During the edit loop, run the affected `lib/TerminalPTY` test suites and
  `just lint`. Run `just test` before commit.
- Use the existing saturated-scrollback live check for window and split-divider
  dragging. Content must follow the drag and settle at the final grid.

## Accepted Risks and Assumptions

- Exact repeated AppKit layout reports will now cross the host queue.
  `ResizeCoalescer` prevents redundant reflows but not enqueueing. Accept this
  small traffic increase unless the live drag check shows a regression.
- The already-landed one-flight-tape, launch-owned birth geometry, and
  resize-coalescer changes are prerequisites and require no further work.
- No current branch or worktree conflict exists. Work that edits the controller
  geometry entry point, the host resize boundary, or recorder geometry
  ownership should land separately.

## Commit progress

- [x] 1. test(pty): characterize spawning resize retention
- [ ] 2. refactor(pty): dedupe resizes on applied geometry
