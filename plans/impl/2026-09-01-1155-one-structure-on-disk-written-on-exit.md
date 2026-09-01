# One structure on disk, written on exit (PERSIST-1)

## 1. Problem

Both recovery checkpoint files carry a full versioned `AppInitFile` structure,
and the loader takes structure from the light tier unconditionally
(`mergeCheckpoints`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift:181`).
Nothing keeps the light tier newer: the `.terminate` performer cancels the armed
light window without flushing it (`app/AppRuntime.swift:1036-1045`), and the
exit path writes only the enriched file (`prepareRecoveryForApplicationExit`,
`app/AppRuntime.swift:1180-1188`). So on every clean quit, up to 2 s of
structural edits -- tab closes, renames, splits, colors, todos -- are on disk in
the enriched file and discarded at load in favor of the older light file. Close
two tabs of three and quit immediately: the next launch offers all three back.

Load-bearing premises, verified in the tree:

- The empty-model quit: closing the last tab (also: last pane, delete of the
  last group, session-creation failure of the only tab -- `Update.swift:1672`,
  `:1692`, `:1582-1583`, `:769-770`) empties the model and emits `.terminate`
  in the same frame. The loader refuses an empty snapshot
  (`Model.swift:1271-1275`), so today the exit-written enriched file fails
  validation and the *stale light file is what preserves the restore offer*.
  A naive "flush structure on exit" destroys that offer. This behavior must
  not regress.
- `toSnapshot` reads only `groups`, `selectedTabId`, `sidebar`
  (`Persistence.swift:82-115`) -- nothing process-scoped. The structure file
  is already a serialization of the session half UPDATE-4 will carve out, so
  this plan neither depends on UPDATE-4 nor changes format when it lands.
- Every light write already funnels through `LightCheckpointPolicy.capture`
  (landed with the PERSIST-3/4 commit `fe524542`), and both checkpoint files
  share one serial `CheckpointWriter` whose sync mode fences all prior writes.

## 2. Decision

One file owns structure; the other owns scrollback only; one predicate decides
what either writer may write.

- **D1.** `last-session.json` (today `last-light.json`; the current
  `AppInitFile` format, version 3, byte-for-byte unchanged) is the only
  structure on disk. The exit path flushes it synchronously, through the
  ordinary policy capture, before the scrollback write; both exit writes ride
  the one serial checkpoint writer, so structure lands first and nothing is
  left in flight at process exit.
- **D2.** `last-scrollback.json` (today `last-enriched.json`) becomes a
  scrollback-only sidecar: its own format version, a map of pane-id UUID
  strings to normalized scrollback text, nothing else. Loading is "load the
  structure, graft sidecar text by pane id"; a sidecar alone restores
  nothing, and `mergeCheckpoints` (and the "light is authoritative" rule)
  disappear rather than being restated.
- **D3.** One restorability predicate -- "at least one group holding at least
  one tab", stated on the snapshot type -- is shared by the loader's build
  guard and every checkpoint writer. The session-checkpoint policy refuses an
  unrestorable projection without taking coverage of it; a scrollback capture
  for an unrestorable snapshot is never constructed. The exit path therefore
  needs no empty-model special case: the empty-quit behavior falls out of the
  writers' shared contract.
- **D4.** The light/enriched vocabulary is retired on disk and in code
  (session/scrollback names for the files, policies, timers, paths, and
  tests). No compatibility reading of the old names or old enriched format:
  the first post-upgrade launch finds no checkpoint and offers no restore,
  once (user-approved).
- **Boundary.** Import, `--init`, and export keep the full init-file format;
  `PaneSnapshot.scrollback` stays in that format and restore staging still
  consumes it after the graft. This satisfies the D5 bind in
  `docs/design/2026-08-10-session-owned-terminal-reported-facts.md` (scrollback
  remains a graft, `PaneSnapshot` disk shape unchanged).

## 3. Invariants

- **I1.** No checkpoint write -- structure or scrollback, scheduled or exit --
  replaces a restorable session's on-disk state with an unrestorable
  session's. (This also closes a live pre-existing hole: a persisted-facet
  message arriving while the restore prompt is up can today overwrite the
  structure file with the empty launch model.)
- **I2.** After a clean exit with a restorable model, the offered restore
  reflects the model at exit time: structural edits made inside the last
  window are included.
- **I3.** After an empty-model quit, the next launch offers the same restore
  it would have offered before the quit-triggering edit (today's behavior,
  preserved).
- **I4.** A refused scrollback write creates no file, reports as complete,
  and leaves the periodic write policy able to write again later -- never
  wedged, never retrying a forbidden write.
- **I5.** A sidecar that fails to decode or carries another version counts as
  absent: the restore is offered from structure alone, with no scrollback. A
  structure file that fails counts as no restore at all, regardless of the
  sidecar.
- **I6.** The graft is defensive by id: sidecar entries for panes absent from
  the structure are ignored; structure panes absent from the sidecar restore
  with nil scrollback. (A deliberately stale sidecar -- preserved by an
  empty-quit -- grafts harmlessly.)
- **I7.** The structure file's bytes for a given model are unchanged from
  today's light checkpoint, and export output is unchanged.

## 4. Proof obligations

- **PO1** (I2, the bug): bootstrap, flush, make a structural edit with no
  flush, run the exit path, load: the offer includes the edit. Fails today.
- **PO2** (I3): drive the real close-last-tab confirmation frame to an empty
  model plus `.terminate`, run the exit path, load: the pre-close session is
  offered and the sidecar file is untouched. Fails under a naive exit flush.
- **PO3** (I1): the policy refuses an unrestorable projection *without taking
  coverage* -- after covering A, capturing empty yields nothing and a later
  capture of A still yields nothing, while a later capture of B yields B.
- **PO4** (I4): refused scrollback write on an empty model: no file, completes
  as success; a later restorable capture still writes.
- **PO5** (I5): corrupt sidecar and version-mismatched sidecar each give a
  structure-only offer; corrupt or version-mismatched structure gives no
  offer even beside a valid sidecar.
- **PO6** (I6): structure holding pane A + sidecar holding A and closed pane
  B: the offer has A's text and no B.
- **PO7** (D3): the loader refuses exactly the snapshots the predicate
  refuses (predicate truth table; the existing `.invalidSnapshot` loader test
  keeps passing). The predicate swap in `validateAndBuildDetailed` is
  behavior-preserving: the parse loop appends one group per snapshot group
  and one tab id per tab or fails the whole load, so the post-parse guard is
  equivalent.
- **PO8** (I7): the existing byte-pin test (light capture bytes ==
  `toInitFile` bytes) and the export tests keep passing unmodified.

Existing tests that pin the two-structure scheme are rewritten against the
graft, not kept alongside: the five `mergeCheckpoints` tests, the
enriched-decoding capture tests, and the app-level "an enriched checkpoint
alone restores" test (which inverts to "a sidecar alone offers no restore").
The lock/crash-detection, restore-prompt, privacy, and projection-facet suites
are untouched by design.

## 5. Non-goals / Accepted risks / Rejected ideas

- **NG1.** UPDATE-4 (the AppModel session/process split) is separate work;
  nothing here depends on it.
- **NG2.** No migration or dual-name reading. Old checkpoint files are
  orphaned in place (0600 inside 0700; no exposure, no cleanup site added).
- **AR1.** An exit-time disk failure leaves the previous structure on disk
  with no recourse -- strictly better than today's no-flush.
- **AR2.** A session-creation failure of the only tab quits and preserves the
  on-disk session, so the next launch re-offers a session that just failed to
  build. Correct: the failure was environmental, and declining the prompt is
  the escape hatch.
- **RI1.** Loader-side tolerance ("keep the last structure that validates"):
  requires a second structure file, reinstating the two-disagreeing-structures
  state this plan exists to delete.
- **RI2.** An exit-site empty-model check: restates the rule at one call site
  when not all writes flow through it; the policy owns the contract (D3).

## 6. Implementation discretion

- How the refused scrollback write reports completion to the write policy
  (PO4 pins the observable behavior; the mechanic -- e.g. success-on-refusal
  at the single write chokepoint -- is the implementer's).
- The sidecar DTO/codec factoring, including the UUID-string key mapping
  (`TypedId` is not `CodingKeyRepresentable`; do not add a protocol-wide
  conformance, which would reshape every other TypedId-keyed encoding).

## 7. Critical files

- `lib/DanTermCore/Sources/DanTermCore/Persistence.swift` -- predicate,
  sidecar codec, graft replacing `mergeCheckpoints`.
- `lib/DanTermCore/Sources/DanTermCore/LightCheckpointPolicy.swift` --
  capture refusal (then renamed per D4).
- `lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift` -- the
  scrollback capture splits from the init-file capture.
- `lib/DanTermCore/Sources/DanTermCore/Model.swift` -- build guard expressed
  through the predicate.
- `app/AppRuntime.swift` -- exit-path flush ordering, scrollback capture
  gating.
- `app/LaunchRecovery.swift` -- structure-or-nothing load plus graft.
- `lib/DanTermSupport/Sources/DanTermSupport/InstancePaths.swift` -- file
  renames.
- Tests: `lib/DanTermCore/Tests/DanTermCoreTests/{CheckpointTests,
  CheckpointCaptureTests, LightCheckpointPolicyTests}.swift`,
  `app-tests/LaunchRecoveryTests.swift`, a new app-level exit-path suite,
  `lib/DanTermSupport/Tests/DanTermSupportTests/InstancePathsTests.swift`.

## 8. Verification

TDD throughout; no new wall-clock values (sync-flush seams and the existing
census-poll guard cover every new test; `agent-docs/test-timing.md` binds).

- Edit loop: `swift test --package-path lib/DanTermCore --filter
  'Checkpoint|LightCheckpointPolicy|Snapshot'`, `swift test --package-path
  lib/DanTermSupport`, `just lint`.
- Before each commit: `just test` (covers the app-tests target).
- End-to-end, once, via `just launch-slot`: rename a tab and quit within 2 s;
  relaunch and confirm the offer shows the rename (PO1 live). Then close the
  last tab to quit; relaunch and confirm the pre-close session is offered
  (PO2 live). `just stop-slot` after.

## Commit progress
- [x] 1. refuse an unrestorable checkpoint write through one shared predicate (D3, I1, PO3/PO4/PO7)
- [ ] 2. flush the structure checkpoint on exit before the scrollback write (D1, I2/I3, PO1/PO2)
- [ ] 3. make the second file a scrollback-only sidecar and retire the light/enriched names (D2/D4, I5/I6, PO5/PO6)

## Implementation notes

- **Commit 1, refusal reporting (the discretion the plan left open).** The
  refused scrollback write reports `.succeeded` synchronously, on the main
  actor, at the `performEnrichedCheckpoint` chokepoint -- the real write
  reports back asynchronously through the writer's main-queue hop. The
  asymmetry is safe: `AppRuntimeSchedulingLifecycle.run` consumes its token
  before running the action, so a re-entrant completion is inert on a second
  pass, and no caller of `performEnrichedCheckpoint` depends on the
  completion arriving after it returns. A synchronous refusal still calls
  `checkpointWriter.drain()`, so a sync flush leaves nothing in flight, the
  same as the light tier's nothing-to-write path.
- **Commit 1, loader guard placement.** `validateAndBuildDetailed` now guards
  the input snapshot with `isRestorable` before the parse loop, rather than
  guarding `parsedGroups`/`allTabIds` after it. This is behavior-preserving
  (PO7): the loop appends one group per snapshot group and one tab id per
  snapshot tab, or returns nil for the whole load. The one visible difference
  is the log line for a snapshot that is both unrestorable and otherwise
  invalid -- it now reports the restorability failure instead of the
  duplicate-id failure. Both still return nil.
- **Commit 1, added loader coverage.** The existing `.invalidSnapshot` loader
  test only pinned `groups: []`. It now also covers one group holding no tabs
  -- the exact shape of the empty launch model that I1 is about -- so the
  loader and the shared predicate are pinned to agree on both refused shapes.
