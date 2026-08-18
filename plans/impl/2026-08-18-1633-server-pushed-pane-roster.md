# Server-pushed pane roster for the phone client

## Problem and outcome

The phone client fetches its pane roster exactly once, during connection
establishment (`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSession.swift`
sends one `ls`; `MobileSessionModel.handle(.attemptSucceeded)` is the only write
to `panes`). Every pane created, closed, or retitled after that moment is
invisible to the phone until it reconnects. Confirmed by ablation: relaunching
the app on the device made the missing pane appear.

Outcome: the Mac pushes the roster. The phone's pane list is always the last
roster the server sent, so there is no snapshot to go stale. The pane sheet
and the status pill's pane title update live.

Load-bearing premises, verified in code:

- Server-initiated notifications on an established connection are established
  practice (the pane-tape follow stream), and the client frame reader plus
  `MobileConnectionRunner` deliver every notification kind without change --
  `DanTermClientSession.readFrame` is method-agnostic and
  `PaneTapeStreamNotification.init?` returns nil on a foreign method by design.
- The runtime already has a compare-projection-after-update pattern
  (`lightCheckpointBaseline`) and a 75ms coalesced reconcile window sized for
  per-prompt title-rewrite bursts.
- The roster is tiny (tens of items), so full-state pushes cost nothing.

## Decision

Make the pane roster a first-class value at the protocol boundary and push it
whole, on change, to subscribed connections.

- **Wire**: a new request method in the `IpcRequest` catalog, `roster`
  (subscribe semantics: the reply carries the current roster; the server then
  pushes a `roster.event` notification, carrying a full roster and nothing
  else, whenever the roster changes, until the connection ends). The
  subscription is connection-scoped and idempotent: at most one per
  connection, and a repeat subscribe replies with the current roster without
  duplicating pushes -- so the wire needs no subscription id. Method name
  constants live in `DanTermProtocol` (`Methods.swift`); the roster item's
  fields are the ones the phone renders today: group id and name, tab id and
  resolved title, pane id and title, selected-tab and focused-pane flags.
- **One shared type, no scraping**: the roster value is defined once in
  `DanTermProtocol` with its encode and decode, and the phone consumes it
  directly. `projectPaneList` and its `malformedReply` vocabulary
  (`ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneList.swift`) are deleted;
  the tab-title resolution chain (custom title, then a terminal title that is
  not the placeholder, then the running command) moves into the core
  projection, so the server resolves titles and the phone renders them
  verbatim.
- **Layering**: the projection `Model -> roster` is a pure `DanTermCore`
  function reading only roster-relevant model fields; dispatch classifies the
  method into a new `Command` case (the `streamPaneTape` precedent); the
  runtime owns the subscriber registry and socket writes
  (`IpcConnection.writeNotification`, already serialized FIFO per connection);
  the wire shape lives in `DanTermProtocol`.
- **Push trigger**: after `reconcile()` on both runtime paths (the inline
  `.reconcileNow` arm and the coalesced sweep), compare the fresh projection
  to the baseline and push to all subscribers when it differs. The baseline is
  the **last reconciled roster**, not the last pushed one: it advances after
  every reconcile regardless of subscriber count, and subscription handling
  never writes it -- a subscriber's bootstrap reply must not swallow a change
  that a pending coalesced reconcile still owes existing subscribers. The
  restore-commit path bypasses `update()` and must run the same
  compare-push-advance step against the pre-restore baseline.
- **Client**: `MobileSessionAttempt` sends the roster subscribe where it sends
  `ls` today and the reply becomes the bootstrap roster, so connect sequencing
  (pick pane, then subscribe tape) is unchanged. `MobileSessionModel.receive`
  decodes the roster notification beside the tape one and replaces `panes`.
- **No protocol version bump**: by `danTermIpcProtocolVersion`'s own rule
  (bump only when an old peer would behave incorrectly, not merely miss a
  feature) and the `ping` precedent. `ls` is unchanged and stays the CLI's.

## Invariants

- I1: The phone's pane list state is exactly the last roster the server sent.
  There is no client-side merge, no refetch path, and no other writer; every
  surface that shows pane facts projects from it.
- I2: Any change to roster-relevant state -- pane created, closed, or split;
  titles (including the resolved tab title's inputs); focus; tab selection;
  group name -- reaches every subscribed connection as a push. Changes to
  non-roster state (cwd, todos, agent activity, theme) do not produce a push.
- I3: Every push is a complete roster and is idempotent. The stream carries no
  sequence numbers, gap detection, or resync machinery.
- I4: Title-rewrite bursts coalesce: a burst that the existing reconcile window
  collapses into one reconcile produces at most one push.
- I5: A subscription lives exactly as long as its connection, and a connection
  holds at most one: a repeat subscribe is idempotent. Connection drop retires
  the subscriber (the `ipcConnectionClosed` hook); app shutdown closes
  subscriber connections; a pane closing does not end the roster stream.
- I6: A roster arriving without the currently selected pane changes the list
  only. Selection and the tape stream are untouched; the streamed pane's
  closure is still reported by the tape stream's `pane-closed` end, which
  drives the existing recovery.
- I7: The tab titles the phone shows are unchanged in content: the core
  projection resolves them by the same chain `projectPaneList` used.
- I8: The subscribe method carries the standard method facets: it does not
  target, does not terminate the instance, is callable remotely, and produces
  an audit record.

## Proof obligations

- PO1 (I1): MobileKit model test -- a roster notification replaces `panes` and
  redraws; the projection the sheet and pill read carries the new list.
  Existing `MobileSessionModelTests` harness (event in, effects out).
- PO2 (I2): Core projection test -- the projection changes exactly when
  roster-relevant model fields change and is unchanged under non-roster
  mutations (cwd, todos, agent activity).
- PO3 (I2): Core dispatch test -- the subscribe request replies with the
  current roster and emits the subscription command (`UpdateIpcTests` helpers).
- PO4 (I3): Client decode test -- the roster notification is recognized by
  method, carries its roster, and a foreign method decodes to nil; plus a
  mixed tape-and-roster ordering test on one scripted conversation
  (`PaneTapeRecordReaderTests` / `ClientSessionTests` templates).
- PO5 (I5): Subscriber-registry test -- a closed connection retires exactly its
  own subscription and siblings survive (pattern:
  `PaneTapeFollowSubscriptions.connectionClosed`), and a repeat subscribe on
  one connection does not duplicate pushes.
- PO6 (I6): MobileKit model test -- a roster lacking the selected pane leaves
  selection and the stream untouched.
- PO7 (I7): Port `PaneListTests`' title-fallback and split-order cases to the
  core projection's tests before deleting them with `PaneList.swift`.
- PO8 (I4): Coalescing eligibility stays pure and tested
  (`Msg.coalescesReconcile` / `reconcileDecision` tests); the push comparison
  itself is a pure equality whose behavior PO2 establishes.
- PO9 (I2, I5): Runtime delivery test over a real socket -- using the existing
  `CommandIpcConnectionFixture` socketpair seam and headless
  `makeCommandTestRuntime` (`app-tests/AppRuntimeCommandTestSupport.swift`),
  subscribe, then mutate roster state through each delivery path (inline
  reconcile, coalesced sweep, restore commit) and observe the notification on
  the peer; a non-roster mutation produces no notification. This is the proof
  that the hooks exist -- PO2, PO3, and PO8 stay green if a hook is missing.
- PO10 (I2): A subscriber that was owed a change by a pending coalesced
  reconcile still receives it when another connection subscribes in between
  (the baseline-seeding race the last-reconciled-roster semantics closes).

## Non-goals

- No CLI command for the roster and no `ls` change; the CLI surface and
  `integrations/danterm/SKILL.md` are untouched.
- No fallback path for an old server or old phone; both sides ship together.
- No phone behavior that acts on roster changes beyond display (no automatic
  pane switching, no notifications or animations).

## Rejected ideas

- **Delta/event feed** (paneCreated, paneClosed, ...): makes the phone a
  bookkeeping replica that silently diverges on any missed event, and would
  need the sequencing and resync machinery the tape stream earned by moving
  data too big to resend. The roster is small; whole-state push makes
  divergence structurally impossible.
- **`ls` grows `follow: true`**: reuses the inspection-snapshot shape but keeps
  the phone scraping it and makes change detection compare a projection it
  does not send.
- **Handshake-implied push** (every remote connection gets rosters): couples
  "remote" to "wants roster" and gives the client no way to decline.
- **Refetch on sheet open** (the cheap fix): same staleness on a shorter
  clock, still stale for the pill, and a round-trip in the way of a tap.

## Implementation discretion

- The subscriber registry's decomposition (pure state type vs. runtime dict)
  is the implementer's, bounded by I5, the baseline semantics in the Decision,
  and the tape-follow ownership precedent.
- Whether `MobilePaneListItem` survives as a phone-side alias or the protocol
  roster item is used everywhere on the phone is the implementer's, bounded by
  the one-shared-type decision (no re-projection layer).

## Critical files

- `lib/DanTermProtocol/Sources/DanTermProtocol/`: roster value + codec,
  `Methods.swift`, `IpcRequest.swift` catalog and facet switches,
  `IpcAuditDescriptor.swift`.
- `lib/DanTermCore/Sources/DanTermCore/`: roster projection (beside
  `IpcEntityEncoder.swift`), `IpcDispatch.swift`, `Command.swift`.
- `app/AppRuntime.swift`: subscriber registry, push hooks after `reconcile()`
  (inline arm + coalesced sweep), restore re-seed, `ipcConnectionClosed`,
  `shutdown()`.
- `lib/DanTermClient/Sources/DanTermClient/`: roster notification decoder
  beside `PaneTapeStreamNotification`.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/`: `MobileSessionModel.swift`
  (notification handling, `panes` write), delete `PaneList.swift`.
- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSession.swift`:
  bootstrap request swap.

## Verification

- `just test` (gate: core, protocol, client, MobileKit suites plus the
  portable purity lint over DanTermMobileKit).
- End to end on the live rig: dev slot 1 serving the tailnet listener, iPhone
  app rebuilt via `DANTERM_IOS_HOST=100.106.152.106 DANTERM_IOS_PORT=7420
  bash scripts/ios-app.sh device`. With the phone connected, use the
  branch-built CLI (`".build/DanTerm Dev.app/Contents/Helpers/danterm" --socket
  ~/Library/Caches/com.danneu.danterm-dev.1/control.sock`) to split a pane,
  close it, and rename a tab; the phone's sheet must reflect each change
  without a reconnect, and the original bug's scenario (pane created after
  connect) must show up in the sheet. Separately, change the selected pane's
  terminal title (e.g. a shell title write) and verify the pill's pane title
  follows.

## Commit progress

- [x] 1. feat(protocol): define the shared roster value and its pure core projection
- [ ] 2. feat(ipc): serve roster subscriptions and push the roster on change
- [ ] 3. feat(ios): subscribe the phone to server-pushed rosters and delete the ls scrape

## Implementation notes

- The core projection resolves the tab title with its own chain rather than
  reusing `tabDisplayTitle`, which has no running-command fallback and
  abbreviates the home directory. I7 asks for the titles the phone shows today,
  which is the `projectPaneList` chain, not the sidebar's.
- `PaneRoster(jsonValue:)` is failable rather than throwing: the deleted
  `malformedReply` vocabulary gave a client no choice to make, and every
  malformed field has the same one recovery.
