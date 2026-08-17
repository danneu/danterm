# One record per pane

Retires S22 and S23 in `docs/scratch/2026-08-11-simplification-audit.md`, and
supersedes the standalone S23 plan.

## Problem

A live pane's runtime state is spread across seven tables in `AppRuntime`, all
created and destroyed together and all keyed by the same pane: the terminal
session, the `PaneHost` that already holds that same session plus the pane's
chrome, pane visibility, the scrollback replay file, the search debouncer, that
debouncer's scheduling token, and the session-subscription token (keyed by
session object identity rather than pane id, but one per pane).

Nothing keeps them in step except hand-written parallel edits, and they are
already out of step:

- **Install writes two tables, teardown removes from four, and a third path
  open-codes a divergent copy of teardown.** `tearDownCurrentSession` -- the
  whole-session path used by restore and import -- repeats `tearDownSession`'s
  body inline and omits the two debouncer lines. A restore performed while a
  short search needle is debouncing leaves an armed scheduling owner and its
  debouncer alive past the discarded session; the pending closure re-resolves
  the pane's session at fire time, and restore and import reuse pane ids, so it
  can deliver a needle from the discarded session into the session that
  replaced it. The drift is dated: the debounce token was added in `88c6bf2c`
  and threaded into `tearDownSession` only, with the inline copy sitting beside
  it.
- **Visibility needs a prune pass because teardown does not remove it.**
  `syncPaneVisibility` ends by filtering the visibility table against the
  session table, because per-pane teardown drops the session and leaves the
  visibility entry behind.
- **Restore rebuilds one table from another.** Staging carries sessions and
  replay files as two maps; the commit step reconstructs pane chrome from the
  staged sessions, and the abort path disposes staged sessions and staged files
  through two separate loops that share no body with live teardown.
- **The split has leaked into the test surface.** `paneHost(for:)` carries a
  lazy back-fill that constructs pane chrome on demand; its only reason to
  exist is that tests assign into the session table directly, behind the
  install path. The UI harness shim hand-copies that back-fill.
- **Replay-file cleanup runs twice for the same reason.** The whole-session
  path cleans replay files per pane and then sweeps the whole table again for
  entries whose session was already gone.

**Intended outcome.** A pane's runtime state has one owner and one lifetime. A
step added to pane teardown applies everywhere without a second edit, and the
class of bug S23 records -- a resource cleaned on one path and forgotten on
another -- has nowhere left to live.

## Decision

`PaneHost` becomes the pane's runtime record, and `AppRuntime` keeps exactly
one pane-keyed table of them. The record owns everything whose lifetime is the
pane's: the session, the pane chrome, visibility, the replay file, the search
debouncer and its token, and the session subscription.

The record is produced whole and destroyed whole:

- Session creation yields a record, so both callers -- the create-session
  command arm and restore staging -- get one. Nothing exists in a half-installed
  state where a session is live but its chrome is not.
- Restore staging stages records. The commit step installs the staged table
  wholesale; the abort path runs the same per-record teardown that live
  teardown runs.
- The whole-session path tears each live pane down through that same body. One
  teardown body, so the divergent copy has nothing to diverge from.

Teardown has two layers, and the split is load-bearing rather than incidental.
What the record owns, it destroys, and that is safe for a staged record as much
as a live one. What is scoped to the *pane id* rather than to the record --
pane-tape follow streams, which are keyed by subscription and resolved by pane
id -- is destroyed only when a live pane goes away, because a discarded staged
record can carry the same pane id as a live pane and must not reach into it.

The other half of the collapse is that work scheduled for a pane stops
resolving that pane by id after the fact. A debounced search needle today
re-reads the pane's scheduling token and session from tables when it fires, so
a token armed by a discarded pane validates against the pane that replaced it
under a reused id. Moving the tables under one key preserves that exactly;
capturing the target when the work is armed is what retires it.

Test code installs panes through the production install path, and the lazy
back-fill in `paneHost(for:)` is deleted with the reason for its existence.

This is the ideal fix and the only one carried forward. Collapsing only the
session and chrome tables -- the literal audit finding -- leaves visibility,
replay files, and debouncers as parallel tables and leaves the drift hazard
that already produced the S23 bug fully intact, so it is rejected.

Critical files: `app/AppRuntime.swift` and `app/PaneHost.swift`; the three
`AppRuntime` extensions in `app/AppPresentationLifecycle.swift`,
`app/PaneFocusReconciliation.swift` and `app/Reconcile.swift`; the benchmark
session provider in `app/AppDelegate.swift`; the UI-harness `AppRuntime` shim
in `tests-ui/SidebarViewTestShim.swift` and its two consuming test files; the
session-injecting tests in `app-tests/`. The doc comment on
`sessionsToTearDown` in `lib/DanTermCore/Sources/DanTermCore/Projections.swift`
names the old table and is updated with it -- the pure function itself takes a
set of pane ids and does not change.

## Invariants

- **I1.** One registry owns pane lifetime. A resource whose lifetime is the
  pane's lives in that pane's record and nowhere else; when it is optional, the
  record is the only place its presence or absence is recorded. Derived caches
  that are rebuilt or reset wholesale, and shared services keyed by something
  other than the pane, are not pane-lifetime state and stay outside the record.
- **I2.** Creation and destruction are single bodies. A record is produced whole
  by session creation, and the live per-pane path, the whole-session path, and
  the staged-restore discard path destroy it through one teardown. Removing a
  record from the table and running its teardown are not separable operations:
  the table is not writable except through installing and removing a pane.
- **I3.** After a whole-session teardown, no scheduled work armed by a discarded
  pane is still armed, and no work pending from a discarded pane can reach a
  pane installed afterward under a reused pane id.
- **I4.** Tests install panes through the production install path. No test
  writes a pane's session into the runtime behind that path, and no production
  code reconstructs a pane's chrome lazily to cover one that did.
- **I5.** A restore that fails while building leaves live pane state untouched
  and leaves no staged replay file on disk. A staged record is never reachable
  as a live pane before the restore commits, and discarding one never disturbs
  a live pane that happens to share its pane id.
- **I6.** Work scheduled for a pane resolves its target by capturing it when the
  work is armed, not by looking the pane up when the work fires.

## Proof obligations

- **PO1** (I1, I2). After the create-session command, the pane's session and its
  chrome are both reachable from the runtime; after that pane is torn down,
  neither is, and the pane's replay file is gone from disk.
- **PO2** (I3, I6). With a short search needle still debouncing on a live pane, a
  whole-session teardown leaves no armed debounce owner in the scheduling
  census, and the needle is never delivered -- including to a session installed
  afterward under the same pane id.
- **PO3** (I2, I5). A restore that fails partway through building its panes
  leaves the panes that were live before it still live and usable, and deletes
  every replay file it had staged. A live pane whose id the failed restore also
  staged keeps its session and its open tape-follow streams.
- **PO4** (I2). A pane that leaves the model is torn down by the reconcile pass
  exactly as the per-pane path tears it down -- session down, chrome dropped,
  replay file removed, scheduled work unarmed -- and an open follow stream on
  that pane is ended, under both reconcile-driven removal and whole-session
  replacement.
- **PO5** (I1). Visibility state does not outlive its pane: a pane installed
  under a reused pane id receives the visibility push its state calls for,
  rather than having it suppressed by the predecessor's entry.

`app-tests/AppRuntimeSessionCommandTests.swift` already establishes the shape
PO1, PO2 and PO4 need -- drive real commands against a real `AppRuntime` built
with application services off, then read
`schedulingLifecycle.captureOwnerCensus()` and the recording session's
delivered needles. Reuse it rather than inventing a harness.
`app-tests/PaneHostHeadlessTests.swift` already proves pane chrome constructs
without a WindowServer, which is what lets creation and staging build records
inside the `just test` gate.

## Non-goals

- The reconciler's pane-keyed diff caches stay separate from the pane record.
  They are reset wholesale by re-init on restore, and folding them into a
  per-pane record would break that.
- Pane-tape follow subscriptions stay keyed by subscription, not by pane: one
  pane can have several, and the connection-closed path enumerates by
  connection.
- The scheduled-work handle-plus-token pairs (audit S24) stay as they are.
- The UI harness keeps its substituted `AppRuntime`; this change mirrors the
  new shape into the shim rather than retiring the substitution seam.

## Accepted risks

- **AR1.** Restore staging builds pane chrome for panes a failed restore will
  discard. The cost is discarded AppKit views on a path that is already
  failing; the gain is one record from creation to teardown, with no
  reconstruction step at commit. On the success path the AppKit work is the
  same work commit does today, one step earlier. Three properties make it safe
  and are worth confirming still hold when it lands: pane chrome reads no model
  state while it is being constructed, its back-pointer into the session is
  weak and is written only into the freshly built staged session, and headless
  construction is already proven by an existing test.

## Rejected ideas

- **RI1.** Giving tests a dedicated session-injection helper instead of routing
  them through the production install path. It keeps a second way to install a
  pane, which is what the lazy back-fill exists to paper over.

## Implementation discretion

- Where the two teardown layers physically live, and how the record reaches the
  scheduling lifecycle, provided I2 and I5 hold and the record gains no
  back-reference to the runtime.
- Whether the harness shim mirrors the production install path or supplies its
  own equivalent, provided I4 holds for the tests that use it.

## Verification

- `swift test --scratch-path .build-app-tests` for `app-tests/`. PO2's test must
  fail before the change for the reason it names -- an armed debounce owner
  survives a whole-session teardown -- and pass after.
- `just test` for the gate, and `just test-ui` for the harness (excluded from
  the gate; needs a WindowServer).
- One real run on a slot: launch, split a few panes, quit through
  `danterm --socket <slot> quit` so the final checkpoint is written, relaunch,
  and confirm the restored panes are live, focused, themed, and scrolled to
  their replayed scrollback.

## Follow-up

- Set the Status column of both the S22 and S23 rows in
  `docs/scratch/2026-08-11-simplification-audit.md` to the landing commit shas,
  following the audit's completion convention.
- Delete `plans/wip/plan-the-ideal-fix-immutable-gadget.md`; its contract is
  carried by I2, I3, PO2 and PO4 here.

## Implementation notes

- Commit 1 reads the record's session through a new `AppRuntime.paneSession(for:)`
  rather than letting every call site index the table. The table itself stays the
  single owner; the accessor only spares ~25 call sites a `paneHosts[id]?.session`
  spelling.
- Routing the whole-session path through `tearDownSession` makes it cancel the
  search debouncer, which is half of PO2 arriving in commit 1. That is an
  unavoidable consequence of having one teardown body, so its regression test
  lands here; the other half of PO2 (a needle from a discarded pane reaching a
  pane installed under the same id) waits for commit 2's arm-time capture.
- The plan's live slot check cannot cover restore: `dev-slot-launcher.py` always
  passes `--fresh`, so a relaunched slot never reads the checkpoint it wrote. The
  live run confirmed split, pane close, and graceful quit; the restore and
  whole-session-replacement paths are covered by the app-tests that drive
  `bootstrapFromSnapshot` against a real runtime.

- Commit 2 hands the session subscription token from `makeTerminalSession` to the
  record through a small `CreatedSession` pair, because restore still stages bare
  sessions until commit 3 turns staging into records. Arming the token at install
  instead would leave a staged session's callbacks live but outside the census,
  which is a second way to disconnect them -- exactly the drift this plan removes.
- PO2's delivery half is not falsifiable by removing only the arm-time capture:
  commit 1 already made every teardown cancel the debounce, so nothing fires at
  all. Its test still pins the behavior end to end, and it is not vacuous -- the
  replacement pane's own needle is asserted to arrive after the same wait, which
  proves the wait outlasts the debounce window. What the arm-time capture buys is
  that the hazard cannot come back if a future path forgets to cancel.
- The record makes one hazard falsifiable that the plan does not name: a short
  needle addressed to a pane that is not installed used to build a debouncer and
  arm a census owner that no teardown would ever reach, because both lived in
  tables keyed by pane id. State that lives in the record cannot exist without the
  pane, so that case now arms nothing. It has a test.
- `test-ui.sh` gains `Debouncer.swift`: the harness compiles `PaneHost.swift`, and
  the record now owns its search debouncer.

- Commit 3 makes `makeTerminalSession` return the pane's whole record rather than a session
  plus a token, which retires the `CreatedSession` pair commit 2 introduced. The replay file
  is the one resource written before the record exists, so it is passed in and, when the
  backend refuses the session, deleted there: with no record to own it, no caller is left to
  remember it.
- PO3's test needed a two-pane restore. A restore that fails on its only pane stages no
  record at all, so the assertion that discarding does not reach a live pane sharing the id
  was vacuous. The test now lets the restore stage a finished record under the live pane's id
  and fail on a second pane; both halves were confirmed to fail under ablation -- ending the
  follow stream in the discard path, and discarding without teardown.
- `RecordingTerminalSession` gained a real follow opening and notice registration, which is
  what lets an app-test hold a live tape-follow stream open with no terminal engine behind it.

## Commit progress

- [x] 1. Make the pane host the runtime's only pane-keyed table. The session
      table folds into the record, install and teardown each become one body
      that the per-pane and whole-session paths share, the lazy `paneHost(for:)`
      back-fill goes, and tests install through the production path. Covers I2,
      I4, PO1, PO4.
- [x] 2. Move the rest of the pane's runtime state into the record -- pane
      visibility, the replay file, the search debouncer and its token, and the
      session subscription -- and make scheduled search work capture its target
      when it is armed. Covers I1, I3, I6, PO2, PO5.
- [x] 3. Stage a restore as whole records: staging builds them, commit installs
      the staged table wholesale, and the discard path runs the same record
      teardown. Covers I5 and the staged half of I2, PO3.
