# Construction audit: ranked findings

Produced 2026-08-18 by a 14-agent fan-out: thirteen read-only auditors, each
scoped to one narrow slice of the tree, plus a cross-cutting synthesis pass over
their combined output. Nothing here has been implemented, built, or run. Every
claim is a source reading of the tree at that date, and confidence is the
auditor's own estimate of how checkable the claim is from the cited code alone.

The bias of this audit is **by construction**: a finding earns a high impact
score when its fix makes a class of bug impossible to express, not when it
deletes the most lines. Each finding therefore carries a **By construction**
field naming exactly what stops being representable -- or `n/a` when the fix is
an honest cleanup rather than a structural one.

## How to use this file

Every finding has a stable id (`PARSE-3`, `RUNTIME-1`, ...). To start work on
one, tell an agent:

> plan the ideal solution to RUNTIME-1 in `docs/scratch/2026-08-18-construction-audit.md`

The finding section is written to be enough context on its own: it names the
files as `path#symbol`, states the problem, quotes the evidence, gives the ideal
fix and the cheaper fallback as an explicit trade-off, and names the behavioral
test that would prove it. The agent should still re-read the cited code -- the
prose is only as current as 2026-08-18.

**Checking things off.** The working list is the [Backlog](#backlog): tick the
box there and, if the outcome needs a word, append it on the same line
(`-- done 1a2b3c4`, `-- skip: covered by MODEL-2`). That is the one place to
edit; the detail sections below are reference and stay as written. A ticked box
means the prose in its `###` section may now describe code that no longer
exists, so read the commit, not the finding.

**Read the themes before the backlog.** Ten root causes explain most of the 77
findings, and fixing a theme retires its symptoms together -- several backlog
items are the same refactor seen from two areas. Then read
[Settle these first](#settle-these-first): ten pairs of findings contradict each
other or have an order that matters, and picking them up in the wrong order
wastes the work.

Scores are impact (1-5) x confidence (1-5), shown as `i x c`. Impact 5 means the
fix removes a whole class of problem; confidence 5 means the claim is verifiable
by reading the cited code.

## Themes

Ranked by the impact the synthesis pass assigned to the combined fix.

### T1. Types that understate their own invariant: a tag beside optional payloads, or a parameter wider than the accepted set

_Impact 5/5 -- 12 findings are symptoms._

**Root cause.** Across every layer the same modeling shortcut recurs: a discriminator (subject, mode tag, method tag, transition case, bare UUID) is stored or passed next to payloads that are only valid for some of its values, or a parameter takes a type far wider than the values the callee accepts. The invariant then lives in prose and is re-checked at each read, which produces the repo's characteristic defect shapes -- a silent `return []`, a `?? default`, a `preconditionFailure`, or an action applied to the wrong entity.

**Combined fix.** Turn each tag-plus-payload product into an enum whose cases carry exactly their own data, and narrow every parameter type to the set the callee actually accepts (including typed-throws and phantom-typed ids at UI boundaries). Do this as one sweep so the reducer, the IPC catalog, the interaction policy, and the AppKit menus all stop re-deriving which payload belongs to which tag; every `preconditionFailure`/`fatalError`/`?? default` guarding an impossible combination is deleted rather than reworded, and that deletion is the acceptance test for the sweep.

Symptoms: [MODEL-1](#model-1), [PARSE-2](#parse-2), [INTERACT-4](#interact-4), [INTERACT-2](#interact-2), [IOS-3](#ios-3), [MODEL-7](#model-7), [CHROME-2](#chrome-2), [PTY-6](#pty-6), [IPC-3](#ipc-3), [IOS-2](#ios-2), [IPC-5](#ipc-5), [CHROME-3](#chrome-3)

### T2. One fact stored twice: a hand-maintained mirror beside the authority that already knows it

_Impact 5/5 -- 12 findings are symptoms._

**Root cause.** A value that some other structure already determines is copied into a second field and kept in step by hand at every mutation site. The mirror is written optimistically (at submission, at construction, at push time) while the authority may decline, arrive later, or move -- so the two drift, and code downstream trusts the mirror. This is the single most common defect generator in the corpus and it has already produced at least three live bugs (the arena pad byte leak, the permanently-wrong resize dedupe, the falsely-reported invalid launch dimensions).

**Combined fix.** For each pair, delete the mirror and compute the fact from its authority: bytes-in-use from the ring cursors, the reverse submission index from the pending map, the container's structural fingerprint from its layout, the host's grid from the launch input, resize dedupe from the applied resize, iOS pinnedness from the replica, the toolbar's state from the projection value it was handed, and every handle+token or directory-resolution pair from one owning value. Where a mirror must stay for performance, it needs the recount-oracle treatment the store already applies to its side tables.

Symptoms: [STORE-1](#store-1), [MODEL-6](#model-6), [MODEL-3](#model-3), [PTY-2](#pty-2), [PTY-5](#pty-5), [IOS-1](#ios-1), [PANE-4](#pane-4), [RUNTIME-4](#runtime-4), [PANE-3](#pane-3), [IPC-6](#ipc-6), [PERSIST-2](#persist-2), [MODEL-4](#model-4)

### T3. A vocabulary enumerated once per consumer instead of declared once in a table

_Impact 4/5 -- 10 findings are symptoms._

**Root cause.** Whenever the codebase has a closed set -- DEC modes, IPC methods, CLI commands, known agents, accessory keys, tape record keys, cell-word fields, mouse buttons, preferences rows -- each consumer writes its own copy of the list rather than reading one declaration. Some copies are exhaustive switches the compiler checks, but the compiler can only check that the cases exist, never that two lists agree about a key's spelling, a number's meaning, or a tag's value. Adding a member therefore means editing three to six places, and the corpus already shows real gaps (group.new absent from the audit projection, mode 1048 settable but not resynchronizable).

**Combined fix.** Declare each closed set once as data -- a spec table or an enum with derived projections -- and make every consumer a projection of it: mode set/reset/query/resync from one ModeSpec list; IPC traits, target keys, and the audit descriptor from one traits value plus the already-round-trip-tested `params`; CLI help, per-parser usage, and the SKILL.md synopsis from one command table with a test asserting equality; agents from one registry both KnownAgent and doctor read; accessory keys, cell-word fields, pointer-owner slots, and preference rows from their own enums/row descriptors rather than parallel integer or index tables.

Symptoms: [PARSE-3](#parse-3), [IPC-1](#ipc-1), [IPC-4](#ipc-4), [IPC-2](#ipc-2), [PERSIST-7](#persist-7), [IOS-4](#ios-4), [PERSIST-6](#persist-6), [INTERACT-6](#interact-6), [STORE-3](#store-3), [CHROME-4](#chrome-4)

### T4. Pushed obligations: an invariant repaired by remembering to call something at every mutation site

_Impact 5/5 -- 6 findings are symptoms._

**Root cause.** State that belongs to an owner is stored outside it, or a repair that belongs to a chokepoint is copied into each arm that happens to need it. Correctness then rests on every current and future mutation site remembering a call the compiler cannot demand: seven search-index refreshes, nine alert-clear copies, four defocus loops, five side-table prunes, two hand-written source-cancel ladders. The known consequences range from a stale bell to a `preconditionFailure` that traps the process on a retired search coordinate.

**Combined fix.** Give each of these facts a single structural owner: funnel every history mutation through one method that refreshes the search index on the way out; move per-pane search and notification-throttle state onto PaneModel and bind pending IPC input requests to their pane so leaf removal prunes and rejects them; add focused-pane alert repair and session-focus reconciliation to the existing `defer`/reconcile sweep and delete the copied arms; and cancel dispatch sources from the one registry that already retains them. In each case the acceptance test is that the per-site call disappears entirely, not that a new site is added.

Symptoms: [INTERACT-1](#interact-1), [REDUCE-3](#reduce-3), [REDUCE-4](#reduce-4), [MODEL-5](#model-5), [REDUCE-6](#reduce-6), [PTY-1](#pty-1)

### T5. The same algorithm implemented twice, and the copies have already drifted

_Impact 4/5 -- 12 findings are symptoms._

**Root cause.** A rule that should exist once is written out per caller, per separator style, per drain reason, per completion shape, or per subclass. Every one of these pairs is documented in the corpus as already divergent -- the tested damage-shift rule is not the shipped one, the two search scans clamp wide cells differently, the two PTY read loops disagree about EIO, the two input forms disagree about rejecting an unmappable key, the two alert-raise paths disagree about the metadata bound -- so the duplication is not hypothetical debt but the direct cause of behavior that changes with the code path.

**Combined fix.** Collapse each pair to one implementation parameterized by what genuinely differs: one damage value holding the shift rule; one generic search-unit emitter over a position factory; one extended-color parser taking the separator shape; one read loop returning why it stopped; one input submission path with an optional completion; one TODO popover controller taking a scope value; one theme list controller with an activation closure; one alert-raise function; one flight tape instead of five capture buffers; one block record-range accessor, one snapshot leaf traversal, and one declared key base for the open tail's scratch tables.

Symptoms: [INTERACT-3](#interact-3), [INTERACT-5](#interact-5), [PARSE-4](#parse-4), [PTY-4](#pty-4), [PANE-5](#pane-5), [CHROME-1](#chrome-1), [CHROME-5](#chrome-5), [REDUCE-5](#reduce-5), [PTY-3](#pty-3), [STORE-5](#store-5), [PERSIST-3](#persist-3), [STORE-4](#store-4)

### T6. The Elm loop is bypassed: AppKit holds or answers for state the model should own

_Impact 4/5 -- 6 findings are symptoms._

**Root cause.** In several places the unidirectional flow is broken in one of three ways -- the view tree is read back as the source of truth (drop targets, previously visible tab, theme browser existence), the model is written outside `update()` (restore/import), or a command re-enters the loop (a modal run loop inside an open send frame, a start-search round trip through the view). Each one puts a fact outside the pure layer, so it is invisible to snapshots, IPC, and the reconcile caches, and the hand-patches beside it (`model.todoPopover = nil`, an out-of-band `reconcileTabState`, an asymmetric pass call) are the visible residue.

**Combined fix.** Make `AppRuntime.model` `private(set)` with `update()` as its only writer, and convert each bypass into the projected shape the confirmation panel already uses: a model slot, a reconcile pass that diffs against its own cache, and a Msg for the answer. Restore and import become Msgs; the theme browser and the alert/restore prompts become model-projected non-modal panels (or sheets, never `runModal`); the drag-cancel decision reads `caches.visibleTabId` and the drop target reads the pure `PaneLayout`; `.startSearch` writes `model.searchState` directly.

Symptoms: [RUNTIME-1](#runtime-1), [RUNTIME-2](#runtime-2), [RUNTIME-5](#runtime-5), [PANE-1](#pane-1), [RUNTIME-3](#runtime-3), [REDUCE-2](#reduce-2)

### T7. Failure reported as a value that success also produces

_Impact 4/5 -- 3 findings are symptoms._

**Root cause.** Several boundaries answer a failure with a value the caller cannot distinguish from a legitimate outcome: a nil decode reads as "clean exit", a `.none` row op reads as "no work", a nil wrapper reads as "this pane is a placeholder forever", and a swallowed write reads as "the lock exists". The caller then advances its state as if the operation landed, so a transient or diagnosable condition becomes a permanent, silent wrong state -- a lost crash prompt, a desynchronized outline with no path to `reloadAll`, a pane that is a blank rectangle for the rest of the tab's life.

**Combined fix.** At each of these seams, either make the operation total so there is nothing to reject, or widen the result so rejection has its own name and the caller must answer it: decide crash recovery on file existence and make the lock writer throw; make SidebarItemStore apply against the projection it is handed or return an explicit `rejected` that escalates to `reloadAll` while holding the cache back; type the container's leaf cache as `PaneWrapperView` and skip (not cache) a pane whose wrapper is missing so the next pass retries.

Symptoms: [PERSIST-1](#persist-1), [MODEL-2](#model-2), [PANE-2](#pane-2)

### T8. Repo-level inventories kept in prose or in a step array with no generator behind them

_Impact 4/5 -- 5 findings are symptoms._

**Root cause.** The gate already proves the pattern works twice (test-estate coverage, manifest ownership), but the remaining inventories -- which target gets which purity policy, which self-tests run, where scratch trees live, where package manifests live, which style rules are enforced -- are hand-typed lists that nothing checks against the tree. A check over a smaller tree than it claims to police reports success, so the gaps are invisible: three redundant purity lines, an orphaned self-test, uncleaned build trees, and a file-header rule violated nine times.

**Combined fix.** Apply the same 'checking nothing is a failure' posture to every remaining inventory: declare each source target's purity policy beside the target and have one gate step enumerate targets and fail on an undeclared one; make `gate-test-coverage-lint.py` require every `scripts/tests/*_test.*` to be reachable from STEPS or carry an in-file opt-out; give the gate one scratch root that `just clean` removes wholesale; have `manifest_targets.py` own the package roots and assert every tracked manifest is matched; and add the missing file-header lint with its self-test.

Symptoms: [BUILD-1](#build-1), [BUILD-2](#build-2), [BUILD-3](#build-3), [BUILD-5](#build-5), [BUILD-4](#build-4)

### T9. God objects: one type holding several jobs, so cross-job invariants are conventions

_Impact 3/5 -- 3 findings are symptoms._

**Root cause.** `Terminal` (7.6k lines, ~60 stored properties), `AppRuntime` (2155 lines, six jobs), and the pane-tape policy sitting in the wrong layer all share one cause: unrelated jobs share one field namespace, so any method can write any field and the invariants between jobs are enforced by comments. The layer placement case is sharper still -- policy code in DanTermSupport sits outside the purity lint's reach, so the guard that would catch a clock or a queue in decision code does not run on it.

**Combined fix.** Extract by job, each landable on its own: lift the terminal's inspection state into a value with intent-level mutations and move the state-synchronization encoder to its own type; extract the pane-tape follow broker (and then the checkpoint scheduler) out of AppRuntime into @MainActor owners with narrow entry points; move the pure pane-tape stream policy into DanTermCore and leave only the socket write in app/. Each extraction is judged by whether the extracted state stops being reachable from the code that used to reach it.

Symptoms: [PARSE-6](#parse-6), [RUNTIME-6](#runtime-6), [PERSIST-5](#persist-5)

### T10. Vocabulary and representations no live code reaches

_Impact 2/5 -- 3 findings are symptoms._

**Root cause.** Msg cases, public kit entry points, and a whole 643-line row representation survive only because tests still exercise them. Because they are tested they read as live contracts, so a reader reasons about states the product cannot enter and a future change picks the stale representation or re-implements a path nobody can take.

**Combined fix.** Delete the dead vocabulary and its tests in one pass -- `.markAlertRead`, the five iOS kit entry points, and `PackedRetainedRow` plus its test file -- moving the cell-word constants onto `LogicalLineRecord.Header` where the live store already aliases them, and let the compiler prove nothing else wanted them.

Symptoms: [REDUCE-7](#reduce-7), [IOS-5](#ios-5), [STORE-2](#store-2)

## Settle these first

Each entry is a pair or group whose members interact: one reverses the other,
one subsumes the other, or the order decides how much of the work survives.
Decide the question in the **Resolution** line before starting either side.

### C1. [IPC-1](#ipc-1) + [IPC-4](#ipc-4) + [IPC-3](#ipc-3)

- [IPC-1](#ipc-1) -- Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch
- [IPC-4](#ipc-4) -- Return one traits value from a single exhaustive switch instead of six parallel per-method enumerations
- [IPC-3](#ipc-3) -- Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear

**Issue.** All three rewrite the same `IpcRequestMethod`/`IpcRequest` projections. The audit-descriptor fix is specified in terms of `targetParameterKeys` and `params`, which the traits fix is simultaneously moving; and the todo collapse changes the case list both of them switch over. Doing them independently means each one is written against a case list and a key vocabulary the next one replaces, and the audit fix in particular could be built on the very duplicate key spellings the traits fix deletes.

**Resolution.** Settle the catalog shape first: collapse `todo.done`/`todo.open` into `todoSetDone` (small, self-contained), then land the single `traits` value plus one `targetParameterKeys`, then derive the audit descriptor from `params` filtered by those keys. The round-trip test `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog` is the fixed point that must keep passing through all three.

### C2. [MODEL-1](#model-1) + [CHROME-2](#chrome-2)

- [MODEL-1](#model-1) -- Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum
- [CHROME-2](#chrome-2) -- Make the confirmation projection carry each button's answer instead of inferring it from button visibility

**Issue.** Both redesign the confirmation transaction end to end and disagree about where the kind lives. The enum fix keeps `ConfirmationSubject` (as a computed property) so confirm dispatch can match on it; the answer fix wants the panel to know no transaction kind at all and the reducer to switch on a `ConfirmationAnswer`. Doing the panel side first means writing an answer enum against a payload shape that is about to change; doing them separately means the reducer grows two dispatch vocabularies.

**Resolution.** Land the PendingConfirmation enum first, then define `ConfirmationAnswer` as a projection of that enum's cases and delete the `Msg.confirmConfirmation`/`chooseDeleteGroupConfirmation` pair in the same change, so there is one message (`.answerConfirmation(id:answer:)`) and one exhaustive switch.

### C3. [MODEL-5](#model-5) + [REDUCE-2](#reduce-2) + [REDUCE-5](#reduce-5)

- [MODEL-5](#model-5) -- Move per-pane search and notification-throttle state into PaneModel so pane teardown prunes them
- [REDUCE-2](#reduce-2) -- Let .startSearch open the pane's search state directly instead of round-tripping through the view
- [REDUCE-5](#reduce-5) -- Raise every pane alert through one function instead of duplicating the ritual in .sessionBell

**Issue.** The storage move relocates `model.searchState` and `model.lastNotificationTime` onto `PaneModel`. The other two write new code against exactly those two dictionaries -- a new `.startSearch` write site and a new `raiseAlert` helper holding the throttle call -- so doing them first means writing, reviewing, and testing code that the storage move immediately rewrites.

**Resolution.** Move the two side tables onto `PaneModel` first (it also shrinks `clearPaneSideTables` to the alert feed), then add the `.startSearch` direct write and the `raiseAlert` funnel against the new location.

### C4. [PERSIST-5](#persist-5) + [PERSIST-6](#persist-6) + [RUNTIME-6](#runtime-6) + [BUILD-1](#build-1)

- [PERSIST-5](#persist-5) -- Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support
- [PERSIST-6](#persist-6) -- Publish the pane-tape record shape once in DanTermProtocol instead of writing keys on both sides
- [RUNTIME-6](#runtime-6) -- Move the pane-tape follow broker out of AppRuntime into its own owner
- [BUILD-1](#build-1) -- Declare each source target's purity profile once, and make the gate enumerate targets

**Issue.** Four findings move or re-own the same pane-tape code across three layers, and the fourth writes a gate that asserts the layer each file is allowed to occupy. Any order other than bottom-up means files are moved twice: the record builders cannot move into core while they still write untyped `[String: JSONValue]` literals that the client parses independently, and the purity declaration would be written against a layout the moves are about to change.

**Resolution.** Bottom-up: (1) define the typed `PaneTapeRecord` in DanTermProtocol and switch both producer and reader to it; (2) move the stream policy and record builders into DanTermCore and `writePaneTapeRecords` into app/; (3) extract the follow broker in app/; (4) declare the purity profiles last, so the gate records the settled layout rather than the transitional one.

### C5. [RUNTIME-1](#runtime-1) + [RUNTIME-3](#runtime-3)

- [RUNTIME-1](#runtime-1) -- Make the restore commit a Msg so `update()` is the only writer of `model`
- [RUNTIME-3](#runtime-3) -- Stop opening nested modal run loops from inside an open send frame

**Issue.** They overlap on the launch restore prompt and pull in opposite directions if ordered wrongly. The modal fix wants the restore prompt projected from a launch model slot with the choice arriving as a Msg; the restore fix wants `commitRestoreSession` reduced to staging plus one `send`. If the restore-as-Msg lands while `applicationDidFinishLaunching` still calls `alert.runModal()` after the IPC server is up, the new `.sessionRestored` Msg can be raced by an IPC-driven `update()` during the prompt -- exactly the discard the restore fix claims to remove.

**Resolution.** Project the restore prompt (and the config-error alert) as non-modal model-driven panels first, so nothing can re-enter `send()` mid-frame; then convert the restore commit itself into `.sessionRestored(model:)` and make `AppRuntime.model` `private(set)`.

### C6. [INTERACT-1](#interact-1) + [PARSE-6](#parse-6)

- [INTERACT-1](#interact-1) -- Refresh the search index through one history-mutation funnel instead of seven hand-placed calls
- [PARSE-6](#parse-6) -- Split the inspection layer and the state-synchronization encoder out of the Terminal struct

**Issue.** Both propose a different owner for the same search state. The funnel makes `history` private behind `withHistory` and keeps `search` on `Terminal`; the inspection lift moves `search` (with selection and links) into a `TerminalInspection` value whose only mutations are intent-level and take the projection as an argument. Building one and then the other means the search-refresh seam is designed twice.

**Resolution.** Decide the ownership question once, in favor of the inspection lift's direction, and make the history funnel its first slice: `withHistory` calls `inspection.resynchronize(with:)` on the way out. Land the funnel first (it removes a live process-trapping bug), but write it so the callback is the inspection API rather than a bare `search?.synchronizeIndex`.

### C7. [STORE-1](#store-1) + [STORE-3](#store-3) + [STORE-2](#store-2)

- [STORE-1](#store-1) -- Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites
- [STORE-3](#store-3) -- Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites
- [STORE-2](#store-2) -- Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them

**Issue.** All three edit `LogicalLineStore` and its neighbours, and two of them touch the same append/trim/drop sites. Introducing `CellWord` first means rewriting lines that sit next to twelve `bytesInUse` mutations the other fix deletes, and both fixes want the cell-word constants -- which currently live inside the file the third fix deletes -- to be somewhere stable.

**Resolution.** Order: delete `bytesInUse` and its twelve mutation sites (it also fixes the live pad-byte over-charge), then move the cell-word constants onto `LogicalLineRecord.Header` and delete `PackedRetainedRow.swift` with its tests, then introduce `CellWord` on top of the now-single layout declaration.

### C8. [INTERACT-2](#interact-2) + [PANE-3](#pane-3)

- [INTERACT-2](#interact-2) -- Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy
- [PANE-3](#pane-3) -- Record which button a press forwarded, replacing the two ad-hoc pairing booleans

**Issue.** Both rewrite `forwardPointerDown`/`forwardPointerUp` in `SwiftTerminalSessionView`, and they interact: the press-record fix exists partly because `forwardPointerDown` can drop a press when `normalizedCell` returns nil, while the pointer-event fix removes that failure mode by making the cell (including `isInsideGrid`) part of every event. Landing the booleans fix first bakes in a guard that the other fix deletes.

**Resolution.** Change `TerminalPointerEvent` to carry the `TerminalViewportCell` first and delete the out-of-band `cancelLinkInteraction` path; then replace `rightButtonForwarded` and `controlClickIsActive` with the single `forwardedButton` record, which by then has no nil-cell early return to reason about.

### C9. [PERSIST-5](#persist-5) + [RUNTIME-6](#runtime-6)

- [PERSIST-5](#persist-5) -- Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support
- [RUNTIME-6](#runtime-6) -- Move the pane-tape follow broker out of AppRuntime into its own owner

**Issue.** The broker extraction defines its entry points against where the policy currently lives (DanTermSupport). If the broker is extracted first, its init signature and session-lookup closure are written against Support-layer types that the layer move relocates, so the new type is edited immediately after it is created.

**Resolution.** Move the policy into core first, then extract the broker against the core-layer policy types; see the four-way pane-tape ordering above for the full sequence.

### C10. [PERSIST-2](#persist-2) + [PERSIST-1](#persist-1)

- [PERSIST-2](#persist-2) -- Give the recovery directory one owner: a RecoveryPaths value threaded from launch
- [PERSIST-1](#persist-1) -- Decide crash recovery from the lock file's existence, not from decoding it

**Issue.** Both change the session-lock API in `RecoveryStore`. The existence fix replaces `readSessionLockFile` with `hasSessionLock(...)` and makes the writer throw; the paths fix changes what every one of those functions takes. Doing the existence fix first means its new signatures are rewritten by the paths fix, and doing them independently keeps the demonstrated split-directory bug (lock and checkpoints resolving differently) alive under a new API.

**Resolution.** Introduce `RecoveryPaths` first and thread it from launch through every read/write/delete, then reshape the lock decision to `hasSessionLock(_:)` plus a throwing writer on top of it -- at which point a test can finally exercise write-checkpoints, write-lock, relaunch, merge in one redirected directory.

## Quick wins

Small effort, impact >= 3, confidence >= 4. Good for a first pass.

- [PARSE-1](#parse-1) (3x4) -- Clamp relative vertical cursor motion to the scroll region, not just to the screen
- [PARSE-4](#parse-4) (3x4) -- Parse the SGR 38/48/58 color grammar once instead of once per separator style
- [STORE-3](#store-3) (3x5) -- Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites
- [STORE-4](#store-4) (3x4) -- State the open tail's scratch-table key base once, so a trimmed head cannot key it two ways
- [STORE-5](#store-5) (3x5) -- Give a block one record-range accessor instead of five hand-copied index conversions
- [INTERACT-4](#interact-4) (3x5) -- Put the selection granularity inside `TerminalSelectionMutation.set` instead of beside it
- [REDUCE-2](#reduce-2) (4x5) -- Let .startSearch open the pane's search state directly instead of round-tripping through the view
- [REDUCE-5](#reduce-5) (3x5) -- Raise every pane alert through one function instead of duplicating the ritual in .sessionBell
- [REDUCE-6](#reduce-6) (3x4) -- Tie a pending IPC input request to its pane so pane teardown can reject it
- [MODEL-3](#model-3) (3x5) -- Collapse ContainerShape to layout plus zoomedLeaf; derive the structural fingerprint
- [MODEL-4](#model-4) (3x5) -- Group the sidebar group row's reload attributes into one Equatable value
- [MODEL-6](#model-6) (3x5) -- Drop the submission-to-request reverse index and derive it from the pending requests
- [MODEL-7](#model-7) (3x4) -- Make PaneTree.remove non-mutating and return an outcome that cannot be misread as a live tree
- [IPC-3](#ipc-3) (3x5) -- Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear
- [PERSIST-1](#persist-1) (4x5) -- Decide crash recovery from the lock file's existence, not from decoding it
- [PERSIST-3](#persist-3) (3x5) -- Graft scrollback through one leaf-mapping traversal instead of re-listing snapshot fields
- [RUNTIME-5](#runtime-5) (3x4) -- Derive the previously visible tab from the reconcile cache, not from `isHidden`
- [PANE-2](#pane-2) (3x5) -- Type the container's leaf cache as the wrapper it needs, so a missing wrapper is retried, not cached
- [PANE-3](#pane-3) (3x4) -- Record which button a press forwarded, replacing the two ad-hoc pairing booleans
- [PANE-4](#pane-4) (3x5) -- Give the pane toolbar one projection argument instead of thirteen optional parameters and two model mirrors
- [CHROME-2](#chrome-2) (4x5) -- Make the confirmation projection carry each button's answer instead of inferring it from button visibility
- [PTY-4](#pty-4) (3x5) -- Read the PTY through one loop instead of one per drain reason
- [IOS-1](#ios-1) (4x5) -- Let the replica report pinnedness instead of re-decoding tape JSON in the session model
- [IOS-4](#ios-4) (3x5) -- Build the accessory key row from the key enum instead of matching two hand-numbered tag tables
- [BUILD-3](#build-3) (3x5) -- Put every gate scratch tree under one root so `just clean` cannot miss one
- [BUILD-4](#build-4) (3x5) -- Lint the Swift file-header rule AGENTS.md states, which is already violated nine times
- [BUILD-5](#build-5) (3x5) -- Give the three manifest-discovery lists one owner so a new package root cannot be skipped

## Highest scoring

The whole corpus ranked by impact x confidence; ties broken by effort. Use this
to pick, and the backlog below to track.

| Score | Id | Effort | Kind | Finding |
|---|---|---|---|---|
| 5x5 = 25 | [IPC-1](#ipc-1) | medium | correctness | Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch |
| 5x5 = 25 | [STORE-1](#store-1) | medium | structural | Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites |
| 5x5 = 25 | [CHROME-1](#chrome-1) | large | structural | Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value |
| 4x5 = 20 | [CHROME-2](#chrome-2) | small | correctness | Make the confirmation projection carry each button's answer instead of inferring it from button visibility |
| 4x5 = 20 | [IOS-1](#ios-1) | small | structural | Let the replica report pinnedness instead of re-decoding tape JSON in the session model |
| 4x5 = 20 | [PERSIST-1](#persist-1) | small | correctness | Decide crash recovery from the lock file's existence, not from decoding it |
| 4x5 = 20 | [REDUCE-2](#reduce-2) | small | structural | Let .startSearch open the pane's search state directly instead of round-tripping through the view |
| 4x5 = 20 | [BUILD-1](#build-1) | medium | structural | Declare each source target's purity profile once, and make the gate enumerate targets |
| 4x5 = 20 | [CHROME-3](#chrome-3) | medium | structural | Carry typed ids in sidebar menu items instead of bare UUIDs |
| 4x5 = 20 | [MODEL-1](#model-1) | medium | structural | Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum |
| 4x5 = 20 | [PARSE-2](#parse-2) | medium | structural | Make "alternate screen live without a retained primary" unrepresentable |
| 4x5 = 20 | [PTY-1](#pty-1) | medium | structural | Cancel every retained dispatch source from the one registry that already holds them |
| 4x5 = 20 | [PTY-2](#pty-2) | medium | structural | Give TerminalPTYHost its geometry from the launch input instead of storing a second copy |
| 4x5 = 20 | [RUNTIME-1](#runtime-1) | medium | structural | Make the restore commit a Msg so `update()` is the only writer of `model` |
| 4x5 = 20 | [RUNTIME-2](#runtime-2) | medium | structural | Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence |
| 4x5 = 20 | [STORE-2](#store-2) | medium | simplification | Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them |
| 4x5 = 20 | [IPC-2](#ipc-2) | large | structural | Generate the CLI help text and SKILL.md synopsis from one command table instead of hand-syncing three copies |
| 4x4 = 16 | [BUILD-2](#build-2) | medium | tooling | Make an orphaned gate self-test fail the gate instead of silently never running |
| 4x4 = 16 | [INTERACT-1](#interact-1) | medium | structural | Refresh the search index through one history-mutation funnel instead of seven hand-placed calls |
| 4x4 = 16 | [INTERACT-2](#interact-2) | medium | api-shape | Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy |
| 4x4 = 16 | [IOS-2](#ios-2) | medium | correctness | Make an authorized attempt carry its target so a Go tap can never be dropped against a stale one |
| 4x4 = 16 | [MODEL-2](#model-2) | medium | correctness | Make SidebarItemStore reject nothing, or report rejection, so a dropped row op cannot strand the outline |
| 4x4 = 16 | [PANE-1](#pane-1) | medium | structural | Resolve the pane drop target from the model layout, not from live wrapper frames |
| 4x4 = 16 | [PERSIST-4](#persist-4) | medium | correctness | Confine the IPC connection's descriptor to its write queue so a queued write cannot land on a reused fd |
| 4x4 = 16 | [REDUCE-3](#reduce-3) | medium | structural | Repair the focused pane's alerts in one pass instead of copying the rule into nine arms |

## Backlog

Grouped by area, so a session can batch one area at a time. Tick the box when
the item is done or deliberately skipped, and say which on the same line.

### Terminal parser and screen state (`PARSE`)

- [ ] **[PARSE-1](#parse-1)** (3x4, small) Clamp relative vertical cursor motion to the scroll region, not just to the screen
- [ ] **[PARSE-2](#parse-2)** (4x5, medium) Make "alternate screen live without a retained primary" unrepresentable
- [ ] **[PARSE-3](#parse-3)** (3x5, medium) Derive DEC/ANSI mode set, reset, query and resynchronization from one mode table
- [ ] **[PARSE-4](#parse-4)** (3x4, small) Parse the SGR 38/48/58 color grammar once instead of once per separator style
- [ ] **[PARSE-5](#parse-5)** (2x4, small) Reset the saved cursor as part of DECSTR
- [ ] **[PARSE-6](#parse-6)** (3x4, large) Split the inspection layer and the state-synchronization encoder out of the Terminal struct

### Scrollback and row storage (`STORE`)

- [ ] **[STORE-1](#store-1)** (5x5, medium) Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites
- [ ] **[STORE-2](#store-2)** (4x5, medium) Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them
- [ ] **[STORE-3](#store-3)** (3x5, small) Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites
- [ ] **[STORE-4](#store-4)** (3x4, small) State the open tail's scratch-table key base once, so a trimmed head cannot key it two ways
- [ ] **[STORE-5](#store-5)** (3x5, small) Give a block one record-range accessor instead of five hand-copied index conversions

### Selection, search, damage, presentation (`INTERACT`)

- [ ] **[INTERACT-1](#interact-1)** (4x4, medium) Refresh the search index through one history-mutation funnel instead of seven hand-placed calls
- [ ] **[INTERACT-2](#interact-2)** (4x4, medium) Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy
- [ ] **[INTERACT-3](#interact-3)** (3x5, medium) Delete `TerminalDamageAccumulator`'s copy of the shift-composition rule and let it hold a `TerminalDamage`
- [ ] **[INTERACT-4](#interact-4)** (3x5, small) Put the selection granularity inside `TerminalSelectionMutation.set` instead of beside it
- [ ] **[INTERACT-5](#interact-5)** (3x4, large) Parameterize the one cell-to-search-unit scan by position type instead of writing it twice
- [ ] **[INTERACT-6](#interact-6)** (2x4, small) Key pointer-owner and wheel-remainder storage by their enums instead of by hand-written slots

### Core reducer (Update/Msg/Command) (`REDUCE`)

- **REDUCE-1** -- merged into [MODEL-1](#model-1); nothing to track here.
- [ ] **[REDUCE-2](#reduce-2)** (4x5, small) Let .startSearch open the pane's search state directly instead of round-tripping through the view
- [ ] **[REDUCE-3](#reduce-3)** (4x4, medium) Repair the focused pane's alerts in one pass instead of copying the rule into nine arms
- [ ] **[REDUCE-4](#reduce-4)** (3x4, medium) Derive terminal focus from the model instead of emitting focusSession(false) from four arms
- [ ] **[REDUCE-5](#reduce-5)** (3x5, small) Raise every pane alert through one function instead of duplicating the ritual in .sessionBell
- [ ] **[REDUCE-6](#reduce-6)** (3x4, small) Tie a pending IPC input request to its pane so pane teardown can reject it
- [ ] **[REDUCE-7](#reduce-7)** (2x5, small) Delete the senderless .markAlertRead message

### Core model and projections (`MODEL`)

- [ ] **[MODEL-1](#model-1)** (4x5, medium) Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum
- [ ] **[MODEL-2](#model-2)** (4x4, medium) Make SidebarItemStore reject nothing, or report rejection, so a dropped row op cannot strand the outline
- [ ] **[MODEL-3](#model-3)** (3x5, small) Collapse ContainerShape to layout plus zoomedLeaf; derive the structural fingerprint
- [ ] **[MODEL-4](#model-4)** (3x5, small) Group the sidebar group row's reload attributes into one Equatable value
- [ ] **[MODEL-5](#model-5)** (3x4, medium) Move per-pane search and notification-throttle state into PaneModel so pane teardown prunes them
- [ ] **[MODEL-6](#model-6)** (3x5, small) Drop the submission-to-request reverse index and derive it from the pending requests
- [ ] **[MODEL-7](#model-7)** (3x4, small) Make PaneTree.remove non-mutating and return an outcome that cannot be misread as a live tree

### IPC protocol, dispatch, CLI (`IPC`)

- [ ] **[IPC-1](#ipc-1)** (5x5, medium) Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch
- [ ] **[IPC-2](#ipc-2)** (4x5, large) Generate the CLI help text and SKILL.md synopsis from one command table instead of hand-syncing three copies
- [ ] **[IPC-3](#ipc-3)** (3x5, small) Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear
- [ ] **[IPC-4](#ipc-4)** (3x5, medium) Return one traits value from a single exhaustive switch instead of six parallel per-method enumerations
- [ ] **[IPC-5](#ipc-5)** (2x5, small) Make IpcRequest.decode typed-throws so IpcServer cannot need two decode-failure paths
- [ ] **[IPC-6](#ipc-6)** (2x5, small) Collapse CLIResolvedTarget into CLIConnectionTarget

### Persistence, recovery, support layer (`PERSIST`)

- [ ] **[PERSIST-1](#persist-1)** (4x5, small) Decide crash recovery from the lock file's existence, not from decoding it
- [ ] **[PERSIST-2](#persist-2)** (3x5, medium) Give the recovery directory one owner: a RecoveryPaths value threaded from launch
- [ ] **[PERSIST-3](#persist-3)** (3x5, small) Graft scrollback through one leaf-mapping traversal instead of re-listing snapshot fields
- [ ] **[PERSIST-4](#persist-4)** (4x4, medium) Confine the IPC connection's descriptor to its write queue so a queued write cannot land on a reused fd
- [ ] **[PERSIST-5](#persist-5)** (3x4, medium) Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support
- [ ] **[PERSIST-6](#persist-6)** (3x4, medium) Publish the pane-tape record shape once in DanTermProtocol instead of writing keys on both sides
- [ ] **[PERSIST-7](#persist-7)** (3x4, medium) Drive doctor's agent probes from one agent registry shared with KnownAgent

### App runtime and reconcile (`RUNTIME`)

- [ ] **[RUNTIME-1](#runtime-1)** (4x5, medium) Make the restore commit a Msg so `update()` is the only writer of `model`
- [ ] **[RUNTIME-2](#runtime-2)** (4x5, medium) Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence
- [ ] **[RUNTIME-3](#runtime-3)** (4x4, medium) Stop opening nested modal run loops from inside an open send frame
- [ ] **[RUNTIME-4](#runtime-4)** (3x5, medium) Give each armed timer one owner instead of a handle field plus a token field
- [ ] **[RUNTIME-5](#runtime-5)** (3x4, small) Derive the previously visible tab from the reconcile cache, not from `isHidden`
- [ ] **[RUNTIME-6](#runtime-6)** (3x5, medium) Move the pane-tape follow broker out of AppRuntime into its own owner

### Pane views and geometry (`PANE`)

- [ ] **[PANE-1](#pane-1)** (4x4, medium) Resolve the pane drop target from the model layout, not from live wrapper frames
- [ ] **[PANE-2](#pane-2)** (3x5, small) Type the container's leaf cache as the wrapper it needs, so a missing wrapper is retried, not cached
- [ ] **[PANE-3](#pane-3)** (3x4, small) Record which button a press forwarded, replacing the two ad-hoc pairing booleans
- [ ] **[PANE-4](#pane-4)** (3x5, small) Give the pane toolbar one projection argument instead of thirteen optional parameters and two model mirrors
- [ ] **[PANE-5](#pane-5)** (3x5, medium) Collapse the four duplicated fire-and-forget input methods into one completion-taking path

### Window chrome and auxiliary UI (`CHROME`)

- [ ] **[CHROME-1](#chrome-1)** (5x5, large) Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value
- [ ] **[CHROME-2](#chrome-2)** (4x5, small) Make the confirmation projection carry each button's answer instead of inferring it from button visibility
- [ ] **[CHROME-3](#chrome-3)** (4x5, medium) Carry typed ids in sidebar menu items instead of bare UUIDs
- [ ] **[CHROME-4](#chrome-4)** (3x5, medium) Build the preferences grid from declared rows so warning rows and padding stop being addressed by literal index
- [ ] **[CHROME-5](#chrome-5)** (3x5, medium) Extract the theme list (filter, selection, cell vending) shared by the browser and the picker sheet
- [ ] **[CHROME-6](#chrome-6)** (3x4, medium) Give the alerts popover a typed, reusable row cell and stop computing row age at build time

### PTY host and session boundary (`PTY`)

- [ ] **[PTY-1](#pty-1)** (4x5, medium) Cancel every retained dispatch source from the one registry that already holds them
- [ ] **[PTY-2](#pty-2)** (4x5, medium) Give TerminalPTYHost its geometry from the launch input instead of storing a second copy
- [ ] **[PTY-3](#pty-3)** (4x4, large) Record every applied transition on the flight tape and delete the five parallel capture buffers
- [ ] **[PTY-4](#pty-4)** (3x5, small) Read the PTY through one loop instead of one per drain reason
- [ ] **[PTY-5](#pty-5)** (3x4, medium) Dedupe grid submissions on the applied fact, not on an optimistic mirror in the controller
- [ ] **[PTY-6](#pty-6)** (2x5, small) Give viewport navigation its own three-case type instead of a nine-case enum guarded by preconditionFailure

### iOS client (`IOS`)

- [ ] **[IOS-1](#ios-1)** (4x5, small) Let the replica report pinnedness instead of re-decoding tape JSON in the session model
- [ ] **[IOS-2](#ios-2)** (4x4, medium) Make an authorized attempt carry its target so a Go tap can never be dropped against a stale one
- [ ] **[IOS-3](#ios-3)** (3x4, medium) Give the model one connection identity instead of four optionals a nil response id can match
- [ ] **[IOS-4](#ios-4)** (3x5, small) Build the accessory key row from the key enum instead of matching two hand-numbered tag tables
- [ ] **[IOS-5](#ios-5)** (2x5, small) Delete the session vocabulary only tests can reach

### Build, gate, CI, docs (`BUILD`)

- [ ] **[BUILD-1](#build-1)** (4x5, medium) Declare each source target's purity profile once, and make the gate enumerate targets
- [ ] **[BUILD-2](#build-2)** (4x4, medium) Make an orphaned gate self-test fail the gate instead of silently never running
- [ ] **[BUILD-3](#build-3)** (3x5, small) Put every gate scratch tree under one root so `just clean` cannot miss one
- [ ] **[BUILD-4](#build-4)** (3x5, small) Lint the Swift file-header rule AGENTS.md states, which is already violated nine times
- [ ] **[BUILD-5](#build-5)** (3x5, small) Give the three manifest-discovery lists one owner so a new package root cannot be skipped

## Findings in detail

## Area: Terminal parser and screen state

_Scope: Terminal escape-sequence parser and screen state machine (lib/TerminalCore: Terminal.swift, EscapeAbsorber.swift, OSCPayload.swift, TerminalInputStream.swift, UTF8Decoder.swift, TerminalScalars.swift, TerminalStyle.swift, TerminalDefaultColors.swift)_

**Auditor's read on the area.** The byte-level layers are in good shape: `UTF8Decoder` is a clean DFA with correct maximal-subpart replacement, `EscapeAbsorber` is a faithful bounded VT500 state machine with inline fixed-capacity parameter storage, and `TerminalInputStream` documents its ASCII-run fast path and chunk-invariance contract well. The problems are concentrated in `Terminal.swift`, where protocol knowledge that should live in one table is hand-enumerated in several places and the two-screen model is expressed as an optional that forces two `preconditionFailure`s and a force unwrap. I did not audit reflow (`resizeWidth`/`reconstructLogicalLines`), `LogicalLineStore`, damage accumulation, or search/link projection internals, and I did not evaluate DEC Special Graphics (`ESC ( 0`), which `docs/scratch/alacritty-test-portage.md` records as a deliberate omission but which the decision register does not mention.

<a id="parse-1"></a>

### PARSE-1. Clamp relative vertical cursor motion to the scroll region, not just to the screen

`correctness` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#movePositionedCursor`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#dispatchCSI`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#positioningRowRange`

**Problem.** CUU, CUD, CNL and CPL are relative vertical motions. xterm, kitty and Ghostty stop them at the scrolling margins whenever the cursor starts inside the region, whether or not origin mode is on. DanTerm routes all four through `movePositionedCursor`, which clamps only to `positioningRowRange` -- and that range is the margins *only in origin mode*. With origin mode off (the default) a `CSI nA` from inside a region walks straight through the top margin into rows the application has reserved.

**Evidence.** `dispatchCSI` handles `case 0x41, 0x6B:` with `movePositionedCursor(row: screen.cursor.row - amount, column: screen.cursor.column)` and `case 0x42, 0x65:` symmetrically; `movePositionedCursor` does `let rowRange = positioningRowRange; screen.cursor.row = min(max(row, rowRange.lowerBound), rowRange.upperBound - 1)`, and `positioningRowRange` is `modes.isOriginMode ? activeScrollRegion : 0..<rowCount`. Compare `references/ghostty/src/terminal/Terminal.zig#cursorUp`, which computes its max from `self.scrolling_region.top` unconditionally, and `references/kitty/kitty/screen.c#screen_cursor_up`, which passes `in_margins = cursor_within_margins(self)` into `screen_ensure_bounds`. The comment on `Terminal.advanceToNextRow` already names the affected workload: inline-viewport TUIs that pin a footer with `CSI 1;N r`. Only libvterm agrees with the current behavior (`references/libvterm/src/state.c` clamps to the full screen in its non-origin branch).

**Ideal fix.** Stop expressing two different clamps through one function. Give the cursor two motion entry points -- an absolute one (CUP/HVP/VPA/CHA) that clamps to `positioningRowRange`, and a relative vertical one that clamps to `activeScrollRegion` when the starting row is inside it and to the full screen otherwise. Route 0x41/0x42/0x45/0x46 through the relative one. The bound then follows from the motion kind rather than from a mode flag the call site never mentions.

**By construction.** After the split, no call site can express "a relative vertical move bounded by the absolute positioning range": the bound is chosen by which entry point you call, so a new relative motion cannot silently inherit the absolute clamp.

**Cheaper fallback.** none -- the ideal fix is small: one extra clamp helper and four call sites.

**Verification.** A behavioral test in `TerminalScrollRegionTests`: feed `CSI 3;8r`, then `CSI 5;1H`, then `CSI 10A`, and assert the cursor row is the region top (index 2), not 0; the symmetric case feeds `CSI 20B` and asserts it stops at the bottom margin. Add the outside-the-region case (cursor above the top margin moving up) to pin that it still reaches row 0.

**Risk.** An application that deliberately parks the cursor outside the region and then moves relatively must keep the full-screen bound; the "starts inside the region" condition preserves that, and the outside-region test pins it.

<a id="parse-2"></a>

### PARSE-2. Make "alternate screen live without a retained primary" unrepresentable

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#inactiveScreen`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#resize`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#encodeStateSynchronization`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#primaryScreenRows`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#swapActiveScreen`

**Problem.** The two screens are stored as `screen` (whichever is live) plus `inactiveScreen: ScreenState?` plus an `activeScreen` enum. Three fields encode two facts, and the combination `activeScreen == .alternate && inactiveScreen == nil` -- alternate live, primary lost -- is expressible. Every reader that needs the primary specifically has to defend against it, so the type system does no work and the invariant is carried by comments and crash guards.

**Evidence.** `encodeStateSynchronization` writes `let primaryState = activeScreen == .primary ? screen : inactiveScreen!` -- a force unwrap. `primaryScreenRows` repeats the same test and then `preconditionFailure("the primary screen must be retained while the alternate is live")`. `resize` cannot address the primary at all: it does `if activeScreen == .alternate { guard var primary = inactiveScreen else { preconditionFailure(...) }; swap(&screen, &primary); inactiveScreen = primary }`, resizes, then swaps back with a second `preconditionFailure("the alternate screen must remain retained during resize")`. `swapActiveScreen` is the sole writer keeping all three fields consistent.

**Ideal fix.** Keep `screen` stored as the live screen (the hot path mutates it in place and must keep doing so), and replace `inactiveScreen` + `activeScreen` with one enum carrying the offscreen state: `case primaryLive(alternate: ScreenState?)` / `case alternateLive(primary: ScreenState)`. `isAlternateScreenActive` becomes a computed case test, `primaryScreenRows` becomes a total function with no guard, `encodeStateSynchronization` loses the force unwrap, and `resize` addresses the primary directly instead of swapping it in and back out. The alternate stays optional because it genuinely may never have been created; the primary stops being optional because it never can be.

**By construction.** "The alternate screen is live and no primary screen exists" becomes unrepresentable, so the two `preconditionFailure` sites and the `inactiveScreen!` force unwrap have nothing left to check and are deleted rather than reworded.

**Cheaper fallback.** If the offscreen enum fights in-place mutation anywhere, store `primary: ScreenState` and `alternate: ScreenState?` separately with the live one selected by `activeScreen` -- this still removes both preconditions and the force unwrap, at the cost of one more field to keep consistent.

**Verification.** Behavior must be unchanged, so the proof is the existing suites plus a test that enters the alternate screen (`CSI ?1049h`), resizes to a different width and height, exits, and asserts the primary content, cursor and scrollback match an equivalent run that never entered the alternate screen. `stateSynchronization` taken while the alternate screen is live must still encode the primary grid.

**Risk.** The resize path is the one place both screens are mutated in the same call; the resize-across-alternate-screen test above is what proves the swap dance was the only thing being removed.

<a id="parse-3"></a>

### PARSE-3. Derive DEC/ANSI mode set, reset, query and resynchronization from one mode table

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#modeKeyPath`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applyDECPrivateModes`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#decPrivateModeStatus`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#appendModes`

**Problem.** What a mode number means is written down four separate times: a number-to-keypath table, a side-effect switch in the setter, a fallback switch in the DECRQM reporter, and a hand-written emitter list in the state-synchronization writer. Adding or changing one mode requires editing up to four lists that nothing cross-checks, so a mode can be settable but unreportable, or settable but not restored when a pane's state is resynchronized.

**Evidence.** `Terminal.modeKeyPath` maps 11 numbers to `WritableKeyPath<TerminalModes, Bool>`. `applyDECPrivateModes` re-switches on the same numbers for 6, 7, 1000, 1002, 1003, 1047, 1048, 1049. `decPrivateModeStatus` re-switches again for 1000, 1002, 1003, 1047, 1049 -- and has no case for 1048, which `applyDECPrivateModes` does implement, so DECRQM answers "not recognized" (status 0) for a mode the terminal honors. `appendModes` hand-lists a fourth time: `let privateModes: [(Int, Bool)] = [(1, modes.isApplicationCursorKeysMode), (6, ...), (7, ...), (12, ...), (25, ...), (1004, ...), (1006, ...), (2004, ...), (2026, ...)]`, followed by a literal `ESC[?1000l ESC[?1002l ESC[?1003l` and a switch over `modes.mouseTrackingMode` that re-derives that mapping a third time.

**Ideal fix.** One `static let modes: [ModeSpec]` keyed by (namespace, number), where each spec carries how to read the flag, how to write it, an optional side effect to run on set/reset, and whether it participates in state resynchronization. `applyANSIModes` / `applyDECPrivateModes` look the spec up per parameter; `decPrivateModeStatus` / `ansiModeStatus` read the same spec's getter; `appendModes` iterates the specs marked resynchronizable and emits `CSI ? n h/l` from that same getter. Mouse tracking stays one enum but is declared as three specs sharing one accessor pair, so those three numbers are enumerated once.

**By construction.** A mode that can be set but not queried, or set but not restored on resynchronization, stops being expressible: one spec supplies all three behaviors, so the sites cannot disagree and the 1048 gap cannot recur.

**Cheaper fallback.** none -- the table is the smaller structure; the current four lists are the workaround.

**Verification.** A behavioral test that, for every mode the engine accepts, feeds `CSI ? n h`, asserts DECRQM (`CSI ? n $p`) reports 1, feeds `CSI ? n l` and asserts it reports 2. Plus a resynchronization round trip: set a spread of modes, take `stateSynchronization`, feed its bytes into a fresh terminal, and assert every mode reports the same DECRQM status as the source.

**Risk.** Closing the 1048 reporting gap changes one externally visible reply; that is a move toward xterm, and the DECRQM sweep test pins the new answer.

<a id="parse-4"></a>

### PARSE-4. Parse the SGR 38/48/58 color grammar once instead of once per separator style

`simplification` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#colonColor`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#semicolonColor`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applyColonSGR`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applySGR`

**Problem.** The extended-color grammar is implemented twice -- once for colon-separated groups and once for semicolon-separated runs -- and the two implementations already accept different languages. The "which field does 38/48/58 write" decision is also written twice, verbatim, in two different functions.

**Evidence.** `colonColor` accepts both `38:2:<colorspace>:r:g:b` (`if group.count >= 6`) and `38:2:r:g:b` (`guard group.count >= 5`); `semicolonColor` accepts only the four-parameter `38;2;r;g;b` form, with no colorspace tolerance. Both hand the result back to identical branches: `applySGR` has `if parameter == 58 { currentStyle.underlineColor = color } else { set(color: color, foreground: parameter == 38) }` and `applyColonSGR` has the same three lines spelled with `leading` instead of `parameter`.

**Ideal fix.** One `extendedColor(from:)` that walks a parameter slice and returns `(TerminalColor?, consumedCount)`, taking the separator shape as an explicit input rather than being written twice; and one `ColorTarget` enum (`.foreground`, `.background`, `.underline`) derived from 38/48/58 with a single apply site. `applySGR` and `applyColonSGR` then differ only in how they cut the slice.

**By construction.** The colon and semicolon forms cannot accept different color grammars, and a future target (or a new subparameter form) cannot be wired into one path and forgotten in the other, because there is only one path.

**Cheaper fallback.** none -- the shared walker is smaller than either of the current copies.

**Verification.** A parameterized test over the color forms -- `38;5;n`, `38:5:n`, `38;2;r;g;b`, `38:2:r:g:b`, `38:2:cs:r:g:b`, and the same five for 48 and 58 -- asserting the resulting `TerminalStyle` foreground/background/underlineColor, plus truncated variants (`38;5`, `38:2:1:2`) asserting the style is unchanged and that later parameters in the same SGR still apply.

**Risk.** Unifying the grammars changes which malformed forms are accepted; the truncated-variant assertions are what fix the intended language rather than letting it drift again.

<a id="parse-5"></a>

### PARSE-5. Reset the saved cursor as part of DECSTR

`correctness` &middot; impact 2, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#softReset`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#resetControlState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#restoreCursor`

**Problem.** DECSTR (`CSI ! p`) is specified to reset the saved cursor state to the home position with default attributes. DanTerm's soft reset clears the scroll region, modes, tab stops and current style but leaves `screen.savedCursor` untouched, so a DECRC (`ESC 8`) issued after a soft reset restores a pre-reset position, origin mode, style and cursor shape that the application believes it discarded.

**Evidence.** `softReset` calls `selectPrimaryScreen()`, `resetControlState()`, clears the hyperlink pen and link slots, then `clearPendingMotionState()`. `resetControlState` assigns `scrollRegion = nil`, `modes = TerminalModes()`, clears the kitty stacks, rebuilds `tabStops`, and sets `currentStyle = TerminalStyle()` -- `screen.savedCursor` appears nowhere. `restoreCursor` then reads every field of that stale `SavedCursorState`, including `modes.isOriginMode = screen.savedCursor.isOriginMode`, so the reset origin mode can also be undone. Compare `references/kitty/kitty/screen.c#do_screen_reset`, which invalidates the savepoints (`main_savepoint.is_valid = false`) on the soft path too.

**Ideal fix.** State the soft reset as one assignment over the complete DECSTR-defined state rather than a list of remembered fields: have `resetControlState` also set `screen.savedCursor = SavedCursorState()`, and the inactive screen's likewise, matching the existing `inactiveScreen?.kittyKeyboardStack.removeAll()` line.

**By construction.** n/a -- this is a missing case in an existing funnel, not a representable-invalid-state problem; putting it in `resetControlState` at least keeps the reset stated in one place rather than at each caller.

**Cheaper fallback.** none -- this is one line inside the existing reset funnel.

**Verification.** A behavioral test: move the cursor and set a distinctive SGR, `ESC 7`, feed `CSI ! p`, then `ESC 8`, and assert the cursor is at row 0 column 0 with the default style and origin mode off -- not at the pre-reset position with the pre-reset attributes.

**Risk.** An application that relies on DECSC state surviving DECSTR would change behavior; no supported workflow depends on that, and the DEC specification plus kitty both discard it.

<a id="parse-6"></a>

### PARSE-6. Split the inspection layer and the state-synchronization encoder out of the Terminal struct

`structural` &middot; impact 3, confidence 4 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#invalidateInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#clearInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#refreshHasContentInspectionState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#encodeStateSynchronization`

**Problem.** `Terminal` is a single 7.6k-line struct carrying roughly sixty stored properties and doing at least five separable jobs: escape dispatch and grid mutation, width/height reflow, scrollback and eviction, user inspection (selection, search, hovered and armed links, viewport anchoring, row-numbering epochs), and the state-synchronization byte encoder. Every private method can write every field, so cross-job invariants -- "a grid mutation that overwrites content retires the link state anchored there", "a history mutation resynchronizes the search index" -- are upheld by remembering to call a function, and the compiler cannot help.

**Evidence.** The inspection fields (`selection`, `selectionRequiresNonemptyReflowResult`, `search`, `hoveredLinkState`, `armedLinkState`, `hoveredLinkRevisionCounter`, `hasContentInspectionState`, `viewportState`, `rowNumberingEpoch`, `evictedRowCount`) are plain private vars sitting alongside `screen`, `history`, `modes` and `styleTable`. Their coherence is maintained by property observers (`didSet { refreshHasContentInspectionState() }` on three of them) and by grid code remembering to call one of four differently scoped entry points -- `invalidateInspection(inViewportRows:)`, `invalidateInspectionState(inViewportRows:)`, `invalidateInspection(inScrollbackRow:)`, `synchronizeSearchIndexPrefix()` -- which a new mutation path must pick correctly from. Separately, `encodeStateSynchronization` and its helpers (`appendControlState`, `appendSavedCursor`, `appendModes`, `appendSemanticState`, `appendGraphemeSynchronization`, `boundedHistoryStart`, `alignedHistoryStart`) are roughly 350 lines that only read state and emit bytes.

**Ideal fix.** Two extractions, independently landable. First, lift the inspection fields into a `TerminalInspection` value that owns them and exposes only intent-level mutations (`invalidate(absoluteRows:)`, `clear()`, `resynchronize(with:)`), with the projection passed in as an argument; `Terminal` then holds one `inspection` field and grid code can reach that state only through the API. Second, move the state-synchronization encoder into its own type in its own file, constructed from a read-only view of the terminal. Both shrink `Terminal` to parser plus grid plus reflow and give each extracted job a testable surface of its own.

**By construction.** After the inspection lift, grid and parser code cannot assign to `selection`, `search` or the link slots at all; the only way to affect them is the invalidation API, so "a new mutation path that writes inspection state directly and skips the damage bookkeeping" stops being expressible.

**Cheaper fallback.** If the inspection lift proves too entangled with reflow's anchor capture and restatement, do the state-synchronization encoder alone -- it is pure read-and-emit -- and leave inspection in place with a written note that the lift is the remaining half.

**Verification.** No behavior may change, so the proof is the existing `TerminalCoreTests` suites (selection, search, hyperlink interaction, stale-wrap-claim, state-synchronization round trips) passing unchanged, plus a state-synchronization round-trip test that feeds an encoded snapshot into a fresh terminal and asserts equality of projected text, cursor, modes and styles.

**Risk.** The inspection lift touches reflow's anchor capture and restatement, the most delicate code in the file; the round-trip and selection-across-resize tests keep it honest, and the encoder extraction can ship first to de-risk the sequencing.

## Area: Scrollback and row storage

_Scope: Scrollback and row storage (LogicalLineStore, LogicalLineRecord, PackedRetainedRow, TerminalMemoryCensus, Instruments, TerminalGeometry)_

**Auditor's read on the area.** The doc-31 arena store is unusually disciplined: the two grand totals are already derived off the block ring, the side-table charge has a recount oracle asserted in `census`, and the fold has one shared shape function feeding all three read walks. The residue is concentrated in three places -- the one remaining hand-maintained byte total (`bytesInUse`), the previous representation (`PackedRetainedRow`) that survives only as a constant namespace, and a handful of hand-copied arithmetic idioms (cell-word decode, block-to-record-range). I did not audit `Terminal.swift`'s side of the seam (anchors, projections, admission triggers) or the test files beyond checking which oracles exist; `TerminalGeometry.swift` is plain read-only value types and yielded nothing.

<a id="store-1"></a>

### STORE-1. Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites

`structural` &middot; impact 5, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#dropTailRecord`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#wrapWriteCursorAtSeam`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#chargedBytes`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#census`

**Problem.** `bytesInUse` is the term that directly bounds `31/I2`, and it is the one maintained total in this file with no owner and no oracle. Twelve mutation sites add or subtract it by hand (`openRecordIfNeeded`, `appendCells`, `appendBlankCells`, `closeOpenRecord`, `forceSplitOpenRecord`, `reopenClosedTail`, `cutTail`, `trimHeadRecord`, `dropHeadRecord`, `dropTailRecord`, `wrapWriteCursorAtSeam`, `resetToEmptyArena`), while the side-table charge next to it gets `recountedChargedBytes` plus an `assert` in `census`, and the row and content totals get `independentDisplayRowRecount` / `independentContentUnitRecount`. One of the twelve is already wrong: tail truncation across a chunk-boundary pad leaves the pad's bytes charged, so history over-charges and evicts earlier than the budget requires.

**Evidence.** The in-use region is by construction the ring span `[head, writeCursor)`, and every site moves the cursor and the counter by the same amount: `openRecordIfNeeded` does `writeCursor += Header.byteCount; bytesInUse += Header.byteCount`; `closeOpenRecord` does `bytesInUse += record.byteLength - headerAndCells(record.cellCount)` with `writeCursor = recordOffset(in: offset) + record.byteLength`; `dropHeadRecord` subtracts exactly the ring distance `nextOffset > oldOffset ? nextOffset - oldOffset : (arenaCapacity - oldOffset) + nextOffset` and sets `head = nextOffset`; `wrapWriteCursorAtSeam` charges a pad at `bytesInUse += pad.byteLength` and sets `writeCursor = boundary`. The exception is `dropTailRecord`, which does `bytesInUse -= record.byteLength; writeCursor = recordOffset(in: offset)` -- when the dropped record is the first one after a chunk-boundary pad, the cursor moves back past the pad but the pad's bytes are never subtracted. `writeCursorPrecedesHead` already needs the empty/full disambiguation (`bytesInUse > 0 && writeCursor <= head`) that a derived form would take from `offsets.count`.

**Ideal fix.** Delete the stored `bytesInUse` field and all twelve of its mutations, and make it computed: `offsets.count == 0 ? 0 : (writeCursor > head ? writeCursor - head : arenaCapacity - head + writeCursor)`. `writeCursorPrecedesHead` becomes `offsets.count > 0 && writeCursor <= head`. Nothing else changes -- `head` and `writeCursor` are already moved correctly at every site, pads included.

**By construction.** A mutation that moves arena bytes without moving their charge stops being expressible: there is no charge to move. The pad-leak class -- any byte the ring cursor skips over but the counter still holds -- becomes unrepresentable, because the counter is the cursor distance.

**Cheaper fallback.** Keep the field, subtract the pad in `dropTailRecord` by comparing the dropped record's offset against the predecessor record's end, and add an `independentArenaBytesInUse` recount asserted in `census` beside the existing side-table assert. This leaves twelve maintenance sites and pins only the one bug already found.

**Verification.** Behavioral test at a budget small enough that a chunk boundary falls a few display rows from the tail: admit rows until `wrapWriteCursorAtSeam` has written a pad, then `truncateTail(displayRows:)` past the pad, and assert `store.census.arenaBytesInUse` matches the same store rebuilt by admitting only the surviving rows -- or, observably, that admitting N further rows after the truncation retains the same record count as admitting N rows into a fresh store at the same content. Today the truncated store retains fewer records.

**Risk.** The derived form is read on the write path (`chargedBytes`, once per admission and once per eviction step); it is two comparisons and a subtraction, cheaper than the load it replaces. The only care needed is that `resetToEmptyArena` keeps setting `head == writeCursor == 0` so the empty case stays unambiguous.

<a id="store-2"></a>

### STORE-2. Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them

`simplification` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift#PackedRetainedRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineRecord.swift#LogicalLineRecord`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#appendCells`

**Problem.** `PackedRetainedRow` is the pre-doc-31 per-display-row representation. Nothing in production constructs, stores, or reads one any more -- the logical-line arena replaced it. What survives is a 643-line type whose only live export is the `Header` enum's cell-word constants, plus a ~420-line test file exercising an encoding the engine no longer produces. A reader working on row storage faces two full layout contracts, one of which is a fiction, and the constants the real store depends on are declared inside the fiction.

**Evidence.** `git grep -l PackedRetainedRow -- '*.swift'` returns seven files. In `Terminal.swift` and `LogicalLineRecord.swift` every hit is a comment. In `LogicalLineStore.swift` every hit is `PackedRetainedRow.Header.<constant>` (`cellKindShift`, `cellKindMask`, `cellScalarMask`, `cellSpillBit`, `cellStyleShift`, `cellBytes`, `hyperlinkEntryBytes`, `identityRunEntryBytes`, `identityCellBytes`). The type's own members -- `pack(_:)`, `unpacked()`, `forEachCell`, `forEachContentCell`, `forEachKind`, `cell(at:)`, `storedCellCount`, `spills`, `storage` -- appear nowhere outside `PackedRetainedRow.swift` and `TerminalPackedRetainedRowTests.swift`. `Header` also mixes two layouts: `byteCount = 7`, `softWrapBit`, `promptShift`, `identityPerCellBit` describe the dead blob header, while `cellScalarMask`/`cellKindShift`/`cellStyleShift`/`cellSpillBit` describe the 8-byte cell word the arena still writes.

**Ideal fix.** Lift the eight-byte cell word into its own small type owned beside `LogicalLineRecord` (see the next finding), move `cellBytes`/`hyperlinkEntryBytes`/`identityRunEntryBytes`/`identityCellBytes` onto `LogicalLineRecord.Header` where the store's aliases already point, then delete `PackedRetainedRow.swift` and `TerminalPackedRetainedRowTests.swift` outright. Rewrite the few doc comments that cite `PackedRetainedRow.pack`'s trimming rule to state the rule directly.

**By construction.** There stops being a second, stale answer to "how is a retained row laid out": the arena record becomes the only stored form in the tree, so neither a reader nor a future change can pick the wrong one, and a layout constant can no longer be edited in a file whose tests do not cover the code that uses it.

**Cheaper fallback.** Keep the file but strip it to the cell-word constants and rename it for what it is. That removes the misleading second contract without the test-file churn, but leaves a namespace named after a representation that no longer exists.

**Verification.** `just test` after deletion -- the retained read-path suites (`TerminalRetainedRowReadPathTests`, `TerminalLogicalLineStoreTests`) already assert the arena's decode behavior per cell, so their staying green with `PackedRetainedRow` gone is the proof that nothing observable depended on it.

**Risk.** Deleting `TerminalPackedRetainedRowTests` removes coverage of the canonical-trim and identity-run rules as `pack` stated them; before deleting, confirm each rule the store still relies on (the strict-step-of-one run shape, the trailing-blank trim asymmetry) is asserted somewhere in the arena suites, and add it there if not.

<a id="store-3"></a>

### STORE-3. Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#withPaintedCells`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#forEachClosedRecordCell`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#appendCells`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#forEachKind`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#forEachStyleId`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#cellKind`

**Problem.** The cell word's field extraction is written out by hand at eight places in `LogicalLineStore`, each repeating the same shift-and-mask triple. The kind decode alone appears five times verbatim. A change to the word layout -- widening the scalar field, moving the style, adding a flag -- must be found and applied at all eight, and a site that gets one shift wrong decodes plausible-looking garbage rather than failing to compile.

**Evidence.** `TerminalCellKind(packedCode: UInt8((word >> PackedRetainedRow.Header.cellKindShift) & PackedRetainedRow.Header.cellKindMask))` is written out in `forEachClosedRecordCell`, `withPaintedCells`, `forEachKind`, `cell(recordIndex:recordOffset:record:cellOffset:)`, and `cellKind(recordAt:cell:)`. `Terminal.StyleId(truncatingIfNeeded: word >> PackedRetainedRow.Header.cellStyleShift)` appears in `withPaintedCells` twice (once for the spacer word), in `forEachStyleId`, and in `cell(...)`. `let field = UInt32(word & PackedRetainedRow.Header.cellScalarMask)` followed by a `word & cellSpillBit` test appears in `forEachClosedRecordCell`, `withPaintedCells`, and `cell(...)`. The write side is spelled once in `appendCells` (`var word = UInt64(kind.packedCode) << cellKindShift; word |= UInt64(styleId) << cellStyleShift; ...`) and separately in `appendBlankCells`, and `cutTail` tests `cellWord(...) & PackedRetainedRow.Header.cellSpillBit` directly.

**Ideal fix.** Introduce a `CellWord` value over `UInt64` beside `LogicalLineRecord`, with `init(kind:styleId:scalarField:isSpill:)` and `@inline(__always)` `kind`, `styleId`, `scalarField`, `isSpill` accessors, and route every site above through it. The borrowed-pointer read loops stay as they are -- they simply wrap the loaded `UInt64`, which is free at -O.

**By construction.** It becomes impossible to read a cell field with the wrong shift or mask at one site while the others are right, and impossible for `appendCells` and `appendBlankCells` to disagree about the word's shape -- the layout is stated in exactly one place.

**Cheaper fallback.** Leave the constants where they are and add the four accessors as `@inline(__always)` private helpers on `LogicalLineStore`, routing the eight sites through them. Same reduction, but the encoding stays split across two types.

**Verification.** `TerminalRetainedRowReadPathTests` and the representation expectations in `TerminalLogicalLineStoreTests` already assert per-cell kind, scalars, and style through the public read walks at every retained position; they must stay green with no test edits.

**Risk.** The read loops in `withPaintedCells` and `forEachClosedRecordCell` are the measured frame path, so confirm the wrapper is fully inlined (it is a single-field frozen struct) rather than assuming it; a paired `just benchmark-quick` against the pre-change revision on a browse workload settles it if there is any doubt.

<a id="store-4"></a>

### STORE-4. State the open tail's scratch-table key base once, so a trimmed head cannot key it two ways

`correctness` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#appendCells`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#hyperlinkId`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#loadOpenScratch`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#cutTail`

**Problem.** `HyperlinkEntry.offset` and `IdentityRun.start` carry a cell offset with no declared base, and the writers and readers disagree about which base that is once the head record has been trimmed. A head trim leaves the in-arena tables in place with their original keys (documented on `LogicalLineRecord.identityEntryCount`) and records the shift in `headTrimmedCells`, so the reader adds it back. The open-tail scratch is written without it.

**Evidence.** `appendCells` computes `let cellOffset = record.cellCount + index` -- `record.cellCount` is the header's count, which `trimHeadRecord` decrements via `trimmed.cellCount -= cut` -- then stores `HyperlinkEntry(offset: cellOffset, id: id)` and `IdentityRun(start: cellOffset, extent: 1, base: identity)`. The reader `cell(recordIndex:recordOffset:record:cellOffset:)` computes `let keyOffset = cellOffset + (recordIndex == 0 ? headTrimmedCells : 0)` and `hyperlinkId`/`contentIdentity` binary-search the open scratch for that `keyOffset`. `loadOpenScratch` refills the same arrays straight from the arena tables, whose keys are original-base. `cutTail` then filters them against a trimmed-base bound: `openHyperlinks.removeAll { $0.offset >= newCellCount }`. Reachability today is narrow -- the head record can only be the open tail when `offsets.count == 1`, and `forcedSplitCellCap` caps one record at 1/32 of the budget -- but nothing in the types or the code states that constraint.

**Ideal fix.** Make the base explicit and single: key the scratch by original cell offset everywhere, computed in one private accessor (the tail's key base, which is `headTrimmedCells` when the open record is also the head and 0 otherwise) used by `appendCells`, `loadOpenScratch`, `cutTail`, and `forEachHyperlinkId` alike. Better still, wrap it in a one-field `OriginalCellOffset` struct so a trimmed-relative count cannot be passed where a key is expected.

**By construction.** With a distinct offset type for the two bases, handing a trimmed-relative index to a table keyed by original offsets stops compiling, so the whole class of "the head trim rebased one side of a lookup" disappears rather than being argued unreachable.

**Cheaper fallback.** Assert the constraint that makes the mix unreachable -- `precondition(headTrimmedCells == 0 || offsets.count > 1)` in `trimHeadRecord` -- so the latent case fails loudly instead of silently misattributing a hyperlink id or a content identity.

**Verification.** Build a store at a budget where one logical line can be head-trimmed while still open, print a hyperlinked and content-identified run into it, evict one display row, append more cells, and assert `recordCells(at: 0)` reports the same `hyperlinkId`/`contentIdentity` per surviving cell as the untrimmed store did for the corresponding cells.

**Risk.** None to behavior in the currently reachable configurations; the change is confined to how the scratch entries are keyed. The main cost is deciding between the cheap precondition and the typed offset -- the precondition documents an accident, the type removes it.

<a id="store-5"></a>

### STORE-5. Give a block one record-range accessor instead of five hand-copied index conversions

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#recomputeIndex`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#firstDisplayRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#contentRank`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#locate`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#independentContentBlockTotalsForTesting`

**Problem.** The mapping from a block index to the retained record indices it covers is written out five times. It is the store's trickiest arithmetic -- it must clamp the first block against `firstRecordSequence` because the head block is partially evicted, and the last against `offsets.count` -- and every reader that touches the block ring re-derives it. The oracle `independentContentBlockTotalsForTesting` re-derives it too, so it does not check that arithmetic independently of the code it is meant to check.

**Evidence.** `let first = max(firstRecordSequence, blockNumber * Self.blockSize) - firstRecordSequence` together with `let end = min(offsets.count, (blockNumber + 1) * Self.blockSize - firstRecordSequence)` appears verbatim in `recomputeIndex` and in `independentContentBlockTotalsForTesting`. The `first` half alone reappears as `blockFirst` in both `contentRank(of:)` and `firstDisplayRow(ofRecord:)`, and as `let firstSequence = max(firstRecordSequence, blockNumber * Self.blockSize)` in `locate(displayRow:)`. All five also independently compute `let blockIndex = sequence / Self.blockSize - firstBlockNumber` or its inverse.

**Ideal fix.** Add two private accessors -- `blockIndex(ofRecord:) -> Int?` and `recordRange(inBlock:) -> Range<Int>` -- and route all five sites through them. `recomputeIndex`, `contentRank`, `firstDisplayRow`, and `locate` then read as a block lookup plus a scan over a range, and the head-block clamp is stated once.

**By construction.** The head block's partial-eviction clamp stops being something each caller can get wrong: a caller can only ask a block which records it covers, so a site that forgets the `max(firstRecordSequence, ...)` clamp cannot be written.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** Existing coverage carries this: `independentContentBlockTotalsForTesting` against `contentBlockTotalsForTesting`, `independentDisplayRowRecount` against `grandDisplayRowTotal`, and the `locate` / `position(ofRecord:cellOffset:)` round-trip expectations in `TerminalLogicalLineStoreTests` all fail if the range conversion changes meaning.

**Risk.** The one judgement call is the test oracle: routing `independentContentBlockTotalsForTesting` through the shared accessor weakens it as an independent check, so keep that site spelled out and say why in its comment.

## Area: Selection, search, damage, presentation

_Scope: Terminal selection, search, hit-testing, damage, and presentation snapshotting_

**Auditor's read on the area.** The area is in good shape: `TerminalDamage`'s word-backed representation, `NeedleWindow`'s position-generic matcher, `TerminalSearchStatus`'s "no invalid counter" enum, and the pinned-range selection drag are all careful, well-documented designs. The findings below are all about facts that still have two owners or two spellings: one damage-composition rule written twice, one search-index refresh that must be pushed from seven call sites, one pointer-cell value that is destructured before it crosses the policy seam, and one selection mutation whose granularity travels beside it instead of inside it. I did not audit the render planner (`RenderFramePlanner`, `SearchMatchRenderPlanning`), `TerminalInputEncoding`, or `LogicalLineStore`, and I ran no builds or tests -- every claim is from reading the cited code.

<a id="interact-1"></a>

### INTERACT-1. Refresh the search index through one history-mutation funnel instead of seven hand-placed calls

`structural` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#synchronizeSearchIndexPrefix`, `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift#synchronizeIndex`, `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift#resolvedSearchMatchRange`

**Problem.** `Terminal.Search` retains match endpoints as `LogicalLineStore.RecordTextPosition` values, which stop resolving the moment history changes which records it owns. Keeping them valid is a pushed obligation: every site that evicts, truncates, closes, or reopens a record must remember to call `synchronizeSearchIndexPrefix()`. There are seven such calls today, in unrelated code paths (budget enforcement, ED 3, two resize tail-pulls, wrap-claim sever, wrap-claim restore, a test helper), and nothing makes a new history mutation call it. The failure is not a stale highlight: a retained coordinate whose record retired reaches `preconditionFailure("the search index retained a retired record coordinate")`, which traps the process.

**Evidence.** `synchronizeSearchIndexPrefix()` appears at seven separate call sites in `Terminal.swift` (inside `enforceScrollbackBudget`, the ED 3 branch that calls `history.removeAll()`, both `history.truncateTail(displayRows:)` resize paths, `severScrollbackWrapClaim`, `restoreWrapClaimBeforeCursor`, and `evictScrollbackRowsForTesting`). It is the only thing that trims `index.prefixMatches` and rebuilds `index.boundaryWindow`. `Search.resolvedSearchMatchRange` then does `guard let start = context.history.position(of: match.start), let end = ... else { preconditionFailure("the search index retained a retired record coordinate") }` -- so a missed synchronize is a trap, not a wrong answer.

**Ideal fix.** Make `history` private to one mutating funnel on `Terminal` -- e.g. `mutating func withHistory<R>(_ body: (inout LogicalLineStore) -> R) -> R` that runs `search?.synchronizeIndex(with: history)` on the way out -- and route every record-ownership mutation through it. `synchronizeIndex` already early-returns after comparing two cheap values (`retainedStart`, `indexedThroughRecord`), so the funnel costs a nil check when no search is active. A mutation site that forgets to refresh then does not compile, because there is no other way to reach the store.

**By construction.** "A history mutation that changes record ownership without refreshing the retained search index" becomes unrepresentable -- and with it the `preconditionFailure` on a retired record coordinate, which no longer has a reachable cause.

**Cheaper fallback.** Keep the pushed calls but have `LogicalLineStore` expose a monotone record-ownership counter, and assert in `searchContext` that the counter the index last saw equals the store's -- turning a silent trap deep in a read into a loud failure next to the missed site. This is strictly worse: it detects the omission instead of preventing it.

**Verification.** Behavioral test: begin a search whose matches sit in the oldest retained records, then drive each history-mutating path (feed past the scrollback budget, `ESC[3J`, narrow-then-widen resize so the tail is pulled back, a wrap-claim sever) and assert after each that `searchStatus` still reports the surviving matches and that `activeSearchMatchRange` resolves. Add one test that mutates history through the new funnel with a deliberately missing manual refresh and shows the counts still agree. `swift test --package-path lib/TerminalCore --filter Search`.

**Risk.** The funnel must not force a copy of the copy-on-write store: it has to hand out `inout` access exactly as today's direct mutation does, or the arena gets copied per mutation. Verify with the existing throughput benchmark before and after.

<a id="interact-2"></a>

### INTERACT-2. Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy

`api-shape` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift#TerminalPointerEvent`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#isViewportPosition`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#cancelTerminalLinkInteraction`, `app/SwiftTerminalSessionView.swift#forwardPointerDown`

**Problem.** `terminalCell(at:...)` produces a `TerminalViewportCell` that answers whether the point was actually on the grid -- its own doc says a caller "reads it here instead of re-deriving the grid extents with its own math". Then the view destructures the cell into `column`/`row`/`offsetX` and drops `isInsideGrid`, because `TerminalPointerEvent` has no field for it. The insideness is smuggled back in as a *second*, separately ordered call to `cancelTerminalLinkInteraction()`, whose correctness depends on hand-written ordering comments ("the press is delivered before the cancellation", "the cancellation runs before the release"). Meanwhile the policy re-derives insideness with `isViewportPosition(column:row:terminal:)` against the terminal's geometry -- but the coordinates it tests were already clamped into range by `terminalCell`, so that guard can never reject an off-grid pointer. The out-of-band cancel is the only thing preventing an off-grid Cmd-press from arming a link at the clamped edge cell.

**Evidence.** `terminalCell` returns `TerminalViewportCell(column: clampedColumn, row: min(max(Int(row),0), rows-1), offsetX:, isInsideGrid:)`; `TerminalPointerEvent.down/.up/.move` take only `column: Int, row: Int, offsetX: Double, modifiers:`. `forwardPointerDown` sends `.down(button, column: cell.column, row: cell.row, ...)` and then, separately, `if cell.isInsideGrid == false { controller.cancelLinkInteraction() }`; `forwardPointerUp` runs the cancel *before* the send; `deliverPointerMove` runs it after. `isViewportPosition` checks `(0..<terminal.geometry.columns).contains(column) && terminal.geometry.rows.indices.contains(row)` on already-clamped values.

**Ideal fix.** Change `TerminalPointerEvent` to carry the `TerminalViewportCell` itself (`case down(TerminalMouseButton, cell: TerminalViewportCell, modifiers:, clickCount:)`, and the same for `up`/`move`). `decideTerminalPointer` then reads `cell.isInsideGrid` where it currently calls `isViewportPosition`, and returns the hover/arm clears for an off-grid event as part of the one decision. Delete the separate `cancelLinkInteraction` forwarding path and the ordering comments with it; keep `cancelTerminalLinkInteraction` only for the genuine mouse-exit-with-no-event case.

**By construction.** "A pointer event whose coordinates were clamped from an off-grid point but which claims to be on the grid" becomes unrepresentable, and so does "the cancel was sent in the wrong order relative to the event" -- there is no second message left to order.

**Cheaper fallback.** Add an `isInsideGrid` parameter to each event case and keep the separate cancel call for the exit path only. Cheaper, but it leaves the value split across a bool and a coordinate pair that a caller can still contradict.

**Verification.** Behavioral test in `TerminalInteractionPolicyTests`: Cmd-press at a point below the last row (an off-grid cell whose clamped row holds a link) and assert the decision arms nothing and opens nothing on release, with no separate cancellation call. Existing link-activation tests must keep passing. `swift test --package-path lib/TerminalCore --filter InteractionPolicy`.

**Risk.** Every pointer call site and the recording/replay layer (`NeutralTerminalRecording`, `TerminalPTYHost`) must be updated together; recorded tapes that encode the old event shape need regenerating, which the project permits (no backwards-compatibility constraint).

<a id="interact-3"></a>

### INTERACT-3. Delete `TerminalDamageAccumulator`'s copy of the shift-composition rule and let it hold a `TerminalDamage`

`simplification` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift#TerminalDamageAccumulator`, `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift#TerminalDamage`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#drainDamage`

**Problem.** The scroll-shift composition rule -- same region sums, `abs(combined) >= region.count` collapses to region rows, a region mismatch escalates to full -- is implemented twice, once in `TerminalDamage.applyShift` and once in `TerminalDamageAccumulator.recordShift`. The two structs are otherwise the same three fields (`isFull`, `shift`, `bits`) with two copies of `==` as well. Production only ever runs the accumulator's copy (`Terminal` stores `damage: TerminalDamageAccumulator` and calls `damage.recordShift`), while `TerminalShiftDamageTests` exercises only the `TerminalDamage` copy. So the rule that ships is the untested one, and they have already drifted: the value type preconditions `region` inside `0..<bits.rowCount`, the accumulator only documents the requirement in a comment, and an out-of-range region there reaches `TerminalDamageRowBits.translate`, which indexes `words[index]` without bounds checking.

**Evidence.** `TerminalDamage.applyShift` and `TerminalDamageAccumulator.recordShift` contain the same `combined`/`bits.translate(region:by:)`/`if abs(combined) >= region.count { shift = nil; bits.fill(region) }` sequence. `TerminalDamage.recordShift` adds `precondition(region.lowerBound >= 0 && region.upperBound <= bits.rowCount, ...)`; the accumulator's version only says "The caller guarantees `0 < abs(delta) < region.count` and `region` within the grid". `Terminal.swift` uses `damage.recordShift(region: range, delta: signedAmount)` on the accumulator; every `recordShift` call in `TerminalShiftDamageTests` is on a `TerminalDamage`.

**Ideal fix.** Make the accumulator a thin wrapper that stores one `TerminalDamage` and forwards `record`/`recordShift`/`recordFull` to it, with `drain()` returning the value and resetting to `.none` at the current row count -- or drop the accumulator entirely and give `TerminalDamage` the `reset(rowCount:isFull:)`, `coversViewport(rowCount:)` and change-reporting the terminal needs. One copy of the rule, and the shift tests then cover the code the terminal runs.

**By construction.** "The tested shift rule and the shipped shift rule disagree" becomes unrepresentable, because there is only one rule; and the accumulator can no longer accept a region the value type would have rejected.

**Cheaper fallback.** Keep both types but move the composition body into one shared `TerminalDamageRowBits`-level helper both call, and add the missing region precondition to the accumulator. Cheaper, still leaves two `==`, two `isFull`/`shift` pairs, and two drain-time state machines.

**Verification.** Point the existing `TerminalShiftDamageTests` composition cases at whatever `Terminal.drainDamage()` returns after real scrolls (feed a scroll region, drain, assert `shift` and `rowIndices`), so the assertions run through the production path. `swift test --package-path lib/TerminalCore --filter ShiftDamage`, plus the throughput benchmark to confirm drain-time allocation did not regress.

**Risk.** The accumulator exists partly to reuse its word storage across drains; today `drain()` already hands the array to the returned value and then calls `removeAll()`, which copies on write anyway, so the reuse is mostly notional -- but confirm with the scrollback-stream benchmark rather than by argument.

<a id="interact-4"></a>

### INTERACT-4. Put the selection granularity inside `TerminalSelectionMutation.set` instead of beside it

`api-shape` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#TerminalSelectionMutation`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#TerminalPointerDecision`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#extensionDecision`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPTYHost.swift`, `lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`

**Problem.** A pointer decision reports its selection as two parallel optionals -- `selectionMutation: TerminalSelectionMutation?` and `selectionGranularity: TerminalSelectionGranularity?` -- that must agree. Nothing enforces the pairing, so producers compute the same condition twice and consumers guess. Both consumers apply `decision.selectionGranularity ?? .character`, which silently converts "the policy forgot the granularity" into "this was a character selection" -- and a wrong settled granularity is not cosmetic: it is what a later Shift-click extension inherits, so the next extension would extend by the wrong unit.

**Evidence.** `extensionDecision` ends with `selectionMutation: fixed == moving ? .clear : .set(orderedRange(fixed, moving)), selectionGranularity: fixed == moving ? nil : granularity` -- the same predicate spelled twice. `pointerDownDecision` does the same with `granularity == .character ? .clear : .set(anchor)` / `granularity == .character ? nil : granularity`. `TerminalPTYHost.swift` and `NeutralTerminalRecording.swift` both contain `granularity: decision.selectionGranularity ?? .character`.

**Ideal fix.** `enum TerminalSelectionMutation { case clear; case set(TerminalTextRange, granularity: TerminalSelectionGranularity) }`, and drop `selectionGranularity` from `TerminalPointerDecision`. Producers state the pair once; both consumers switch on the mutation and pass the granularity straight to `terminal.setSelection(_:granularity:)` with no `??` default left to write.

**By construction.** "A set-selection with no granularity" and "a clear carrying a granularity" become unrepresentable, and with them the `?? .character` default that would otherwise settle the wrong extension unit.

**Cheaper fallback.** None -- the ideal fix is small; it is one enum payload and two consumer switches.

**Verification.** Existing `TerminalInteractionPolicyTests` and `TerminalSelectionTests` assertions on `selectionMutation` / `terminal.selectionGranularity` re-express against the new payload and must keep passing; add one test that double-clicks (token granularity), then Shift-clicks further right, and asserts the extension stays token-granular through the host seam. `swift test --package-path lib/TerminalCore` and `swift test --package-path lib/TerminalPTY`.

**Risk.** Purely mechanical; the only exposure is the number of test call sites that pattern-match `.set(range)` and need the new payload.

<a id="interact-5"></a>

### INTERACT-5. Parameterize the one cell-to-search-unit scan by position type instead of writing it twice

`simplification` &middot; impact 3, confidence 4 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift#scanClosedRecordSearchUnits`, `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift#forEachSearchUnit`, `lib/TerminalCore/Sources/TerminalCore/NeedleWindow.swift#NeedleWindow`

**Problem.** Search scans the same content twice with two copies of the same algorithm, differing only in which coordinate type they emit: `scanClosedRecordSearchUnits` walks closed records and emits `RecordTextPosition` units, `forEachSearchUnit` walks the projection and emits `TextAnchor` units. Both make the identical decisions -- `narrow`/`wideHead` fold to a grapheme key, `padding` becomes `.scalar(0x20)`, `wideTail`/`spacerHead` emit nothing, a non-forced-split boundary emits `.scalar(0x0A)` spanning to the next row's column 0 -- and `NeedleWindow<Position>` is already generic precisely so one matcher can serve both. Because the closed prefix and the mutable suffix of a single query are scanned by different copies, any drift between them shows up as a match that appears or disappears as rows retire from the live grid into closed history, which is exactly the transition a user cannot reproduce on demand. The copies have already diverged in detail: the record scan clamps a wide cell's end with `min(scan.cellCount, cellOffset + width)`, the projection scan does not clamp at all.

**Evidence.** `scanClosedRecordSearchUnits` has `switch kind { case .narrow, .wideHead: key = Self.searchGraphemeKey(for: scalars); case .padding: key = .scalar(0x20); case .wideTail, .spacerHead: key = nil }` plus a `.scalar(0x0A)` unit when `previous.isForcedSplit == false`. `forEachSearchUnit` has the same switch over `cell.kind` and the same `.scalar(0x0A)` unit when `absoluteRow < lastContentRow, row.isSoftWrapped == false`. Both then feed `matcher.record(NeedleWindow.Unit(key:start:end:))`.

**Ideal fix.** Extract one generic unit emitter -- a function over a cell-kind/scalars/boundary source that yields `(SearchGraphemeKey, Position, Position)` triples, with the two sources supplying only how a position is minted and how a line boundary is detected. Both scans then differ by a position factory and a row source, and the fold/skip/boundary rules exist once.

**By construction.** "The closed-history scan and the live-projection scan classify the same cell differently" becomes unrepresentable, so a match can no longer change existence purely because its row moved from the live grid into closed history.

**Cheaper fallback.** Keep both scans but pin them together with a property-style test that feeds the same content through the record path and the projection path and asserts identical key sequences. That catches drift instead of preventing it, and it needs maintaining alongside the two copies.

**Verification.** Behavioral test: search for a needle straddling the history/live seam, then feed enough output to push the whole match into closed history, asserting `searchStatus` total and `activeSearchMatchRange` are unchanged at every step -- including a needle containing a wide character, a padding cell, and a hard line break. The existing `scannedSearchMatchRanges` oracle gives a second comparison point. `swift test --package-path lib/TerminalCore --filter Search`.

**Risk.** This is the hot scan path; `forEachSearchUnit`'s comment says it avoids constructing selection units and avoids allocating for the single-scalar cell. The generic version must stay non-allocating and inlinable, so it needs the `scrollback-stream` / search benchmarks before and after.

<a id="interact-6"></a>

### INTERACT-6. Key pointer-owner and wheel-remainder storage by their enums instead of by hand-written slots

`structural` &middot; impact 2, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#TerminalInteractionState`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#wheelRemainder`

**Problem.** `TerminalInteractionState` stores one owner per mouse button as a three-element array literal indexed by `button.rawValue`, and one wheel remainder per route as three named fields reached through three hand-written switch functions. Both are per-case storage enumerated by hand. `TerminalMouseButton` is a plain `Int`-raw enum with no `CaseIterable`, so adding a fourth button (back/forward, which AppKit does deliver) makes `state.pointerOwners[button.rawValue]` a fatal index-out-of-range at the first press rather than a compile error; adding a wheel route means remembering to extend three separate switches.

**Evidence.** `fileprivate var pointerOwners: [TerminalPointerConsumption?] = [nil, nil, nil]`, read and written throughout `decideTerminalPointer` as `state.pointerOwners[button.rawValue]`. `TerminalMouseButton` is declared `public enum TerminalMouseButton: Int` with `left = 0`, `middle = 1`, `right = 2` and no `CaseIterable`. The wheel side has `localWheel`/`reportWheel`/`alternateWheel` plus `wheelRemainder(for:state:)`, `setWheelRemainder(_:for:state:)` and `resetWheelRemainder(for:state:)`, each a three-case switch over `TerminalWheelRoute`.

**Ideal fix.** Make both enums `CaseIterable` and hold the per-case values in one small keyed value (a dictionary keyed by the enum, or a fixed-size store built from `allCases`) with a subscript. `state.owners[button]` and `state.wheel[route]` then have no index arithmetic and no per-case accessor functions, and a new case gets storage automatically.

**By construction.** "A button with no slot in the owner array" and "a wheel route wired into some of its accessors but not all" become unrepresentable: storage is derived from the case list rather than restated next to it.

**Cheaper fallback.** Leave the storage shape and add `CaseIterable` plus a `precondition(button.rawValue < pointerOwners.count)`. That converts a crash into a louder crash and keeps the three wheel switches.

**Verification.** Behavioral test: drive a full press/drag/release gesture on each button and each wheel route through `decideTerminalPointer` / `decideTerminalWheel` and assert ownership latching and fractional accumulation are unchanged; the existing `TerminalInteractionPolicyTests` wheel-remainder and owner tests cover most of this already. `swift test --package-path lib/TerminalCore --filter InteractionPolicy`.

**Risk.** `TerminalInteractionState` is `Equatable` and copied per event; a dictionary makes it refcounted, which matters if this value is copied on a hot path. Prefer a fixed-size inline store over a `Dictionary` if the pointer path shows up in a profile.

## Area: Core reducer (Update/Msg/Command)

_Scope: The pure Elm reducer and its message/command vocabulary (lib/DanTermCore/Sources/DanTermCore/Update.swift, Msg.swift, Command.swift, CoreEnvironment.swift, ReconcileFollowUps.swift, PaneLifecycle*.swift)_

**Auditor's read on the area.** The reducer is disciplined in the large: one chokepoint `defer` runs the four repair passes, `Command` is genuinely free of projection cases, and every `Command` case has exactly one consumer in `AppRuntime.perform`. The weak spots are all in the middle layer: a pending-confirmation record whose four optionals are validated by hand instead of by type, one Msg/Command pair that launders model state through the view and back, and a "clear the focused pane's alerts" rule copied into nine arms with two arms that quietly disagree. I did not audit IpcDispatch.swift, ModelOperations.swift, or Model.swift beyond the declarations the reducer arms depend on, nor the app-side reconcile passes except where a finding proposes moving work into one.

<a id="reduce-1"></a>

### REDUCE-1. Make PendingConfirmation an enum so a subject cannot carry the wrong payload

**Merged into [MODEL-1](#model-1).** Same defect and same fix; the survivor also covers the read sites in `Projections.swift` and `ModelOperations.swift` and names the `quitAuthorized` field. Kept here for the one observation it adds: the two confirm messages should each match only their own cases. Track the work under MODEL-1.

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PendingConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#confirmPendingConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#chooseDeleteGroupConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#reconcilePendingConfirmation`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#emitConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#emitDeleteGroupConfirmation`

**Problem.** `PendingConfirmation` is a flat struct of `subject` plus three optionals (`tabTitle`, `impact`, `deleteGroup`) whose validity is entirely a function of `subject`. Which optionals must be present, and which message may act on the record, is re-checked by hand in four places, and three of those checks answer an invalid combination by silently returning `[]` -- the shape a user sees as a confirmation panel that does nothing when clicked.

**Evidence.** `PendingConfirmation` declares `let subject: ConfirmationSubject; let tabTitle: DisplayLine?; let impact: CloseImpact?; let deleteGroup: DeleteGroupConfirmation?`. `emitConfirmation` builds `.app` with `impact: nil, deleteGroup: nil`, close subjects with `impact: impact, deleteGroup: nil`, and `emitDeleteGroupConfirmation` builds `.deleteGroup` with `impact: nil` plus a non-nil `deleteGroup`. Nothing stops `.tab` + non-nil `deleteGroup`, or `.deleteGroup` + nil `deleteGroup`. The consumers pay for it: `confirmPendingConfirmation` opens with `if case .deleteGroup = pending.subject { return [] }` and then still needs `case .deleteGroup: return []` arms in both of its switches; `chooseDeleteGroupConfirmation` guards `case .deleteGroup(let groupId) = pending.subject, let frozen = pending.deleteGroup` and drops the click if either half is missing; `closeSubjectHasGrown` starts with `guard let snapshot = pending.impact ... else { return false }`, so a close confirmation built without an impact silently loses its grown-subject re-prompt.

**Ideal fix.** Replace the struct with an enum that carries exactly the payload its case needs: `case quit(id:)`, `case close(id:, subject: CloseSubject, tabTitle: DisplayLine?, impact: CloseImpact, quitAuthorized: Bool)`, `case deleteGroup(id:, groupId: GroupId, frozen: DeleteGroupConfirmation)`. Split `ConfirmationSubject` so `CloseSubject` holds only pane/tab/tabs. Then `Msg.confirmConfirmation` matches only the quit and close cases and `Msg.chooseDeleteGroupConfirmation` only the delete-group case, and every `return []` for an impossible combination disappears.

**By construction.** A pending confirmation whose payload does not match its subject -- a delete-group transaction with no frozen destination, a close transaction with no impact snapshot, a quit transaction carrying an impact -- becomes unrepresentable, and with it the class of "the confirmation panel is up but the button does nothing".

**Cheaper fallback.** Keep the struct but give it a private init per subject and a `switch`-returning accessor that returns the payload bundle, so at least construction cannot produce an invalid pair. This still lets a reader construct a mismatched record inside the module.

**Verification.** Existing behavioral tests must keep passing: confirming a close whose subject grew re-prompts; choosing "move tabs" on a delete-group confirmation whose destination group vanished re-emits a fresh confirmation. Add one behavioral test that a delete-group confirmation answered by the plain confirm path is impossible to send (it no longer compiles) -- expressed as a test that the delete-group choice message is the only way the group is deleted.

**Risk.** Touches every construction and consumption site of the confirmation record plus the app-side `reconcileConfirmation` reader, so the panel's rendering switch must be re-derived from the new cases.

<a id="reduce-2"></a>

### REDUCE-2. Let .startSearch open the pane's search state directly instead of round-tripping through the view

`structural` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Command.swift#Command`, `lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `app/SwiftTerminalSessionView.swift#startSearch`, `lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift`

**Problem.** Opening search is a decision the reducer already made, but the reducer does not record it. It emits a command, the runtime calls into the view, and the view immediately emits a message back that makes the reducer write the state it could have written in the first place. No information is gained on the trip, and the message's only parameter is always the same constant, leaving a dead branch in the reducer.

**Evidence.** `case .startSearch` returns `[.sendStartSearch(paneId: tab.paneTree.focusedPaneId)]`. `AppRuntime.perform` maps it to `paneSession(for: paneId)?.startSearch()`, whose entire body is `callbackGate.emit(.searchStarted(""))` (its comment even says "`.searchStarted` is what creates the pane's searchState"). That callback becomes `Msg.searchStarted(paneId:needle:)`, whose arm creates `model.searchState[paneId] = SearchModel()` and sets `focusOwner = .field`. It is the only emitter in the tree, so the arm's `if !needle.isEmpty { model.searchState[paneId]?.needle = needle }` branch can never run.

**Ideal fix.** Have `case .startSearch` write `model.searchState[paneId] = SearchModel()` with `focusOwner = .field` and return no command. The overlay already mounts from `model.searchState` via `reconcilePaneChrome` and the responder already moves via `reconcilePaneFocus`, so `Command.sendStartSearch`, `Msg.searchStarted`, the `TerminalBackendBoundary` mapping, and `SwiftTerminalSessionView.startSearch()` all delete.

**By construction.** There is no longer a moment where the reducer has decided search is open and the model does not say so, so no message ordering can drop or duplicate the opening; and a `searchStarted` report that disagrees with the reducer's own decision cannot be expressed.

**Cheaper fallback.** Keep the command but drop the `needle` parameter from `Msg.searchStarted` so the dead branch goes away. This leaves the round trip -- and with it the window where the model says search is closed while the view is opening it.

**Verification.** Behavioral test at the reducer: send `.startSearch` to a model with a selected tab and assert `model.searchState[focusedPaneId]` exists with `focusOwner == .field` and that no command is returned. UI-level check via `just test-ui` that Cmd-F still mounts the overlay and puts the caret in the field.

**Risk.** If any engine path other than `startSearch()` was expected to open the overlay later (none exists today), it would need its own message; the search-needle and end-search commands stay as they are.

<a id="reduce-3"></a>

### REDUCE-3. Repair the focused pane's alerts in one pass instead of copying the rule into nine arms

`structural` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#applySelectTab`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#navigateToPane`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closePaneBody`

**Problem.** "Under `alertClearMode == .focus`, the focused pane of the selected tab has no unread alerts" is an invariant, but it is enforced by nine hand-written copies of the same two lines at the arms that happen to move focus. Arms that move focus by another route were missed, so the model can sit in a state that violates the rule with nothing to repair it.

**Evidence.** `if model.config.alertClearMode == .focus { markAlertsReadForPane(...) }` appears nine times in Update.swift: in `.movePaneToTab`, `.movePaneToNewTab`, `.focusDirection`, `.paneBecameFirstResponder`, `.searchFieldBecameFirstResponder`, `.appBecameActive`, and in `closePaneBody`, `applySelectTab`, `navigateToPane`. Two of them disagree with the rest: `.movePaneToTab` and `.movePaneToNewTab` set `model.selectedTabId = targetTabId` directly and then clear alerts for the *moved* pane, not for the newly selected tab's `paneTree.focusedPaneId`. So dragging a pane into a tab whose focused pane holds an unread alert selects that tab and leaves the badge lit, while reaching the same tab through `.selectTab` clears it.

**Ideal fix.** Add `reconcileFocusedPaneAlerts(&model)` to the `defer` block at the top of `update()`, beside `reconcileTabState`: when `config.alertClearMode == .focus` and `model.isAppActive`, mark alerts read for `selectedTab(in: model)?.paneTree.focusedPaneId`. Delete all nine call sites. The `isAppActive` condition is what keeps a bell raised for the focused pane while the app is in the background unread -- the behavior `.sessionBell` and `desktopAlertCommands` already rely on -- and it makes `.appBecameActive`'s copy fall out for free.

**By construction.** A model in which focus-clear mode is on, the app is active, and the focused pane still has an unread alert stops being reachable, so "this arm forgot to clear alerts" ceases to be a possible defect.

**Cheaper fallback.** Route `.movePaneToTab` and `.movePaneToNewTab` through `applySelectTab` so at least every selection change clears the same pane. The nine copies remain, so the next arm that moves focus can miss it again.

**Verification.** Behavioral test: with `alertClearMode == .focus`, raise an unread alert on tab B's focused pane, then send `.movePaneToTab` moving a pane from tab A into tab B; assert no unread alert remains for tab B's focused pane -- and that the same holds after `.selectTab`, `.focusDirection`, and a last-pane `.closePane` that moves focus.

**Risk.** The `isAppActive` condition is a deliberate behavior choice: today a focus change while the app is inactive clears alerts, and after the fix it would not. Worth confirming with the user, since it changes what the dock badge shows after a background IPC navigate.

<a id="reduce-4"></a>

### REDUCE-4. Derive terminal focus from the model instead of emitting focusSession(false) from four arms

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Command.swift#Command`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#applySelectTab`, `app/AppRuntime.swift`, `app/PaneFocusReconciliation.swift#reconcilePaneFocus`

**Problem.** Which session is focused is a projection of `selectedTabId` plus that tab's `focusedPaneId`, yet only half of it is pushed, from four copies of the same loop, and only the `false` half. Nothing emits `focused: true`; that half arrives from AppKit responder callbacks. So one fact has two owners and four writers, and an arm that changes the selection without copying the loop silently leaves a background pane believing it has focus.

**Evidence.** `commands.append(.focusSession(paneId: oldPaneId, focused: false))` inside `for oldPaneId in paneIdsForTab(oldTabId, in: model)` appears verbatim four times: in `.createTab`, `.movePaneToTab`, `.movePaneToNewTab`, and `applySelectTab`. `AppRuntime.perform` maps the command to `paneSession(for: paneId)?.setFocused(focused)`, which is `forwardFocusIfChanged`, the same private helper `becomeFirstResponder`/`resignFirstResponder` call with `true`/`false`. The app already owns a model-derived focus pass, `reconcilePaneFocus`, built on `desiredPaneFocus(in: model)`.

**Ideal fix.** Add a `reconcileSessionFocus` pass beside `reconcilePaneFocus` that computes the desired focused pane from the model (`selectedTab.paneTree.focusedPaneId`, and nothing when no tab is selected) and calls `setFocused` on the diff against what it last applied. Delete `Command.focusSession` and all four copies of the defocus loop. `forwardFocusIfChanged` already dedupes, so an idempotent pass costs nothing.

**By construction.** A background pane that still reports focus to its child process becomes unrepresentable: focus is recomputed from the model on every sweep, so no arm can omit the defocus and no ordering can leave two panes focused at once.

**Cheaper fallback.** Keep the command but emit it from one helper called by every arm that writes `selectedTabId`, so at least the four copies collapse into one. The fact still has two owners and the `true` half still comes from AppKit.

**Verification.** Behavioral test at the runtime level (`just test-ui`): split a tab, switch to another tab, and assert the previously focused pane's session reports unfocused; switch back and assert it reports focused again. At the reducer level, assert `.selectTab` returns no commands at all once the projection owns focus.

**Risk.** Focus reporting is externally visible (DECSET 1004 focus events reach the child), so the pass must not thrash: it needs a last-applied cache and must run after `reconcileContainers` has mounted or unmounted the views.

<a id="reduce-5"></a>

### REDUCE-5. Raise every pane alert through one function instead of duplicating the ritual in .sessionBell

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#desktopAlertCommands`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#throttledNotification`

**Problem.** There are two implementations of "raise one pane alert": the `.sessionBell` arm and `desktopAlertCommands`. They repeat the same five steps in the same order, including the one-unread-per-pane hack and the 100-item cap magic number, and they have already drifted -- only one of them applies the terminal metadata length bound.

**Evidence.** `.sessionBell` runs: the `model.isAppActive && focusedPaneId == paneId` skip, `guard tabForPane(paneId, in: model) != nil`, `markAlertsReadForPane`, `AlertModel(... kind: .bell ...)`, `model.alerts.insert(alert, at: 0)`, `if model.alerts.count > 100 { model.alerts.removeLast() }`, then `throttledNotification`. `desktopAlertCommands` runs the identical sequence with `kind: .desktopNotification`, and additionally opens with `guard senderTitle.fitsTerminalMetadataValueLimit, body.fitsTerminalMetadataValueLimit`. The bell path's body is a pane title that never passes through that bound.

**Ideal fix.** Extract one `raiseAlert(model:&, paneId:, kind:, presentation:, body:, env:)` holding the skip rules, the mark-read hack, the insert, the cap (as one named constant on `AppModel`), and the throttle call. `.sessionBell` supplies `.bell` with the pane title; `desktopAlertCommands` supplies `.desktopNotification` with the resolved presentation. The metadata bound stays where the sender's text enters, at the `.sessionNotification` arm.

**By construction.** The alert list can no longer grow past its cap, or skip the mark-read hack, on a path someone adds later: there is one place that inserts an alert, so a third alert kind inherits the whole policy instead of re-stating four of its five steps.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** Behavioral tests already pinning the bell path (focused-pane suppression while active, one unread per pane, the 1-second per-kind throttle) must pass unchanged, and the same three assertions must hold for `.sessionNotification`.

**Risk.** Low. The only semantic decision is where the metadata length bound sits; keeping it at the `.sessionNotification` arm preserves today's behavior exactly.

<a id="reduce-6"></a>

### REDUCE-6. Tie a pending IPC input request to its pane so pane teardown can reject it

`correctness` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PendingInputRequest`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#rejectPendingCreation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closeTabRemoval`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closePaneBody`, `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift`

**Problem.** The reducer treats the two kinds of in-flight IPC work asymmetrically. A pending session creation records enough to be rejected when its pane dies, and every close path does reject it. A pending input request records only its outstanding submission ids, so no close path can find it, and the only thing that ever fails it is app shutdown. A caller whose pane closes mid-delivery waits for the app to quit.

**Evidence.** `struct PendingInputRequest { var remaining: Set<InputSubmissionId> }` -- no pane. `rejectPendingCreation` resolves `model.pane(paneId)?.session?.id` and removes from `pendingSessionCreations`, and is called from `closeTabRemoval`, `closePaneBody`, `deleteGroupBody`, and the `.sessionCreationFailed` arm; there is no counterpart for `pendingInputRequests`. Outside `.inputSubmissionCompleted`, the only writer that clears them is `case .runtimeWillShutdown`, which fails them with "application shut down before pane input was delivered".

**Ideal fix.** Add `let paneId: PaneId` to `PendingInputRequest` (the dispatch site in IpcDispatch already has it in hand) and extend the existing per-pane rejection helper to fail every request owned by that pane with `-32603` when the pane leaves the tree, at the same four call sites that already reject pending creations. Delete the submission ids from `pendingInputSubmissions` in the same step.

**By construction.** A pending input request that outlives the pane it targets stops being representable: every path that removes a pane from the tree can see, and must answer, the requests bound to it -- the same guarantee pending session creations already have.

**Cheaper fallback.** Leave the model as is and rely on the runtime always invoking the completion -- `TerminalPaneSession.send` does reject synchronously when already torn down. That leaves the guarantee outside the core, unprovable by a reducer test, and silent if a send is in flight across teardown.

**Verification.** Reducer test: dispatch a pane input request that leaves a submission outstanding, then send `.closePane` for that pane; assert an `.ipcError` for the request id is returned and `model.pendingInputRequests` is empty. A late `.inputSubmissionCompleted` for the same submission must then produce no second reply.

**Risk.** Must not double-reply: the arm has to remove the request before emitting the error so a completion arriving afterwards finds nothing, which the existing `removeValue` guard in `.inputSubmissionCompleted` already handles.

<a id="reduce-7"></a>

### REDUCE-7. Delete the senderless .markAlertRead message

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** `Msg.markAlertRead` has no producer anywhere in the app, the iOS target, or the IPC dispatch table. Its only callers are two unit tests, so the reducer arm and the test both describe a path the product cannot take, and a reader has to check the whole tree to learn that.

**Evidence.** Grepping `markAlertRead` across app/, ios/, and lib/ outside tests returns only the declaration in `Msg.swift` and the arm in `Update.swift`; the alerts popover row activation sends `.activateAlert`, and bulk clearing goes through `.markAllAlertsRead`, `.clearAlertsForPane`, and `.clearAlertsForTabs`. The two hits in `UpdateAlertTests.swift` are the only senders.

**Ideal fix.** Remove the case, the arm, and the two tests that exercise it. If per-alert acknowledgement is wanted in manual clear mode, add it back with the UI or IPC producer in the same change so the vocabulary always names something a user can do.

**By construction.** n/a -- this removes dead vocabulary rather than making a state unrepresentable.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** The build fails if any real producer existed; `swift test --package-path lib/DanTermCore` passes after the two tests are deleted, and the remaining alert tests still pin `.activateAlert` marking its alert read outside manual mode.

**Risk.** None beyond losing a path nothing uses; the same behavior is reachable through `.activateAlert` and the bulk-clear messages.

## Area: Core model and projections

_Scope: Pure domain model and derived projections (lib/DanTermCore/Sources/DanTermCore: Model.swift, ModelOperations.swift, PaneLayout.swift, PaneGridOverride.swift, Projections.swift, PaneRosterProjection.swift, DisplayLine.swift, DropZone.swift, DragDropInput.swift, EntityTitle.swift, SidebarItemStore.swift, ScrollbarMath.swift, ChipKind.swift)_

**Auditor's read on the area.** The core of this area is in good shape: `PaneTree` already makes "a pane with no owning leaf" unrepresentable, `PaneGridOverride` fails instead of clamping, `DisplayLine` is a genuinely tight boundary type, and `PaneLayout` is a clean pure projection with one rounding rule shared by layout and drag inversion. The remaining defects all have the same shape -- a product type whose fields are only valid in certain combinations, or a second copy of a fact some other value already carries. I did not audit Update.swift, IpcDispatch.swift, Persistence.swift, PaneLifecycleReducer.swift, Reconcile.swift, or SidebarView.swift as subjects; I read them only to establish reachability and call-site counts for defects whose home is in my files. I looked at ScrollbarMath's UInt64 subtraction (`total - offset - len` traps on underflow) and dropped it: the engine's `scrollProjection` guarantees `topRow + windowRows <= totalRows`, so I could not show it reachable.

<a id="model-1"></a>

### MODEL-1. Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PendingConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredConfirmation`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#closeConfirmationCopy`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#emitConfirmation`

**Problem.** `PendingConfirmation` stores a `ConfirmationSubject` next to four independently-optional payload fields (`tabTitle`, `impact`, `deleteGroup`, `quitAuthorized`). Only five of the many field combinations are legal, and the pairing is enforced nowhere -- it is a convention shared by three construction sites and re-checked defensively at every read. The type admits `.deleteGroup` with a nil `deleteGroup`, `.tab` with a nil `tabTitle`, and `.app` with a frozen `impact`.

**Evidence.** `PendingConfirmation` declares `let subject: ConfirmationSubject; let tabTitle: DisplayLine?; let impact: CloseImpact?; let deleteGroup: DeleteGroupConfirmation?; let quitAuthorized: Bool`. Every arm of `desiredConfirmation` re-derives the pairing defensively -- `case .pane: guard let impact = pending.impact else { return nil }`; `case .tab(let tabId): guard tabById(...) != nil, let tabTitle = pending.tabTitle, let impact = pending.impact else { return nil }`; `case .deleteGroup: guard let frozen = pending.deleteGroup ... else { return nil }`. `closeConfirmationCopy` carries two crash arms that exist only because the type permits the combination: `case .app: preconditionFailure("app confirmations do not have frozen close copy")` and `case .deleteGroup: preconditionFailure("delete-group confirmations do not have close copy")`. `emitConfirmation` hand-fills the nils per subject (`tabTitle: nil, impact: nil, deleteGroup: nil, quitAuthorized: false` for `.app`), and `Update.swift#emitDeleteGroupConfirmation` fills a different subset.

**Ideal fix.** Delete the subject/payload split and give `PendingConfirmation` an `id` plus one enum whose cases carry exactly their own data: `.quit`, `.closePane(PaneId, CloseImpact, quitAuthorized: Bool)`, `.closeTab(TabId, title: DisplayLine, CloseImpact, quitAuthorized: Bool)`, `.closeTabs([TabId], CloseImpact, quitAuthorized: Bool)`, `.deleteGroup(GroupId, DeleteGroupConfirmation)`. `desiredConfirmation` then returns a non-optional projection for a non-nil pending confirmation, and `closeConfirmationCopy` takes only the three close cases and loses both `preconditionFailure` arms. `ConfirmationSubject`, which confirm dispatch still wants, becomes a computed property.

**By construction.** A pending confirmation missing the payload its subject requires, or carrying a payload its subject has no use for, becomes unrepresentable; so does a confirmation kind with no close copy reaching `closeConfirmationCopy`, which deletes both `preconditionFailure` calls rather than guarding them.

**Cheaper fallback.** none -- the ideal fix is a mechanical retype of one value plus three construction sites and one reader.

**Verification.** DanTermCore test: for each confirmation the reducer can raise (close pane, close tab, close multiple tabs, quit, delete group), assert `desiredConfirmation(in: model)` is non-nil right after the raising message and that `.confirmConfirmation(id:)` performs the action. Today the tab arm can project nil, which orders the panel out (`Reconcile.swift#reconcileConfirmation` calls `confirmationPanel?.orderOut(nil)`) while `model.pendingConfirmation` stays set -- a transaction the user can never answer.

**Risk.** Confirm/cancel dispatch in Update.swift switches on `subject`; keep a computed `subject` through the change so those arms are untouched.

<a id="model-2"></a>

### MODEL-2. Make SidebarItemStore reject nothing, or report rejection, so a dropped row op cannot strand the outline

`correctness` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift#SidebarItemStore`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#advanceSidebarCache`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#computeSidebarRowOps`

**Problem.** `SidebarItemStore.apply` validates every index and cache lookup itself and returns `.none` when a check fails. `.none` also means "this op legitimately produced no outline work", so the caller cannot tell a rejected structural op from a no-op -- and the reconcile driver advances its projection cache to `new` regardless. A single rejected insert or remove desynchronizes the mounted outline from the projection permanently: the next sweep diffs against a cache that claims the op landed, so nothing ever emits the repair and no path escalates to `reloadAll`.

**Evidence.** `apply` has eight fail-closed guards returning `.none`, e.g. `case .insertTab: guard let parent = groupItemCache[groupId], var children = childItems[groupId], children.indices.contains(index) || index == children.count else { return .none }` and `case .removeGroup(let index): guard !projection.isSingleGroupMode, rootItems.indices.contains(index), case .group(let group) = rootItems[index].kind else { return .none }`. The consumer `app/SidebarView.swift#applyRowOp` does `switch store.apply(op, projection: projection) { case .none: return ... }` and reports nothing back, while `app/SidebarReconcileDriver.swift` unconditionally stores the result of `advanceSidebarCache(...)`. `advanceSidebarCache` retains only rows named by `suppressedRenameTarget`, `unappliedTabIds`, or `unappliedGroupIds`, and only `.repaint`/`.setGroupCollapsed` ever populate those sets -- never a rejected insert or remove. Indices are cumulative (`computeSidebarRowOps` documents "each index is relative to the running (intermediate) state"), so one rejection invalidates every later index in the script.

**Ideal fix.** Stop validating indices in the store: have it apply each op against the projection it is handed, deriving the row position from that projection's own ordering, so an out-of-range or unknown-parent op is unrepresentable and `apply` becomes total. Where a rejection genuinely cannot be designed away, widen the return so it names rejection -- `enum SidebarOutlineMutation { case noWork; case rejected; ... }` -- and have the driver turn any `rejected` into a `reloadAll` in the same sweep while keeping the old projection in its cache.

**By construction.** "The mounted outline disagrees with the last-applied projection, and the diff can never notice" stops being expressible: either the store cannot reject an op the diff produced, or the cache cannot advance past a rejection.

**Cheaper fallback.** Keep the guards but return `.rejected` and treat it as a forced rebuild. The store can still disagree with the projection, but the damage is bounded to one extra reload instead of a permanently wrong outline.

**Verification.** Pure test over the diff/store pair: build old and new `SidebarProjection`s, run `computeSidebarRowOps`, apply the script to a `SidebarItemStore` seeded from a stale state (one row already missing), and assert the store's resulting row ids equal `new`'s row ids. Today ops are silently dropped and the assertion fails.

**Risk.** Deriving indices from the projection changes the store's contract with `app/SidebarView.swift#applyRowOp`, which feeds NSOutlineView index-based insert/remove calls; those calls must receive the same index the store used, so the mutation must keep carrying it.

<a id="model-3"></a>

### MODEL-3. Collapse ContainerShape to layout plus zoomedLeaf; derive the structural fingerprint

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#ContainerShape`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#containerShape`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#computeContainerOps`

**Problem.** `ContainerShape` stores three facts of which two are derived. `tree` is exactly `layout` with the ratios dropped, and `isZoomed` is exactly `zoomedLeaf != nil`. Both duplicates participate in `Equatable`, and `isZoomed` is read by nothing at all -- it can only produce a spurious shape difference. The initializer also takes `tree` and `layout` independently, so a value whose structural fingerprint disagrees with its own layout tree is representable.

**Evidence.** `ContainerShape` declares `let tree: ContainerShapeNode; let layout: ContainerLayoutNode; let isZoomed: Bool; let zoomedLeaf: PaneId?`, with an initializer defaulting `layout` to `defaultContainerLayoutNode(tree)` -- a fabricated 0.5-ratio tree. `containerShapeNode` and `containerLayoutNode` are the same walk, the second keeping `ratio`. `containerShape(of:)` always builds them consistently (`isZoomed: tab.paneTree.isZoomed, zoomedLeaf: tab.paneTree.isZoomed ? tab.paneTree.focusedPaneId : nil`). `computeContainerOps` reads only `oldShape.tree != shape.tree`, `oldShape.layout != shape.layout`, and `oldShape.zoomedLeaf != shape.zoomedLeaf`; grepping `isZoomed` across app/ and lib/ finds no read of `ContainerShape.isZoomed` outside its own declaration and test fixtures.

**Ideal fix.** Reduce `ContainerShape` to `let layout: ContainerLayoutNode` and `let zoomedLeaf: PaneId?`, with `var structure: ContainerShapeNode` computed by dropping ratios from `layout`. Delete `isZoomed`, `containerShapeNode(_:)` over `SplitNodeModel`, and `defaultContainerLayoutNode`; `computeContainerOps` then compares `structure` for `.setTree` and `layout` for `.setLayout` off one stored value.

**By construction.** A container shape whose structural fingerprint contradicts its own layout tree, and a shape claiming zoom with no zoomed leaf (or a zoomed leaf with zoom off), stop existing as values.

**Cheaper fallback.** none -- the ideal fix is smaller than what it replaces.

**Verification.** The existing container-op model-apply tests must keep passing: build old/new shapes from real `TabModel`s via `containerShape(of:)`, apply `computeContainerOps` to a presence/visibility map, and assert it equals the new key set and visibility. Add one case asserting a ratio-only edit yields `.setLayout` and never `.setTree`.

**Risk.** Test fixtures construct `ContainerShape(tree:isZoomed:zoomedLeaf:)` directly and must be rewritten to build a layout node; no production caller does.

<a id="model-4"></a>

### MODEL-4. Group the sidebar group row's reload attributes into one Equatable value

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Projections.swift#SidebarGroupProjection`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#computeSidebarRowOps`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#advanceSidebarCache`

**Problem.** Which fields of `SidebarGroupProjection` count as "reload attributes" is written out by hand in two places that must agree: the diff that decides whether to emit `.reloadGroup`, and the cache-retention helper that rolls a suppressed group row back. Adding an attribute and forgetting either list is silent -- forget the diff and the row never repaints; forget the retention and the cache claims an unapplied attribute was painted. The tab row has no such hazard because it is compared and retained as a whole value.

**Evidence.** `computeSidebarRowOps` compares a hand-built tuple: `if (oldGroup.name, oldGroup.unreadAlertCount, oldGroup.tabCount, oldGroup.isFirst) != (newGroup.name, newGroup.unreadAlertCount, newGroup.tabCount, newGroup.isFirst) { ops.append(.reloadGroup(id: newGroup.id)) }`. `advanceSidebarCache#retainGroupReloadAttrs` re-lists the same four: `merged.groups[gi].name = oldGroup.name; merged.groups[gi].unreadAlertCount = oldGroup.unreadAlertCount; merged.groups[gi].tabCount = oldGroup.tabCount; merged.groups[gi].isFirst = oldGroup.isFirst`. The contrasting tab path is one whole-value compare (`if let oldTab = oldTabById[newTab.id], oldTab != newTab`) and one whole-value assignment in `retainTabProjection`.

**Ideal fix.** Nest the four fields in a `SidebarGroupProjection.Attributes: Equatable` value (`name`, `unreadAlertCount`, `tabCount`, `isFirst`), leaving `id`, `isCollapsed`, and `tabs` as the structural fields. The diff becomes `oldGroup.attributes != newGroup.attributes` and the retention becomes `merged.groups[gi].attributes = oldGroup.attributes`, so both sides name one value and a new attribute joins both automatically.

**By construction.** An attribute that drives a group-row repaint but is absent from the suppression rollback (or the reverse) cannot be written: there is one value, not two enumerations of one.

**Cheaper fallback.** none -- this is a pure regrouping of existing fields.

**Verification.** Existing sidebar row-op model-apply test, plus one behavioral test: with a group row under inline rename, change a group attribute, assert no `.reloadGroup` is applied to that row, and assert the change is re-emitted on the next sweep after the rename ends.

**Risk.** `SidebarGroupProjection` is built in `desiredSidebar` and read by `app/SidebarView.swift`'s group-cell configuration; both need the extra `.attributes` hop.

<a id="model-5"></a>

### MODEL-5. Move per-pane search and notification-throttle state into PaneModel so pane teardown prunes them

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#PaneModel`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#clearPaneSideTables`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredSearchOverlays`

**Problem.** `AppModel` keeps two dictionaries keyed by `PaneId` whose entire lifetime is the pane's -- `searchState` and `lastNotificationTime` -- outside the tree that owns panes. Pruning them is a convention: every pane-destroying path must remember to call `clearPaneSideTables`, and there are five such call sites. This is the same dual-ownership drift the model already eliminated for panes themselves.

**Evidence.** `AppModel` declares `var lastNotificationTime: [PaneId: [AlertKind: Date]] = [:]` and `var searchState: [PaneId: SearchModel] = [:]`, while the pane-access section header states the principle they violate: "Panes live only in the split-tree leaves ... NO stored index is kept (that would reintroduce the drift this refactor removes)", and `SplitNodeModel.leaf` states "A pane exists iff a tree leaf owns it (no separate `AppModel.panes` dict), so the old dual-write drift between dict and tree is structurally impossible." `clearPaneSideTables` exists only to re-establish by hand what leaf ownership would give for free, and Update.swift calls it from five separate teardown paths. `desiredSearchOverlays` iterates `model.searchState` rather than live panes, so a missed prune projects an overlay for a pane that no longer exists.

**Ideal fix.** Put `var search: SearchModel?` and `var lastNotification: [AlertKind: Date]` on `PaneModel`. Removing the leaf removes them, so no teardown path can forget. `desiredSearchOverlays` becomes a walk over live panes keyed by `pane.search != nil`, and `clearPaneSideTables` shrinks to the alert feed alone -- `alerts` is a global ordered list, so it legitimately stays a separate prune.

**By construction.** "A destroyed pane's search overlay or notification throttle survives it" stops being expressible, because that state has no storage independent of the leaf that owns the pane.

**Cheaper fallback.** Keep the dictionaries but derive the prune instead of pushing it: one `reconcilePaneSideTables(&model)` at the end of `update()` filtering both dictionaries to `Set(model.allPaneIds)`. Cheaper, and it removes the five-call-site convention, but a stale entry can still exist for the duration of one message.

**Verification.** Behavioral test: open a search on a pane in a split tab, close that pane, and assert `desiredSearchOverlays(in: model)` holds no key for it and a newly created pane starts with no overlay. A second test closes a pane with a recorded bell time and asserts the next bell on a fresh pane is not throttled.

**Risk.** `PaneModel` is `Equatable` and feeds `desiredPaneToolbar` and container shape comparisons; adding live search state to it means a keystroke in the find field now changes the pane value. Confirm the projections that key off `PaneModel` do not gain spurious diffs -- container shapes drop pane payload already, but toolbar equality should be re-checked.

<a id="model-6"></a>

### MODEL-6. Drop the submission-to-request reverse index and derive it from the pending requests

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#PendingInputRequest`

**Problem.** The in-flight IPC input bookkeeping is stored twice: `pendingInputRequests[requestId].remaining` holds the submission ids a request waits on, and `pendingInputSubmissions` holds the same edges reversed. Nothing ties them together, so every mutation updates both by hand and a disagreeing pair is representable -- a submission mapped to a request that no longer lists it would be resolved a second time, and a submission in `remaining` with no reverse entry would block its request's reply forever.

**Evidence.** `AppModel` declares `var pendingInputRequests: [UUID: PendingInputRequest] = [:]` and `var pendingInputSubmissions: [InputSubmissionId: UUID] = [:]`; `PendingInputRequest` is `var remaining: Set<InputSubmissionId>`. Four sites must keep them in step: `IpcDispatch.swift#dispatch` writes `model.pendingInputRequests[reqId] = PendingInputRequest(remaining: Set(submissionIds))` then loops `model.pendingInputSubmissions[submissionId] = reqId`; the shutdown arm calls `removeAll()` on both; and `.inputSubmissionCompleted` removes from the reverse map, removes from `remaining`, and on rejection loops `for pendingId in request.remaining { model.pendingInputSubmissions.removeValue(forKey: pendingId) }`.

**Ideal fix.** Keep only `pendingInputSubmissions: [InputSubmissionId: UUID]` and delete `pendingInputRequests` and `PendingInputRequest`. A request is outstanding while any entry maps to it; "the last submission completed" is `model.pendingInputSubmissions.values.contains(requestId) == false` after the removal, and a rejection is `model.pendingInputSubmissions = model.pendingInputSubmissions.filter { $0.value != requestId }`. In-flight counts are single digits, so the scan costs nothing.

**By construction.** A submission whose owning request has already replied, and a request waiting on a submission that no longer maps back to it, both become unrepresentable -- one edge set instead of two that must mirror each other.

**Cheaper fallback.** Keep both dictionaries but move every mutation behind two methods on `AppModel` (`beginInputRequest`, `completeInputSubmission`) so no caller can touch one map without the other. This preserves the invalid states as values; it only reduces the number of places that can create them.

**Verification.** Behavioral test through the IPC reducer: issue a multi-item pane-input request, complete the submissions out of order, and assert exactly one reply is emitted after the last; repeat with a mid-way rejection and assert exactly one error is emitted and no later completion produces a second reply.

**Risk.** The shutdown arm builds its error list from `pendingInputRequests.keys`; after the change it must build a de-duplicated set of request ids from the values, or it will emit one error per submission.

<a id="model-7"></a>

### MODEL-7. Make PaneTree.remove non-mutating and return an outcome that cannot be misread as a live tree

`api-shape` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PaneTree`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#removeLeaf`

**Problem.** `PaneTree.remove` mutates in place and reports emptiness through a boolean on its result. In the emptied case it leaves `root` and `focusedPaneId` untouched -- the tree still contains the pane the call just reported as removed -- so the returned value and the mutated tree disagree, and correctness rests on every caller reading `emptiedTree` before writing the tree back. A call site that writes `tab.paneTree = sourcePaneTree` without checking silently resurrects the pane it just moved elsewhere, duplicating a pane id across two tabs.

**Evidence.** `remove` does `guard let newRoot else { return Removal(pane: removedPane, emptiedTree: true, focusMoved: focusMoved) }` -- returning before `root = newRoot`. The callers branch by hand: `Update.swift#movePaneToTab` writes `if !removal.emptiedTree { updateTab(...) { $0.paneTree = sourcePaneTree } } else { removeTab(...) }`, and `movePaneToNewTab` guards with `guard let removal = sourcePaneTree.remove(paneId), !removal.emptiedTree else { return [] }`. `Removal` documents the hazard -- "Describes a removal without permitting an empty `PaneTree` value" -- while still handing back a tree that contradicts its own report.

**Ideal fix.** Replace the mutating method with a non-mutating `func removing(_ paneId: PaneId) -> RemovalOutcome`, where `RemovalOutcome` is `.notFound`, `.emptied(PaneModel)`, or `.remaining(PaneTree, pane: PaneModel, focusMoved: Bool)`. The surviving tree then exists only inside the case that has one.

**By construction.** "A pane tree that reported its last pane removed, still holding it" stops being obtainable: the emptied case carries no tree to write back.

**Cheaper fallback.** Keep the mutating signature but have callers pre-test `if case .leaf(let p) = tree.root, p.id == paneId`, which is what `movePaneToNewTab` already does for its single-pane path. This spreads the shape test back out to call sites and is strictly worse.

**Verification.** Behavioral test: move the only pane of a two-tab window's first tab into the second tab, then assert the model has exactly one tab and the moved pane id appears exactly once in `model.allPaneIds`. A second test moves a pane out of a split tab and asserts the source tab survives with its remaining pane focused.

**Risk.** Three call sites in Update.swift change shape; each already branches on `emptiedTree`, so the rewrite is mechanical, but the focus-move assertions in PaneTreeTests exercise the mutating form and need updating.

## Area: IPC protocol, dispatch, CLI

_Scope: IPC surface: wire protocol, dispatch, and the CLI client (lib/DanTermProtocol, IpcDispatch/IpcEntityEncoder, lib/DanTermClient, app/IpcServer.swift, cli/main.swift, integrations/danterm/SKILL.md)_

**Auditor's read on the area.** The wire layer is in good shape: framing is one shared `IpcLineFramer` used by both ends, the CLI can only build a request through the typed `IpcRequest` catalog, and `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog` pins encode/decode against each other for every method, so the two mirrored switches in `IpcRequest` cannot drift silently. The weak spots are the projections that were written as a *third* copy of the same facts with a `default:` escape (the audit descriptor), and the human-facing surface (help text, per-parser usage strings, SKILL.md) which is admitted in a comment to be hand-synced with no check. I did not audit the tape/snapshot record formats, the audit log writer itself, or the transports' socket mechanics beyond their error vocabulary.

<a id="ipc-1"></a>

### IPC-1. Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch

`correctness` &middot; impact 5, confidence 5 &middot; effort medium

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/IpcAuditDescriptor.swift#auditDescriptor`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#params`, `app/IpcServer.swift#dispatch`

**Problem.** `IpcRequest.auditDescriptor` re-describes what a request carries in a switch that falls back to `default:`, and it misses `group.new`. `group.new` accepts a full `LaunchSpec` (`--cmd`, `--cwd`), it is remote-callable (`requiresLocalCaller` is true only for `quit`), and it produces an audit record -- but the record it produces has `command: nil` and `cwd: nil`. The audit log is the only durable trace of authority an admitted tailnet peer exercised, and a command launched through `group new --cmd '...'` leaves no trace of what ran.

**Evidence.** In IpcAuditDescriptor.swift#auditDescriptor: `switch self { case .tabNew(_, let value, _), .paneSplit(_, _, let value, _): launch = value; default: launch = nil }`. The catalog case is `case groupNew(name: String, launch: LaunchSpec?, background: Bool)` (IpcRequest.swift#IpcRequest) and the CLI builds it with a launch spec in CLIParser.swift#parseGroupNewCommand (`--cmd`, `--cwd`, defaulted to the caller's cwd). `IpcRequestMethod.producesAuditRecord` returns true for `.groupNew`, and app/IpcServer.swift#dispatch writes `.requestStarted(caller:request: typedRequest.auditDescriptor)` before serving a remote request, so the descriptor is the whole record. The declared intent is in the field doc: "Retains a launch command because it is authority exercised by the caller." IpcAuditDescriptorTests#launchAuthorityIsRetained covers only `.tabNew` and `.paneSplit`.

**Ideal fix.** Stop writing the audit projection as an independent enumeration. Build the descriptor from `IpcRequest.params` -- the one encoding already pinned by the round-trip test -- keeping the target keys named by `targetParameterKeys` plus the launch keys, and replacing content-bearing keys (`text`, `input`) with the existing `IpcAuditInputAccounting` counts. Then a method that carries a launch spec on the wire is audited for it because the wire form is the source, and there is nothing per-method left to forget.

**By construction.** A request that carries launch authority (or a target) on the wire but is invisible in the audit log becomes unrepresentable: the descriptor is a redaction of the sent params rather than a parallel description of them, so there is no arm in which a field can be omitted by falling through.

**Cheaper fallback.** Keep the hand-written switch but delete both `default:` arms so every case is listed; adding a catalog case then fails to compile until its launch and input accounting are decided. This keeps three descriptions of the same facts, so they can still disagree about a key's spelling.

**Verification.** Add to IpcAuditDescriptorTests: `IpcRequest.groupNew(name: "g", launch: LaunchSpec(cmd: "ssh server", cwd: "/tmp/work", title: nil), background: false).auditDescriptor` has `command == "ssh server"` and `cwd == "/tmp/work"`. Broaden it to a loop over `representativeCLICommands()` asserting that every request whose params contain a `launch` object reports a non-nil `command`/`cwd`, and that no descriptor's encoded form contains pane text. Run `swift test --package-path lib/DanTermProtocol --filter IpcAuditDescriptor`.

**Risk.** Deriving from params means new fields land in the audit log by default, so the redaction list must be a denylist-free design: encode only keys the descriptor names (target keys, launch keys, accounting), never "everything except". Getting that backwards would put pane text in a durable log.

<a id="ipc-2"></a>

### IPC-2. Generate the CLI help text and SKILL.md synopsis from one command table instead of hand-syncing three copies

`structural` &middot; impact 4, confidence 5 &middot; effort large

**Files.** `cli/main.swift#DanTermCLI`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseCLI`, `integrations/danterm/SKILL.md`

**Problem.** The command grammar is written out three times: `usageText` in the CLI, ~48 per-parser `usage:` strings inside `parseCLI` and its helpers, and the synopsis block in SKILL.md. Nothing checks them against each other or against the parser, so a new flag, a renamed subcommand, or a changed default can be true in one copy and false in the other two -- and SKILL.md is what agents read as the contract.

**Evidence.** cli/main.swift#DanTermCLI states it outright: "Top-level help text. Kept in sync by hand with `parseCLI` ... there is no automated check, so any change to either touches this string too." The same grammar appears a second time as a literal inside the parser (CLIParser.swift#parseTabNewCommand: `let usage = "usage: danterm tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] ..."`) and a third time at integrations/danterm/SKILL.md lines 37-68, whose own header says "Keep this section synced with `danterm help` and the parser". The only automated SKILL.md check in the tree (scripts/tests/danterm-cli_test.sh) merely `cmp`s the bundled copy against the repo file -- it never compares it to the parser or to the help text.

**Ideal fix.** Declare each command once in `DanTermProtocol` as a table entry: verb path, synopsis line, one-line description, and the parsing closure. `parseCLI` dispatches through the table (so an unknown verb and a per-command usage error both come from the entry), `usageText` renders from the table, and a test asserts the SKILL.md synopsis block equals the rendered synopsis. A command with no help entry, and a help entry with no command, both stop existing.

**By construction.** A documented command that the parser does not accept -- and an accepted command that neither `danterm help` nor SKILL.md mentions -- becomes unrepresentable, because the help text and the synopsis are projections of the same table the dispatcher reads.

**Cheaper fallback.** Keep the parser as-is but move every `usage:` literal into the table and add one test that asserts SKILL.md's fenced synopsis block is byte-equal to the generated help synopsis. This removes the two worst copies and leaves the parser's structure alone.

**Verification.** A test in DanTermProtocolTests that, for every table entry, `parseCLI` accepts the synopsis's example form and that the rendered help contains exactly the table's verbs; plus a test comparing the generated synopsis to the block in integrations/danterm/SKILL.md. Behaviorally: `danterm help` output and the SKILL.md block stay equal after adding a command without touching either string.

**Risk.** The table must not flatten genuinely different error wording (for example `pane tape`'s multi-line explanations), so entries need a free-form usage body rather than a generated one-liner; over-normalizing would degrade today's error messages.

<a id="ipc-3"></a>

### IPC-3. Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear

`api-shape` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift#dispatchIpc`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#decode`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseTodoIdCommand`

**Problem.** `todo.done` and `todo.open` differ only by a boolean, and `todo.done`/`open`/`delete` share one argument grammar. Because they are separate catalog cases with identical payloads, three places group them and then re-switch to recover which one they had, each ending in a `preconditionFailure`/`default` arm that the compiler cannot prove unreachable. A future case added to one of those groupings crashes the daemon or the CLI at runtime instead of failing to build.

**Evidence.** IpcDispatch.swift#dispatchIpc: `case .todoDone(let owner, let todoId), .todoOpen(let owner, let todoId):` then `switch request { case .todoDone: shouldBeDone = true; case .todoOpen: shouldBeDone = false; default: preconditionFailure("exhaustive todo state request") }`. IpcRequest.swift#decode: `case .todoDone, .todoOpen, .todoDelete:` then an inner `switch method` ending in `default: preconditionFailure("exhaustive todo method switch")`. CLIParser.swift#parseTodoIdCommand takes `method: IpcRequestMethod` purely as a selector and ends in `default: preconditionFailure("todo id parser requires a todo mutation method")`.

**Ideal fix.** Collapse the pair into `case todoSetDone(owner: TodoOwner, todoId: TodoId, isDone: Bool)` while keeping the two distinct wire methods (`todo.done` decodes with `isDone: true`, `todo.open` with `false`), and change `parseTodoIdCommand` to take the request constructor `(TodoOwner, TodoId) -> IpcRequest` instead of a method enum. All three re-switches and all three `preconditionFailure`s go away, and `dispatchIpc` reads the boolean straight out of the payload.

**By construction.** "A todo request reached a branch that cannot name its own variant" stops being expressible: the variant is a value in the payload, and the parser is handed the constructor rather than a tag it must translate back.

**Cheaper fallback.** Keep the two cases but replace each grouped arm with separate arms that duplicate two lines of body. No `preconditionFailure` remains, at the cost of a little repetition.

**Verification.** Existing behavior tests must keep passing: `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog` (which requires every wire method to still round trip, so `todo.done` and `todo.open` must stay distinct on the wire) plus the core dispatch tests that `todo done` marks an item done and `todo open` reopens it. `swift test --package-path lib/DanTermProtocol` and `swift test --package-path lib/DanTermCore`.

**Risk.** The wire methods must stay two, not one -- collapsing them on the wire would be an external CLI-surface change and would break the round-trip test's method-coverage assertion. The refactor must keep `IpcRequestMethod` unchanged.

<a id="ipc-4"></a>

### IPC-4. Return one traits value from a single exhaustive switch instead of six parallel per-method enumerations

`simplification` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#IpcRequestMethod`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#targetParameterKeys`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcAuditDescriptor.swift#auditTarget`

**Problem.** Adding one request method means writing its name into six hand-maintained lists: the four attribute switches on `IpcRequestMethod` (`terminatesInstance`, `isTargeting`, `requiresLocalCaller`, `producesAuditRecord`), `IpcRequest.targetParameterKeys`, and `IpcRequest.auditTarget`. Each is exhaustive, so the compiler catches an omission -- but the same 33-case list is spelled out six times, and the two target projections can disagree about a key's spelling without any compiler complaint (`targetParameterKeys` says `afterTabId`; `auditTarget` independently repeats it).

**Evidence.** IpcRequest.swift#IpcRequestMethod contains four switches whose non-default arm lists all of `.ping, .doctorPermissions, .ls, .focusInfo, .roster, .groupNew, ... .todoClearCompleted` verbatim. IpcRequest.swift#targetParameterKeys and IpcAuditDescriptor.swift#auditTarget then group the same cases a fifth and sixth time -- `case .tabNew(let target, _, _): switch target { case .group: return ["group"]; case .afterTab: return ["afterTabId"] }` appears in both files with the key strings typed out twice.

**Ideal fix.** Declare one `IpcRequestMethod.traits` returning a small struct (`terminatesInstance`, `isTargeting`, `requiresLocalCaller`, `producesAuditRecord`) from a single exhaustive switch, with the four properties as one-line projections of it. Take the target keys from one place too: `auditTarget` becomes `params` filtered by `targetParameterKeys` (see the audit-descriptor finding), so the key spellings exist once.

**By construction.** The four attributes can no longer disagree about which cases exist, and the target key vocabulary exists once rather than twice, so an audit record naming a key the wire never used stops being expressible.

**Cheaper fallback.** Keep the four properties but express three of them as the small exceptional set (`terminatesInstance` is `self == .quit`) and leave only `producesAuditRecord` exhaustive. Fewer copies, but a new method silently inherits the majority answer -- which is exactly what the current comments say they are preventing, so this trade is a real loss.

**Verification.** The existing behavior tests already pin the answers and must stay green: `IpcRequestTests.quitIsTheOnlyInstanceEndingMethod`, `quitIsTheOnlyLocalCallerMethod`, `everyTargetingCatalogMethodRejectsAbsentTarget`, and the audit descriptor's target assertions. Add one test asserting that for every `representativeCLICommands()` entry, `auditDescriptor.target`'s keys equal `request.targetParameterKeys` restricted to the keys actually present in `request.params`.

**Risk.** The traits struct must keep the switch exhaustive (no defaulted initializer), or a new method would inherit defaults silently -- which is worse than today's six lists.

<a id="ipc-5"></a>

### IPC-5. Make IpcRequest.decode typed-throws so IpcServer cannot need two decode-failure paths

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `app/IpcServer.swift#dispatch`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#decode`

**Problem.** `IpcRequest.decode` throws only `IpcRequestDecodeError`, but its signature says `throws`, so the server writes two near-identical 12-line failure blocks -- one for the real error, one for an "impossible" error that maps to `.internalError`. The dead branch is untestable and any future edit has to be made twice.

**Evidence.** app/IpcServer.swift#dispatch has `catch let error as IpcRequestDecodeError { ... dispatchToRuntime(.ipcRequestDecodeFailed(reqId: reqId, error: error), ...) }` immediately followed by `catch { ... dispatchToRuntime(.ipcRequestDecodeFailed(reqId: reqId, error: .internalError), ...) }` with identical audit-append and `rememberRequest` lines. Every throw site inside IpcRequest.swift#decode and its private helpers produces `IpcRequestDecodeError` -- `invalid(...)`, `.methodNotFound`, and the `LaunchSpecParseError`/`KeyModsDecodeError`/`PaneTapeSyncPolicyError` cases are all caught and rethrown as `invalid(...)`.

**Ideal fix.** Declare `public static func decode(method:params:) throws(IpcRequestDecodeError) -> IpcRequest`. The second catch block stops compiling and is deleted; the server has exactly one decode-failure path.

**By construction.** "A decode failure the server classified as an internal error" becomes unrepresentable: the type system states that decoding fails only with the client-facing vocabulary, so there is no second outcome to handle.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** Existing server behavior must hold: a request with an unknown method still answers JSON-RPC -32601 and a bad-shape request -32602, with a `requestDecodeFailed` audit record in both cases. Covered by the decode tests in `swift test --package-path lib/DanTermProtocol --filter IpcRequest` plus the CLI end-to-end script scripts/tests/danterm-cli_test.sh.

**Risk.** `throws(E)` propagates: any helper called from `decode` that gains a differently-typed error must convert it explicitly. That is the point, but it makes future edits in that file slightly more deliberate.

<a id="ipc-6"></a>

### IPC-6. Collapse CLIResolvedTarget into CLIConnectionTarget

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `cli/main.swift#CLIResolvedTarget`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#CLIConnectionTarget`

**Problem.** Two enums with identical cases and identical payloads exist side by side, plus a private converter between them. The distinction they claim to draw -- "before" versus "after" ambient socket resolution -- is already carried by the optionality of the parsed value (`CLIInvocation.target` is `CLIConnectionTarget?`, and `selectConnectionTarget` returns a non-optional).

**Evidence.** CLIParser.swift declares `public enum CLIConnectionTarget { case unixSocket(path: String); case tcp(host: String, port: UInt16) }`; cli/main.swift#CLIResolvedTarget declares `enum CLIResolvedTarget: Equatable { case unixSocket(path: String); case tcp(host: String, port: UInt16) }` and `private extension CLIResolvedTarget { init(_ target: CLIConnectionTarget) { switch target { case .unixSocket(let path): self = .unixSocket(path: path); case .tcp(let host, let port): self = .tcp(host: host, port: port) } } }`.

**Ideal fix.** Delete `CLIResolvedTarget` and have `selectConnectionTarget` return a non-optional `CLIConnectionTarget`. `openSession` switches over the one type.

**By construction.** The class of bug where the two enums drift -- one gains a transport case the other lacks, or the converter maps a payload wrong -- stops existing, because there is one type and no conversion.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The existing target-selection behavior tests must stay green: `quit` without `--socket`/`--tcp` is refused, `DANTERM_SOCK` is used when no explicit target is given, and `DANTERM` set without `DANTERM_SOCK` reports "DanTerm is not running". Run the CLI test target and scripts/tests/danterm-cli_test.sh.

**Risk.** `CLIConnectionTarget` is public in DanTermProtocol while `CLIResolvedTarget` is CLI-local; reusing the public type means the CLI's resolved value is expressible by other clients. That is harmless here -- it is the same shape either way.

## Area: Persistence, recovery, support layer

_Scope: Persistence, recovery, and the portable side-effect layer (lib/DanTermCore Persistence/CheckpointCapture/RecoveryCheckpointPolicy/AgentSession/TabTodo + all of lib/DanTermSupport/Sources/DanTermSupport)_

**Auditor's read on the area.** The pure halves are in good shape: `RecoveryCheckpointPolicy` is a tight, self-consistent state machine (I traced every edge and found no reachable stuck state), `CheckpointCapture` already makes snapshot/scrollback pairing structural, `ControlSocketListener` and `TailnetListener` own their descriptors carefully, and `AgentSession` validation is sound. The weak spots cluster in three places: `RecoveryStore` (the whole session-lock contract is decided by a decode that can fail silently, and each path helper defaults its own directory independently), the snapshot codec's hand-enumerated re-builds, and layer placement in the pane-tape files. I did not audit `CLIPathInstaller`, `FontAvailability`, `TailnetBindAddress`, or the whois/HTTP parsing in `TailnetWhoisResolver` beyond a scan for swallowed failures, and I stayed out of `app/AppRuntime`'s checkpoint scheduling, which another auditor owns.

<a id="persist-1"></a>

### PERSIST-1. Decide crash recovery from the lock file's existence, not from decoding it

`correctness` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift#readSessionLockFile`, `lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift#writeSessionLockFile`, `app/main.swift`

**Problem.** The session lock's stated contract is that its presence means the previous exit was unclean. The implementation instead requires the file to be read AND JSON-decoded into a `SessionLock`; any failure on either step returns nil, which the only caller reads as "previous exit was clean". The write side swallows every error too, so a lock that was never written and a lock that decoded badly are both invisible, and the user silently loses the restore prompt after a crash.

**Evidence.** `readSessionLockFile` is `guard let data = try? Data(contentsOf: sessionLockURL(...)) else { return nil }` followed by `return try? decoder.decode(SessionLock.self, from: data)` -- a truncated or foreign-format file yields nil. Its own doc comment says "Its presence at next launch means the previous exit was unclean -- no PID liveness check needed", and the sole production caller in `app/main.swift` only ever tests `if readSessionLockFile() != nil { previousSessionCrashed = true }`; neither `pid` nor `startedAt` is read anywhere in app or lib. `writeSessionLockFile` is three `try?`/`guard let ... else { return }` statements in a row (`encoder.encode`, `createDirectory`, `data.write`), so a failure to create the lock is unreported.

**Ideal fix.** Make existence the observed fact: expose `hasSessionLock(...) -> Bool` backed by `FileManager.fileExists`, and let the file's contents be diagnostics only (write them, never parse them for the decision). Make the writer `throws` (or return a typed outcome) so the launch path can log or surface a lock it failed to create -- an app that cannot write its lock cannot detect its own crash, which is worth saying out loud.

**By construction.** "The crash prompt depends on the lock file's byte contents" becomes unrepresentable: with no decode on the decision path, a corrupt, truncated, empty, or future-format lock file cannot be mistaken for a clean exit.

**Cheaper fallback.** none -- the ideal fix is small; keeping the decode as an optional diagnostic read alongside a boolean existence check is strictly extra code for the same behavior.

**Verification.** In `RecoveryStoreTests`, write a `session.json` containing `{` (invalid JSON) into a temp recovery dir and assert the crash-detection query reports a previous unclean exit; then delete it and assert it reports clean. Today the first assertion fails.

**Risk.** A stale lock left by an older build with different contents now correctly triggers the recovery prompt where it previously did not -- that is the intended behavior, but it changes what the first launch after this change does if such a file exists.

<a id="persist-2"></a>

### PERSIST-2. Give the recovery directory one owner: a RecoveryPaths value threaded from launch

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift#recoveryDirectoryURL`, `lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift#lightCheckpointURL`, `lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift#sessionLockURL`, `app/main.swift`, `app/AppRuntime.swift`

**Problem.** Four helpers each resolve the recovery directory on their own, with three different seam shapes: `recoveryDirectoryURL(identity:)` takes an identity, `sessionLockURL(recoveryDir:)`/`writeSessionLockFile(recoveryDir:)` take a directory, and `lightCheckpointURL()`/`enrichedCheckpointURL()` take nothing at all and hard-call the zero-arg default. Two consequences: the lock and the checkpoints can resolve to different directories (in the existing tests they demonstrably do), and no test can exercise the real recovery flow -- write checkpoints, write a lock, relaunch, merge -- because the checkpoint files cannot be redirected anywhere.

**Evidence.** `lightCheckpointURL()` is `recoveryDirectoryURL().appendingPathComponent("last-light.json")` with no parameter, while `writeSessionLockFile` takes `recoveryDir: URL = recoveryDirectoryURL()`. `RecoveryStoreTests` reflects the gap exactly: the lock round-trip drives a temp dir, but `lightCheckpointURLEndsWithLastLightJson` can only assert `url.lastPathComponent == "last-light.json"`. `app/main.swift` reads `Data(contentsOf: lightCheckpointURL())` and `enrichedCheckpointURL()`, `app/AppRuntime.swift` writes to the same two, and `app/IpcServer.swift` separately calls `recoveryDirectoryURL()` for the audit log.

**Ideal fix.** Introduce `struct RecoveryPaths { let directory: URL; var light: URL; var enriched: URL; var sessionLock: URL }` built once from a `DanTermInstanceIdentity` (plus a `RecoveryPaths(directory:)` init for tests), and make every read/write/delete take one. Construct it at launch and hand the same value to the delegate, the runtime, and the audit-log writer.

**By construction.** "The lock file and the checkpoint files live in different directories" becomes unrepresentable -- one value carries the directory, and every path is derived from it rather than re-resolved.

**Cheaper fallback.** Add a `recoveryDir:` parameter to `lightCheckpointURL`/`enrichedCheckpointURL` so at least the tier files become redirectable. This restores testability but leaves four independent defaults that can still disagree.

**Verification.** A DanTermSupport test that builds a `RecoveryPaths` on a temp dir, writes a light and an enriched checkpoint plus a lock through the production entry points, and asserts the relaunch path (crash detected, both tiers found and merged) sees them. No such end-to-end test can be written today.

**Risk.** Touches app call sites in main.swift, AppDelegate, AppRuntime, and IpcServer; a missed call site silently keeps using a stale free function, so the free functions should be deleted in the same change.

<a id="persist-3"></a>

### PERSIST-3. Graft scrollback through one leaf-mapping traversal instead of re-listing snapshot fields

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Persistence.swift#graftScrollback`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#TabSnapshot`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#GroupSnapshot`

**Problem.** `graftScrollback` rebuilds every `GroupSnapshot` and `TabSnapshot` by hand-listing their stored properties, purely so it can replace the tree inside. Any field added to `TabSnapshot` or `GroupSnapshot` later is preserved by the light checkpoint (which never passes through this function) and silently dropped by the enriched checkpoint and by `.exportState`, which both do. The tiers would then disagree about the model, and `mergeCheckpoints` -- which takes structure from light and only scrollback from enriched -- would hide the divergence from anything but the enriched-only restore path.

**Evidence.** `graftScrollback` contains `GroupSnapshot(id: group.id, name: group.name, isCollapsed: group.isCollapsed, tabs: ...)` and `TabSnapshot(id: tab.id, customTitle: tab.customTitle, focusedPaneId: tab.focusedPaneId, rootNode: graftScrollbackIntoNode(...), color: tab.color, todos: tab.todos)`. Both lists happen to be complete today, and the two most recently added persisted fields (`TabSnapshot.todos`, `PaneSnapshot.gridOverride`) show the pattern: `todos` had to be added here by hand, while `PaneSnapshot` escaped because `graftScrollbackIntoNode` uses `case .leaf(var ps)` and mutates.

**Ideal fix.** Make the container fields `var` and give `AppModelSnapshot` a single `mapPaneSnapshots(_ transform: (PaneSnapshot) -> PaneSnapshot)` traversal; `graftScrollback` becomes one call into it, mutating copies the way the leaf case already does. Every future leaf-level transform reuses the same traversal, so no site ever enumerates a container's fields again.

**By construction.** "An enriched checkpoint or export loses a snapshot field the light checkpoint keeps" becomes unrepresentable: no code path re-constructs a group or tab from its parts, so there is nothing to forget.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** A core test that builds a snapshot with every optional tab/group field populated, runs `graftScrollback` with an empty scrollback map, and asserts the result equals the input (`AppModelSnapshot` is already `Equatable`). It passes today and would keep passing under a new field only after the ideal fix.

**Risk.** Loosening `let` to `var` on the snapshot DTOs slightly widens mutation surface; the types are already `var`-bearing (`todos`, `scrollback`) so this is consistent rather than new.

<a id="persist-4"></a>

### PERSIST-4. Confine the IPC connection's descriptor to its write queue so a queued write cannot land on a reused fd

`correctness` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift#writeLine`, `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift#close`

**Problem.** `writeLine` checks the `closed` flag under the lock, releases the lock, and only then enqueues its write. `close()` sets `closed` under the lock and enqueues `Darwin.close(fd)`. Between those two moments the enqueue order can invert: the close work item runs first, the write work item then calls `Darwin.write` on a descriptor number the kernel may already have handed to a newly accepted IPC connection, an audit-log file, or a checkpoint file. The result is a JSON-RPC line delivered to the wrong peer or spliced into an unrelated file -- the descriptor analogue of the use-after-free the project rules forbid.

**Evidence.** `writeLine` does `lock.lock(); let shouldWrite = !closed; lock.unlock()` and then, after encoding, `writeQueue.async { ... Darwin.write(fd, ...) }`. `close()` does `lock.lock(); let shouldClose = !closed; closed = true; lock.unlock(); guard shouldClose else { return }; writeQueue.async { [fd] in Darwin.close(fd) }`. Nothing re-checks `closed` inside the queued write block, and the process opens descriptors continuously (accept loop in app/IpcServer, `CheckpointWriter`, `IpcAuditLogWriter.openLogFile`), so a released number is quickly reused.

**Ideal fix.** Let the write queue own the descriptor: store it as a queue-confined `var fd: Int32?` (or a small box), have `close()` enqueue `fd = nil; Darwin.close(...)`, and have every queued write read the descriptor from that variable and no-op when it is nil. `forceClose` keeps its lock-guarded `shutdown()` so a parked write fails fast; the actual close still rides the queue, as it does now.

**By construction.** "A write executes against a descriptor this connection has already closed" becomes unrepresentable: after teardown the queue-local descriptor is nil, and no other code path holds the number.

**Cheaper fallback.** Re-check `closed` at the top of the queued write block. Cheaper, but it keeps two owners for one fact (the lock-guarded flag and the descriptor), so the invariant remains a convention rather than a structure.

**Verification.** A DanTermSupport test over a socketpair: enqueue a large notification and call `close()` from another thread in a loop, asserting nothing is written to a control descriptor opened immediately after the close. More practically, an assertion-style test that a write submitted after `close()` reports `false` to its completion and performs no syscall on the old number.

**Risk.** The descriptor becomes optional, so `forceClose`'s `shutdown()` must still run against the live value under the lock before the queue nils it -- getting that ordering wrong would turn a forced close back into a draining one.

<a id="persist-5"></a>

### PERSIST-5. Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeStreamState.swift`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeFollow.swift`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift#writePaneTapeRecords`

**Problem.** About a thousand lines of deterministic decision logic -- the follow-subscription state machine and the events-vs-synchronize stream policy -- live in the portable-effects layer, which the pure-core ADR reserves for portable side effects. The consequence is not cosmetic: `scripts/core-purity-lint.sh` runs its hard IO bans only over `lib/DanTermCore/Sources/DanTermCore`, so this decision code sits outside the guard that stops `FileManager`, `DispatchQueue`, or a bare `Date()` from creeping into a decision. The comparable pure policy for the other stream, `RecoveryCheckpointPolicy`, is correctly in core.

**Evidence.** `PaneTapeStreamState.swift`'s own header opens "Pure pane-tape stream policy in two halves", and `PaneTapeFollow.swift` holds `PaneTapeFollowSubscriptions`, a plain mutating struct over a dictionary. Grepping those two files plus `PaneTapeRecords.swift` for `IpcConnection|FileManager|DispatchQueue|Darwin|Date()` yields exactly one hit: the `connection: IpcConnection` parameter of `writePaneTapeRecords`. All three import only `Foundation` and `DanTermProtocol`, which `DanTermCore` already depends on.

**Ideal fix.** Move `PaneTapeStreamState.swift`, `PaneTapeFollow.swift`, and the record builders in `PaneTapeRecords.swift` into `lib/DanTermCore/Sources/DanTermCore/`, and relocate `writePaneTapeRecords` -- the single site that touches a connection -- to `app/`, where the runtime already owns the connection registry. The pane-tape policy then compiles under the nested core package and under the pure lint profile.

**By construction.** "Pane-tape stream policy reads a clock, a file, or a queue" becomes a compile-and-lint failure rather than something a reviewer must notice.

**Cheaper fallback.** Leave the code where it is and add a third lint profile covering the pane-tape files with the pure-tier bans. That buys the guard without the move, but it forks the profile list per file group and leaves the ADR's layer story wrong.

**Verification.** `swift test --package-path lib/DanTermCore` compiles and runs the moved pane-tape suites, and `scripts/core-purity-lint.sh` fails if an IO token is introduced into them. Behavior is unchanged, so the existing `PaneTapeFollowTests`/`PaneTapeStreamStateTests` assertions must pass verbatim after the move.

**Risk.** The move splits test files across two nested packages, and the app target reaches both through symlinks, so a stale symlink or a test left behind in DanTermSupportTests would fail to resolve the moved symbols.

<a id="persist-6"></a>

### PERSIST-6. Publish the pane-tape record shape once in DanTermProtocol instead of writing keys on both sides

`api-shape` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift#makePaneTapeEventRecord`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift#makePaneTapeStart`, `lib/DanTermClient/Sources/DanTermClient/PaneTapeRecordReader.swift`

**Problem.** The producer builds each tape record as an untyped `[String: JSONValue]` with literal keys, and the in-repo reader parses the same records with its own copies of those literals. The two modules share `DanTermProtocol` -- which already owns the stream's version, format, capture modes, and end reasons -- but not the record shape itself, so the keys are the one part of the contract that can drift. A renamed or newly optional key compiles clean on both sides and only fails at runtime, in a stream a person is watching.

**Evidence.** `makePaneTapeEventRecord` writes `record["byteOffset"]`/`record["byteLength"]` and `makePaneTapeStart` writes `record["reconstructible"]`; `lib/DanTermClient/Sources/DanTermClient/PaneTapeRecordReader.swift` independently reads `value["byteOffset"]`, `value["reconstructible"]`, and `value["droppedFeedBytes"]`. The reader's own header claims to be "the one place" that knows the shape, which is true for the consumer half only. `PaneTapeRecords.swift`'s header already says the shared vocabulary belongs in DanTermProtocol; the keys are what escaped it.

**Ideal fix.** Define the records in DanTermProtocol as one typed value -- `enum PaneTapeRecord { case start(...), event(...), gap(...), end(...) }` with a single `JSONValue` encode and a matching decode -- and have the producer build it and the reader consume it. Key strings then exist exactly once.

**By construction.** "Producer and reader disagree about a record key or its optionality" becomes unrepresentable -- there is one encode and one decode over one type, so a change to either is a compile error on both sides.

**Cheaper fallback.** Put the key names in a shared `enum PaneTapeRecordKey: String` in DanTermProtocol and use it from both sides. That kills typo drift but still lets the two sides disagree about which keys are optional.

**Verification.** A DanTermProtocol round-trip test: build each record kind, encode to `JSONValue`, decode back, and assert equality; plus keeping the existing `PaneTapeFollowTests` wire-shape assertions (e.g. `records.first?["droppedFeedBytes"] == .number(6)`) green, since they pin the external JSON contract the CLI and clients already consume.

**Risk.** The record JSON is an external contract consumed by `danterm pane tape` clients, so the typed encode must reproduce the current bytes exactly -- including omitting `originElapsedNanoseconds` and the byte-position keys when absent.

<a id="persist-7"></a>

### PERSIST-7. Drive doctor's agent probes from one agent registry shared with KnownAgent

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#gatherClaudeFacts`, `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#gatherCodexFacts`, `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift#KnownAgent`, `lib/DanTermProtocol/Sources/DanTermProtocol/DoctorFacts.swift`

**Problem.** The set of agents DanTerm knows is written out separately in four places: `KnownAgent` in core, two near-identical probe functions in DoctorProber, named `claude`/`codex` fields on `DoctorFacts`, and hardcoded pairs in `cli/Doctor.swift`. `KnownAgent`'s doc comment claims the exact invariant this breaks -- that adding an agent cannot leave it known to one lookup and unknown to another. Adding a third agent means editing all four and produces a build that compiles while doctor stays silent about it.

**Evidence.** `gatherClaudeFacts` and `gatherCodexFacts` differ only in the root directory, the hook file names, and the extra TOML scan -- both then build the same `DoctorFacts.Agent` from `skillPaths = [root/skills/danterm, home/.agents/skills/danterm]`. `DoctorFacts` declares `public var claude: Agent` and `public var codex: Agent` as separate stored fields, and `cli/Doctor.swift` names `facts.claude` twice, `facts.codex` twice, and both again in `facts.claude.dantermHooks.isEmpty == false || facts.codex.dantermHooks.isEmpty == false`.

**Ideal fix.** Put one `AgentIntegration` registry in DanTermProtocol (the leaf both core and support already depend on): a case per agent carrying its id, display name, home-directory resolver, hook file list, skill subpath, and resume-command template. `KnownAgent` becomes a thin core view over it, `DoctorFacts` carries `agents: [AgentIntegrationId: Agent]`, and DoctorProber keeps one probe function mapped over the registry.

**By construction.** "An agent is known to the toolbar chip but invisible to doctor" becomes unrepresentable -- both are derived from one registry, so a new case forces every consumer to handle it.

**Cheaper fallback.** Keep the two probe functions but parameterize them into one `gatherAgentFacts(root:hookFiles:skillPaths:)`, leaving the agent list still duplicated across core, protocol, and the CLI. This removes the copied algorithm but not the divergent enumerations.

**Verification.** A DanTermSupport test that populates a temp home with a fixture directory for every registry entry and asserts `gatherDoctorFacts` returns a fact per entry; adding a registry case without touching DoctorProber must make that test cover the new agent automatically.

**Risk.** `DoctorFacts` is a public protocol type consumed by the CLI's report, so changing the two named fields to a keyed collection changes the doctor JSON shape -- external in the sense that the shipped skill documents it, so `integrations/danterm/SKILL.md` must change in the same commit.

## Area: App runtime and reconcile

_Scope: AppKit runtime: Command interpreter and reconcile passes (app/AppRuntime.swift, app/Reconcile.swift, app/ReconcileOutbox.swift, app/AppRuntimePorts.swift, app/AppRuntimeSchedulingLifecycle.swift, app/AppPresentationLifecycle.swift, app/AppDelegate.swift, app/AppLaunchPolicy.swift, app/MenuCommandPolicy.swift, app/ObserveOnMain.swift, app/main.swift)_

**Auditor's read on the area.** The reconcile layer is in good shape: every panel except one is projected from a model slot through a diffed cache, the outbox already forbids dispatching on a reporting stack, and `AppRuntimeSchedulingLifecycle` gives every timer/monitor/subscription a single census-backed teardown -- which is why I found no violation of docs/design/2026-06-09-appkit-lifetime-safety.md. The weak seams are all "two writers for one truth": restore writes `model` directly, the theme browser keeps its existence in a view field, alerts open nested modal run loops inside an open send frame, and several armed owners are stored as handle+token field pairs kept in lockstep by hand. I did not audit the pure projections in `lib/DanTermCore` beyond what the passes read, nor the sidebar driver, nor `IpcServer` internals.

<a id="runtime-1"></a>

### RUNTIME-1. Make the restore commit a Msg so `update()` is the only writer of `model`

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `app/AppRuntime.swift#commitRestoreSession`, `app/AppRuntime.swift#tearDownCurrentSession`, `app/AppRuntime.swift#bootstrapFromValidatedRestore`, `app/AppRuntime.swift#importState`

**Problem.** Restore and import replace the whole application model without going through the Elm loop. `commitRestoreSession` assigns `model = staged.model` directly, and because that assignment skips `update()`, the surrounding code hand-patches the derived state the pure layer would otherwise have produced: `tearDownCurrentSession` writes `model.todoPopover = nil` with the comment "session teardown bypasses the reconciler; clear directly", and `commitRestoreSession` calls `reconcileTabState(&model)` with the comment "Restore bypasses update(); reconcile tab state here so the first cmd-shift-i after a restore sees a populated mruOrder". Every future model invariant that `update()` establishes must be remembered a second time on this path, and nothing makes the omission visible.

**Evidence.** Only four sites in `app/` assign into `model` (grep `model = ` / `model.<field> = ` across AppRuntime.swift, Reconcile.swift, AppDelegate.swift): the two lines in `AppRuntime.init`, `model.todoPopover = nil` in `tearDownCurrentSession`, and `model = staged.model` in `commitRestoreSession`. `commitRestoreSession` then follows the assignment with `lightCheckpointBaseline = currentLightCheckpointProjection()`, `cancelCoalescedReconcile()`, `reconcileTabState(&model)`, and `sweepAndDispatchFollowUps()` -- an open-coded replay of what `dispatchInFrame` does for every other message.

**Ideal fix.** Add a `Msg` case carrying the validated restored model (for example `.sessionRestored(model:)`). `update()` installs it and runs the same normalization every other message gets (tab state, todo-popover retraction, MRU seeding) and returns one `Command` -- swap the pane-host table -- that the runtime performs by tearing down the live table and installing the staged one. `send()` then supplies the frame, the sweep, and the roster push, so `commitRestoreSession` shrinks to staging plus one `send`. `AppRuntime.model` becomes `private(set)` with `update()` as its only writer outside `init`.

**By construction.** It becomes impossible to install an application model whose derived state was never normalized by the pure layer: no code path can assign `model` except `update()`, so "restore forgot to run what update() runs" cannot be written. The `model.todoPopover = nil` and `reconcileTabState(&model)` patch-ups have nowhere to live.

**Cheaper fallback.** none -- the ideal fix is a Msg case, an update arm, and one Command arm; the staging code is unchanged.

**Verification.** Core test: send `.sessionRestored` with a snapshot-built model whose `mruOrder` is empty and whose `todoPopover` names a pane absent from the restored tree; assert the resulting model has a populated `mruOrder` and a nil `todoPopover`. App test (app-tests/AppRuntimeSessionCommandTests.swift style): drive a restore through the public bootstrap entry point and assert the live pane host table equals the staged panes and that the switcher projection is non-empty on the first `.mruCycleStepped`.

**Risk.** The restore commit currently interleaves AppKit container teardown with the model swap; moving the swap into `update()` means the host-swap command must still run before the sweep, or the first post-restore reconcile diffs against a half-swapped table.

<a id="runtime-2"></a>

### RUNTIME-2. Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `app/AppRuntime.swift#toggleThemeBrowser`, `app/Reconcile.swift#reconcileThemeBrowser`, `app/AppDelegate.swift#toggleThemeBrowser`, `app/ThemeBrowserView.swift#closeBrowser`

**Problem.** The theme browser is the one panel whose existence is pushed imperatively instead of projected from the model. `toggleThemeBrowser()` creates or removes the view, installs constraints, and then hand-calls two reconcile passes outside the ordered sweep; `reconcileThemeBrowser` must ask the view whether it exists before it can compute a projection. Because the fact lives in a view field, the browser is invisible to snapshots, to IPC, and to `update()`, and the out-of-band call pair is already asymmetric: the close path calls `reconcilePaneFocus()` and the open path does not.

**Evidence.** `toggleThemeBrowser` reads `if let existing = themeBrowserView { existing.removeFromSuperview(); themeBrowserView = nil; reconcileThemeBrowser(); reconcilePaneFocus(); return }`, and the open path ends with `themeBrowserView = browser; browser.reloadTable(); reconcileThemeBrowser()` with no `reconcilePaneFocus()`. `reconcileThemeBrowser` begins `let new = themeBrowserView == nil ? nil : desiredThemeBrowser(in: model)`, while `desiredThemeBrowser(in:)` in lib/DanTermCore/Sources/DanTermCore/Projections.swift is a total function. Compare `reconcileConfirmation`, whose `desiredConfirmation(in: model)` is itself optional and which creates `ConfirmationPanel` inside the pass.

**Ideal fix.** Add a `model.themeBrowserOpen` slot, make `desiredThemeBrowser(in:)` return `ThemeBrowserProjection?` driven by it, and let `reconcileThemeBrowser` create and insert the view on the nil -> non-nil transition and remove it on the reverse -- the `reconcileConfirmation` / `reconcilePreferencesPanel` shape. The menu action and the browser's own close button both become `send(.toggleThemeBrowser)`; `AppRuntime.toggleThemeBrowser` and the out-of-band pass calls disappear.

**By construction.** "The browser is on screen but the model does not know it" stops being representable, and so does an out-of-band pass call: the only way to change browser existence is a Msg, so every existence change runs the whole ordered sweep (including `reconcilePaneFocus`) instead of the subset a call site remembered.

**Cheaper fallback.** none -- one model flag plus moving about fifteen lines of view construction into the existing pass.

**Verification.** UI test (tests-ui/ThemeBrowserViewTests.swift): send the toggle Msg and assert the content area gains a `ThemeBrowserView` subview; send it again and assert the subview is gone and pane focus returned to the focused terminal. Core test: assert the toggle Msg flips the model slot and that `desiredThemeBrowser` is nil while it is false.

**Risk.** The browser is inserted above tab containers (`buildAndInsertContainer` positions containers below it); the pass must preserve that z-order when it creates the view, or containers can cover the browser after a tab build.

<a id="runtime-3"></a>

### RUNTIME-3. Stop opening nested modal run loops from inside an open send frame

`correctness` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `app/AppRuntimePorts.swift#live`, `app/AppRuntime.swift#presentConfigError`, `app/AppRuntime.swift#dispatchInFrame`, `app/AppDelegate.swift#applicationDidFinishLaunching`

**Problem.** `AppRuntimePorts.live`'s `presentAlert` runs `NSAlert.runModal()`, and it is reached from inside the command loop: `perform(.saveDanTermConfig)` catches a write failure and calls `presentConfigError` -> `ports.presentAlert`. `runModal` spins a nested run loop while `dispatchInFrame` is still iterating the command array a completed `update()` produced. During that loop the app's local NSEvent monitor and main-queue-delivered IPC requests can both call `send()`, which runs `update(&model, ...)` and a full `reconcile()` re-entrantly; the outer loop then resumes performing commands computed against a model version that no longer exists. The launch-time restore prompt has the same shape: `applicationDidFinishLaunching` calls `alert.runModal()` after `AppRuntime.init` has already started the IPC server, so a client request can mutate the model during the prompt and then be silently discarded by `commitRestoreSession`.

**Evidence.** `AppRuntimePorts.live` defines `presentAlert: { title, message in let alert = NSAlert(); ...; alert.runModal() }`. `AppRuntime.perform` case `.saveDanTermConfig` does `do { try configStore.save(config) } catch { presentConfigError(error) }`, and the whole `perform` loop runs inside `outbox.withFrame { dispatchInFrame(msg) }`. `AppRuntimeIpcDispatch.serve`, built in `makeIpcDispatch`, is `@MainActor` and is awaited from `IpcServer`'s connection task (`await runtimeDispatch.serve(...)`), so it lands on the main queue, which drains under the modal panel run-loop mode. The launch prompt is `let response = alert.runModal()` in `applicationDidFinishLaunching`, before `bootstrapFromValidatedRestore`.

**Ideal fix.** No command arm may block the main actor. Turn user-visible alerts into the model-projected shape the quit confirmation already uses: `update()` puts the message in a model slot, a reconcile pass shows a non-modal panel, and the button press comes back as a Msg. Where a real sheet is wanted, `presentAlert` becomes `beginSheetModal(for:completionHandler:)`, which never nests a run loop. Do the same for the restore prompt: project it from a launch model slot and let the choice arrive as a Msg, so bootstrap does not block the loop it has already started serving.

**By construction.** With no nested run loop reachable from `perform`, a second `update()` cannot begin while the first one's commands are still being performed; "commands executed against a stale model" and "a reconcile pass running inside another pass" stop being expressible from the alert paths.

**Cheaper fallback.** If the launch prompt must stay modal, start the IPC server only after the prompt resolves, so no request can be accepted against a model that is about to be replaced. This is a trade-off: it leaves the in-frame `saveDanTermConfig` alert unfixed.

**Verification.** App test: install a fake `presentAlert` port that calls `runtime.send(...)` with a model-mutating Msg before returning, drive a `saveDanTermConfig` failure, and assert the final model reflects both the config save and the injected message. After the ideal fix, assert the failure produces the alert model slot and that no port call happens inside `perform`.

**Risk.** Non-modal alerts change user-visible behavior: a failure the user currently must dismiss becomes dismissible later or ignorable. The projected panel must still be prominent enough that a config write failure is not missed.

<a id="runtime-4"></a>

### RUNTIME-4. Give each armed timer one owner instead of a handle field plus a token field

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/AppRuntime.swift#shutdown`, `app/AppRuntime.swift#scheduleLightCheckpointIfNeeded`, `app/AppRuntime.swift#applyRecoveryAction`, `app/AppRuntime.swift#cancelCoalescedReconcile`, `app/AppRuntimeSchedulingLifecycle.swift#AppRuntimeSchedulingLifecycle`

**Problem.** Five scheduled owners are each stored as two fields written in lockstep: `lightCheckpointTimer`/`lightCheckpointTimerToken`, `enrichedCheckpointTimer`/`enrichedCheckpointTimerToken`, `coalescedReconcileTimer`/`coalescedReconcileTimerToken`, `switcherEventMonitor`/`switcherEventMonitorToken`, and `ipcServer`/`ipcServerToken`. Nothing ties a pair together, so the nil-ing is hand-written at eight sites, and the scheduling guard reads only the handle (`guard lightCheckpointTimer == nil`) while cancellation goes through the token. An edit that retires one half leaves either a live timer with no census entry or a census entry whose handle is already gone.

**Evidence.** `shutdown()` ends with ten lines of `switcherEventMonitor = nil; switcherEventMonitorToken = nil; lightCheckpointTimer = nil; lightCheckpointTimerToken = nil; ...` -- pure bookkeeping after `schedulingLifecycle.shutdown()` has already fired every cancel closure. `scheduleLightCheckpointIfNeeded` guards on `lightCheckpointTimer == nil`, while `cancelCoalescedReconcile`, `flushPendingCheckpoint`, `prepareRecoveryForApplicationExit`, and the `.terminate` command arm each clear token then handle by hand. The runtime already knows the right shape: `RosterSubscriber` and `PaneTapeFollowTransport` bundle their connection with their `AppRuntimeSchedulingToken`.

**Ideal fix.** Introduce one small `@MainActor` value that owns a scheduled source and its census token together -- `ScheduledTimer` with `arm(after:handler:)`, `cancel()`, and `isArmed`, built on `AppRuntimeSchedulingLifecycle`. Each of the five sites becomes a single optional field of that type; `cancel()` retires both halves, `isArmed` answers the scheduling guard, and `shutdown()` loses its nil-ing block because the census already retired the owners.

**By construction.** A live `DispatchSourceTimer` with no census entry, and a census entry whose handle has already been dropped, both stop being representable: handle and token are created and destroyed by the same call, so no caller can leave an intermediate state behind.

**Cheaper fallback.** none -- a roughly forty-line type and mechanical replacement at the eight sites.

**Verification.** app-tests/AppRuntimeSchedulingLifecycleTests.swift style: send a coalescing Msg, assert `captureOwnerCensus()[.timer] == 1`; send a non-coalescing Msg, assert the census returns to zero and that a later coalescing Msg arms again -- the guard and the census must agree after every transition.

**Risk.** The enriched-checkpoint timer is rearmed from inside its own event handler via `applyRecoveryAction`; the new type must allow re-arming from within a handler that has just consumed its own token, or the recovery policy stops rescheduling.

<a id="runtime-5"></a>

### RUNTIME-5. Derive the previously visible tab from the reconcile cache, not from `isHidden`

`structural` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `app/Reconcile.swift#reconcileContainers`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#containerOpsStrandVisible`

**Problem.** `reconcileContainers` decides whether an in-flight pane drag must be cancelled by asking AppKit which container is currently unhidden, rather than by remembering what the previous pass applied. The reconciler's contract is that each pass diffs against a cache holding the last value it applied; here it reads the view tree back, so the decision depends on a fact the pass is about to overwrite, and on arbitrary dictionary iteration order when more than one container is momentarily unhidden (a freshly built `SplitContainerView` is unhidden until its `setVisible` op runs).

**Evidence.** `let previouslyVisibleTabId = tabContainers.first(where: { !$0.value.isHidden })?.key`, passed to `containerOpsStrandVisible(ops:previouslyVisibleTabId:)` and `containerOpsEditVisibleTree(ops:previouslyVisibleTabId:)` to decide `cancelPaneDrag()`. `ContainerShape` in ModelOperations.swift deliberately excludes visibility and `computeContainerOps` takes `selectedTabId` as a separate side input, so `caches.containerShape` alone cannot answer the question -- but nothing stops the cache bag from carrying the selection that produced it.

**Ideal fix.** Store the applied selection next to the applied shapes: add `var visibleTabId: TabId?` to `ReconcilerCaches`, pass `caches.visibleTabId` into the two stranding predicates, and set it to `model.selectedTabId` at the end of the pass alongside `caches.containerShape = new`. `ReconcilerCaches()` re-init on teardown resets it for free, matching every other cache field.

**By construction.** The reconciler can no longer read its own output back out of AppKit: the only source for "what did the last pass show" is the cache, so a view whose `isHidden` was changed by anything other than this pass cannot influence the drag-cancel decision.

**Cheaper fallback.** none -- one field and two line edits.

**Verification.** UI test (tests-ui/SplitContainerViewTests.swift or PaneWrapperViewTests.swift): with two tabs and an in-flight pane drag, select the other tab and assert the drag overlay is torn down; repeat with the selected tab's tree edited (a split) instead. Both must hold when a second container has been built but not yet hidden in the same pass.

**Risk.** The first pass after a teardown has a nil cached selection where the view scan previously found a container, so a drag started before a restore would no longer be cancelled by the first sweep -- but `tearDownCurrentSession` already calls `cancelPaneDrag()` directly, so this is covered.

<a id="runtime-6"></a>

### RUNTIME-6. Move the pane-tape follow broker out of AppRuntime into its own owner

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/AppRuntime.swift#beginPaneTapeFollow`, `app/AppRuntime.swift#finishPaneTapeFollowStart`, `app/AppRuntime.swift#deliverPaneTapeFollowBatch`, `app/AppRuntime.swift#retirePaneTapeFollowTransport`, `app/AppRuntime.swift#tearDownSession`, `app/AppRuntime.swift#shutdown`

**Problem.** `AppRuntime` is 2155 lines holding at least six unrelated jobs: the Elm dispatch frame, the Command interpreter, the IPC request registry, the pane-tape follow streaming broker, checkpoint scheduling, and restore staging. The tape broker alone is roughly 330 lines, nine private methods, two private tables, and one private struct, and its invariants (retire a transport with `run` not `cancel`; a sibling stream on the same socket must keep its notice) are enforced only by comments on runtime fields every other part of the runtime can also reach. Its lifecycle leaks into unrelated methods as well.

**Evidence.** `private var paneTapeFollowSubscriptions`, `private var paneTapeFollowTransports`, `private struct PaneTapeFollowTransport`, plus `streamFinitePaneTape`, `beginPaneTapeFollow`, `finishPaneTapeFollowStart`, `paneTapeFollowEventsAvailable`, `fetchPaneTapeFollow`, `deliverPaneTapeFollowBatch`, `failPaneTapeFollow`, `dropPaneTapeFollow`, `endPaneTapeFollowers`, `writePaneTapeFollowEnd`, and `retirePaneTapeFollowTransport` all live on `AppRuntime`. `shutdown()` contains `for subscriptionId in paneTapeFollowSubscriptions.removeAll() { retirePaneTapeFollowTransport(subscriptionId)?.close() }`, and `tearDownSession(_:)` opens with `endPaneTapeFollowers(for: paneId)`.

**Ideal fix.** Extract a `@MainActor final class PaneTapeFollowBroker` owning both tables, taking the scheduling lifecycle and a session-lookup closure at init, and exposing four entry points: `begin(reqId:paneId:...)`, `paneClosed(_:)`, `connectionClosed(_:)`, and `shutdown()`. `AppRuntime` keeps one field and forwards, so the `.streamPaneTape` arm, `tearDownSession`, `ipcConnectionClosed`, and `shutdown()` each become a one-line call. Follow on by extracting the checkpoint scheduler (`RecoveryCheckpointPolicy`, the two timers, the two capture helpers) the same way.

**By construction.** The transports table stops being reachable from unrelated runtime code, so "another method retired a transport without its notice registration" and "a sibling stream's census token was cancelled" become impossible to write outside one small type whose only exit is `retire`. The broker's shutdown obligation becomes a single visible call rather than a loop buried in `AppRuntime.shutdown()`.

**Cheaper fallback.** none -- the extraction is mechanical because the broker's state is already private and reached only through these methods.

**Verification.** Existing behavior must hold: app-tests/PaneTapeFollowEncodingTests.swift plus a census test -- open two follow streams on one connection, close one pane, assert the surviving stream still receives batches and that `captureOwnerCensus()[.subscription]` drops by exactly one; then close the connection and assert the census returns to its baseline.

**Risk.** The broker must arm its tokens on the runtime's own lifecycle; if the extraction gives it a separate one, a stream could stay armed after `AppRuntime.shutdown()`. The census test above is what catches that.

## Area: Pane views and geometry

_Scope: Pane presentation: terminal view, pane host, and pane geometry interaction_

**Auditor's read on the area.** The presentation core of this area is in good shape: `SwiftTerminalSessionView.synchronizePresentation` is a genuinely single geometry/scale detector with the display-scaling invariant stated where it binds, `SplitContainerView` applies the pure `paneLayout` and nothing else, and `PaneDividerView` reports gestures without owning a ratio. The weak seam is everything the model-owned-geometry lift did not reach: pane drag-and-drop still hit-tests live AppKit wrapper frames, and the pane wrapper still keeps its own copies of zoom/splits facts. I did not audit the terminal engine packages under `lib/`, `AppRuntime` beyond the two pane-drag/lookup entry points the area's files call, or the sidebar.

<a id="pane-1"></a>

### PANE-1. Resolve the pane drop target from the model layout, not from live wrapper frames

`structural` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `app/PaneDragCoordinator.swift#PaneDragCoordinator.updateDrag`, `app/PaneWrapperView.swift#ToolbarDragHandleView.mouseDragged`, `app/SplitContainerView.swift#SplitContainerView.reconcilePanes`, `app/AppRuntime.swift#AppRuntime.startPaneDrag`, `lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift#paneLayout`

**Problem.** Pane drag-and-drop is the one pane-geometry consumer that still derives its geometry from AppKit views instead of the model. `PaneDragCoordinator` hit-tests `wrapper.convert(wrapper.bounds, to: nil)` for each candidate pane, and nothing in that path knows which panes the model says are hidden. Under zoom the pure layout returns a frame only for the zoomed pane and puts every sibling in `hiddenPaneIds`, so the siblings keep the frames they had before the zoom -- stale rectangles that still tile the whole container. A drag started while a pane is zoomed therefore highlights and drops onto invisible panes.

**Evidence.** `paneLayout(in:tree:zoomedPaneId:)` returns `PaneLayout(paneFrames: [zoomedPaneId: bounds], dividers: [:], hiddenPaneIds: paneIds.subtracting([zoomedPaneId]))`, and `SplitContainerView.reconcilePanes` only calls `setFrameIfNeeded` `if let rect = layout.paneFrames[paneId]` -- so a hidden wrapper is merely `isHidden = true` with its pre-zoom frame intact. `AppRuntime.startPaneDrag` builds `provider = { findPaneWrapper(for: $0)?.convert(wrapper.bounds, to: nil) }`, which resolves through `paneHost(for:)?.wrapper` and never consults hiddenness, and `PaneDragCoordinator.updateDrag` accepts the first pane where `frame.contains(locationInWindow)`. The comment in `ToolbarDragHandleView.mouseDragged` states the opposite premise the flat container invalidated: "In-tab split/swap targets aren't mounted while zoomed, so those drops stay inert (PaneDragCoordinator skips nil frames)."

**Ideal fix.** Make drop-target resolution a projection of the same `PaneLayout` the container applied. Add a pure core function -- `paneDropTarget(at point: PaneLayoutRect-space point, layout: PaneLayout, excluding source: PaneId) -> PaneDrop?` -- that walks `layout.paneFrames` (which by definition excludes hidden panes) and calls the existing `resolveDropZone`. `PaneDragCoordinator` then holds the layout and a container-to-window transform instead of a frame provider, and stores one `currentDrop: PaneDrop?` in place of the parallel `currentTarget` / `currentIntent` optionals.

**By construction.** A drop onto a pane the model does not display becomes unrepresentable: the only rectangles the resolver can see are the ones the pure layout produced for visible panes, and "a target with no intent" (or an intent with no target) stops being expressible once both live in one optional value.

**Cheaper fallback.** Keep the frame provider but have it return nil for any pane in the container's hidden set, and have `SplitContainerView` publish that set. This removes the zoom bug without removing the second geometry source, so the next zoom-like presentation state reopens the class.

**Verification.** UI-harness test: build a two-pane tab, zoom one pane, start a pane drag from the zoomed pane's toolbar, drive `updatePaneDrag` to a point inside the zoomed pane's rectangle, and assert `currentPaneDrop()` is nil rather than naming the hidden sibling. Pure-core test: `paneDropTarget` over a zoomed layout returns only the zoomed pane for every point in bounds.

**Risk.** The coordinate transform must be got right once (container space to window space) instead of per-wrapper; a mistake would shift every highlight, which the harness test above catches directly.

<a id="pane-2"></a>

### PANE-2. Type the container's leaf cache as the wrapper it needs, so a missing wrapper is retried, not cached

`correctness` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `app/SplitContainerView.swift#SplitContainerView.reconcilePanes`, `app/AppRuntime.swift#AppRuntime.buildAndInsertContainer`

**Problem.** When the wrapper lookup fails, the container substitutes a bare placeholder view and stores it permanently under that pane id. Every later layout pass finds the placeholder in `leafViews`, so it never asks for the real wrapper again: the pane is a blank rectangle for the rest of the tab's life, with no error and no path back. The lookup is a weak-self closure into `AppRuntime`, so "nil" is a transient condition, not a permanent fact about the pane.

**Evidence.** `reconcilePanes` does `view = wrapperLookup(paneId) ?? NSView()` and then `leafViews[paneId] = view`, keyed `[PaneId: NSView]`; on the next pass `if let existing = leafViews[paneId] { view = existing }` short-circuits the lookup. The lookup itself is `{ [weak self] paneId in self?.paneHost(for: paneId)?.wrapper }` from `buildAndInsertContainer`.

**Ideal fix.** Declare `leafViews` as `[PaneId: PaneWrapperView]` and skip a pane whose wrapper is absent -- no placeholder, no cache entry. The next layout pass (the container already re-runs `applyModelLayout` from `layout()`) resolves it as soon as the wrapper exists.

**By construction.** The container can no longer hold a view that is not a pane's wrapper, so "a pane permanently showing a placeholder" stops being a state the cache can represent.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** UI-harness test: build a container whose lookup returns nil for one pane, force a layout pass, then make the wrapper available and force another pass; assert the pane's `PaneWrapperView` is a subview of the container and occupies the model's frame.

**Risk.** None beyond the type change; the divider path is untouched.

<a id="pane-3"></a>

### PANE-3. Record which button a press forwarded, replacing the two ad-hoc pairing booleans

`correctness` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.mouseDown`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.rightMouseUp`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.forwardPointerDown`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.forwardPointerUp`

**Problem.** Press/release pairing is encoded in two independent booleans that each cover one button. `rightButtonForwarded` exists precisely because an unpaired press or release latches the engine's button owner -- the code says so -- but the left and middle buttons have no equivalent, and `forwardPointerDown` can silently drop a press (`guard ... let cell = normalizedCell(for: event)`) that `forwardPointerUp` will still answer with a release once geometry exists. `controlClickIsActive` is a third piece of the same fact: which button the current press is being reported as.

**Evidence.** `rightMouseDown` sets `rightButtonForwarded = true` before forwarding and `rightMouseUp` does `guard rightButtonForwarded else { return }`, with the comment "an unpaired press would latch the engine's button owner and swallow the next right-click". `mouseDown` instead does `controlClickIsActive = event.modifierFlags.contains(.control); forwardPointerDown(event, button: controlClickIsActive ? .right : .left)` and `mouseUp` forwards unconditionally on the same boolean. Both `forwardPointerDown` and `forwardPointerUp` open with `guard isTornDown == false, let cell = normalizedCell(for: event) else { return }`, and `normalizedCell` returns nil whenever `displayedCellSize` or `currentDimensions` is nil.

**Ideal fix.** Hold one `forwardedButton: TerminalMouseButton?` (or a small set, if simultaneous buttons matter) written only by `forwardPointerDown` when the press actually reached the controller, and read by `forwardPointerUp` to decide both whether to send a release and which button to name. `controlClickIsActive` and `rightButtonForwarded` both disappear into it.

**By construction.** A release for a button whose press was never forwarded -- and a release naming a different button than its press -- stops being expressible, because the release reads the button out of the record the press wrote.

**Cheaper fallback.** Add the same explicit guard to the left and middle paths. Cheaper, but it keeps three booleans whose combinations include states the gesture cannot be in.

**Verification.** UI-harness test against the session view with a scripted controller: synthesize a press while the view has no resolved geometry, then give it geometry and synthesize the matching release; assert no pointer-up reached the controller. A second case: control-press, release Control, release the mouse; assert down and up both name the right button.

**Risk.** Must keep the existing behavior that a control-click still reports focus even when its press is dropped -- `mouseDown` emits `.clickedToFocus` ungated today, and that must stay ungated.

<a id="pane-4"></a>

### PANE-4. Give the pane toolbar one projection argument instead of thirteen optional parameters and two model mirrors

`api-shape` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `app/PaneWrapperView.swift#PaneWrapperView.updateToolbar`, `app/PaneWrapperView.swift#PaneWrapperView.makePaneMenu`, `app/Reconcile.swift#AppRuntime.reconcilePaneChrome`

**Problem.** The single production caller already holds one projection value and unpacks it into thirteen arguments, three of which are `Bool?` meaning "leave whatever you had". The wrapper then stores `isZoomed` and `hasSplits` as its own copies of model facts and builds the context menu from them, so the menu's zoom title and enablement come from a second source of truth rather than from the model the same menu reads for cwd and agent id. Adding a field to the projection does not force the call site to pass it, so a new toolbar fact can be silently dropped.

**Evidence.** `func updateToolbar(label:progress:isRemote:remoteLabel:agentLabel:chipTooltip:chipKind:unreadAlertCount:totalTodoCount:uncompletedTodoCount:isZoomed:hasSplits:isGridClaimed:)` with defaults for all but `label`; `reconcilePaneChrome` calls it passing exactly `render.label ... render.isGridClaimed` from one `desiredPaneToolbar` value. Inside, `if let isZoomed { self.isZoomed = isZoomed; ... }` and `if let hasSplits { self.hasSplits = hasSplits }`, and `makePaneMenu` uses them: `let zoom = wrapperItem(isZoomed ? "Unzoom Pane" : "Zoom Pane", ...); zoom.isEnabled = hasSplits || isZoomed` -- while three lines above, the same method reads `runtime?.model.pane(paneId)?.session?.cwd` straight from the model.

**Ideal fix.** Take the projection whole: `func apply(_ render: PaneToolbarRender)`. Store that one value as the wrapper's rendered state, and have `makePaneMenu` read zoom and splits from it (or from the model, as the cwd and agent items already do) instead of from separate stored booleans. Tests construct a `PaneToolbarRender` rather than relying on parameter defaults.

**By construction.** A wrapper whose menu disagrees with the toolbar it is showing, and a call site that forgets a newly added toolbar fact, both become unexpressible: there is one value, and the compiler requires all of it.

**Cheaper fallback.** Keep the parameter list but make `isZoomed`/`hasSplits`/`isGridClaimed` non-optional, so "told nothing" stops being a state. This removes the stale-mirror risk without removing the drift risk when a field is added.

**Verification.** UI-harness test: apply a projection with `isZoomed: true, hasSplits: true`, open the pane menu, and assert the item reads "Unzoom Pane" and is enabled; apply the unzoomed projection and assert it reads "Zoom Pane". Existing `PaneWrapperViewTests` cases for the grid-claim button must keep passing after being rewritten to pass a whole projection.

**Risk.** Touches every UI-harness call site that relies on defaults; those rewrites are mechanical.

<a id="pane-5"></a>

### PANE-5. Collapse the four duplicated fire-and-forget input methods into one completion-taking path

`simplification` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputKey`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendText`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputText`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputWheel`, `app/TerminalSession.swift#TerminalSession`

**Problem.** Every pane input verb exists twice -- once fire-and-forget, once with a completion -- giving four verbs, eight protocol requirements, eight implementations in the session view, four default implementations, and a matching pair in each shim. The two forms of a verb must stay behaviorally identical by hand, and they already differ in one place: the unmappable-key rejection is expressed in the completion form and expressed as a silent `return` in the other, while the protocol's default extension answers `.delivered` for an input the fire-and-forget form may have dropped.

**Evidence.** In the session view: `func sendInputKey(_ key: KeyName, modifiers: KeyMods) { guard let key = Self.terminalKey(for: key) else { return } ... }` beside `func sendInputKey(_:modifiers:onCompletion:) { guard let key = ... else { ... onCompletion(.rejected) ... } ... }`; the same doubling for `sendText`, `sendInputText`, `sendInputWheel`. `TerminalSession`'s extension defines each completion form as `sendX(...); DispatchQueue.main.async { MainActor.assumeIsolated { onCompletion(.delivered) } }` -- a report that cannot know whether the call it wrapped delivered anything.

**Ideal fix.** One requirement per verb, with an optional completion: `func sendInputKey(_ key: KeyName, modifiers: KeyMods, onCompletion: (@MainActor @Sendable (TerminalInputSubmissionResult) -> Void)?)`. Better still, one requirement total -- `func send(_ input: PaneInput, onCompletion: ...)` over a `PaneInput` enum with `.text`, `.paste`, `.key`, `.wheel` cases -- so a new input kind adds one enum case rather than two protocol requirements, two implementations, and one default.

**By construction.** Two forms of one verb cannot disagree about what they reject, and no default implementation can claim `.delivered` for a submission it did not observe, because there is only one submission path to observe.

**Cheaper fallback.** Keep the four verbs but delete the fire-and-forget requirements, letting callers pass an ignoring completion. Halves the surface without introducing the input value type.

**Verification.** Existing IPC-level behavior tests for `input`/`text` submission results must pass unchanged; add one asserting that an unmappable key name reports `.rejected` on every entry point that reports at all.

**Risk.** Touches the `TerminalSession` protocol and both UI-harness shims; the compiler enumerates every site, and no observable IPC behavior changes.

## Area: Window chrome and auxiliary UI

_Scope: Window chrome and auxiliary UI (sidebar, TODO/alerts popovers, preferences, confirmation, theme browser, chips, chrome bar)_

**Auditor's read on the area.** Most of this area is in good shape: the chip stack (ChipArtwork/ChipRenderer/ChipView), SingleLineLabel, SidebarCellViews, SidebarReconcileDriver, and SidebarView's rename slot are careful, well-owned code with their invariants written down. The weak spots are all at boundaries where a typed fact is flattened before it crosses: the two TODO popover controllers share an abstract base Swift cannot check, ConfirmationPanel re-derives which answer it is sending from a button's visibility, sidebar menu items carry bare UUIDs, and PreferencesPanel addresses grid rows by literal index. I did not audit TerminalPaneView/PaneWrapper or Reconcile.swift/AppRuntime.swift themselves (other owners), citing them only as call sites; I also did not review layout constants or visual design.

<a id="chrome-1"></a>

### CHROME-1. Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value

`structural` &middot; impact 5, confidence 5 &middot; effort large

**Files.** `app/TodoPopoverControllerBase.swift#TodoPopoverControllerBase`, `app/TodoPopoverView.swift#TodoPopoverViewController`, `app/TabTodoPopoverView.swift#TabTodoPopoverViewController`

**Problem.** TodoPopoverControllerBase emulates an abstract class with about twenty members whose bodies are `fatalError("subclass must override")`. Swift cannot check that emulation: an added member, or a third TODO scope, compiles and traps at runtime instead of failing to build. The two concrete subclasses then re-implement the same algorithm twice -- projection apply with first-responder capture and restore, selection preservation across every mutating Msg, list key handling, and the Cmd-key equivalent table -- differing only in the row type, the edit-target type, and the TodoOwner they send to. That duplication has already drifted.

**Evidence.** TodoPopoverControllerBase declares `composeDraft`, `clearComposeDraft()`, `isEditing`, `applyStoredProjection()`, `saveEditThenReturnToList()`, `addTodoAndStayInCompose()`, `cancelEditAndReturnToList()`, `enterEditForSelectedRow()`, `focusListFromInput()`, `closePopoverFromList()`, `handleListKeyDown(_:)`, `performTodoKeyEquivalent(with:)`, `syncModeVisibility()`, `parentTodoPopover`, `shortcutHelpScope`, `clearCompleted()`, `headerTitle`, `tableColumnIdentifier`, `registerDragTypes(on:)`, `numberOfRows(in:)` -- every one a `fatalError` override point. `TodoPopoverViewController.apply(_:)` and `TabTodoPopoverViewController.apply(_:)` are the same sequence (capture five first-responder booleans, save the edit draft, swap the projection, reconcile the edit target, reload, restore selection, `restoreFirstResponder(...)`). Drift is already visible: `TodoPopoverViewController.selectNearestSelectableRow(near:focus:)` searches backwards only (`delta: -1`) while the tab version searches forward then backward; `TodoPopoverViewController.cancelEditAndReturnToList()` calls `makeFirstResponder(tableView)` even when `selectTodo(id:)` returned false, while `TabTodoPopoverViewController.cancelEditAndReturnToList()` falls back to `focusListFromInput()`. The split leaks outward too: `AppRuntime.closeTodoShortcutHelpPopover()` casts the same content view controller twice, once per subclass, to call a method that lives on the base.

**Ideal fix.** Keep one non-generic `TodoPopoverViewController` (so @objc actions and delegate methods stay legal) and move everything scope-specific into a `TodoPopoverScope` protocol value the controller holds: it vends rows as a uniform row description (optional item, isSelectable, isHeader, an opaque edit-target token), answers headerTitle / composePlaceholder / shortcutHelpScope / drag type, and builds the Msgs (add, edit, toggle, delete, reorder, move, clearCompleted, closePopover) for a target. Pane and tab become two conforming values, not two subclasses; apply, focus restore, selection preservation, list-key routing, and Cmd-key handling exist once. Reconcile's two-case applyTodoPopover switch and AppRuntime's double cast collapse to one call.

**By construction.** "A TODO popover forgot to override a required member" and "the pane and tab popovers behave differently in a case nobody meant them to differ" both stop being expressible: there is one implementation of the algorithm and no unimplemented member to forget. A future third scope becomes a value, not a class that can silently trap.

**Cheaper fallback.** If a scope value proves awkward for the tab's grouped drag/drop, keep the subclass split but delete every fatalError member that has a sane default and make the remaining ones a protocol the concrete class must satisfy, so a missing implementation is a compile error rather than a trap. That leaves the duplicated apply/selection algorithm in place, which is where the drift actually lives.

**Verification.** Extend tests-ui/TodoPopoverViewTests.swift and tests-ui/TabTodoPopoverViewTests.swift with the same behavioral scenarios run against both scopes: delete the selected row and assert the selection lands on a neighbour; cancel an edit whose item was removed and assert focus lands somewhere valid; Cmd-N from list mode focuses compose. Both suites must pass unchanged after the refactor, and today the shared cases expose the two drifts above.

**Risk.** Large, and it touches the most keyboard-sensitive surface in the app; drag/drop and focus restoration are easy to regress. Mitigate by first driving the two existing UI suites to cover the shared behaviors, then refactoring under them.

<a id="chrome-2"></a>

### CHROME-2. Make the confirmation projection carry each button's answer instead of inferring it from button visibility

`correctness` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `app/ConfirmationPanel.swift#confirm`, `app/ConfirmationPanel.swift#configure`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#ConfirmationProjection`

**Problem.** The panel decides which Msg the primary button sends by reading its own view state. ConfirmationProjection carries only titles, so "this confirmation has a secondary button" is being used as a stand-in for "this confirmation is a delete-group transaction". Any future confirmation that wants a third choice, or a two-button quit variant, silently answers as a delete-group.

**Evidence.** `configure(_:)` sets `secondaryButton.isHidden = projection.secondaryTitle == nil`. `confirm(_:)` reads that flag back: `if secondaryButton.isHidden { runtime?.send(.confirmConfirmation(id: transactionId)) } else { runtime?.send(.chooseDeleteGroupConfirmation(id: transactionId, moveTabs: true)) }`, and `chooseCloseTabs(_:)` hardcodes `.chooseDeleteGroupConfirmation(id:, moveTabs: false)`. `ConfirmationProjection` in Projections.swift holds exactly id, title, informativeText, commands, confirmTitle, secondaryTitle -- no answer semantics at all.

**Ideal fix.** Give the projection a typed answer per button: a `ConfirmationAnswer` enum (confirm, deleteGroupMovingTabs, deleteGroupClosingTabs, ...) paired with each title, so a button is a (title, answer) pair. The panel's three actions collapse into one `answer(_:)` that sends `.answerConfirmation(id:, answer:)`; the reducer switches on the answer. The panel no longer knows any transaction kind exists.

**By construction.** It becomes impossible for the panel to send an answer that does not belong to the confirmation it is showing, because the only answers it can send are the ones the projection handed it. "Button visibility means transaction kind" ceases to be a rule anyone can break.

**Cheaper fallback.** None -- the ideal fix is small: one enum, one Msg case, and three action bodies become one.

**Verification.** In tests-ui/ConfirmationPanelTests.swift, configure the panel with a quit projection that has a secondary title and assert the primary button dispatches the quit answer, not the delete-group one. That test fails today.

**Risk.** Low. One projection field, one reducer switch, and the existing panel tests cover the current two flows.

<a id="chrome-3"></a>

### CHROME-3. Carry typed ids in sidebar menu items instead of bare UUIDs

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `app/SidebarView.swift#contextMenu`, `app/SidebarView.swift#contextNewTab`, `app/SidebarView.swift#contextRenameTab`, `app/SidebarView.swift#contextRenameGroup`

**Problem.** AGENTS.md says entity ids are phantom-typed so the compiler rejects passing one where another is expected, but the sidebar's context menus launder them through `NSMenuItem.representedObject` as raw UUID and re-wrap them in the handler. TabId and GroupId are both UUID-backed, so wiring a group menu item to a tab action (or the reverse) compiles, passes AppKit validation, and acts on the wrong entity -- or on nothing -- with no diagnostic. The pairing of an item's action with its payload is enforced only by reading the two lines side by side.

**Evidence.** `contextMenu(forGroupId:)` sets `newTabItem.representedObject = groupId.rawValue`, `renameItem.representedObject = groupId.rawValue`, `deleteItem.representedObject = groupId.rawValue`; `contextMenu(forTabId:clickedRow:)` sets `renameItem.representedObject = tabId.rawValue`. Each handler does `guard let rawId = sender.representedObject as? UUID` and re-types it: `GroupId(rawValue: rawId)` in `contextNewTab`, `contextRenameGroup`, `contextDeleteGroup`; `TabId(rawValue: rawId)` in `contextRenameTab`. The multi-tab items already do better with `TabIdsBox` and `SetTabColorsInfo`, so the file carries both patterns side by side.

**Ideal fix.** Box one payload type for the whole menu: a `final class SidebarMenuCommand` whose `Intent` enum carries the typed ids (`newTab(GroupId)`, `renameGroup(GroupId)`, `deleteGroup(GroupId)`, `renameTab(TabId)`, `setColors([TabId], TabColor?)`, `clearTitles([TabId])`, ...). Every item points at one `@objc func performSidebarCommand(_:)` that switches exhaustively on the intent and sends the matching Msg. Item construction names the intent, not an action selector plus a loose payload.

**By construction.** A menu item whose payload does not match the action it triggers stops being expressible: there is one action, and the payload is a typed enum case naming both the operation and the id type it needs. Adding a sidebar menu command becomes an exhaustive-switch obligation instead of a hand-matched pair.

**Cheaper fallback.** Keep the per-action selectors but box each id in a typed wrapper class (GroupIdBox, TabIdBox) so the `as?` in the handler rejects a mismatched payload at runtime. That turns a silent wrong-entity action into a no-op -- better, but still not a compile-time guarantee.

**Verification.** In tests-ui/SidebarContextMenuTests.swift, build the group menu, invoke each item's action against a recording runtime, and assert the dispatched Msg names the clicked group; do the same for the tab menu. After the fix a cross-wired item fails to compile.

**Risk.** Medium. Mechanical, but it touches every context-menu action; the existing menu tests plus per-item dispatch assertions cover it.

<a id="chrome-4"></a>

### CHROME-4. Build the preferences grid from declared rows so warning rows and padding stop being addressed by literal index

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/PreferencesPanel.swift#buildUI`

**Problem.** The settings form is one positional `NSGridView(views:)` array, and six statements then reach back into it by literal row number to attach padding and capture the three warning rows. Inserting, removing, or reordering a settings row silently retargets all six: the panel would pad the wrong row and hide the wrong warning, with no compile error and no visible failure until someone opens Settings with a bad font configured. The file already shows awareness of this hazard -- the width loop runs over `0..<grid.numberOfRows` with a comment saying every row is constrained "so reordering or removing a row cannot silently drop it" -- yet the warning rows beside it stay index-addressed.

**Evidence.** After the ten-entry `NSGridView(views:)` literal: `grid.row(at: 5).topPadding = 8`, `grid.row(at: 7).topPadding = 8`, `grid.row(at: 9).topPadding = 4`, `themeWarningRow = grid.row(at: 1)`, `fontFamilyWarningRow = grid.row(at: 3)`, `remoteThemeWarningRow = grid.row(at: 8)`. The indices are correct today (Theme=0, themeWarning=1, Font Family=2, fontFamilyWarning=3, Font Size=4, Clear Alerts=5, copyOnSelect=6, Remote Theme=7, remoteThemeWarning=8, Config file=9) -- correct only by counting.

**Ideal fix.** Describe the form as a list of row descriptors (label, control, optional warning label, optional top padding) and build the grid by appending them with `NSGridView.addRow(with:)`, which returns the NSGridRow it just added. Capture the warning row and apply the padding from that returned object as the row is created, and apply the control-column width constraint in the same pass; no index is ever written down.

**By construction.** "A settings row was reordered and the warning row or padding now points at the wrong row" stops being expressible, because no code names a row position: each row's handle comes from creating that row.

**Cheaper fallback.** Keep the array literal but look each special row up by identity -- find the row containing a given warning label -- instead of by number. That removes the silent-retarget failure without restructuring the builder, at the cost of a lookup helper.

**Verification.** In tests-ui/PreferencesPanelTests.swift, apply a projection with only `fontFamilyWarning` set and assert the font-family warning label is visible while both other warning labels stay hidden; then add a settings row to the form in the same commit and re-run -- the test must still pass.

**Risk.** Low. Layout-only, and the panel sizes itself from its content, so a mistake shows immediately in the UI harness.

<a id="chrome-5"></a>

### CHROME-5. Extract the theme list (filter, selection, cell vending) shared by the browser and the picker sheet

`simplification` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/ThemeBrowserView.swift#searchChanged`, `app/RemoteThemePickerSheet.swift#searchChanged`, `app/ThemeSwatchViews.swift#themeCell`

**Problem.** Two surfaces present the same theme catalog and each keeps its own copy of the list state and the algorithms over it: the name array, the filtered array, the case-insensitive filter, the reselect-after-filter step, the table column setup, and the current-theme row lookup. Only the commit gesture genuinely differs -- the browser applies on selection change, the sheet applies on Select or double-click. The cell body was already factored into `ThemeBrowserCellView.themeCell`, so what remains duplicated is the state machine around it, which is exactly where the two have already diverged.

**Evidence.** `ThemeBrowserView.searchChanged(_:)` and `RemoteThemePickerSheet.searchChanged(_:)` are the same five lines (`trimmingCharacters(in: .whitespaces).lowercased()`, empty-query reset, `allNames.filter { $0.lowercased().contains(query) }`, `reloadData()`, `selectCurrentThemeRow()`). Both types declare `allNames` / `filteredNames`, both build `NSTableColumn(identifier: "ThemeName")` with `rowHeight = 24` and `intercellSpacing = .zero`, both implement `numberOfRows(in:)` over `filteredNames`, and both implement `selectCurrentThemeRow()` -- with different bodies: the sheet's also drives `selectButton.isEnabled`, the browser's short-circuits on `tableView.selectedRow != idx`. Both `viewFor` bodies call `ThemeBrowserCellView.themeCell` differing only in reuse identifier.

**Ideal fix.** One `ThemeListController` owning allNames, the filter query, the current theme name, and the table's data source and delegate; it exposes `apply(currentThemeName:)`, `filter(_:)`, and an `onActivate: (String) -> Void`. The browser embeds it with activate-on-selection, the sheet with activate-on-commit plus an observer for Select-button enablement. The filter and reselect algorithms then exist once.

**By construction.** "The two theme lists filter or reselect differently" stops being expressible: there is one filter and one selection rule, and a host can only choose what happens when a theme is activated.

**Cheaper fallback.** If embedding a controller inside the sheet's lifecycle is awkward, at minimum move the filter and the current-row lookup into free functions over `[String]` (they are pure) and have both call sites use them, leaving only the AppKit wiring duplicated.

**Verification.** tests-ui/ThemeBrowserViewTests.swift and tests-ui/RemoteThemePickerSheetTests.swift both exist; add the same scenario to each (type a query that excludes the current theme, assert selection state, clear the query, assert the current theme is reselected) and require both suites to pass unchanged after the extraction.

**Risk.** Medium. The sheet's Select-button enablement and the browser's apply-on-selection are genuinely different behaviors that must stay separate; both have UI test coverage.

<a id="chrome-6"></a>

### CHROME-6. Give the alerts popover a typed, reusable row cell and stop computing row age at build time

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `app/AlertsPopoverView.swift#makeAlertRow`, `app/AlertsPopoverView.swift#relativeTime`, `app/AlertsPopoverView.swift#apply`

**Problem.** Every alert row is assembled from scratch on every reload -- six subviews and about twenty constraints per row, with no reuse identifier -- which is the one place in this area that ignores the typed-cell pattern the rest of the app uses (SidebarTabCellView, SidebarGroupCellView, TodoRowView, ThemeBrowserCellView). The same ad-hoc construction bakes the relative timestamp into the view at build time, so an open popover's "now" or "5m" labels are frozen until some unrelated model change re-pushes the projection; nothing in the runtime reconciles on a clock tick.

**Evidence.** `makeAlertRow(_:)` returns a bare `NSView` built from an `NSImageView`, two `NSTextField`s, a `SingleLineLabel`, a dot `NSView`, and an `NSBox`, then activates the full constraint set -- and never sets an `identifier`, so `tableView(_:viewFor:)` cannot reuse it. `apply(_:)` ends with an unconditional `tableView.reloadData()`. The time text comes from `relativeTime(alert.createdAt)`, evaluated once inside `makeAlertRow`; `AlertsPopoverProjection` carries `createdAt: Date` per row (Projections.swift) and nothing re-renders on a timer.

**Ideal fix.** Add an `AlertRowCellView` in the SidebarCellViews mould -- it owns its whole view tree once and exposes a single `apply(_ row: AlertRowProjection)` -- and vend it through `makeView(withIdentifier:)`. For the timestamp, project the display string in the core alongside the other row text (the model already owns wall clock through CoreEnv), so a row's age is a projected fact that changes when the projection changes, exactly like the unread flag.

**By construction.** With the age projected, "a row shows a time that no longer matches the model" stops being expressible -- the label is a projected string, not a value computed during view construction. The typed cell also removes the class of bug where a rebuilt row keeps a stale subview because one path forgot to set it.

**Cheaper fallback.** Keep the view-side `relativeTime` but drive a refresh while the popover is open (recompute the visible rows' time labels on a coarse timer owned by the controller and torn down in `viewWillDisappear`). That fixes the staleness without moving the clock read, at the cost of a timer where a projection would do.

**Verification.** In tests-ui/AlertsPopoverViewTests.swift, apply a projection twice with different row content and assert the row views are the same reused instances carrying the new text; and assert a row's time text equals the value the projection supplies rather than one derived at construction.

**Risk.** Low. The row is presentation-only; the main care is keeping click-to-activate working with reused cells, since it currently rides `tableViewSelectionDidChange` with `selectionHighlightStyle = .none`.

## Area: PTY host and session boundary

_Scope: Process lifecycle and the engine/app session boundary (lib/TerminalPTY, app/TerminalSession.swift, DanTermCore boundary files)_

**Auditor's read on the area.** The lifecycle reducer (PaneProcessLifecycle.swift) and the launch policy are genuinely clean: pure, exhaustively cased, and well covered by LifecycleReducerTests/LaunchPolicyTests. InFlightLaunch and ResizeCoalescer are exemplary -- each is a single ownership rule in its own file with the argument written down. The tests do not re-implement production; the spawner, exit probe, and resource-lifecycle protocols are real injected seams and the suite drives real PTY descriptors through them (scripts/terminal-pty-host-test-seam-lint.sh enforces that). The weight of my findings is in TerminalPTYHost.swift, where several facts are stored twice and two teardown paths hand-enumerate the same source set. I did not audit rendering, the flight recorder's internals, DoctorPermissionProber (self-contained and outside process lifecycle in any meaningful sense), or TerminalHostTools' two standalone executables.

<a id="pty-1"></a>

### PTY-1. Cancel every retained dispatch source from the one registry that already holds them

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#exitBoundElapsed`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#finishTeardown`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#retainUntilCancellation`

**Problem.** The host owns seven dispatch sources (read, write, process, child-exit poll, grace, session poll, exit bound) and two independent teardown paths each hand-enumerate all of them. `exitBoundElapsed` and `finishTeardown` are the same ladder written twice in a different order. A source added later must be remembered in both, and nothing makes that failure visible: a forgotten cancel leaks a live timer or descriptor source past the point the host reports irreversible quiescence, which is exactly the guarantee `whenQuiescent` exists to make.

**Evidence.** `exitBoundElapsed` runs `cancelExitBound(); cancelGrace(); cancelSessionPoll(); cancelProcessSource(); cancelChildExitPoll(); closeMaster()` (closeMaster cancels read and write). `finishTeardown` runs the identical set: `cancelExitBound(); closeMaster(); cancelGrace(); cancelSessionPoll(); cancelProcessSource(); cancelChildExitPoll()`. Meanwhile `retainUntilCancellation(_:descriptorBacked:)` already stores *every* source in `retainedSources[id]`, and `completeTeardownIfPossible` already gates completion on `retainedSources.isEmpty`, so the registry is the authority on what exists but is not the thing the cancel paths iterate.

**Ideal fix.** Make `retainUntilCancellation` the sole place a source is remembered, and store beside each entry what its cancel needs: whether it has been activated (libdispatch requires resume before cancel -- `cancelReadSource` and `cancelProcessSource` both open-code that), and a closure that clears the typed field (`readSource = nil`, etc.). Both teardown paths then become one `cancelAllRetainedSources()` that walks `retainedSources`. Adding an eighth source registers it once and is cancelled by both paths without either being edited.

**By construction.** A teardown path that cancels only some of the host's sources becomes unrepresentable: there is one enumeration of "sources this host owns", and it is the same collection that `completeTeardownIfPossible` waits on, so "registered but not cancelled" and "cancelled but still counted" cannot diverge.

**Cheaper fallback.** none -- the ideal fix is medium and mechanical; the registry and its id already exist.

**Verification.** The existing resource-census assertions already state the behavior: after `close()` and after `forceExitBoundForTesting()`, `resourceSnapshot().isReleased` must hold (activeSourceCount == 0, hasOpenMaster == false). Add a third source-bearing scenario -- a host torn down while its child-exit poll and session poll are both armed -- and assert `isReleased` on both the ordinary and the forced-quiescence path.

**Risk.** Read and process sources must still be activated before cancellation, and the master close barrier still depends on `descriptorSourceIDs`; both facts must move into the registry entry rather than being dropped.

<a id="pty-2"></a>

### PTY-2. Give TerminalPTYHost its geometry from the launch input instead of storing a second copy

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#start`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#init`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift#TerminalPaneLaunchConfiguration`

**Problem.** The pane's initial grid is stored twice -- once as `TerminalPTYHost.initialDimensions` (used to build the Terminal) and once inside `LaunchPolicyInput.initialDimensions` (used to size the PTY at spawn). Because they can disagree, `start` has to reconcile them, and the way it does so is to silently rewrite the caller's value to a sentinel 0x0 so the pure reducer will reject it. A caller who passes a valid but different grid gets `.launchFailed(.invalidDimensions)` -- a diagnosis that is simply false about the input it was handed.

**Evidence.** `start(_:)` reads: `guard input.initialDimensions == initialDimensions else { var invalidInput = input; invalidInput.initialDimensions = .init(columns: 0, rows: 0); process(.start(invalidInput)); return }`. `resolveLaunchPlan` then fails on `input.initialDimensions.isValid`. `TerminalPaneLaunchConfiguration` already solved the same problem the right way one layer up -- its `initialDimensions` is a computed property over `launchInput`, with the comment "a second copy could only ever be a launch failure waiting to happen" -- so the host is the last place holding the duplicate.

**Ideal fix.** Move the launch input into `TerminalPTYHost.init`, which needs a grid at construction anyway to build the `Terminal`, and drop the parameter from `start()` (it becomes `start()` with no argument, or the host stores the input and `submitStart()` kicks it). The stored `initialDimensions` then *is* `launchInput.initialDimensions`; the mismatch guard and the 0x0 poisoning both delete.

**By construction.** "A host whose terminal grid and whose child's PTY grid disagree" stops being expressible, and with it the whole class of launch failures that report the wrong reason.

**Cheaper fallback.** If some caller genuinely must build a host before it knows its launch input, keep the two-step construction but make the mismatch a `preconditionFailure` rather than a fabricated `.invalidDimensions` result -- it is a programming error, not a launch failure. Say plainly that this is the trade-off: it keeps the duplicate fact alive.

**Verification.** `TerminalPaneSessionControllerTests` and `TerminalPTYHostTests` both already assert `.launchFailed(.invalidDimensions)` for a 0x0 input; those keep passing because 0x0 is still genuinely invalid. The new behavioral assertion is that a host constructed from a launch input carrying, say, 100x30 starts a child whose `TIOCGWINSZ` reports 100x30 -- readable today through the childless PTY channel fixture, which already inspects the winsize the host installs.

**Risk.** `TerminalPaneSessionController.init(host:launchInput:)` is the package/test constructor that currently lets the two be supplied separately; the tests that use it need reshaping to build the host from the input.

<a id="pty-3"></a>

### PTY-3. Record every applied transition on the flight tape and delete the five parallel capture buffers

`simplification` &middot; impact 4, confidence 4 &middot; effort large

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyOutput`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#execute`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyResize`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#neutralEvents`

**Problem.** The host runs two recorders over the same event vocabulary. The always-on `flightTape` records `.feed`, `.write`, and `.resize`. Behind the `captureTransitions` flag, five more buffers record overlapping slices of the same stream -- `appliedTransitions`, `capturedOutput`, `capturedInputWrites`, `capturedReplyWrites`, `capturedSubmittedTransitions` -- updated at eight separate `if captureTransitions` sites scattered through the shipping input, output, resize and pointer paths. `capturedOutput` is a concatenation of `appliedTransitions`' `.feed` payloads; `capturedInputWrites` is `capturedSubmittedTransitions` filtered to `.input`. A new transition kind has to be threaded into whichever subset of the six a future reader happens to consult, and nothing forces them to agree.

**Evidence.** `TerminalPTYAppliedTransition` has cases feed/input/paste/focus/mouse/resize/scrollByRows/scrollToTopRow/scrollToBottom. `NeutralTerminalRecordingEvent` -- what the flight tape already stores -- has exactly those plus `.write` and `.checkpoint`, and `TerminalPaneSessionController.neutralEvents(_:)` is a pure 1:1 translation between the two. In `applyOutput` the two recorders sit four lines apart: `flightTape.record(.feed(bytes))` at the top, then `if captureTransitions { capturedOutput.append(contentsOf: bytes); appliedTransitions.append(.feed(bytes)) }` at the bottom. `applyResize` does the same with `flightTape.record(.resize(...))` and `appliedTransitions.append(.resize(grid))`.

**Ideal fix.** Record the remaining transition kinds (`.input`, `.paste`, `.focus`, `.mouse`, `.viewport`) on `flightTape` at the same points that record them into `appliedTransitions` today, and make `captureTransitions` select an unbounded recorder configuration rather than a second set of buffers -- the `flightTapeConfiguration` knob already exists and the test suite already uses it to control retention. `TerminalPTYAppliedTransition`, the five buffers, the eight branch sites, the four test-only accessors, and `neutralEvents(_:)` all delete; the characterization recording is built from a tape capture.

**By construction.** Two logs of the same pane's transitions cannot disagree about order or content, because there is one log. A transition kind added to the vocabulary is recorded in one place or in none.

**Cheaper fallback.** If unbounded tape retention proves too costly for the characterization app build, keep one ordered `[NeutralTerminalRecordingEvent]` log behind the flag and derive `outputBytes`, `inputWrites`, `replyWrites`, and `submittedTransitions` from it as computed projections. That still collapses five stores into one; it just keeps two recorders instead of one.

**Verification.** `TerminalPTYHostTests` already asserts recording equality by building a `NeutralTerminalRecording` from `host.transitions()` and comparing whole values after replay; keep those assertions and source the events from the tape capture instead. Add one behavioral test that a key press, a paste, a pointer drag, and a resize all appear in `flightRecordingCapture()` in the order the owner applied them.

**Risk.** The two recorders observe at different points -- the tape records `.write` after the bytes cross the descriptor and split at submission boundaries, while `capturedInputWrites` records at command emission before nonblocking IO splits them. Tests that assert pre-split write shapes need restating against post-split spans, or the tape needs both events.

<a id="pty-4"></a>

### PTY-4. Read the PTY through one loop instead of one per drain reason

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readReady`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#drainCommittedOutput`

**Problem.** The host reads the master descriptor with two hand-written loops that differ only in what bounds them. Each allocates its own 16 KiB buffer, each open-codes the EINTR retry, each decides independently what counts as end of output. The EOF rules already differ -- `readReady` treats `result == 0` and `errno == EIO` as the end-of-output edge, while `drainCommittedOutput` treats any non-EINTR error including EIO as a plain `break` -- and a future fix to one loop's error handling has no reason to reach the other.

**Evidence.** `readReady` loops `while bytesReadThisTurn < turnLimit` over `Darwin.read(masterFD, ...)`, handling `result > 0`, `result == 0 || errno == EIO`, and `errno == EINTR`. `drainCommittedOutput` loops `while remaining > 0` over the same call with the same `buffer.withUnsafeMutableBytes` shape, handling `result > 0`, `errno == EINTR`, and `else { break }`. Both feed the reducer with `process(.output(Array(buffer.prefix(result))))`.

**Ideal fix.** One private `readChunks(upTo:)` that owns the buffer, the EINTR retry, and the EOF classification, and returns why it stopped (`.limitReached`, `.wouldBlock`, `.endOfOutput`). `readReady` calls it with the turn limit and cancels the read source on `.endOfOutput`; `drainCommittedOutput` calls it with the FIONREAD count and reports `.outputEOF` unconditionally, as it does today.

**By construction.** "Two read paths that disagree about what EIO means" stops being expressible: there is one classification of a read result and both callers consume it.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The existing childless-channel tests cover both edges behaviorally: closing the child end must produce `.rejected(.writeFailed(EIO))` for a queued submission and drive the descriptor source count to zero, and a child that exits with output still in the buffer must have that output present in the final snapshot (`__FRAGMENTED_DONE__` case). Both must keep passing unchanged.

**Risk.** Low. The one behavioral decision to make explicit is whether `drainCommittedOutput` should adopt `readReady`'s EIO-is-EOF rule; it reports `.outputEOF` on that path anyway, so the observable result is the same.

<a id="pty-5"></a>

### PTY-5. Dedupe grid submissions on the applied fact, not on an optimistic mirror in the controller

`correctness` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#setGridDimensions`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyResize`

**Problem.** `TerminalPaneSessionController.lastSubmittedGrid` is a main-actor mirror of "the grid the engine is running at", but it is advanced at submission time while the authority -- `applyResize` on the owner queue -- is free to decline. When it declines, the mirror is permanently wrong and the dedupe guard then swallows every later attempt to submit that same grid, so the pane can never recover the geometry it believes it already has.

**Evidence.** `setGridDimensions` does `guard isTornDown == false, submission != lastSubmittedGrid else { return }` then `lastSubmittedGrid = submission; host.resize(submission)`. `applyResize` opens with `guard descriptorOwnershipSealed == false, masterFD >= 0 else { return }` and then `guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { return }` -- three ways to return before `terminal.resize` and before `flightTape.record(.resize(...))`. Nothing reports the refusal back, so the controller keeps `lastSubmittedGrid` at a grid the terminal never adopted.

**Ideal fix.** Delete `lastSubmittedGrid`. The host already knows the applied geometry fact whole -- it is what `flightTape.record(.resize(columns:rows:pinned:))` states -- so make `applyResize` the deduping authority: it compares the submission against the last *applied* grid-and-pinnedness and does nothing when they match. Submission-rate control is not what this guard buys anyway; `ResizeCoalescer` already collapses a drag into as many reflows as the owner can afford.

**By construction.** "The pane believes it submitted a grid the engine never applied" becomes unrepresentable, because the only record of what has been submitted is the record of what was applied.

**Cheaper fallback.** Keep the controller-side guard but set `lastSubmittedGrid` only from a value the host reports back as applied (it can ride the update signal alongside `primaryHistoryGeneration`). This is a trade-off: it keeps a mirror alive and only shortens the window in which it is wrong.

**Verification.** Behavioral test through the existing childless PTY channel: submit a grid while the child end is closed (so `applyResize` returns early), then reopen and submit the same grid again, and assert the terminal's reported columns/rows change. Today the second submission is swallowed and the assertion fails.

**Risk.** Moving the dedupe onto the owner queue means every submission crosses the queue, which is a change in submission traffic during a drag; `ResizeCoalescer` already bounds the work that traffic causes, but the change should be measured against the drag workload before it lands.

<a id="pty-6"></a>

### PTY-6. Give viewport navigation its own three-case type instead of a nine-case enum guarded by preconditionFailure

`api-shape` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyViewportNavigation`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYAppliedTransition`

**Problem.** `applyViewportNavigation` takes the full nine-case `TerminalPTYAppliedTransition` but accepts only three of them, and enforces that at runtime with a `preconditionFailure` -- a crash in a shipping pane, reachable from any future call site that passes the wrong case. The parameter type is documenting a contract the compiler could enforce instead.

**Evidence.** The function's switch ends with `case .feed, .input, .paste, .focus, .mouse, .resize: preconditionFailure("applyViewportNavigation takes only .scrollByRows, .scrollToTopRow, .scrollToBottom")`. It is called with a literal case at five sites (`send`, `applyKey`, `applyPaste`, `scroll(byRows:)`, `scroll(toTopRow:)`, `scrollToBottom`, `applyWheel`, and the test interaction switch), so the wide type buys nothing at any of them.

**Ideal fix.** Declare a three-case `ViewportNavigation { case byRows(Int); case toTopRow(Int); case toBottom }`, take that as the parameter, and map it to a `TerminalPTYAppliedTransition` only where the transition is appended for capture. The `preconditionFailure` and its six dead cases delete.

**By construction.** Passing a non-navigation transition to the navigation path stops compiling, so the crash it currently guards against cannot be written.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** Existing behavior must not move: `TerminalPTYHostTests` already asserts that a scroll that changes the projection appears in `transitions()` as `.scrollByRows(-1)` and that a key press snaps the viewport to the bottom before writing. Both keep passing unchanged.

**Risk.** None beyond mechanical churn; `NeutralTerminalViewportNavigation` in TerminalCoreRecording already has this exact shape, so the mapping in `neutralEvents(_:)` gets shorter rather than longer.

## Area: iOS client

_Scope: The iOS client (ios/DanTermMobileKit/Sources, ios/DanTermMobileApp)_

**Auditor's read on the area.** This is the cleanest area I have audited in this repo: the pure kit really does hold every session decision, the shell really does hold only effects, and the recent keyboard work is finished properly -- `MobileContentBox` is keyboard-absent by construction and `MobileSurfacePlacement` is the single presentation offset that the drawn layer, the scroll chrome, and hit-testing all read, so no grid, claim, or frame-store allocation can see the keyboard. The findings below are about facts that still have two owners (pinnedness, the connection identity), one gesture the reconnect policy drops, one hand-maintained integer table, and vocabulary that only tests reach. I did not audit the render-execution or TerminalCore packages the surface links against, `PaneReplica`'s event-application arithmetic beyond its pinnedness bit, or the checkpoint digest/plist envelope.

<a id="ios-1"></a>

### IOS-1. Let the replica report pinnedness instead of re-decoding tape JSON in the session model

`structural` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#pinnedStatement`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#noteRecordPinnedness`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift#applyEvent`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionEvent.swift#MobileSessionEvent`

**Problem.** One wire fact -- whether the pane's grid is a pinned override -- is decoded twice by two unrelated decoders. `PaneReplica` decodes it properly, through `NeutralTerminalRecordingEvent`, and holds it in `heldPinned`. `MobileSessionModel` decodes it again by hand, sniffing the raw JSON object of an event record for a `"type" == "resize"` string and a `"pinned"` boolean, and uses that second reading to decide whether a standing claim was released externally. The two readings agree only by coincidence of two independently written literals.

**Evidence.** `MobileSessionModel.pinnedStatement(in:)` contains `guard event.event["type"]?.asString == "resize" else { return nil }` and then `if case .bool(let pinned)? = event.event["pinned"] { return pinned }; return false`. The same record shape is decoded in `NeutralTerminalRecording.swift` under `case "resize"` as `.resize(columns:rows:pinned: try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false)`, and `PaneReplica.applyEvent` stores the result in `heldPinned`, which is what `PaneReplica.pinned` and therefore `MobileSurfaceFacts.pinned` already expose to the model. So the model reaches the same bit by two paths: through `surface.pinned` (used by `claimControl`) and through its own string-matching sniff (used by `noteRecordPinnedness`).

**Ideal fix.** Delete `pinnedStatement` and `noteRecordPinnedness`'s decoding. Make `MobileSessionEvent.recordApplied` carry the replica's post-apply state -- `case recordApplied(PaneTapeRecord, pinned: Bool?)` -- filled in by the shell from `surfaceView.pinned` right after `surfaceView.apply(record)` succeeds. The model then ends a confirmed standing claim when that reported bit is `false`. Ordering is preserved: the shell dispatches `.recordApplied` inside the same drain turn as the frame that produced it, strictly before any later frame event, which is exactly the response-versus-record ordering the current comment relies on. The model keeps one reader of pinnedness and no knowledge of the tape's JSON keys.

**By construction.** A tape record whose pinnedness the model reads differently from the replica that applied it becomes unspellable: the model has no access to the record's raw fields at all, so a rename of the `pinned` key or the `resize` type name is a compile error in one decoder rather than a silent `false` in a second one.

**Cheaper fallback.** If carrying the bit on the event is unwanted, have `PaneReplica` expose a `static func pinnedStatement(in: PaneTapeRecord) -> Bool?` built on `NeutralTerminalRecordingEvent`, so there is still exactly one decoder even though two callers ask it. This keeps the duplicate call site but removes the duplicate parser.

**Verification.** A behavioral test in `MobileSessionModelTests`: drive a claim, confirm it with its success response, then feed a resize event record whose pinnedness is stated only through the recording schema (including one with the key absent) and assert that a following rotation emits no renewal resize -- and that a record stating `pinned: true` still renews. Run `swift test --package-path ios/DanTermMobileKit`.

**Risk.** The claim-release timing is subtle and already well tested; the fix must keep `.recordApplied` dispatched only when `apply` did not throw, so a rejected record still cannot end the claim.

<a id="ios-2"></a>

### IOS-2. Make an authorized attempt carry its target so a Go tap can never be dropped against a stale one

`correctness` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileReconnectPolicy.swift#handle`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#startAttempt`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#connect`, `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/ReconnectPolicyTests.swift#oneAttemptAtATime`

**Problem.** The episode's target and the target the in-flight attempt actually dialed are owned separately and can disagree. `MobileConnectTarget.setTarget` retargets the episode on every Go gesture, but `MobileReconnectPolicy.handle(.userRequestedConnect)` answers `.rest` whenever an attempt is already in flight, so the model starts nothing and never tears the old attempt down. A user who taps Go, waits during a slow dial, edits the host, and taps Go again gets: the new host stored and remembered, no new attempt, and -- if the first dial eventually succeeds -- a connection to the host they just replaced, while the status line still reads the old target's wording. The same seam has a second face: `startAttempt` guards `guard let target = connectTarget.established else { return [] }`, so the policy can latch `attemptInFlight = true` for an attempt that was never started and whose outcome nothing will ever report; every later signal then answers `.rest`, including `userRequestedConnect`, which is a permanently unrecoverable session.

**Evidence.** `MobileReconnectPolicy.handle` under `case .userRequestedConnect` sets `remainingDelays`/`standing` and then `guard attemptInFlight == false else { return .rest }`. `MobileSessionModel.connect(to:env:)` returns `[.storeTarget(host:port:)] + reconnect(.userRequestedConnect, env:)`, with no `.disconnect` of its own -- the teardown lives only in `startAttempt`, which `.rest` never reaches. `ReconnectPolicyTests.oneAttemptAtATime` pins this as intended, justified by "two concurrent attempts would race over the same stored resume cursor" -- but `startAttempt` already begins with `[.flushCheckpoint(...), .disconnect]` and the shell bumps `connectionGeneration`, so a gesture-started attempt replaces rather than races.

**Ideal fix.** Move the episode target into the decision: `MobileReconnectPolicy.MobileReconnectDecision.attemptNow(MobileServerTarget)`, with the policy taking the target on `.userRequestedConnect` and reusing it for automatic attempts. `userRequestedConnect` then always returns `attemptNow` -- it is the manual remedy, and the model's existing `.disconnect` fences whatever was in flight -- and `startAttempt` takes a non-optional target from the decision, so its `guard ... else { return [] }` disappears.

**By construction.** "The policy authorized an attempt but no attempt ran" and "the in-flight attempt is dialing a target the model has already replaced" both stop being expressible: an authorization is a value that carries the target it authorizes, and there is no way to hold one without starting the attempt it names.

**Cheaper fallback.** Leave the policy alone and have `MobileSessionModel.connect` compare the newly resolved target against `connectTarget.established` before calling `reconnect`, emitting an explicit teardown plus a fresh attempt when it changed. This fixes the user-visible wrong-host case but leaves `attemptInFlight` able to latch on an attempt that was never started.

**Verification.** In `MobileSessionModelTests`, drive `.connectRequested` for host A, do not answer the attempt, then `.connectRequested` for host B, and assert the effects contain `.disconnect` followed by `.connect(target B)`. Replace `ReconnectPolicyTests.oneAttemptAtATime`'s gesture expectation with `attemptNow` carrying the target. Run `swift test --package-path ios/DanTermMobileKit`.

**Risk.** The rewritten test currently encodes the opposite contract, so the change must be argued in the plan rather than slipped in; and the shell must keep fencing the old attempt's callback (it already does, via `connectionGeneration`) or a late `.connected` from the abandoned dial would resurface.

<a id="ios-3"></a>

### IOS-3. Give the model one connection identity instead of four optionals a nil response id can match

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#receive`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#endConnection`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#MobileSessionModel`

**Problem.** What the model knows about the live connection is spread over four independent optionals -- `tapeRequestId`, `serverVersion`, `standingClaim`, and `status.connection` -- kept in step only by everyone remembering to call `endConnection()`. Combinations such as "subscribed but no tape request id" or "a standing claim with no connection" are representable. One of them has a sharp edge: `receive` decides whether a response belongs to the tape subscription with `response.id == tapeRequestId`, comparing two `JSONValue?`s, so a response carrying no id at all (`JsonRpcResponse.id` is optional, and JSON-RPC uses a null id for a request the server could not parse) matches whenever `tapeRequestId` is nil and is treated as the subscription's refusal, ending the connection with the wrong cause. The file already knows this hazard -- it guards against exactly it for the claim -- but does not apply the same care to the subscription.

**Evidence.** `MobileSessionModel.receive` contains `guard response.id == tapeRequestId else { ... }` twice, on the error and the success path, with `private var tapeRequestId: JSONValue?`. Immediately above, the claim path is written defensively with the comment "`pending` is unwrapped first so a confirmed claim (pending nil) can never match a response that carries no id" and the code `if let pending = standingClaim?.pendingRequestId, pending == response.id`. `endConnection()` is the only thing that keeps the four fields consistent, resetting `status.noteStream(nil)`, `status.noteRequestOutcome(nil)`, `tapeRequestId`, `serverVersion`, and `standingClaim` by hand.

**Ideal fix.** Replace the four fields with one `private var connection: Connection` enum: `case none`, `case establishing`, `case handshaken(serverVersion: String)`, `case subscribed(tapeRequestId: JSONValue, claim: StandingClaim?)`. The tape request id is then non-optional exactly where it exists, so `response.id == tapeRequestId` becomes a comparison against a real value and a nil-id response cannot match it; `endConnection()` collapses to `connection = .none`, and a claim outliving its connection stops being expressible.

**By construction.** "A response with no id was read as the tape subscription's", "a standing claim survives its connection", and "a subscribed connection with no subscription id" all become unspellable, because each fact only exists inside the case that owns it.

**Cheaper fallback.** Unwrap before comparing -- `if let tapeRequestId, response.id == tapeRequestId` -- mirroring the claim guard. One line, closes the nil-matching hole, leaves the four-optional bookkeeping and the hand-written reset in place.

**Verification.** In `MobileSessionModelTests`, feed a `JsonRpcResponse(id: nil, error: ...)` frame on a connection whose subscription id is not nil and assert the connection does not end and only the request-outcome part of the status moves; then assert an error response carrying the real subscription id does end it. Run `swift test --package-path ios/DanTermMobileKit`.

**Risk.** The four fields are read from several branches, so the refactor touches most of `receive`, `end`, and `paneAttached`; the existing model tests are behavioral and should carry it without edits.

<a id="ios-4"></a>

### IOS-4. Build the accessory key row from the key enum instead of matching two hand-numbered tag tables

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift#terminalAccessoryEntries`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift#accessoryTapped`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalBottomBarView.swift#configureViews`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileInputMapper.swift#MobileAccessoryKey`

**Problem.** Which key a button sends is carried by a bare integer written twice, in two separately maintained lists that nothing checks against each other: a `TerminalAccessoryEntry` table with literal tags 0 through 9, and a `MobileAccessoryKey(tag:)` switch mapping those same literals back. The Ctrl button -- the one with behavior, since it holds the latch highlight -- is found by the third copy of the same number, `entry.tag == 1`. Adding, removing, or reordering a key means editing three places, and a mismatch compiles cleanly and silently sends the wrong key to the Mac.

**Evidence.** `terminalAccessoryEntries` is a literal array of `TerminalAccessoryEntry(title: "Esc", systemImage: nil, tag: 0)` through `tag: 9`; `private extension MobileAccessoryKey { init?(tag: Int) }` switches `case 0: self = .escape` ... `case 9: self = .slash`; `configureViews` picks the latch button with `if entry.tag == 1 { controlButton = button }`; and `accessoryTapped` recovers the key with `guard let key = MobileAccessoryKey(tag: sender.tag)`, whose `default: return nil` silently swallows an unmapped tag.

**Ideal fix.** Make the row one table of `(key: MobileAccessoryKey, title: String, systemImage: String?)`, and give each button a `UIAction` that captures its own `key` and calls `onAccessoryKey`. The tag, the `init?(tag:)` extension, and the failable recovery all disappear; `controlButton` is found by `entry.key == .control`. Make `MobileAccessoryKey` `CaseIterable` in the kit and derive the table with an exhaustive `switch` over the key for its title and image, so a new key added to the enum fails to compile until the row is told how to draw it.

**By construction.** "A button whose tag names a different key than the row intended" and "a key added to `MobileAccessoryKey` that the bar silently cannot send" both stop being expressible: the button holds the key value itself, and the presentation table is an exhaustive switch over the enum.

**Cheaper fallback.** Keep the two tables but store the key on the button through the table rather than through `tag`, e.g. a `[ObjectIdentifier: MobileAccessoryKey]` the bar owns. This removes the numeric coupling without making the key set exhaustive.

**Verification.** Behavioral, through the existing smoke path rather than a unit test the app package cannot host: extend `MobileSmokeInputScript` / `scripts/ios-app.sh`'s driven probe to tap each accessory key and assert the pane received the corresponding input, so a tag/key mismatch fails the run rather than a reading.

**Risk.** None beyond the usual UIKit target/action rewrite; the bar holds no session fact, so nothing else observes the change.

<a id="ios-5"></a>

### IOS-5. Delete the session vocabulary only tests can reach

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileConnectionState.swift#MobileConnectionState`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileReconnectPolicy.swift#MobileReconnectEvent`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileResumePolicy.swift#resumeCheckpoint`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDeadlineTimer.swift#isPending`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplicaCheckpoint.swift#PaneReplicaCheckpointStore`

**Problem.** Five public entry points are produced or called by nothing but their own tests, and two of them carry doc comments describing callers that no longer exist. Because they are tested, they read as live contracts: a future reader extending the reconnect or resume story will reason about states the app can never enter, and the `MobileDeadlineTimer.isPending` comment actively points at a scheduling pattern the model replaced with its own `checkpointDeadlineIsArmed` flag.

**Evidence.** `MobileConnectionState.listingPanes` appears only in `MobileStatus`'s two switches and `StatusLineTests`; nothing calls `status.noteConnection(.listingPanes, ...)`. `MobileReconnectEvent.userCancelled` is handled in `MobileReconnectPolicy.handle` and asserted in `ReconnectPolicyTests` but is never dispatched -- the model has no cancel gesture. `MobileResumePolicy.resumeCheckpoint(stored:)` is used only by `ResumePolicyTests`; production asks `trustsStoredPosition` instead and the shell does the `? load : nil` itself. `MobileDeadlineTimer.isPending` is referenced only in `DeadlineTimerTests`, while its comment says "Callers that schedule one flush per dirty period use it to leave a pending deadline alone". `PaneReplicaCheckpointStore.remove()` has no caller at all.

**Ideal fix.** Delete all five, with the assertions that only exercised them, and let the compiler prove nothing else wanted them. If a cancel gesture or a pane-listing status is wanted, add it with the code that produces it.

**By construction.** n/a

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** `swift test --package-path ios/DanTermMobileKit` and `./scripts/ios-portability-gate.sh` after the deletions; the remaining suites must pass untouched, which is what shows nothing behavioral was carried by these symbols.

**Risk.** `userCancelled` may be a placeholder for a planned disconnect gesture; if so it should be raised with the user rather than deleted quietly, since the surrounding policy comments treat cancel as part of the design.

## Area: Build, gate, CI, docs

_Scope: Build, gate, CI, and the documentation contract_

**Auditor's read on the area.** This area is unusually well engineered: the bundle layout is generated from a Swift declaration rather than restated in YAML, the ADR index is machine-checked against the notes it lists, and two of the biggest hand-copied inventories (Swift test-estate coverage, manifest ownership) already have dedicated lints with their own self-tests. The remaining weaknesses are all the same shape -- an inventory that lives in prose or in a step string with no generator or executable check behind it. I did not audit Swift sources, the benchmark harness internals, or docs/research/.

<a id="build-1"></a>

### BUILD-1. Declare each source target's purity profile once, and make the gate enumerate targets

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `scripts/run-test-suite.sh#STEPS`, `scripts/core-purity-lint.sh`, `scripts/gate-test-coverage-lint.py`

**Problem.** Which purity policy applies to which module is written nowhere except eleven hand-typed lines of the gate's step array. A target nobody remembers to add a line for is silently unlinted forever, and no check says so -- exactly the gap scripts/gate-test-coverage-lint.py was written to close for test estates, left open for purity. The hand-maintained nature already shows: three of the eleven lines are strict subsets of another line and do nothing.

**Evidence.** STEPS contains both `./scripts/core-purity-lint.sh --allow-imports DequeModule lib/TerminalCore/Sources/TerminalCore` and `./scripts/core-purity-lint.sh lib/TerminalCore/Sources/TerminalCore`. Reading scripts/core-purity-lint.sh, the first runs the import allowlist, then the Cocoa/AppKit rule, then (PROFILE defaults to `pure`) the token denylist -- a strict superset of the second, which runs only the last two. The same duplication exists for lib/TerminalCore/Sources/TerminalRenderPlanning (`--allow-imports TerminalCore` plus a bare invocation) and lib/TerminalPTY/Sources/PaneProcessLifecycle (`--forbid-imports` plus a bare invocation). Meanwhile `ls lib/*/Sources/*/ ios/*/Sources/*/` lists 34 first-party source directories; only 8 distinct ones are named by any purity step. TerminalRenderExecution, TerminalSpriteGeometry, TerminalCoreRecording, TerminalPaneSession, and ios/DanTermMobileApp are among the unlinted ones.

**Ideal fix.** Move the policy next to what it describes: give every first-party source target a declared purity policy (a table keyed by target path, or a marker in the owning Package.swift read as text the way scripts/manifest_targets.py already reads targets), including an explicit `unrestricted` for host-bound ones. Replace the eleven step lines with one gate step that enumerates every declared target under lib/*/Sources/* and ios/*/Sources/*, applies the declared policy, and fails when a target has no declaration -- the same 'checking nothing is a failure' posture gate-test-coverage-lint.py and ios-portability-gate.sh already take.

**By construction.** A first-party source target with no purity policy becomes unrepresentable: adding a new module under lib/ or ios/ fails the gate until someone states what it may import and do. Two lint lanes over the same directory also become unrepresentable, since the enumeration visits each target once.

**Cheaper fallback.** Delete the three redundant bare invocations and add a small lint asserting every source directory appears in exactly one purity step. Removes the duplication and the silent skip, but the policy still lives in the gate rather than with the module.

**Verification.** Add a throwaway target lib/TerminalCore/Sources/ScratchTarget containing `import AppKit` and run `just test`; it must fail naming the target as having no declared purity policy. Then declare it `pure` and confirm the failure changes to the Cocoa-import violation. Separately, delete the three redundant STEPS lines and confirm the gate still fails when `import Darwin` is added to lib/TerminalPTY/Sources/PaneProcessLifecycle.

**Risk.** Enumerating targets means some currently-unlinted module gets a policy for the first time and may fail; each needs a deliberate `unrestricted` or a real cleanup. That is the point of the change, but it makes the first commit larger than the mechanism alone.

<a id="build-2"></a>

### BUILD-2. Make an orphaned gate self-test fail the gate instead of silently never running

`tooling` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `scripts/run-test-suite.sh#STEPS`, `scripts/gate-test-coverage-lint.py#gate_steps`, `scripts/tests/terminal_benchmark_state_test.py`

**Problem.** scripts/tests/ holds 68 self-tests, and whether one runs depends entirely on somebody having typed its path into the STEPS array. Nothing checks the two against each other. gate-test-coverage-lint.py solves precisely this for Swift packages -- the manifest is the claim, the step list is the fulfilment -- and the equivalent claim for a shell/python self-test (its existence on disk) has no such check.

**Evidence.** Diffing the `scripts/tests/` paths named inside the STEPS array against the files on disk yields two files present in the tree but absent from STEPS: danterm-cli_test.sh (deliberately opt-in via the justfile's `test-cli` recipe, which needs a GUI) and terminal_benchmark_state_test.py. The latter runs only because scripts/tests/terminal-benchmark-harness_test.sh happens to invoke `python3 "$ROOT/scripts/tests/terminal_benchmark_state_test.py"` inside its body. Neither situation is declared anywhere, so the invariant holds by coincidence rather than by check.

**Ideal fix.** Extend the lint that already parses STEPS as text (gate-test-coverage-lint.py#gate_steps) to require that every scripts/tests/*_test.{sh,py} is reachable from STEPS -- named directly, or named by a wrapper the gate runs, using the one-level-of-indirection rule the lint already implements -- or carries an explicit in-file opt-out line stating why (`# gate: opt-out -- requires a GUI, run via just test-cli`). A file that is neither reachable nor opted out fails the gate.

**By construction.** A self-test that exists but never runs becomes unrepresentable: the file's presence is itself the claim, and the gate refuses to pass until the claim is fulfilled by a step or explicitly withdrawn in the file.

**Cheaper fallback.** A plain glob-versus-STEPS diff with a hardcoded exemption list inside the lint. Cheaper, but the reason for an exemption then lives away from the test it exempts, which is the same drift in a new place.

**Verification.** Add scripts/tests/orphan_test.sh that exits 0, run `just test`, and confirm the gate fails naming the orphan. Add the opt-out marker line and confirm it passes. Add a STEPS entry instead and confirm it also passes.

**Risk.** The indirection follower must handle a test invoked from inside another test's body (the terminal_benchmark_state_test.py case) or that file becomes a false positive on day one. Over-permissive following could also mark a test 'covered' by a mention in a comment; the existing lint's token-level parsing is the guard against that.

<a id="build-3"></a>

### BUILD-3. Put every gate scratch tree under one root so `just clean` cannot miss one

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `justfile#clean`, `scripts/tests/just-clean_test.sh`, `scripts/ios-portability-gate.sh`, `scripts/ios-app.sh`, `.gitignore`

**Problem.** `just clean` claims to need no inventory, but it is an inventory -- four literal directory names -- and it is already incomplete. Build trees the gate creates survive `just clean`, and the test written to prevent exactly this cannot see them, because it derives its expectations from only one of the several files that choose scratch paths.

**Evidence.** justfile#clean prunes `-name .spm-build -o -name .build -o -name .build-gate -o -name .build-app-tests`, under a comment claiming 'Scratch trees are matched by name, not listed, so a gate step that picks a new --scratch-path is cleaned without a second list to keep in step.' But scripts/ios-portability-gate.sh builds into `--scratch-path "$package/.build-ios-gate"` and scripts/ios-app.sh writes `OUT="$ROOT/.build-ios-app/$TARGET"`; neither name is in the prune list. scripts/tests/just-clean_test.sh builds its SCRATCH_PATHS list by grepping `--scratch-path` out of scripts/run-test-suite.sh only, so the iOS gate's path is invisible to it. .gitignore is a third copy of the same inventory and carries `.build-ios-*/` -- so the tree is known to exist and known to be build output, and only the cleaner does not know.

**Ideal fix.** Give the gate one scratch root: every step that names a scratch path names <repo>/.build-gate/<slug> (distinct subdirectories still satisfy the 'no shared build directory' rule the STEPS header states), and `just clean` removes .build, .spm-build, and .build-gate. Three fixed names, no per-step list, and a new step's scratch tree is inside the cleaned root by construction.

**By construction.** A gate build tree that `just clean` does not remove becomes unrepresentable, because there is nowhere for a scratch tree to live except inside a directory clean already deletes.

**Cheaper fallback.** Have scripts/tests/just-clean_test.sh derive its path list from every script that names a --scratch-path or a .build-* output directory, not just run-test-suite.sh, and add the two missing names to the justfile. Restores the check but leaves three copies of the inventory in place.

**Verification.** Run `just test` on a clean checkout, then `just clean`, then assert `find . -maxdepth 3 -type d -name '.build*' -not -path './references/*'` prints nothing. Pin that as the assertion in scripts/tests/just-clean_test.sh instead of the derived path list.

**Risk.** Moving lib/TerminalCore/.build-gate and ios/DanTermMobileKit/.build-gate to a shared root invalidates those warm incremental trees once, so the first gate run after the change is cold. scripts/type-check-budget-gate.sh parses --scratch-path from its wrapped command and must keep working with the new location.

<a id="build-4"></a>

### BUILD-4. Lint the Swift file-header rule AGENTS.md states, which is already violated nine times

`tooling` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `AGENTS.md`, `app/AlertsPopoverView.swift`, `lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift`, `lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift`, `scripts/run-test-suite.sh#STEPS`

**Problem.** AGENTS.md states a mechanically checkable rule and gives a concrete reason it matters -- `///` on line 1 silently attaches to the next declaration rather than documenting the file -- but nothing enforces it. The rule has drifted, and it drifted into exactly the failure mode it warns about. This repo already runs sixteen lints for rules of this kind; the file-header rule is the one left as prose.

**Evidence.** AGENTS.md, Code Style: 'Every `.swift` file opens with a `//` block on line 1, above the imports -- not Xcode's `//  FileName.swift` banner, and not `///` (Swift has no file-level doc comment, so `///` would silently attach to the next declaration).' Scanning the 600 tracked .swift files under app/, lib/, and ios/ finds nine first lines that break it: eight begin with `///` (app/AlertsPopoverView.swift, app/TodoShortcutHelpView.swift, app/TodoRowView.swift, app/TodoToolbarButton.swift, app/TabTodoPopoverView.swift, lib/DanTermCore/Sources/DanTermCore/TodoInputCommand.swift, TodoPopoverState.swift, TodoShortcutCatalog.swift), and lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift opens with `import Foundation` and no header at all.

**Ideal fix.** Add scripts/swift-file-header-lint.sh with a scripts/tests/swift-file-header-lint_test.sh self-test in the house style, wire it into STEPS, and fix the nine files. The check is three conditions on line 1: it starts with `//`, it does not start with `///`, and it is not a bare `// <Filename>.swift` banner.

**By construction.** A .swift file whose leading `///` silently becomes documentation for the first declaration below it becomes unrepresentable in the tree, because the gate rejects it on the commit that introduces it.

**Cheaper fallback.** none -- the ideal fix is small. The rule is already written; only the enforcement is missing.

**Verification.** Add a scratch .swift file whose first line is `/// something` and run `just test`; the gate must fail naming the file. Change it to `// something` and confirm the gate passes. Run the lint over the tree at HEAD and confirm it reports exactly the nine files above before they are fixed.

**Risk.** Low. The only judgement call is whether the eight `///` headers should become `//` headers verbatim or be rewritten as real file headers plus a declaration doc; a mechanical `///`-to-`//` change would satisfy the lint while leaving the type without the `///` comment AGENTS.md separately requires.

<a id="build-5"></a>

### BUILD-5. Give the three manifest-discovery lists one owner so a new package root cannot be skipped

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `scripts/gate-test-coverage-lint.py#MANIFEST_GLOBS`, `scripts/manifest-ownership-lint.py#MANIFEST_GLOBS`, `scripts/ios-portability-gate.sh#MANIFESTS`, `scripts/manifest_targets.py`

**Problem.** Three separate checks each carry a private copy of 'where first-party packages live'. Each guards against an empty result, so a wholesale move is caught -- but adding a package root none of the three globs matches is caught by none of them, and each check keeps reporting success over a smaller tree than it claims to police.

**Evidence.** scripts/gate-test-coverage-lint.py has `MANIFEST_GLOBS = ("Package.swift", "lib/*/Package.swift", "ios/*/Package.swift")`; scripts/manifest-ownership-lint.py has the identical tuple with an identical comment; scripts/ios-portability-gate.sh has `MANIFESTS=(Package.swift lib/*/Package.swift ios/*/Package.swift)`. All three fail only when the list resolves to nothing -- e.g. gate-test-coverage-lint's 'no first-party manifest found, so this check is checking nothing'. A package added at, say, tools/Foo/Package.swift would have no ownership check, no test-estate coverage check, and no iOS-pin check, while all three lints keep printing a pass.

**Ideal fix.** Declare the package roots once -- scripts/manifest_targets.py is already the shared reader for two of the three -- and have it expose both a Python API and a `--list` mode the shell gate consumes. Then add the assertion the current 'empty means failure' guard cannot make: every tracked Package.swift outside references/ must be matched by the declared roots, so a manifest in an undeclared location fails the gate rather than being ignored.

**By construction.** A first-party Package.swift that no gate check ever looks at becomes unrepresentable: every tracked manifest is either matched by the declared roots or fails the gate.

**Cheaper fallback.** Keep three copies but add a single check that `git ls-files '*Package.swift'` (minus references/) equals the declared set. Drift can still happen, but it can no longer be silent.

**Verification.** Create tools/Scratch/Package.swift declaring a target and a test target, run `just test`, and confirm the gate fails saying the manifest sits outside the declared package roots. Move it to lib/Scratch/ and confirm the failure becomes the real coverage complaint (no gate lane runs its tests) instead.

**Risk.** scripts/terminal-headless-draw-compare.py writes a synthetic Package.swift into a temporary tree; the new completeness assertion must read tracked files only, or that scratch manifest becomes a spurious failure.

## Dropped as duplicates

- Make PendingConfirmation an enum so a subject cannot carry the wrong payload -- duplicate of "Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum", which survives: same defect and same fix, but the survivor also covers the read sites in Projections.swift and ModelOperations.swift (desiredConfirmation, closeConfirmationCopy and its two preconditionFailure arms) and names the quitAuthorized field the reducer-area version omits. Keep the dropped finding's one extra observation -- that the two confirm messages should each match only their own cases -- as part of the survivor.

