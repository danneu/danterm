# RUNTIME-6: Extract the pane-tape streaming broker out of AppRuntime

## Context

Audit item RUNTIME-6 (docs/scratch/2026-08-18-construction-audit.md) is the
last open item in the pane-tape chain; PERSIST-6, WIRE-2, WIRE-3, WIRE-6, and
PERSIST-5 have all landed. `app/AppRuntime.swift` (2183 lines) still holds the
whole pane-tape IPC feature as private members: the transport struct, two
tables (`paneTapeFollowSubscriptions`, `paneTapeFollowTransports`), and eleven
methods in one block (lines 657-1000). Its correctness rules -- retire a
transport's census token with `run`, never `cancel`; never touch a sibling
stream's notice or token -- are held only by comments on state every other
runtime method can reach, and its lifecycle leaks into four unrelated methods
(the `.streamPaneTape` dispatch arm, `tearDownSession`, `ipcConnectionClosed`,
`shutdown()`).

Desired outcome: one owner type for all of "pane tape over IPC" -- follow,
snapshot, and dump -- so the invariants become unwritable-from-outside rather
than reviewer-enforced, and `AppRuntime` forwards at four one-line sites.

Load-bearing premises (verified against the current tree):

- The two tables and the transport struct are referenced only inside
  `app/AppRuntime.swift`; nothing else in `app/` or `app-tests/` reads them.
- All pure policy (`PaneTapeFollowSubscriptions`, stream state, record
  builders) already lives in `lib/DanTermCore`; the only wire write is
  `writePaneTapeRecords` in `app/PaneTapeWireWrite.swift`, whose only callers
  are the methods being moved.
- No test today can drive the append edge (notify -> fetch -> deliver batch):
  the `RecordingTerminalSession` fixture discards the notify closure and does
  not implement `paneTapeFollowBatch`.
- In `AppRuntime.shutdown()`, the follower retire-and-close loop runs while
  `schedulingLifecycle` is still active, before `schedulingLifecycle.shutdown()`.

## Decision

Extract a `@MainActor final class PaneTapeBroker` in a new
`app/PaneTapeBroker.swift`, owning the transport struct, both tables, and all
eleven methods. Decisive constraints:

- **Scope: the whole feature, not just follow.** The finite dump/snapshot path
  (`streamFinitePaneTape`) moves too, so the `.streamPaneTape` dispatch arm
  becomes a single forward and "pane missing at start" (the error reply) and
  "pane vanished after start" (the `.paneClosed` terminator) live in one owner.
  The pane-session lookup and the "pane no longer available" error move into
  the broker; `takeIpcConnection` stays in the arm -- it is the IPC request
  registry, not tape state.
- **The broker takes the runtime's own `AppRuntimeSchedulingLifecycle` as a
  required init dependency and has no way to create its own.** This discharges
  the audit's stated risk (a stream staying armed past `AppRuntime.shutdown()`)
  by construction.
- **The session lookup captures the runtime weakly** (the runtime owns the
  broker; a strong capture is a retain cycle -- lifetime-safety rule, and the
  `ReconcileOutbox.setDispatcher` precedent). An uninstalled/dead lookup
  behaves as "no pane", which every path already handles.
- **Entry surface: one forward per current leak site** -- a single stream
  entry for both capture modes, plus pane-closed, connection-closed, and
  shutdown notifications. `AppRuntime` keeps one stored broker and nothing
  else tape-related.
- **`app/PaneTapeWireWrite.swift` folds into the broker's file** as a
  file-private nonisolated function (it is called from a utility-queue block,
  so it cannot become a `@MainActor` method). The helper is then unreachable
  from any other file by access control rather than by comment; the generic
  `IpcConnection.writeBatchedNotification` it calls stays module-visible, so
  this is an ownership claim, not a global ban on tape-shaped notifications.
- **Refactor discipline inverted TDD:** the new behavioral tests are written
  first against the current code and must pass before the move, so a pass
  after the move is evidence of preserved behavior.

## Invariants

- I1 Ending or retiring one stream never disturbs a sibling stream on the same
  socket or pane: the sibling keeps its notice, its census entry, and its
  writes.
- I2 No teardown short of app shutdown closes the client's connection; the
  socket belongs to the client, not to one stream.
- I3 App shutdown closes each follower's connection (the peer sees EOF, no
  terminator record first), and the broker's shutdown runs while the scheduling
  lifecycle is still active -- before `schedulingLifecycle.shutdown()` -- so
  each socket is closed exactly once, by the broker.
- I4 Closing a pane writes an `end(reason: .paneClosed)` terminator to each of
  that pane's followers on their still-open sockets.
- I5 Every follow-stream transport and deferred callback the broker schedules
  is armed on the runtime's lifecycle and visible in its owner census; after
  the extraction the census counts are unchanged for every scenario. The finite
  capture's utility hop is not armed today and is not armed by this change (see
  AR1).
- I6 The request audit completes exactly once per `.streamPaneTape` request, at
  the start reply; batch and terminator writes bypass the audited transport.
- I7 Pane-tape state is unreachable outside the broker: `AppRuntime` holds one
  broker reference and forwards at exactly four sites, and both tables, the
  transport struct, and the record-writing helper are private to
  `PaneTapeBroker`.
- I8 All existing observable behavior -- wire shapes, record ordering, error
  replies, recorded session calls -- is unchanged.

## Proof obligations

- PO1 (I1, I2, I4, I5) Census/sibling scenario: two follow streams on one
  connection over two panes; closing one pane delivers that stream's
  `.paneClosed` terminator, cancels only its notice, and drops the
  `.subscription` census by exactly one; the sibling still receives a batch
  afterward; closing the connection returns the census to its baseline.
- PO2 (I8, premise) Append-edge delivery: a recorder notice on a followed pane
  results in the scripted batch arriving on the wire. Requires extending the
  `RecordingTerminalSession` fixture to retain the notify closure and script
  `paneTapeFollowBatch` continuations (value-captured, never
  session-captured -- the closure runs off the main actor).
- PO3 (I3) Shutdown EOF: with a follow stream open, `runtime.shutdown()` gives
  the peer EOF with no terminator record first.
- PO4 (I8) Absent pane: a `.streamPaneTape` request naming a pane with no
  session answers `"pane no longer available"` and completes its request audit,
  for each capture mode. The guard moves out of the dispatch arm into the
  broker, and no current test covers it.
- PO5 (I6, I8) The existing tests pass verbatim:
  `AppRuntimeIpcCommandTests.paneTapeCommandsWriteSessionErrors` and
  `.paneTapeDumpPutsDecodableRecordsOnTheWire`,
  `AppRuntimeSessionCommandTests.failedRestoreLeavesLivePanesUntouched`,
  `PaneTapeFollowEncodingTests`, and the core `PaneTapeFollowTests` /
  `PaneTapeStreamStateTests`.

All new tests drive `runtime.perform(.streamPaneTape(...))` and the runtime's
teardown entry points -- never a directly constructed broker -- because the
extraction's risk is the wiring and the shared lifecycle, and the census
assertions catch a private-lifecycle regression immediately.

## Non-goals

- Extracting the checkpoint scheduler or the roster-subscriber table (same
  pattern, named follow-ons in the audit; this change sets the shape only).
- Any wire, CLI, or behavior change; `integrations/danterm/SKILL.md` is
  untouched.
- Duplicating the pure state-machine coverage (one fetch in flight, opening
  gating) already pinned in `lib/DanTermCore` tests.

Accepted risks:

- AR1 A finite capture's utility-queue block stays unregistered with the
  scheduling lifecycle, so a dump that is mid-`prepareOpening` when
  `AppRuntime.shutdown()` runs can still write afterwards. The ideal is to arm
  that work like the follow path does, but that changes shutdown behavior and
  census counts, which this refactor's no-behavior-change contract rules out;
  it belongs to a follow-on item, not here.

## Rejected ideas

- RI1 Direct-construction broker unit tests: they pin the init surface
  (structure) and prove nothing the runtime-path census tests do not.
- RI2 Keeping `PaneTapeWireWrite.swift` as its own file: after the move the
  broker is its only caller, and file-privacy is the stronger statement of its
  own header's claim.
- RI3 A follow-only broker (the audit's literal four entry points): it leaves
  the finite dump and the shared wire write straddling the new boundary.

## Implementation discretion

- Installer mechanics for the session lookup (post-init setter per the
  `ReconcileOutbox` precedent vs. any equivalent that satisfies the
  weak-capture invariant), and the broker's internal method decomposition.
- Fixture scripting details for PO1-PO4 beyond the constraints stated in PO2.

## Critical files

- `app/AppRuntime.swift` -- remove the block and tables, add the broker field
  and four forwards.
- `app/PaneTapeBroker.swift` (new) -- the owner; absorbs
  `app/PaneTapeWireWrite.swift` (deleted). Invariant comments (run-not-cancel,
  sibling isolation, table keying) travel with the code.
- `app/PaneHost.swift` -- header says pane-tape follow streams "stay in
  AppRuntime"; repoint it at the broker, keeping the id-keyed-state rationale.
- `app-tests/AppRuntimeCommandTestSupport.swift` -- fixture extension (PO2).
- New app-tests suite for PO1-PO4.
- `docs/scratch/2026-08-18-construction-audit.md` -- mark RUNTIME-6 done in the
  follow-up chore commit, per house habit.

## Verification

1. Before the move: new fixture extension + PO1-PO4 tests pass against the
   current code (`swift test --scratch-path .build-app-tests --filter <suite>`).
2. After the move: same tests pass unchanged; PO5 suites pass verbatim.
3. Full gate: `just test`.

## Commit progress

- [x] 1. test(runtime): pin pane-tape stream lifecycle behavior
- [ ] 2. refactor(runtime): extract the pane-tape broker
- [ ] 3. chore(audit): mark RUNTIME-6 done
