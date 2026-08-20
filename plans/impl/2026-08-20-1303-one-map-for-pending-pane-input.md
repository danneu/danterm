# One map for pending pane input, rejected on pane teardown (MODEL-6 + REDUCE-6)

## Problem

`AppModel` tracks an in-flight `pane.input` request in two hand-mirrored maps:
`pendingInputRequests[requestId].remaining` (request -> submission ids) and
`pendingInputSubmissions` (submission id -> request). Nothing ties them
together, so a disagreeing pair is representable: a submission mapped to a
request that no longer lists it would be resolved twice, and a submission in
`remaining` with no reverse entry would block its reply forever. The request
also records no pane, so no pane-teardown path can find it; only
`.runtimeWillShutdown` ever fails it. Pending session creations already get the
opposite treatment: every teardown path rejects them through one helper.

Evidence (current tree, unchanged since the audit):
`lib/DanTermCore/Sources/DanTermCore/Model.swift` (`PendingInputRequest`, the
three pending maps on `AppModel`), `IpcDispatch.swift` (the `.paneInput` arm
writes both maps), `Update.swift` (`.runtimeWillShutdown`,
`.inputSubmissionCompleted`, `rejectPendingCreation` and its four call sites in
`.sessionCreationFailed`, `deleteGroupBody`, `closePaneBody`,
`closeTabRemoval`).

Premise worth stating: no caller hangs today. The runtime already completes a
send to a missing or torn-down pane as `.rejected(.processEnded)`
(`app/AppRuntime.swift` send arms, `TerminalPaneSession.send`,
`TerminalPTYHost.send`). The value of this change is the invariant being held
by the reducer, where a test can prove it, and the symmetry with pending
session creations -- not a live bug.

Source: `docs/scratch/2026-08-18-construction-audit.md` MODEL-6 and REDUCE-6,
which cite each other as prerequisites and are one change.

## Decision

One map, keyed by submission id, whose value carries the owning request id
and the owning pane id. The request->submissions direction is derived by
scanning values (in-flight counts are single digits). `PendingInputRequest`
and the request-keyed map are deleted.

The existing per-pane rejection helper becomes the single place that fails
*all* pending IPC work bound to a pane -- pending creation and pending input
-- and every teardown path that calls it today keeps calling it. A fifth
teardown path cannot pick up one half and miss the other.

Scope: `lib/DanTermCore` plus the tests that seed these maps by hand. No
runtime, protocol, CLI, or persistence change. `PendingInputRequest` is
internal; nothing in `app/` or `ios/` production code reads either map.

## Invariants

- I1. A `pane.input` request replies exactly once: success after its last
  submission is delivered, or one error on the first rejection. Out-of-order
  completion does not change this.
- I2. A completion for a submission whose request has already replied produces
  nothing.
- I3. When a pane leaves the tree -- close pane, close tab, delete group,
  session creation failed -- every pending `pane.input` request bound to that
  pane is rejected with code `-32603`, and a later completion for any of its
  submissions produces nothing (I2).
- I4. App shutdown rejects every pending request once: one `-32603` per
  request, not per submission, for creations and inputs alike. Error order is
  unspecified.
- I5. Pending creation and pending input are rejected by the same teardown
  helper at the same call sites; pending creation behavior is unchanged.
- I6. A pane moved between tabs (not destroyed) keeps its pending input.

## Proof obligations

- PO1 (I1, I2): existing `UpdateIpcTests` "pane.input defers success until
  every submission is delivered" and "pane.input preserves each host rejection
  reason in its IPC error" keep passing. Add a characterization test: a
  three-item request completed out of order replies once, after the last.
- PO2 (I3): new reducer test, fails today -- split a tab, dispatch a multi-item
  `pane.input`, complete nothing, close that pane: one `.ipcError(reqId, -32603,
  ...)` is returned and a later `.inputSubmissionCompleted` for a sibling
  submission returns nothing. Repeat through `closeTab` on a single-pane tab
  (a different teardown line), `deleteGroup`, and `.sessionCreationFailed`.
- PO3 (I4): existing `UpdateSessionEventTests` "runtime shutdown rejects
  pending creation and input requests" keeps passing, reseeded through a real
  `pane.input` dispatch instead of constructing the struct by hand. Add: a
  multi-item request in flight at shutdown yields exactly one error. Do not
  assert error order.
- PO4 (I5): existing close/delete/sessionCreationFailed cleanup tests keep
  passing; PO2 exercises the helper's input half at each site.
- PO5 (I6): moving a pane to another tab with a request in flight, then
  completing its submissions, still replies once.
- PO6: `app-tests/AppRuntimePendingIpcShutdownTests.swift` and the two
  `app-tests/AppRuntimeIpcCommandTests.swift` tests that seed the maps by hand
  are reseeded with the new value and keep their assertions (one reply on the
  wire, maps empty afterwards). They use pane ids outside the tree and never
  reach teardown, so any pane id is valid there.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing how the runtime completes a send to a missing pane. It
  keeps replying `.rejected(.processEnded)`; after this change the reducer has
  already answered, and I2 makes the late completion silent.
- Non-goal: documenting the new rejection message in `integrations/danterm/SKILL.md`;
  it does not document `pane.input` error texts.
- Accepted risk: shutdown error order becomes unspecified once request ids
  are derived from a set of values. The only test that observes it already
  collapses the ids into a `Set`.
- Rejected idea: keep both maps behind two `AppModel` mutators. It reduces
  the writers but keeps the inconsistent state representable.
- Rejected idea: store pending submissions on `PaneModel` so pane removal
  prunes them (the MODEL-5 shape). `.inputSubmissionCompleted` carries only a
  submission id and shutdown needs every request, so both would scan all
  panes; and teardown must *reply*, not just prune, so pruning-by-removal buys
  nothing.
- Rejected idea: fold `pendingSessionCreations` into the same table. It is
  keyed by session and resolved by a different edge
  (`.sessionProcessStarted`); unify the teardown helper, not the storage.

## Implementation discretion

- The rejection message text per teardown cause (pane closed, process failed
  to start, app shut down), beyond naming the cause.
- The helper's name and signature, and whether the value struct is one type
  or two.

## Merge notes

- LOOKUP-4 rewrites the `allPaneIds` loops in `closeTabRemoval`,
  `deleteGroupBody`, and `.sessionCreationFailed`; MODEL-7 changes
  `paneTree.remove` in `closePaneBody`. Both are textual neighbors of the
  rejection call, not semantic conflicts.
- LOOKUP-1 (persisted/ephemeral `AppModel` split) will move these maps; land
  this first so it moves one map, not two.
- The uncommitted `dialogSurfaces` diff in `app/` and `app-tests/` does not
  touch these sites.

## Verification

- `swift test --package-path lib/DanTermCore --filter UpdateIpcTests`
- `swift test --package-path lib/DanTermCore --filter UpdateSessionEventTests`
- `just test` for the gate, including the `app-tests` reseeds.

## Implementation notes

- The teardown helper takes a cause (`paneClosed`, `processFailedToStart`)
  instead of a message string, so one call site cannot word the creation
  rejection and the input rejection differently. The creation texts are the ones
  the four sites already used; the input texts name the same cause.
- Teardown rejects by scanning the submission values for the pane, so a pane
  moved between tabs keeps its pending input: only removal from the tree calls
  the helper.
