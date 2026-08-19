# Construction and cost audit: ranked findings

Two fan-outs over the tree at 2026-08-18, 27 read-only auditors in total, each
scoped to one narrow slice so nobody was reading more than they could hold.

- **Round 1 -- construction.** Thirteen auditors looking for simplifications,
  correctness fixes, and better structure, biased hard toward fixes that make a
  class of bug impossible to express. 77 findings, ids like `PARSE-2`,
  `RUNTIME-1`.
- **Round 2 -- cost.** Twelve auditors looking for performance wins and data
  modeling improvements *that do not regress each other*: a win bought with a
  cache, a mirror, or a hand-invalidated side table was scored down on purpose,
  because that is the shape round 1 spends most of its findings undoing. 61
  findings, ids like `FEED-1`, `HIST-3`.

Nothing here has been implemented, built, or run. Every claim is a source
reading, and confidence is the auditor's estimate of how checkable the claim is
from the cited code alone.

**No number in this file was measured.** The round-2 auditors were forbidden
from running benchmarks -- twelve agents each building two arms would have
wrecked the machine, and this repo does not accept an unmeasured magnitude
anyway. Each cost finding instead names, in **Measurement**, the exact command
and workload that would decide it and the number that must move, and in
**Regression risk**, what could get slower and which workload would show it.
Treat every cost finding as a candidate with a stated experiment, not as a
result.

## How to use this file

Every finding has a stable id. To start work on one, tell an agent:

> plan the ideal solution to RUNTIME-1 in `docs/scratch/2026-08-18-construction-audit.md`

The finding section is meant to be enough context on its own: files as
`path#symbol`, the problem, quoted evidence, the ideal fix, the cheaper fallback
named as an explicit trade-off, what stops being representable, and the
behavioral test that would prove it. The agent should still re-read the cited
code -- the prose is only as current as 2026-08-18.

**Checking things off.** The working list is the [Backlog](#backlog): tick the
box there and, if the outcome needs a word, append it on the same line
(`-- done 1a2b3c4`, `-- skip: covered by MODEL-2`). That is the one place to
edit; the detail sections below are reference and stay as written. A ticked box
means the prose in its `###` section may now describe code that no longer
exists, so read the commit, not the finding.

**Read the themes before the backlog.** Sixteen root causes explain most of the
138 findings, and fixing a theme retires its symptoms together. Then read
[Settle these first](#settle-these-first): those groups contradict each other or
have an order that decides how much of the work survives.

Scores are impact (1-5) x confidence (1-5), written `i x c`. Impact 5 means the
fix removes a whole class of problem or a whole class of cost; confidence 5
means the claim is verifiable by reading the cited code.

A few findings are marked **merged** -- two auditors found the same thing from
different angles. They keep their id so a link never dangles, but they carry no
checkbox; the survivor does.

## Themes

### Structure themes

From round 1. Ranked by the impact the synthesis pass assigned to the combined fix.

#### T1. Types that understate their own invariant: a tag beside optional payloads, or a parameter wider than the accepted set

_Impact 5/5 -- 12 findings are symptoms._

**Root cause.** Across every layer the same modeling shortcut recurs: a discriminator (subject, mode tag, method tag, transition case, bare UUID) is stored or passed next to payloads that are only valid for some of its values, or a parameter takes a type far wider than the values the callee accepts. The invariant then lives in prose and is re-checked at each read, which produces the repo's characteristic defect shapes -- a silent `return []`, a `?? default`, a `preconditionFailure`, or an action applied to the wrong entity.

**Combined fix.** Turn each tag-plus-payload product into an enum whose cases carry exactly their own data, and narrow every parameter type to the set the callee actually accepts (including typed-throws and phantom-typed ids at UI boundaries). Do this as one sweep so the reducer, the IPC catalog, the interaction policy, and the AppKit menus all stop re-deriving which payload belongs to which tag; every `preconditionFailure`/`fatalError`/`?? default` guarding an impossible combination is deleted rather than reworded, and that deletion is the acceptance test for the sweep.

Symptoms: [MODEL-1](#model-1), [PARSE-2](#parse-2), [INTERACT-4](#interact-4), [INTERACT-2](#interact-2), [IOS-3](#ios-3), [MODEL-7](#model-7), [CHROME-2](#chrome-2), [PTY-6](#pty-6), [IPC-3](#ipc-3), [IOS-2](#ios-2), [IPC-5](#ipc-5), [CHROME-3](#chrome-3)

#### T2. One fact stored twice: a hand-maintained mirror beside the authority that already knows it

_Impact 5/5 -- 12 findings are symptoms._

**Root cause.** A value that some other structure already determines is copied into a second field and kept in step by hand at every mutation site. The mirror is written optimistically (at submission, at construction, at push time) while the authority may decline, arrive later, or move -- so the two drift, and code downstream trusts the mirror. This is the single most common defect generator in the corpus and it has already produced at least three live bugs (the arena pad byte leak, the permanently-wrong resize dedupe, the falsely-reported invalid launch dimensions).

**Combined fix.** For each pair, delete the mirror and compute the fact from its authority: bytes-in-use from the ring cursors, the reverse submission index from the pending map, the container's structural fingerprint from its layout, the host's grid from the launch input, resize dedupe from the applied resize, iOS pinnedness from the replica, the toolbar's state from the projection value it was handed, and every handle+token or directory-resolution pair from one owning value. Where a mirror must stay for performance, it needs the recount-oracle treatment the store already applies to its side tables.

Symptoms: [STORE-1](#store-1), [MODEL-6](#model-6), [MODEL-3](#model-3), [PTY-2](#pty-2), [PTY-5](#pty-5), [IOS-1](#ios-1), [PANE-4](#pane-4), [RUNTIME-4](#runtime-4), [PANE-3](#pane-3), [IPC-6](#ipc-6), [PERSIST-2](#persist-2), [MODEL-4](#model-4)

#### T3. A vocabulary enumerated once per consumer instead of declared once in a table

_Impact 4/5 -- 10 findings are symptoms._

**Root cause.** Whenever the codebase has a closed set -- DEC modes, IPC methods, CLI commands, known agents, accessory keys, tape record keys, cell-word fields, mouse buttons, preferences rows -- each consumer writes its own copy of the list rather than reading one declaration. Some copies are exhaustive switches the compiler checks, but the compiler can only check that the cases exist, never that two lists agree about a key's spelling, a number's meaning, or a tag's value. Adding a member therefore means editing three to six places, and the corpus already shows real gaps (group.new absent from the audit projection, mode 1048 settable but not resynchronizable).

**Combined fix.** Declare each closed set once as data -- a spec table or an enum with derived projections -- and make every consumer a projection of it: mode set/reset/query/resync from one ModeSpec list; IPC traits, target keys, and the audit descriptor from one traits value plus the already-round-trip-tested `params`; CLI help, per-parser usage, and the SKILL.md synopsis from one command table with a test asserting equality; agents from one registry both KnownAgent and doctor read; accessory keys, cell-word fields, pointer-owner slots, and preference rows from their own enums/row descriptors rather than parallel integer or index tables.

Symptoms: [PARSE-3](#parse-3), [IPC-1](#ipc-1), [IPC-4](#ipc-4), [IPC-2](#ipc-2), [PERSIST-7](#persist-7), [IOS-4](#ios-4), [PERSIST-6](#persist-6), [INTERACT-6](#interact-6), [STORE-3](#store-3), [CHROME-4](#chrome-4)

#### T4. Pushed obligations: an invariant repaired by remembering to call something at every mutation site

_Impact 5/5 -- 6 findings are symptoms._

**Root cause.** State that belongs to an owner is stored outside it, or a repair that belongs to a chokepoint is copied into each arm that happens to need it. Correctness then rests on every current and future mutation site remembering a call the compiler cannot demand: seven search-index refreshes, nine alert-clear copies, four defocus loops, five side-table prunes, two hand-written source-cancel ladders. The known consequences range from a stale bell to a `preconditionFailure` that traps the process on a retired search coordinate.

**Combined fix.** Give each of these facts a single structural owner: funnel every history mutation through one method that refreshes the search index on the way out; move per-pane search and notification-throttle state onto PaneModel and bind pending IPC input requests to their pane so leaf removal prunes and rejects them; add focused-pane alert repair and session-focus reconciliation to the existing `defer`/reconcile sweep and delete the copied arms; and cancel dispatch sources from the one registry that already retains them. In each case the acceptance test is that the per-site call disappears entirely, not that a new site is added.

Symptoms: [INTERACT-1](#interact-1), [REDUCE-3](#reduce-3), [REDUCE-4](#reduce-4), [MODEL-5](#model-5), [REDUCE-6](#reduce-6), [PTY-1](#pty-1)

#### T5. The same algorithm implemented twice, and the copies have already drifted

_Impact 4/5 -- 12 findings are symptoms._

**Root cause.** A rule that should exist once is written out per caller, per separator style, per drain reason, per completion shape, or per subclass. Every one of these pairs is documented in the corpus as already divergent -- the tested damage-shift rule is not the shipped one, the two search scans clamp wide cells differently, the two PTY read loops disagree about EIO, the two input forms disagree about rejecting an unmappable key, the two alert-raise paths disagree about the metadata bound -- so the duplication is not hypothetical debt but the direct cause of behavior that changes with the code path.

**Combined fix.** Collapse each pair to one implementation parameterized by what genuinely differs: one damage value holding the shift rule; one generic search-unit emitter over a position factory; one extended-color parser taking the separator shape; one read loop returning why it stopped; one input submission path with an optional completion; one TODO popover controller taking a scope value; one theme list controller with an activation closure; one alert-raise function; one flight tape instead of five capture buffers; one block record-range accessor, one snapshot leaf traversal, and one declared key base for the open tail's scratch tables.

Symptoms: [INTERACT-3](#interact-3), [INTERACT-5](#interact-5), [PARSE-4](#parse-4), [PTY-4](#pty-4), [PANE-5](#pane-5), [CHROME-1](#chrome-1), [CHROME-5](#chrome-5), [REDUCE-5](#reduce-5), [PTY-3](#pty-3), [STORE-5](#store-5), [PERSIST-3](#persist-3), [STORE-4](#store-4)

#### T6. The Elm loop is bypassed: AppKit holds or answers for state the model should own

_Impact 4/5 -- 6 findings are symptoms._

**Root cause.** In several places the unidirectional flow is broken in one of three ways -- the view tree is read back as the source of truth (drop targets, previously visible tab, theme browser existence), the model is written outside `update()` (restore/import), or a command re-enters the loop (a modal run loop inside an open send frame, a start-search round trip through the view). Each one puts a fact outside the pure layer, so it is invisible to snapshots, IPC, and the reconcile caches, and the hand-patches beside it (`model.todoPopover = nil`, an out-of-band `reconcileTabState`, an asymmetric pass call) are the visible residue.

**Combined fix.** Make `AppRuntime.model` `private(set)` with `update()` as its only writer, and convert each bypass into the projected shape the confirmation panel already uses: a model slot, a reconcile pass that diffs against its own cache, and a Msg for the answer. Restore and import become Msgs; the theme browser and the alert/restore prompts become model-projected non-modal panels (or sheets, never `runModal`); the drag-cancel decision reads `caches.visibleTabId` and the drop target reads the pure `PaneLayout`; `.startSearch` writes `model.searchState` directly.

Symptoms: [RUNTIME-1](#runtime-1), [RUNTIME-2](#runtime-2), [RUNTIME-5](#runtime-5), [PANE-1](#pane-1), [RUNTIME-3](#runtime-3), [REDUCE-2](#reduce-2)

#### T7. Failure reported as a value that success also produces

_Impact 4/5 -- 3 findings are symptoms._

**Root cause.** Several boundaries answer a failure with a value the caller cannot distinguish from a legitimate outcome: a nil decode reads as "clean exit", a `.none` row op reads as "no work", a nil wrapper reads as "this pane is a placeholder forever", and a swallowed write reads as "the lock exists". The caller then advances its state as if the operation landed, so a transient or diagnosable condition becomes a permanent, silent wrong state -- a lost crash prompt, a desynchronized outline with no path to `reloadAll`, a pane that is a blank rectangle for the rest of the tab's life.

**Combined fix.** At each of these seams, either make the operation total so there is nothing to reject, or widen the result so rejection has its own name and the caller must answer it: decide crash recovery on file existence and make the lock writer throw; make SidebarItemStore apply against the projection it is handed or return an explicit `rejected` that escalates to `reloadAll` while holding the cache back; type the container's leaf cache as `PaneWrapperView` and skip (not cache) a pane whose wrapper is missing so the next pass retries.

Symptoms: [PERSIST-1](#persist-1), [MODEL-2](#model-2), [PANE-2](#pane-2)

#### T8. Repo-level inventories kept in prose or in a step array with no generator behind them

_Impact 4/5 -- 5 findings are symptoms._

**Root cause.** The gate already proves the pattern works twice (test-estate coverage, manifest ownership), but the remaining inventories -- which target gets which purity policy, which self-tests run, where scratch trees live, where package manifests live, which style rules are enforced -- are hand-typed lists that nothing checks against the tree. A check over a smaller tree than it claims to police reports success, so the gaps are invisible: three redundant purity lines, an orphaned self-test, uncleaned build trees, and a file-header rule violated nine times.

**Combined fix.** Apply the same 'checking nothing is a failure' posture to every remaining inventory: declare each source target's purity policy beside the target and have one gate step enumerate targets and fail on an undeclared one; make `gate-test-coverage-lint.py` require every `scripts/tests/*_test.*` to be reachable from STEPS or carry an in-file opt-out; give the gate one scratch root that `just clean` removes wholesale; have `manifest_targets.py` own the package roots and assert every tracked manifest is matched; and add the missing file-header lint with its self-test.

Symptoms: [BUILD-1](#build-1), [BUILD-2](#build-2), [BUILD-3](#build-3), [BUILD-5](#build-5), [BUILD-4](#build-4)

#### T9. God objects: one type holding several jobs, so cross-job invariants are conventions

_Impact 3/5 -- 3 findings are symptoms._

**Root cause.** `Terminal` (7.6k lines, ~60 stored properties), `AppRuntime` (2155 lines, six jobs), and the pane-tape policy sitting in the wrong layer all share one cause: unrelated jobs share one field namespace, so any method can write any field and the invariants between jobs are enforced by comments. The layer placement case is sharper still -- policy code in DanTermSupport sits outside the purity lint's reach, so the guard that would catch a clock or a queue in decision code does not run on it.

**Combined fix.** Extract by job, each landable on its own: lift the terminal's inspection state into a value with intent-level mutations and move the state-synchronization encoder to its own type; extract the pane-tape follow broker (and then the checkpoint scheduler) out of AppRuntime into @MainActor owners with narrow entry points; move the pure pane-tape stream policy into DanTermCore and leave only the socket write in app/. Each extraction is judged by whether the extracted state stops being reachable from the code that used to reach it.

Symptoms: [PARSE-6](#parse-6), [RUNTIME-6](#runtime-6), [PERSIST-5](#persist-5)

#### T10. Vocabulary and representations no live code reaches

_Impact 2/5 -- 3 findings are symptoms._

**Root cause.** Msg cases, public kit entry points, and a whole 643-line row representation survive only because tests still exercise them. Because they are tested they read as live contracts, so a reader reasons about states the product cannot enter and a future change picks the stale representation or re-implements a path nobody can take.

**Combined fix.** Delete the dead vocabulary and its tests in one pass -- `.markAlertRead`, the five iOS kit entry points, and `PackedRetainedRow` plus its test file -- moving the cell-word constants onto `LogicalLineRecord.Header` where the live store already aliases them, and let the compiler prove nothing else wanted them.

Symptoms: [REDUCE-7](#reduce-7), [IOS-5](#ios-5), [STORE-2](#store-2)

### Cost themes

From round 2. These are about where the work happens, not about whether it is correct.

#### P1. The live screen is a stack of separately allocated rows holding non-POD cells

_Impact 5/5 -- 5 findings are symptoms._

**Root cause.** ScreenState represents the viewport as a flat array of GridRow values, each owning its own cells array, and GridCell holds a TerminalScalars whose spill case carries a reference. So the physical position of a row is its viewport row (a scroll must move every row), the vacated row is a fresh 5.7 KB allocation, every cell copy runs a retain and every overwrite a release, and every per-cell loop re-proves uniqueness of two nested arrays. The rare multi-scalar cell sets the cost of the common one, and the common one is paid once per printed character and once per scrolled line.

**Combined fix.** Represent the live screen as one contiguous rows-by-columns buffer of POD cells with a ring base row: a cell becomes a 16-byte word (scalar or spill index, kind, style, sentinel-0 identity and hyperlink) with spill payloads in a Terminal-owned side array, exactly as the history arena already encodes them; a scroll becomes a base advance plus blanking `amount` recycled rows in place, with no row moves and no allocation; and the grid vends one `withRowCells(row:)` view that every per-cell loop goes through, which is also the single seam the ring has to teach. Once the printer owns the target column through that seam, the pre-clear collapses to a `severWidePartner` that touches only the neighbour.

Symptoms: [FEED-1](#feed-1), [ROW-5](#row-5), [FEED-2](#feed-2), [ROW-2](#row-2), [ROW-4](#row-4)

#### P2. Per-scalar facts are re-derived at the call site instead of read out of a generated table

_Impact 4/5 -- 7 findings are symptoms._

**Root cause.** The scalar tables publish packed bits and sorted arrays rather than answers, and the code around them expresses set membership and bounded domains with heap collections. So the hot path per scalar decodes a bitfield through failable initializers, scans array literals for class membership, binary-searches decomposition and fold tables just to learn a scalar is unaffected, and keys its one bulk-print fast path on a byte range rather than on the property that fast path actually stands for. Tab stops repeat the shape at grid scale: a dense bounded column domain stored as a Set<Int> that is rebuilt per HT byte.

**Combined fix.** Let the generator emit decoded answers and let bounded domains be words. Emit the scalar record as a palette of fully-formed classification values indexed by UInt8 stage tables, with `isBulkPrintable`, `hasCanonicalDecomposition` and `hasCaseFold` as fields on that palette, and emit the UAX #29 pair verdicts as a 19x19 class table so the stateful rules are reached only for the pairs that need them; express every remaining class set as a UInt32 mask. Then extend the print run across decoded scalars carrying the bulk-printable flag rather than across bytes in 0x20...0x7E, make the parser's action enum POD by leaving CSI and OSC payloads in the absorber that already owns them, and store tab stops as a column bitset so next-stop and previous-stop are word scans.

Symptoms: [UNI-1](#uni-1), [UNI-2](#uni-2), [UNI-3](#uni-3), [FEED-5](#feed-5), [UNI-4](#uni-4), [FEED-3](#feed-3), [FEED-4](#feed-4)

#### P3. Retained history is re-walked to re-derive facts an earlier pass in the same turn already produced

_Impact 5/5 -- 11 findings are symptoms._

**Root cause.** The store's readers are stateless coordinates -- a display-row cursor that holds only (record, row), a matcher that holds only a query, a census that materializes rows -- so every question is answered by folding, painting or scanning the retained content again from scratch. Cost is then proportional to how much history exists rather than to what changed or what was asked, which is why one browse frame folds each row three times, one search keystroke rescans the whole arena, one status read scans the mutable suffix three times, and a style sweep triggered by table count walks two million cells.

**Combined fix.** Make each pass carry its product to the next consumer, and make the header answer the questions it already encodes. Widen the display-row cursor to hold the fold's row count and cell range and step it incrementally; short-circuit the content-unit walk on the hasWideCells bit; walk a truncated tail with one locate plus advance; hold the open tail's header and spills in scratch so admission stops round-tripping the arena; maintain the retained side's per-style-id live count on the admission and eviction walks that already touch every cell; count the memory census from the store's borrowing walks instead of materializing rows. On the search side, produce one match snapshot per frame that status, active match and viewport ranges all read; make the retained index a property of a needle prefix that refines on append; give the matcher a KMP state plus a POD ring of start positions; carry each suffix match's content ordinal out of the scan that counted it; and answer row-has-content from the record shape rather than by painting a row.

Symptoms: [HIST-1](#hist-1), [HIST-2](#hist-2), [HIST-3](#hist-3), [HIST-4](#hist-4), [HIST-5](#hist-5), [ROW-3](#row-3), [FIND-1](#find-1), [FIND-2](#find-2), [FIND-3](#find-3), [FIND-4](#find-4), [FIND-5](#find-5)

#### P4. The published frame plan and its damage throw away the row structure the planner computed

_Impact 4/5 -- 9 findings are symptoms._

**Root cause.** The planner keeps its state per row and then flattens it into four whole-viewport arrays, and damage is published as a heap bitset with no predicates. Every downstream consumer therefore has to rebuild the row partition by scanning: the clip filters all four arrays per run, ink reach is recomputed over every cell in the viewport, the swapchain folds a copy of the bits to ask whether the frame is whole, and each buffer maintains its own mirror of the publish sequence. So the incremental path -- whose entire purpose is to touch only the damaged rows -- does work proportional to the whole viewport on every frame, and allocates several times per frame to do it.

**Combined fix.** Make the plan row-indexed and let it share the planner's retained rows: a row owns its four run arrays plus its computed ink reach, so reuse is a retain per undamaged row, the clip becomes a selection of row indices with no predicate and no allocation, and reach rides the same copy-forward and relocation the runs already ride. Give TerminalDamage the predicates its callers ask for -- a non-allocating `covers(rowCount:)` and span iteration instead of `rowIndices` -- store its bits inline for viewports up to 128 rows, and replace the per-buffer stale-damage mirrors with a generation-keyed list of published damage that a buffer folds once at acquisition. In the executor, set the context's color space once per frame and pass RenderColor components per run instead of allocating a CGColor and memoizing it, and append surrogate pairs into the batched cmap path so only true multi-scalar clusters reach CTLine.

Symptoms: [FRAME-1](#frame-1), [DRAW-2](#draw-2), [FRAME-2](#frame-2), [DRAW-1](#draw-1), [FRAME-3](#frame-3), [FRAME-4](#frame-4), [FRAME-5](#frame-5), [DRAW-3](#draw-3), [DRAW-4](#draw-4)

#### P5. Bytes are re-copied and re-encoded at every boundary they cross

_Impact 4/5 -- 9 findings are symptoms._

**Root cause.** No layer owns a byte buffer that the next layer can borrow, so each seam allocates its own copy and re-parses what the previous seam produced. The read path allocates per read() syscall so the flight recorder has something to retain, the recorder holds one malloc per chunk, the framer appends one byte at a time, the tape record is JSON-encoded, decoded into a JSONValue tree, and encoded again for the wire, and the pending-input queue rebases every span whenever its head moves. The delivered unit everywhere is whatever the previous layer happened to hand over -- a 1 KB clist read, one record, one merge -- rather than a unit the app chose.

**Combined fix.** Give each boundary one owned buffer and one encoding. Hold a lifetime turn buffer on the PTY host, read successive syscalls into successive offsets, and emit exactly one output for the whole fence-bound turn into a buffer-pointer `feed` entry point; back the flight recorder with a single bounded byte ring whose slots are (direction, offset, length) spans, so the read path can feed and record the same region without a copy. Hold pending input in a Deque with absolute lifetime-byte span coordinates so a partial write never rewrites the queue, and make the coalesced update payload an accumulator that appends rather than a signal rebuilt per merge. On the wire side, frame lines by scanning slices for 0x0A, carry a tape record as its typed Encodable event so it is encoded exactly once, decode it once at the phone's edge into that same typed value, batch a delivery into one notification encoded inside the write queue rather than one per record on the main actor, and base64 sync chunks lazily from Data slices.

Symptoms: [XPORT-1](#xport-1), [XPORT-2](#xport-2), [XPORT-3](#xport-3), [XPORT-4](#xport-4), [WIRE-1](#wire-1), [WIRE-2](#wire-2), [WIRE-3](#wire-3), [WIRE-6](#wire-6), [MOBILE-3](#mobile-3)

#### P6. Arrival triggers whole-state work, because no value says what actually changed

_Impact 5/5 -- 18 findings are symptoms._

**Root cause.** The app has no representation of "has the persisted state moved", "has this row's text moved", "has this replica's state moved", so it answers those questions by rebuilding the whole thing and comparing, once per message on the Mac and once per applied tape record on the phone. AppModel mixes persisted and ephemeral fields with only comments to separate them and stores ids as Strings in its snapshot, projections re-normalize strings the model stores raw, membership questions flatten trees into arrays and sets, container visibility is emitted outside the diff, and the phone rebuilds its font world and repaints every pixel per record. In every case the cost scales with how much state exists rather than with what changed.

**Combined fix.** Give each of these facts a value and diff that value. Split AppModel into a stored `persisted` half plus ephemeral fields and type the snapshot's ids as the phantom-typed ids, so change detection is a value comparison instead of a full serialization with a uuidString per entity, and let the engine emit the bounded checkpoint tail once instead of trimming projected text five times. Store DisplayLine on the model, normalized once at ingress, with an allocation-free fast path for text that is already clean. Answer membership with a short-circuiting tree walk, key groups, tabs and the sidebar projection by id with OrderedDictionary, resolve each row's chrome from one tabChrome call, and make container visibility a diffed field so a hidden tab stops re-solving its layout on every sweep; build the pane roster only when a subscriber exists, and drive the pane strip's fitting from precomputed metrics. On the phone, resolve cell metrics only where displayScale, bounds or grid change, feed the drained damage into a TerminalFrameSwapchain instead of repainting the grid per tick, report replica state only on a transition, and own the replica off the main actor so the main thread receives frames rather than records.

Symptoms: [LOOKUP-1](#lookup-1), [LOOKUP-2](#lookup-2), [WIRE-4](#wire-4), [WIRE-5](#wire-5), [LOOKUP-3](#lookup-3), [RECON-3](#recon-3), [LOOKUP-4](#lookup-4), [LOOKUP-5](#lookup-5), [LOOKUP-6](#lookup-6), [RECON-1](#recon-1), [RECON-4](#recon-4), [RECON-5](#recon-5), [RECON-6](#recon-6), [DRAW-5](#draw-5), [MOBILE-1](#mobile-1), [MOBILE-2](#mobile-2), [MOBILE-4](#mobile-4), [MOBILE-5](#mobile-5)

## Settle these first

Each entry is a group whose members interact: one reverses the other, one
subsumes the other, or the order decides how much of the work survives. Decide
the question in the **Resolution** line before starting either side. These came
out of the round-1 synthesis; the round-2 fold pass found no further
contradictions, only the two overlaps recorded as merges.

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

**Structure.**

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

**Cost.**

- [FEED-2](#feed-2) (4x5) -- Reach a row's cells once per run, not once per cell, on the bulk ASCII write and scan loops
- [FEED-3](#feed-3) (3x5) -- Store tab stops as a column bitset instead of a Set<Int>, so HT is a word scan rather than an allocation
- [ROW-4](#row-4) (3x4) -- Write each printed cell once: clearCellAndPair's store at the target column is immediately overwritten
- [HIST-2](#hist-2) (4x5) -- Skip the per-cell content-unit walk when the record's hasWideCells bit proves the count
- [HIST-4](#hist-4) (3x5) -- Take one locate for the whole truncated tail instead of one per row
- [FRAME-3](#frame-3) (3x5) -- Give TerminalDamage the predicates its consumers ask for, so no hot caller materializes a folded copy or a row array
- [XPORT-3](#xport-3) (3x5) -- Give pending-input spans absolute byte coordinates so a partial write never rewrites the queue
- [LOOKUP-3](#lookup-3) (4x5) -- Make DisplayLine normalization allocation-free for text that is already a single clean line
- [LOOKUP-4](#lookup-4) (3x5) -- Answer pane-membership and layout questions with a tree walk instead of materializing pane-id arrays and sets
- [RECON-1](#recon-1) (5x5) -- Make container visibility a diffed field of ContainerShape instead of an unconditional per-tab op
- [RECON-5](#recon-5) (3x4) -- Separate the pane strip's overflow-label metrics from its color so fitting stops measuring text
- [WIRE-1](#wire-1) (4x5) -- Frame IPC lines by scanning for the newline, not by appending one byte at a time
- [WIRE-6](#wire-6) (3x5) -- Chunk and base64 the sync payload from slices, without copying the bytes three times first
- [MOBILE-4](#mobile-4) (4x4) -- Signal replica state and surface geometry only when they change, not once per applied record

## Highest scoring

Both rounds ranked together by impact x confidence, ties broken by effort.

| Score | Id | Effort | Kind | Finding |
|---|---|---|---|---|
| 5x5 = 25 | [RECON-1](#recon-1) | small | perf-hot-path | Make container visibility a diffed field of ContainerShape instead of an unconditional per-tab op |
| 5x5 = 25 | [IPC-1](#ipc-1) | medium | correctness | Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch |
| 5x5 = 25 | [MOBILE-1](#mobile-1) | medium | perf-hot-path | Resolve cell metrics where the display scale changes, not on every applied tape record |
| 5x5 = 25 | [STORE-1](#store-1) | medium | structural | Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites |
| 5x5 = 25 | [CHROME-1](#chrome-1) | large | structural | Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value |
| 5x5 = 25 | [FEED-1](#feed-1) | large | data-modeling | Represent the viewport as a rotating row ring so a scroll advances a head index instead of moving every row |
| 5x5 = 25 | [FIND-1](#find-1) | large | data-modeling | Narrow the closed-history index on needle append instead of rebuilding it per keystroke |
| 5x5 = 25 | [WIRE-2](#wire-2) | large | data-modeling | Carry a tape record as its typed event, not as a JSONValue decoded from its own encoding |
| 4x5 = 20 | [CHROME-2](#chrome-2) | small | correctness | Make the confirmation projection carry each button's answer instead of inferring it from button visibility |
| 4x5 = 20 | [FEED-2](#feed-2) | small | perf-hot-path | Reach a row's cells once per run, not once per cell, on the bulk ASCII write and scan loops |
| 4x5 = 20 | [HIST-2](#hist-2) | small | perf-hot-path | Skip the per-cell content-unit walk when the record's hasWideCells bit proves the count |
| 4x5 = 20 | [IOS-1](#ios-1) | small | structural | Let the replica report pinnedness instead of re-decoding tape JSON in the session model |
| 4x5 = 20 | [LOOKUP-3](#lookup-3) | small | perf-hot-path | Make DisplayLine normalization allocation-free for text that is already a single clean line |
| 4x5 = 20 | [PERSIST-1](#persist-1) | small | correctness | Decide crash recovery from the lock file's existence, not from decoding it |
| 4x5 = 20 | [REDUCE-2](#reduce-2) | small | structural | Let .startSearch open the pane's search state directly instead of round-tripping through the view |
| 4x5 = 20 | [WIRE-1](#wire-1) | small | perf-hot-path | Frame IPC lines by scanning for the newline, not by appending one byte at a time |
| 4x5 = 20 | [BUILD-1](#build-1) | medium | structural | Declare each source target's purity profile once, and make the gate enumerate targets |
| 4x5 = 20 | [CHROME-3](#chrome-3) | medium | structural | Carry typed ids in sidebar menu items instead of bare UUIDs |
| 4x5 = 20 | [DRAW-1](#draw-1) | medium | perf-hot-path | Carry each row's ink reach in the retained row product instead of rescanning the whole plan per apply |
| 4x5 = 20 | [FIND-2](#find-2) | medium | perf-occupancy | Build the per-frame match snapshot once and pass it to all three search reads |
| 4x5 = 20 | [FRAME-2](#frame-2) | medium | perf-hot-path | Recompute ink reach only for the damaged rows instead of the whole plan on every incremental apply |
| 4x5 = 20 | [HIST-3](#hist-3) | medium | perf-hot-path | Carry the fold's result in DisplayRowCursor so a row is folded once, not three times |
| 4x5 = 20 | [LOOKUP-2](#lookup-2) | medium | data-modeling | Type snapshot identity fields as typed ids instead of String so capture stops formatting UUIDs |
| 4x5 = 20 | [MOBILE-2](#mobile-2) | medium | structural | Feed the drained damage into the frame stores instead of re-rendering the whole grid every tick |
| 4x5 = 20 | [MOBILE-3](#mobile-3) | medium | data-modeling | Decode each tape event once into a typed value instead of re-encoding and re-decoding it per record |
| 4x5 = 20 | [MODEL-1](#model-1) | medium | structural | Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum |
| 4x5 = 20 | [PARSE-2](#parse-2) | medium | structural | Make "alternate screen live without a retained primary" unrepresentable |
| 4x5 = 20 | [PTY-1](#pty-1) | medium | structural | Cancel every retained dispatch source from the one registry that already holds them |
| 4x5 = 20 | [PTY-2](#pty-2) | medium | structural | Give TerminalPTYHost its geometry from the launch input instead of storing a second copy |
| 4x5 = 20 | [RUNTIME-1](#runtime-1) | medium | structural | Make the restore commit a Msg so `update()` is the only writer of `model` |
| 4x5 = 20 | [RUNTIME-2](#runtime-2) | medium | structural | Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence |
| 4x5 = 20 | [STORE-2](#store-2) | medium | simplification | Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them |
| 4x5 = 20 | [UNI-1](#uni-1) | medium | data-modeling | Store the packed scalar record as a palette index over 29 decoded entries, not a 16-bit bitfield |
| 4x5 = 20 | [XPORT-1](#xport-1) | medium | perf-hot-path | Make the read turn, not the read() syscall, the unit that is fed and published |
| 4x5 = 20 | [FRAME-1](#frame-1) | large | data-modeling | Publish the frame plan row-indexed so a row copy and a clip stop scanning the whole viewport |

## Backlog

Grouped by area, so a session can batch one area at a time. Tick the box when
the item is done or deliberately skipped, and say which on the same line.

### Structure

Round 1: simplification, correctness, and structure.

#### Terminal parser and screen state (`PARSE`)

- [ ] **[PARSE-1](#parse-1)** (3x4, small) Clamp relative vertical cursor motion to the scroll region, not just to the screen
- [ ] **[PARSE-2](#parse-2)** (4x5, medium) Make "alternate screen live without a retained primary" unrepresentable
- [ ] **[PARSE-3](#parse-3)** (3x5, medium) Derive DEC/ANSI mode set, reset, query and resynchronization from one mode table
- [ ] **[PARSE-4](#parse-4)** (3x4, small) Parse the SGR 38/48/58 color grammar once instead of once per separator style
- [ ] **[PARSE-5](#parse-5)** (2x4, small) Reset the saved cursor as part of DECSTR
- [ ] **[PARSE-6](#parse-6)** (3x4, large) Split the inspection layer and the state-synchronization encoder out of the Terminal struct

#### Scrollback and row storage (`STORE`)

- [ ] **[STORE-1](#store-1)** (5x5, medium) Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites
- [ ] **[STORE-2](#store-2)** (4x5, medium) Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them
- [ ] **[STORE-3](#store-3)** (3x5, small) Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites
- [ ] **[STORE-4](#store-4)** (3x4, small) State the open tail's scratch-table key base once, so a trimmed head cannot key it two ways
- [ ] **[STORE-5](#store-5)** (3x5, small) Give a block one record-range accessor instead of five hand-copied index conversions

#### Selection, search, damage, presentation (`INTERACT`)

- [ ] **[INTERACT-1](#interact-1)** (4x4, medium) Refresh the search index through one history-mutation funnel instead of seven hand-placed calls
- [ ] **[INTERACT-2](#interact-2)** (4x4, medium) Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy
- [ ] **[INTERACT-3](#interact-3)** (3x5, medium) Delete `TerminalDamageAccumulator`'s copy of the shift-composition rule and let it hold a `TerminalDamage`
- [ ] **[INTERACT-4](#interact-4)** (3x5, small) Put the selection granularity inside `TerminalSelectionMutation.set` instead of beside it
- [ ] **[INTERACT-5](#interact-5)** (3x4, large) Parameterize the one cell-to-search-unit scan by position type instead of writing it twice
- [ ] **[INTERACT-6](#interact-6)** (2x4, small) Key pointer-owner and wheel-remainder storage by their enums instead of by hand-written slots

#### Core reducer (Update/Msg/Command) (`REDUCE`)

- **REDUCE-1** -- merged into [MODEL-1](#model-1); nothing to track here.
- [ ] **[REDUCE-2](#reduce-2)** (4x5, small) Let .startSearch open the pane's search state directly instead of round-tripping through the view
- [ ] **[REDUCE-3](#reduce-3)** (4x4, medium) Repair the focused pane's alerts in one pass instead of copying the rule into nine arms
- [ ] **[REDUCE-4](#reduce-4)** (3x4, medium) Derive terminal focus from the model instead of emitting focusSession(false) from four arms
- [ ] **[REDUCE-5](#reduce-5)** (3x5, small) Raise every pane alert through one function instead of duplicating the ritual in .sessionBell
- [ ] **[REDUCE-6](#reduce-6)** (3x4, small) Tie a pending IPC input request to its pane so pane teardown can reject it
- [ ] **[REDUCE-7](#reduce-7)** (2x5, small) Delete the senderless .markAlertRead message

#### Core model and projections (`MODEL`)

- [ ] **[MODEL-1](#model-1)** (4x5, medium) Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum
- [ ] **[MODEL-2](#model-2)** (4x4, medium) Make SidebarItemStore reject nothing, or report rejection, so a dropped row op cannot strand the outline
- [ ] **[MODEL-3](#model-3)** (3x5, small) Collapse ContainerShape to layout plus zoomedLeaf; derive the structural fingerprint
- [ ] **[MODEL-4](#model-4)** (3x5, small) Group the sidebar group row's reload attributes into one Equatable value
- [ ] **[MODEL-5](#model-5)** (3x4, medium) Move per-pane search and notification-throttle state into PaneModel so pane teardown prunes them
- [ ] **[MODEL-6](#model-6)** (3x5, small) Drop the submission-to-request reverse index and derive it from the pending requests
- [ ] **[MODEL-7](#model-7)** (3x4, small) Make PaneTree.remove non-mutating and return an outcome that cannot be misread as a live tree

#### IPC protocol, dispatch, CLI (`IPC`)

- [ ] **[IPC-1](#ipc-1)** (5x5, medium) Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch
- [ ] **[IPC-2](#ipc-2)** (4x5, large) Generate the CLI help text and SKILL.md synopsis from one command table instead of hand-syncing three copies
- [ ] **[IPC-3](#ipc-3)** (3x5, small) Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear
- [ ] **[IPC-4](#ipc-4)** (3x5, medium) Return one traits value from a single exhaustive switch instead of six parallel per-method enumerations
- [ ] **[IPC-5](#ipc-5)** (2x5, small) Make IpcRequest.decode typed-throws so IpcServer cannot need two decode-failure paths
- [ ] **[IPC-6](#ipc-6)** (2x5, small) Collapse CLIResolvedTarget into CLIConnectionTarget

#### Persistence, recovery, support layer (`PERSIST`)

- [ ] **[PERSIST-1](#persist-1)** (4x5, small) Decide crash recovery from the lock file's existence, not from decoding it
- [ ] **[PERSIST-2](#persist-2)** (3x5, medium) Give the recovery directory one owner: a RecoveryPaths value threaded from launch
- [ ] **[PERSIST-3](#persist-3)** (3x5, small) Graft scrollback through one leaf-mapping traversal instead of re-listing snapshot fields
- [ ] **[PERSIST-4](#persist-4)** (4x4, medium) Confine the IPC connection's descriptor to its write queue so a queued write cannot land on a reused fd
- [ ] **[PERSIST-5](#persist-5)** (3x4, medium) Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support
- [ ] **[PERSIST-6](#persist-6)** (3x4, medium) Publish the pane-tape record shape once in DanTermProtocol instead of writing keys on both sides
- [ ] **[PERSIST-7](#persist-7)** (3x4, medium) Drive doctor's agent probes from one agent registry shared with KnownAgent

#### App runtime and reconcile (`RUNTIME`)

- [ ] **[RUNTIME-1](#runtime-1)** (4x5, medium) Make the restore commit a Msg so `update()` is the only writer of `model`
- [ ] **[RUNTIME-2](#runtime-2)** (4x5, medium) Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence
- [ ] **[RUNTIME-3](#runtime-3)** (4x4, medium) Stop opening nested modal run loops from inside an open send frame
- [ ] **[RUNTIME-4](#runtime-4)** (3x5, medium) Give each armed timer one owner instead of a handle field plus a token field
- [ ] **[RUNTIME-5](#runtime-5)** (3x4, small) Derive the previously visible tab from the reconcile cache, not from `isHidden`
- [ ] **[RUNTIME-6](#runtime-6)** (3x5, medium) Move the pane-tape follow broker out of AppRuntime into its own owner

#### Pane views and geometry (`PANE`)

- [ ] **[PANE-1](#pane-1)** (4x4, medium) Resolve the pane drop target from the model layout, not from live wrapper frames
- [ ] **[PANE-2](#pane-2)** (3x5, small) Type the container's leaf cache as the wrapper it needs, so a missing wrapper is retried, not cached
- [ ] **[PANE-3](#pane-3)** (3x4, small) Record which button a press forwarded, replacing the two ad-hoc pairing booleans
- [ ] **[PANE-4](#pane-4)** (3x5, small) Give the pane toolbar one projection argument instead of thirteen optional parameters and two model mirrors
- [ ] **[PANE-5](#pane-5)** (3x5, medium) Collapse the four duplicated fire-and-forget input methods into one completion-taking path

#### Window chrome and auxiliary UI (`CHROME`)

- [ ] **[CHROME-1](#chrome-1)** (5x5, large) Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value
- [ ] **[CHROME-2](#chrome-2)** (4x5, small) Make the confirmation projection carry each button's answer instead of inferring it from button visibility
- [ ] **[CHROME-3](#chrome-3)** (4x5, medium) Carry typed ids in sidebar menu items instead of bare UUIDs
- [ ] **[CHROME-4](#chrome-4)** (3x5, medium) Build the preferences grid from declared rows so warning rows and padding stop being addressed by literal index
- [ ] **[CHROME-5](#chrome-5)** (3x5, medium) Extract the theme list (filter, selection, cell vending) shared by the browser and the picker sheet
- [ ] **[CHROME-6](#chrome-6)** (3x4, medium) Give the alerts popover a typed, reusable row cell and stop computing row age at build time

#### PTY host and session boundary (`PTY`)

- [ ] **[PTY-1](#pty-1)** (4x5, medium) Cancel every retained dispatch source from the one registry that already holds them
- [ ] **[PTY-2](#pty-2)** (4x5, medium) Give TerminalPTYHost its geometry from the launch input instead of storing a second copy
- [ ] **[PTY-3](#pty-3)** (4x4, large) Record every applied transition on the flight tape and delete the five parallel capture buffers
- [ ] **[PTY-4](#pty-4)** (3x5, small) Read the PTY through one loop instead of one per drain reason
- [ ] **[PTY-5](#pty-5)** (3x4, medium) Dedupe grid submissions on the applied fact, not on an optimistic mirror in the controller
- [ ] **[PTY-6](#pty-6)** (2x5, small) Give viewport navigation its own three-case type instead of a nine-case enum guarded by preconditionFailure

#### iOS client (`IOS`)

- [ ] **[IOS-1](#ios-1)** (4x5, small) Let the replica report pinnedness instead of re-decoding tape JSON in the session model
- [ ] **[IOS-2](#ios-2)** (4x4, medium) Make an authorized attempt carry its target so a Go tap can never be dropped against a stale one
- [ ] **[IOS-3](#ios-3)** (3x4, medium) Give the model one connection identity instead of four optionals a nil response id can match
- [ ] **[IOS-4](#ios-4)** (3x5, small) Build the accessory key row from the key enum instead of matching two hand-numbered tag tables
- [ ] **[IOS-5](#ios-5)** (2x5, small) Delete the session vocabulary only tests can reach

#### Build, gate, CI, docs (`BUILD`)

- [ ] **[BUILD-1](#build-1)** (4x5, medium) Declare each source target's purity profile once, and make the gate enumerate targets
- [ ] **[BUILD-2](#build-2)** (4x4, medium) Make an orphaned gate self-test fail the gate instead of silently never running
- [ ] **[BUILD-3](#build-3)** (3x5, small) Put every gate scratch tree under one root so `just clean` cannot miss one
- [ ] **[BUILD-4](#build-4)** (3x5, small) Lint the Swift file-header rule AGENTS.md states, which is already violated nine times
- [ ] **[BUILD-5](#build-5)** (3x5, small) Give the three manifest-discovery lists one owner so a new package root cannot be skipped

### Cost

Round 2: performance and data modeling. Every item names the experiment that would decide it.

#### Terminal feed hot loop (`FEED`)

- [ ] **[FEED-1](#feed-1)** (5x5, large) Represent the viewport as a rotating row ring so a scroll advances a head index instead of moving every row
- [ ] **[FEED-2](#feed-2)** (4x5, small) Reach a row's cells once per run, not once per cell, on the bulk ASCII write and scan loops
- [ ] **[FEED-3](#feed-3)** (3x5, small) Store tab stops as a column bitset instead of a Set<Int>, so HT is a word scan rather than an allocation
- [ ] **[FEED-4](#feed-4)** (3x3, medium) Make TerminalStreamAction trivial and small by referencing parser-owned payloads, as the ASCII run already does
- [ ] **[FEED-5](#feed-5)** (3x3, small) Test grapheme-break class membership with a bitmask instead of array-literal `contains`

#### Cell, row, and style layout (`ROW`)

- **ROW-1** -- merged into [STORE-2](#store-2); nothing to track here.
- [ ] **[ROW-2](#row-2)** (5x4, large) Move multi-scalar spills out of GridCell so a live cell is trivially copyable and 16 bytes
- [ ] **[ROW-3](#row-3)** (4x3, medium) Stop recovering style liveness by rescanning the whole retained arena on the feed path
- [ ] **[ROW-4](#row-4)** (3x4, small) Write each printed cell once: clearCellAndPair's store at the target column is immediately overwritten
- [ ] **[ROW-5](#row-5)** (4x4, medium) Recycle the vacated row's cell buffer on scroll instead of allocating a fresh one per line

#### Scrollback store: append, retention, reflow (`HIST`)

- [ ] **[HIST-1](#hist-1)** (4x4, large) Give the open tail record one home: move its header and spills into the open scratch
- [ ] **[HIST-2](#hist-2)** (4x5, small) Skip the per-cell content-unit walk when the record's hasWideCells bit proves the count
- [ ] **[HIST-3](#hist-3)** (4x5, medium) Carry the fold's result in DisplayRowCursor so a row is folded once, not three times
- [ ] **[HIST-4](#hist-4)** (3x5, small) Take one locate for the whole truncated tail instead of one per row
- [ ] **[HIST-5](#hist-5)** (3x4, medium) Price the memory census by walking records, not by materializing every retained row

#### Damage and the per-frame snapshot (`FRAME`)

- [ ] **[FRAME-1](#frame-1)** (4x5, large) Publish the frame plan row-indexed so a row copy and a clip stop scanning the whole viewport
- [ ] **[FRAME-2](#frame-2)** (4x5, medium) Recompute ink reach only for the damaged rows instead of the whole plan on every incremental apply
- [ ] **[FRAME-3](#frame-3)** (3x5, small) Give TerminalDamage the predicates its consumers ask for, so no hot caller materializes a folded copy or a row array
- [ ] **[FRAME-4](#frame-4)** (2x4, medium) Store damage rows inline for grid-sized viewports instead of a heap array per damage value
- [ ] **[FRAME-5](#frame-5)** (3x3, medium) Derive each swapchain buffer's missed damage from its presented generation instead of mirroring damage into every buffer

#### AppKit draw path (`DRAW`)

- [ ] **[DRAW-1](#draw-1)** (4x5, medium) Carry each row's ink reach in the retained row product instead of rescanning the whole plan per apply
- [ ] **[DRAW-2](#draw-2)** (4x4, large) Give RenderFramePlan row-indexed run ranges so drawing a row set is an index, not a filter of every run
- [ ] **[DRAW-3](#draw-3)** (3x4, medium) Lower RenderColor straight into the context as components, deleting both the per-run CGColor allocation and the memo dictionary
- [ ] **[DRAW-4](#draw-4)** (3x4, medium) Route single-scalar astral cells through the batched cmap path instead of one CTLine per cell
- [ ] **[DRAW-5](#draw-5)** (2x3, medium) Stop driving a full NSScrollView geometry transaction from every viewport-state delivery

#### PTY transport (`XPORT`)

- [ ] **[XPORT-1](#xport-1)** (4x5, medium) Make the read turn, not the read() syscall, the unit that is fed and published
- [ ] **[XPORT-2](#xport-2)** (3x4, large) Store flight-recorder payloads in one bounded byte ring instead of one array per chunk
- [ ] **[XPORT-3](#xport-3)** (3x5, small) Give pending-input spans absolute byte coordinates so a partial write never rewrites the queue
- [ ] **[XPORT-4](#xport-4)** (2x4, small) Accumulate coalesced update payloads instead of rebuilding the merged signal per hop

#### Core lookups and copies (`LOOKUP`)

- [ ] **[LOOKUP-1](#lookup-1)** (5x4, large) Split AppModel into a persisted value and an ephemeral value so checkpoint change-detection stops rebuilding a DTO
- [ ] **[LOOKUP-2](#lookup-2)** (4x5, medium) Type snapshot identity fields as typed ids instead of String so capture stops formatting UUIDs
- [ ] **[LOOKUP-3](#lookup-3)** (4x5, small) Make DisplayLine normalization allocation-free for text that is already a single clean line
- [ ] **[LOOKUP-4](#lookup-4)** (3x5, small) Answer pane-membership and layout questions with a tree walk instead of materializing pane-id arrays and sets
- [ ] **[LOOKUP-5](#lookup-5)** (3x4, large) Key groups and tabs by id and make mruOrder an OrderedSet so per-message repair stops allocating sets
- [ ] **[LOOKUP-6](#lookup-6)** (2x5, small) Resolve each sidebar row's chrome once per sweep instead of twice through separate title and subtitle accessors

#### Reconcile cost per frame (`RECON`)

- [ ] **[RECON-1](#recon-1)** (5x5, small) Make container visibility a diffed field of ContainerShape instead of an unconditional per-tab op
- **RECON-2** -- merged into [MODEL-3](#model-3); nothing to track here.
- [ ] **[RECON-3](#recon-3)** (4x4, medium) Normalize terminal-reported text once at ingress so DisplayLine is stored, not recomputed every sweep
- [ ] **[RECON-4](#recon-4)** (3x5, medium) Key the sidebar projection's tabs by id so row lookups stop being linear scans with intermediate arrays
- [ ] **[RECON-5](#recon-5)** (3x4, small) Separate the pane strip's overflow-label metrics from its color so fitting stops measuring text
- [ ] **[RECON-6](#recon-6)** (2x5, small) Compute the pane roster only when someone is subscribed, instead of on every send

#### Search index and scanning (`FIND`)

- [ ] **[FIND-1](#find-1)** (5x5, large) Narrow the closed-history index on needle append instead of rebuilding it per keystroke
- [ ] **[FIND-2](#find-2)** (4x5, medium) Build the per-frame match snapshot once and pass it to all three search reads
- [ ] **[FIND-3](#find-3)** (4x4, medium) Replace NeedleWindow's key ring with a KMP state plus a POD ring of start positions
- [ ] **[FIND-4](#find-4)** (3x4, medium) Answer "does this projection row have content" without materializing a painted GridRow
- [ ] **[FIND-5](#find-5)** (3x4, medium) Carry each suffix match's content ordinal out of the scan that already counts it

#### Serialization: IPC, tape, checkpoints (`WIRE`)

- [ ] **[WIRE-1](#wire-1)** (4x5, small) Frame IPC lines by scanning for the newline, not by appending one byte at a time
- [ ] **[WIRE-2](#wire-2)** (5x5, large) Carry a tape record as its typed event, not as a JSONValue decoded from its own encoding
- [ ] **[WIRE-3](#wire-3)** (4x4, medium) Encode a delivered tape batch as one notification off the main actor, not one per record
- [ ] **[WIRE-4](#wire-4)** (4x4, medium) Detect persisted-state divergence without re-projecting the whole model on every message
- [ ] **[WIRE-5](#wire-5)** (3x4, medium) Let the engine cut the checkpoint tail once, instead of re-walking the projected text to trim it
- [ ] **[WIRE-6](#wire-6)** (3x5, small) Chunk and base64 the sync payload from slices, without copying the bytes three times first

#### iOS client data flow (`MOBILE`)

- [ ] **[MOBILE-1](#mobile-1)** (5x5, medium) Resolve cell metrics where the display scale changes, not on every applied tape record
- [ ] **[MOBILE-2](#mobile-2)** (4x5, medium) Feed the drained damage into the frame stores instead of re-rendering the whole grid every tick
- [ ] **[MOBILE-3](#mobile-3)** (4x5, medium) Decode each tape event once into a typed value instead of re-encoding and re-decoding it per record
- [ ] **[MOBILE-4](#mobile-4)** (4x4, small) Signal replica state and surface geometry only when they change, not once per applied record
- [ ] **[MOBILE-5](#mobile-5)** (4x3, large) Own the replica off the main actor and hand the main actor frames instead of records

#### Unicode tables and lookups (`UNI`)

- [ ] **[UNI-1](#uni-1)** (4x5, medium) Store the packed scalar record as a palette index over 29 decoded entries, not a 16-bit bitfield
- [ ] **[UNI-2](#uni-2)** (4x4, large) Derive the bulk-print run predicate from the scalar record instead of from a printable-ASCII byte range
- [ ] **[UNI-3](#uni-3)** (3x4, medium) Generate the UAX #29 pair verdicts as a class table instead of array-literal set membership
- [ ] **[UNI-4](#uni-4)** (3x4, medium) Let the canonical-caseless tables answer "this scalar is unaffected" without a binary search or an allocation

## Findings in detail

## Structure findings

### Area: Terminal parser and screen state (`PARSE`)

_Scope: Terminal escape-sequence parser and screen state machine (lib/TerminalCore: Terminal.swift, EscapeAbsorber.swift, OSCPayload.swift, TerminalInputStream.swift, UTF8Decoder.swift, TerminalScalars.swift, TerminalStyle.swift, TerminalDefaultColors.swift)_

**Auditor's read on the area.** The byte-level layers are in good shape: `UTF8Decoder` is a clean DFA with correct maximal-subpart replacement, `EscapeAbsorber` is a faithful bounded VT500 state machine with inline fixed-capacity parameter storage, and `TerminalInputStream` documents its ASCII-run fast path and chunk-invariance contract well. The problems are concentrated in `Terminal.swift`, where protocol knowledge that should live in one table is hand-enumerated in several places and the two-screen model is expressed as an optional that forces two `preconditionFailure`s and a force unwrap. I did not audit reflow (`resizeWidth`/`reconstructLogicalLines`), `LogicalLineStore`, damage accumulation, or search/link projection internals, and I did not evaluate DEC Special Graphics (`ESC ( 0`), which `docs/scratch/alacritty-test-portage.md` records as a deliberate omission but which the decision register does not mention.

<a id="parse-1"></a>

#### PARSE-1. Clamp relative vertical cursor motion to the scroll region, not just to the screen

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

#### PARSE-2. Make "alternate screen live without a retained primary" unrepresentable

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

#### PARSE-3. Derive DEC/ANSI mode set, reset, query and resynchronization from one mode table

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

#### PARSE-4. Parse the SGR 38/48/58 color grammar once instead of once per separator style

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

#### PARSE-5. Reset the saved cursor as part of DECSTR

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

#### PARSE-6. Split the inspection layer and the state-synchronization encoder out of the Terminal struct

`structural` &middot; impact 3, confidence 4 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#invalidateInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#clearInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#refreshHasContentInspectionState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#encodeStateSynchronization`

**Problem.** `Terminal` is a single 7.6k-line struct carrying roughly sixty stored properties and doing at least five separable jobs: escape dispatch and grid mutation, width/height reflow, scrollback and eviction, user inspection (selection, search, hovered and armed links, viewport anchoring, row-numbering epochs), and the state-synchronization byte encoder. Every private method can write every field, so cross-job invariants -- "a grid mutation that overwrites content retires the link state anchored there", "a history mutation resynchronizes the search index" -- are upheld by remembering to call a function, and the compiler cannot help.

**Evidence.** The inspection fields (`selection`, `selectionRequiresNonemptyReflowResult`, `search`, `hoveredLinkState`, `armedLinkState`, `hoveredLinkRevisionCounter`, `hasContentInspectionState`, `viewportState`, `rowNumberingEpoch`, `evictedRowCount`) are plain private vars sitting alongside `screen`, `history`, `modes` and `styleTable`. Their coherence is maintained by property observers (`didSet { refreshHasContentInspectionState() }` on three of them) and by grid code remembering to call one of four differently scoped entry points -- `invalidateInspection(inViewportRows:)`, `invalidateInspectionState(inViewportRows:)`, `invalidateInspection(inScrollbackRow:)`, `synchronizeSearchIndexPrefix()` -- which a new mutation path must pick correctly from. Separately, `encodeStateSynchronization` and its helpers (`appendControlState`, `appendSavedCursor`, `appendModes`, `appendSemanticState`, `appendGraphemeSynchronization`, `boundedHistoryStart`, `alignedHistoryStart`) are roughly 350 lines that only read state and emit bytes.

**Ideal fix.** Two extractions, independently landable. First, lift the inspection fields into a `TerminalInspection` value that owns them and exposes only intent-level mutations (`invalidate(absoluteRows:)`, `clear()`, `resynchronize(with:)`), with the projection passed in as an argument; `Terminal` then holds one `inspection` field and grid code can reach that state only through the API. Second, move the state-synchronization encoder into its own type in its own file, constructed from a read-only view of the terminal. Both shrink `Terminal` to parser plus grid plus reflow and give each extracted job a testable surface of its own.

**By construction.** After the inspection lift, grid and parser code cannot assign to `selection`, `search` or the link slots at all; the only way to affect them is the invalidation API, so "a new mutation path that writes inspection state directly and skips the damage bookkeeping" stops being expressible.

**Cheaper fallback.** If the inspection lift proves too entangled with reflow's anchor capture and restatement, do the state-synchronization encoder alone -- it is pure read-and-emit -- and leave inspection in place with a written note that the lift is the remaining half.

**Verification.** No behavior may change, so the proof is the existing `TerminalCoreTests` suites (selection, search, hyperlink interaction, stale-wrap-claim, state-synchronization round trips) passing unchanged, plus a state-synchronization round-trip test that feeds an encoded snapshot into a fresh terminal and asserts equality of projected text, cursor, modes and styles.

**Risk.** The inspection lift touches reflow's anchor capture and restatement, the most delicate code in the file; the round-trip and selection-across-resize tests keep it honest, and the encoder extraction can ship first to de-risk the sequencing.

### Area: Scrollback and row storage (`STORE`)

_Scope: Scrollback and row storage (LogicalLineStore, LogicalLineRecord, PackedRetainedRow, TerminalMemoryCensus, Instruments, TerminalGeometry)_

**Auditor's read on the area.** The doc-31 arena store is unusually disciplined: the two grand totals are already derived off the block ring, the side-table charge has a recount oracle asserted in `census`, and the fold has one shared shape function feeding all three read walks. The residue is concentrated in three places -- the one remaining hand-maintained byte total (`bytesInUse`), the previous representation (`PackedRetainedRow`) that survives only as a constant namespace, and a handful of hand-copied arithmetic idioms (cell-word decode, block-to-record-range). I did not audit `Terminal.swift`'s side of the seam (anchors, projections, admission triggers) or the test files beyond checking which oracles exist; `TerminalGeometry.swift` is plain read-only value types and yielded nothing.

<a id="store-1"></a>

#### STORE-1. Derive arena bytes-in-use from the ring cursors instead of maintaining it at twelve sites

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

#### STORE-2. Delete PackedRetainedRow's dead body and move the cell-word constants to the store that uses them

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

#### STORE-3. Give the 8-byte cell word one encode/decode type instead of eight hand-inlined shift sites

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

#### STORE-4. State the open tail's scratch-table key base once, so a trimmed head cannot key it two ways

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

#### STORE-5. Give a block one record-range accessor instead of five hand-copied index conversions

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#recomputeIndex`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#firstDisplayRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#contentRank`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#locate`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#independentContentBlockTotalsForTesting`

**Problem.** The mapping from a block index to the retained record indices it covers is written out five times. It is the store's trickiest arithmetic -- it must clamp the first block against `firstRecordSequence` because the head block is partially evicted, and the last against `offsets.count` -- and every reader that touches the block ring re-derives it. The oracle `independentContentBlockTotalsForTesting` re-derives it too, so it does not check that arithmetic independently of the code it is meant to check.

**Evidence.** `let first = max(firstRecordSequence, blockNumber * Self.blockSize) - firstRecordSequence` together with `let end = min(offsets.count, (blockNumber + 1) * Self.blockSize - firstRecordSequence)` appears verbatim in `recomputeIndex` and in `independentContentBlockTotalsForTesting`. The `first` half alone reappears as `blockFirst` in both `contentRank(of:)` and `firstDisplayRow(ofRecord:)`, and as `let firstSequence = max(firstRecordSequence, blockNumber * Self.blockSize)` in `locate(displayRow:)`. All five also independently compute `let blockIndex = sequence / Self.blockSize - firstBlockNumber` or its inverse.

**Ideal fix.** Add two private accessors -- `blockIndex(ofRecord:) -> Int?` and `recordRange(inBlock:) -> Range<Int>` -- and route all five sites through them. `recomputeIndex`, `contentRank`, `firstDisplayRow`, and `locate` then read as a block lookup plus a scan over a range, and the head-block clamp is stated once.

**By construction.** The head block's partial-eviction clamp stops being something each caller can get wrong: a caller can only ask a block which records it covers, so a site that forgets the `max(firstRecordSequence, ...)` clamp cannot be written.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** Existing coverage carries this: `independentContentBlockTotalsForTesting` against `contentBlockTotalsForTesting`, `independentDisplayRowRecount` against `grandDisplayRowTotal`, and the `locate` / `position(ofRecord:cellOffset:)` round-trip expectations in `TerminalLogicalLineStoreTests` all fail if the range conversion changes meaning.

**Risk.** The one judgement call is the test oracle: routing `independentContentBlockTotalsForTesting` through the shared accessor weakens it as an independent check, so keep that site spelled out and say why in its comment.

### Area: Selection, search, damage, presentation (`INTERACT`)

_Scope: Terminal selection, search, hit-testing, damage, and presentation snapshotting_

**Auditor's read on the area.** The area is in good shape: `TerminalDamage`'s word-backed representation, `NeedleWindow`'s position-generic matcher, `TerminalSearchStatus`'s "no invalid counter" enum, and the pinned-range selection drag are all careful, well-documented designs. The findings below are all about facts that still have two owners or two spellings: one damage-composition rule written twice, one search-index refresh that must be pushed from seven call sites, one pointer-cell value that is destructured before it crosses the policy seam, and one selection mutation whose granularity travels beside it instead of inside it. I did not audit the render planner (`RenderFramePlanner`, `SearchMatchRenderPlanning`), `TerminalInputEncoding`, or `LogicalLineStore`, and I ran no builds or tests -- every claim is from reading the cited code.

<a id="interact-1"></a>

#### INTERACT-1. Refresh the search index through one history-mutation funnel instead of seven hand-placed calls

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

#### INTERACT-2. Carry the normalized `TerminalViewportCell` into `TerminalPointerEvent` and decide link cancellation inside the policy

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

#### INTERACT-3. Delete `TerminalDamageAccumulator`'s copy of the shift-composition rule and let it hold a `TerminalDamage`

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

#### INTERACT-4. Put the selection granularity inside `TerminalSelectionMutation.set` instead of beside it

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

#### INTERACT-5. Parameterize the one cell-to-search-unit scan by position type instead of writing it twice

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

#### INTERACT-6. Key pointer-owner and wheel-remainder storage by their enums instead of by hand-written slots

`structural` &middot; impact 2, confidence 4 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#TerminalInteractionState`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#wheelRemainder`

**Problem.** `TerminalInteractionState` stores one owner per mouse button as a three-element array literal indexed by `button.rawValue`, and one wheel remainder per route as three named fields reached through three hand-written switch functions. Both are per-case storage enumerated by hand. `TerminalMouseButton` is a plain `Int`-raw enum with no `CaseIterable`, so adding a fourth button (back/forward, which AppKit does deliver) makes `state.pointerOwners[button.rawValue]` a fatal index-out-of-range at the first press rather than a compile error; adding a wheel route means remembering to extend three separate switches.

**Evidence.** `fileprivate var pointerOwners: [TerminalPointerConsumption?] = [nil, nil, nil]`, read and written throughout `decideTerminalPointer` as `state.pointerOwners[button.rawValue]`. `TerminalMouseButton` is declared `public enum TerminalMouseButton: Int` with `left = 0`, `middle = 1`, `right = 2` and no `CaseIterable`. The wheel side has `localWheel`/`reportWheel`/`alternateWheel` plus `wheelRemainder(for:state:)`, `setWheelRemainder(_:for:state:)` and `resetWheelRemainder(for:state:)`, each a three-case switch over `TerminalWheelRoute`.

**Ideal fix.** Make both enums `CaseIterable` and hold the per-case values in one small keyed value (a dictionary keyed by the enum, or a fixed-size store built from `allCases`) with a subscript. `state.owners[button]` and `state.wheel[route]` then have no index arithmetic and no per-case accessor functions, and a new case gets storage automatically.

**By construction.** "A button with no slot in the owner array" and "a wheel route wired into some of its accessors but not all" become unrepresentable: storage is derived from the case list rather than restated next to it.

**Cheaper fallback.** Leave the storage shape and add `CaseIterable` plus a `precondition(button.rawValue < pointerOwners.count)`. That converts a crash into a louder crash and keeps the three wheel switches.

**Verification.** Behavioral test: drive a full press/drag/release gesture on each button and each wheel route through `decideTerminalPointer` / `decideTerminalWheel` and assert ownership latching and fractional accumulation are unchanged; the existing `TerminalInteractionPolicyTests` wheel-remainder and owner tests cover most of this already. `swift test --package-path lib/TerminalCore --filter InteractionPolicy`.

**Risk.** `TerminalInteractionState` is `Equatable` and copied per event; a dictionary makes it refcounted, which matters if this value is copied on a hot path. Prefer a fixed-size inline store over a `Dictionary` if the pointer path shows up in a profile.

### Area: Core reducer (Update/Msg/Command) (`REDUCE`)

_Scope: The pure Elm reducer and its message/command vocabulary (lib/DanTermCore/Sources/DanTermCore/Update.swift, Msg.swift, Command.swift, CoreEnvironment.swift, ReconcileFollowUps.swift, PaneLifecycle*.swift)_

**Auditor's read on the area.** The reducer is disciplined in the large: one chokepoint `defer` runs the four repair passes, `Command` is genuinely free of projection cases, and every `Command` case has exactly one consumer in `AppRuntime.perform`. The weak spots are all in the middle layer: a pending-confirmation record whose four optionals are validated by hand instead of by type, one Msg/Command pair that launders model state through the view and back, and a "clear the focused pane's alerts" rule copied into nine arms with two arms that quietly disagree. I did not audit IpcDispatch.swift, ModelOperations.swift, or Model.swift beyond the declarations the reducer arms depend on, nor the app-side reconcile passes except where a finding proposes moving work into one.

<a id="reduce-1"></a>

#### REDUCE-1. Make PendingConfirmation an enum so a subject cannot carry the wrong payload

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

#### REDUCE-2. Let .startSearch open the pane's search state directly instead of round-tripping through the view

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

#### REDUCE-3. Repair the focused pane's alerts in one pass instead of copying the rule into nine arms

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

#### REDUCE-4. Derive terminal focus from the model instead of emitting focusSession(false) from four arms

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

#### REDUCE-5. Raise every pane alert through one function instead of duplicating the ritual in .sessionBell

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

#### REDUCE-6. Tie a pending IPC input request to its pane so pane teardown can reject it

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

#### REDUCE-7. Delete the senderless .markAlertRead message

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** `Msg.markAlertRead` has no producer anywhere in the app, the iOS target, or the IPC dispatch table. Its only callers are two unit tests, so the reducer arm and the test both describe a path the product cannot take, and a reader has to check the whole tree to learn that.

**Evidence.** Grepping `markAlertRead` across app/, ios/, and lib/ outside tests returns only the declaration in `Msg.swift` and the arm in `Update.swift`; the alerts popover row activation sends `.activateAlert`, and bulk clearing goes through `.markAllAlertsRead`, `.clearAlertsForPane`, and `.clearAlertsForTabs`. The two hits in `UpdateAlertTests.swift` are the only senders.

**Ideal fix.** Remove the case, the arm, and the two tests that exercise it. If per-alert acknowledgement is wanted in manual clear mode, add it back with the UI or IPC producer in the same change so the vocabulary always names something a user can do.

**By construction.** n/a -- this removes dead vocabulary rather than making a state unrepresentable.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** The build fails if any real producer existed; `swift test --package-path lib/DanTermCore` passes after the two tests are deleted, and the remaining alert tests still pin `.activateAlert` marking its alert read outside manual mode.

**Risk.** None beyond losing a path nothing uses; the same behavior is reachable through `.activateAlert` and the bulk-clear messages.

### Area: Core model and projections (`MODEL`)

_Scope: Pure domain model and derived projections (lib/DanTermCore/Sources/DanTermCore: Model.swift, ModelOperations.swift, PaneLayout.swift, PaneGridOverride.swift, Projections.swift, PaneRosterProjection.swift, DisplayLine.swift, DropZone.swift, DragDropInput.swift, EntityTitle.swift, SidebarItemStore.swift, ScrollbarMath.swift, ChipKind.swift)_

**Auditor's read on the area.** The core of this area is in good shape: `PaneTree` already makes "a pane with no owning leaf" unrepresentable, `PaneGridOverride` fails instead of clamping, `DisplayLine` is a genuinely tight boundary type, and `PaneLayout` is a clean pure projection with one rounding rule shared by layout and drag inversion. The remaining defects all have the same shape -- a product type whose fields are only valid in certain combinations, or a second copy of a fact some other value already carries. I did not audit Update.swift, IpcDispatch.swift, Persistence.swift, PaneLifecycleReducer.swift, Reconcile.swift, or SidebarView.swift as subjects; I read them only to establish reachability and call-site counts for defects whose home is in my files. I looked at ScrollbarMath's UInt64 subtraction (`total - offset - len` traps on underflow) and dropped it: the engine's `scrollProjection` guarantees `topRow + windowRows <= totalRows`, so I could not show it reachable.

<a id="model-1"></a>

#### MODEL-1. Replace PendingConfirmation's subject-plus-optional-payloads with one per-subject enum

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

#### MODEL-2. Make SidebarItemStore reject nothing, or report rejection, so a dropped row op cannot strand the outline

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

#### MODEL-3. Collapse ContainerShape to layout plus zoomedLeaf; derive the structural fingerprint

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#ContainerShape`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#containerShape`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#computeContainerOps`

**Problem.** `ContainerShape` stores three facts of which two are derived. `tree` is exactly `layout` with the ratios dropped, and `isZoomed` is exactly `zoomedLeaf != nil`. Both duplicates participate in `Equatable`, and `isZoomed` is read by nothing at all -- it can only produce a spurious shape difference. The initializer also takes `tree` and `layout` independently, so a value whose structural fingerprint disagrees with its own layout tree is representable.

**Evidence.** `ContainerShape` declares `let tree: ContainerShapeNode; let layout: ContainerLayoutNode; let isZoomed: Bool; let zoomedLeaf: PaneId?`, with an initializer defaulting `layout` to `defaultContainerLayoutNode(tree)` -- a fabricated 0.5-ratio tree. `containerShapeNode` and `containerLayoutNode` are the same walk, the second keeping `ratio`. `containerShape(of:)` always builds them consistently (`isZoomed: tab.paneTree.isZoomed, zoomedLeaf: tab.paneTree.isZoomed ? tab.paneTree.focusedPaneId : nil`). `computeContainerOps` reads only `oldShape.tree != shape.tree`, `oldShape.layout != shape.layout`, and `oldShape.zoomedLeaf != shape.zoomedLeaf`; grepping `isZoomed` across app/ and lib/ finds no read of `ContainerShape.isZoomed` outside its own declaration and test fixtures.

**Ideal fix.** Reduce `ContainerShape` to `let layout: ContainerLayoutNode` and `let zoomedLeaf: PaneId?`, with `var structure: ContainerShapeNode` computed by dropping ratios from `layout`. Delete `isZoomed`, `containerShapeNode(_:)` over `SplitNodeModel`, and `defaultContainerLayoutNode`; `computeContainerOps` then compares `structure` for `.setTree` and `layout` for `.setLayout` off one stored value.

**By construction.** A container shape whose structural fingerprint contradicts its own layout tree, and a shape claiming zoom with no zoomed leaf (or a zoomed leaf with zoom off), stop existing as values.

**Cheaper fallback.** none -- the ideal fix is smaller than what it replaces.

**Verification.** The existing container-op model-apply tests must keep passing: build old/new shapes from real `TabModel`s via `containerShape(of:)`, apply `computeContainerOps` to a presence/visibility map, and assert it equals the new key set and visibility. Add one case asserting a ratio-only edit yields `.setLayout` and never `.setTree`.

**Risk.** Test fixtures construct `ContainerShape(tree:isZoomed:zoomedLeaf:)` directly and must be rewritten to build a layout node; no production caller does.

**Added by the cost pass (RECON-2).** The performance pass prices this mirror per sweep rather than per reader. `desiredContainerShapes` rebuilds both indirect enums for every tab in the model on every reconcile sweep, and an indirect enum boxes each node, so a tab with P panes heap-allocates 2 x (2P-1) boxes per sweep -- and sweeps run inline for every non-coalescing Msg and at up to 1/0.075s for coalesced ones. Dropping the `tree` mirror and comparing the layout tree with a ratio-skipping structural walk halves that allocation count and removes the one reason the projection needs a second traversal. No calibrated workload can decide it, because every workload on the ladder runs one tab and one pane: the honest instrument is `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30`, reading the combined main-thread share of the shape-node builders and `swift_allocObject` under `reconcileContainers`, and the honest report at one tab is "the frame is present or absent", not a speedup. The regression risk is that structural equality and layout equality stop being two separately stored values that can be compared field by field: if the ratio-skipping walk is written wrong, a pure ratio change is misread as a tree change and the container is torn down and rebuilt (losing pane view state), or a genuine tree change is misread as ratio-only and the panes never remount. Both directions need a behavioral test over the diff -- a ratio-only edit must emit `.setLayout` and never `.setTree`, and a split or close must emit `.setTree` -- before the second mirror is deleted.

<a id="model-4"></a>

#### MODEL-4. Group the sidebar group row's reload attributes into one Equatable value

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

#### MODEL-5. Move per-pane search and notification-throttle state into PaneModel so pane teardown prunes them

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

#### MODEL-6. Drop the submission-to-request reverse index and derive it from the pending requests

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

#### MODEL-7. Make PaneTree.remove non-mutating and return an outcome that cannot be misread as a live tree

`api-shape` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PaneTree`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#removeLeaf`

**Problem.** `PaneTree.remove` mutates in place and reports emptiness through a boolean on its result. In the emptied case it leaves `root` and `focusedPaneId` untouched -- the tree still contains the pane the call just reported as removed -- so the returned value and the mutated tree disagree, and correctness rests on every caller reading `emptiedTree` before writing the tree back. A call site that writes `tab.paneTree = sourcePaneTree` without checking silently resurrects the pane it just moved elsewhere, duplicating a pane id across two tabs.

**Evidence.** `remove` does `guard let newRoot else { return Removal(pane: removedPane, emptiedTree: true, focusMoved: focusMoved) }` -- returning before `root = newRoot`. The callers branch by hand: `Update.swift#movePaneToTab` writes `if !removal.emptiedTree { updateTab(...) { $0.paneTree = sourcePaneTree } } else { removeTab(...) }`, and `movePaneToNewTab` guards with `guard let removal = sourcePaneTree.remove(paneId), !removal.emptiedTree else { return [] }`. `Removal` documents the hazard -- "Describes a removal without permitting an empty `PaneTree` value" -- while still handing back a tree that contradicts its own report.

**Ideal fix.** Replace the mutating method with a non-mutating `func removing(_ paneId: PaneId) -> RemovalOutcome`, where `RemovalOutcome` is `.notFound`, `.emptied(PaneModel)`, or `.remaining(PaneTree, pane: PaneModel, focusMoved: Bool)`. The surviving tree then exists only inside the case that has one.

**By construction.** "A pane tree that reported its last pane removed, still holding it" stops being obtainable: the emptied case carries no tree to write back.

**Cheaper fallback.** Keep the mutating signature but have callers pre-test `if case .leaf(let p) = tree.root, p.id == paneId`, which is what `movePaneToNewTab` already does for its single-pane path. This spreads the shape test back out to call sites and is strictly worse.

**Verification.** Behavioral test: move the only pane of a two-tab window's first tab into the second tab, then assert the model has exactly one tab and the moved pane id appears exactly once in `model.allPaneIds`. A second test moves a pane out of a split tab and asserts the source tab survives with its remaining pane focused.

**Risk.** Three call sites in Update.swift change shape; each already branches on `emptiedTree`, so the rewrite is mechanical, but the focus-move assertions in PaneTreeTests exercise the mutating form and need updating.

### Area: IPC protocol, dispatch, CLI (`IPC`)

_Scope: IPC surface: wire protocol, dispatch, and the CLI client (lib/DanTermProtocol, IpcDispatch/IpcEntityEncoder, lib/DanTermClient, app/IpcServer.swift, cli/main.swift, integrations/danterm/SKILL.md)_

**Auditor's read on the area.** The wire layer is in good shape: framing is one shared `IpcLineFramer` used by both ends, the CLI can only build a request through the typed `IpcRequest` catalog, and `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog` pins encode/decode against each other for every method, so the two mirrored switches in `IpcRequest` cannot drift silently. The weak spots are the projections that were written as a *third* copy of the same facts with a `default:` escape (the audit descriptor), and the human-facing surface (help text, per-parser usage strings, SKILL.md) which is admitted in a comment to be hand-synced with no check. I did not audit the tape/snapshot record formats, the audit log writer itself, or the transports' socket mechanics beyond their error vocabulary.

<a id="ipc-1"></a>

#### IPC-1. Derive the IPC audit descriptor from the request's encoded params, not a third hand-written switch

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

#### IPC-2. Generate the CLI help text and SKILL.md synopsis from one command table instead of hand-syncing three copies

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

#### IPC-3. Give the todo state change one catalog case so three unreachable `preconditionFailure` arms disappear

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

#### IPC-4. Return one traits value from a single exhaustive switch instead of six parallel per-method enumerations

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

#### IPC-5. Make IpcRequest.decode typed-throws so IpcServer cannot need two decode-failure paths

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

#### IPC-6. Collapse CLIResolvedTarget into CLIConnectionTarget

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `cli/main.swift#CLIResolvedTarget`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#CLIConnectionTarget`

**Problem.** Two enums with identical cases and identical payloads exist side by side, plus a private converter between them. The distinction they claim to draw -- "before" versus "after" ambient socket resolution -- is already carried by the optionality of the parsed value (`CLIInvocation.target` is `CLIConnectionTarget?`, and `selectConnectionTarget` returns a non-optional).

**Evidence.** CLIParser.swift declares `public enum CLIConnectionTarget { case unixSocket(path: String); case tcp(host: String, port: UInt16) }`; cli/main.swift#CLIResolvedTarget declares `enum CLIResolvedTarget: Equatable { case unixSocket(path: String); case tcp(host: String, port: UInt16) }` and `private extension CLIResolvedTarget { init(_ target: CLIConnectionTarget) { switch target { case .unixSocket(let path): self = .unixSocket(path: path); case .tcp(let host, let port): self = .tcp(host: host, port: port) } } }`.

**Ideal fix.** Delete `CLIResolvedTarget` and have `selectConnectionTarget` return a non-optional `CLIConnectionTarget`. `openSession` switches over the one type.

**By construction.** The class of bug where the two enums drift -- one gains a transport case the other lacks, or the converter maps a payload wrong -- stops existing, because there is one type and no conversion.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The existing target-selection behavior tests must stay green: `quit` without `--socket`/`--tcp` is refused, `DANTERM_SOCK` is used when no explicit target is given, and `DANTERM` set without `DANTERM_SOCK` reports "DanTerm is not running". Run the CLI test target and scripts/tests/danterm-cli_test.sh.

**Risk.** `CLIConnectionTarget` is public in DanTermProtocol while `CLIResolvedTarget` is CLI-local; reusing the public type means the CLI's resolved value is expressible by other clients. That is harmless here -- it is the same shape either way.

### Area: Persistence, recovery, support layer (`PERSIST`)

_Scope: Persistence, recovery, and the portable side-effect layer (lib/DanTermCore Persistence/CheckpointCapture/RecoveryCheckpointPolicy/AgentSession/TabTodo + all of lib/DanTermSupport/Sources/DanTermSupport)_

**Auditor's read on the area.** The pure halves are in good shape: `RecoveryCheckpointPolicy` is a tight, self-consistent state machine (I traced every edge and found no reachable stuck state), `CheckpointCapture` already makes snapshot/scrollback pairing structural, `ControlSocketListener` and `TailnetListener` own their descriptors carefully, and `AgentSession` validation is sound. The weak spots cluster in three places: `RecoveryStore` (the whole session-lock contract is decided by a decode that can fail silently, and each path helper defaults its own directory independently), the snapshot codec's hand-enumerated re-builds, and layer placement in the pane-tape files. I did not audit `CLIPathInstaller`, `FontAvailability`, `TailnetBindAddress`, or the whois/HTTP parsing in `TailnetWhoisResolver` beyond a scan for swallowed failures, and I stayed out of `app/AppRuntime`'s checkpoint scheduling, which another auditor owns.

<a id="persist-1"></a>

#### PERSIST-1. Decide crash recovery from the lock file's existence, not from decoding it

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

#### PERSIST-2. Give the recovery directory one owner: a RecoveryPaths value threaded from launch

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

#### PERSIST-3. Graft scrollback through one leaf-mapping traversal instead of re-listing snapshot fields

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

#### PERSIST-4. Confine the IPC connection's descriptor to its write queue so a queued write cannot land on a reused fd

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

#### PERSIST-5. Move the pure pane-tape stream policy into DanTermCore and leave only the socket write in Support

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

#### PERSIST-6. Publish the pane-tape record shape once in DanTermProtocol instead of writing keys on both sides

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

#### PERSIST-7. Drive doctor's agent probes from one agent registry shared with KnownAgent

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#gatherClaudeFacts`, `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#gatherCodexFacts`, `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift#KnownAgent`, `lib/DanTermProtocol/Sources/DanTermProtocol/DoctorFacts.swift`

**Problem.** The set of agents DanTerm knows is written out separately in four places: `KnownAgent` in core, two near-identical probe functions in DoctorProber, named `claude`/`codex` fields on `DoctorFacts`, and hardcoded pairs in `cli/Doctor.swift`. `KnownAgent`'s doc comment claims the exact invariant this breaks -- that adding an agent cannot leave it known to one lookup and unknown to another. Adding a third agent means editing all four and produces a build that compiles while doctor stays silent about it.

**Evidence.** `gatherClaudeFacts` and `gatherCodexFacts` differ only in the root directory, the hook file names, and the extra TOML scan -- both then build the same `DoctorFacts.Agent` from `skillPaths = [root/skills/danterm, home/.agents/skills/danterm]`. `DoctorFacts` declares `public var claude: Agent` and `public var codex: Agent` as separate stored fields, and `cli/Doctor.swift` names `facts.claude` twice, `facts.codex` twice, and both again in `facts.claude.dantermHooks.isEmpty == false || facts.codex.dantermHooks.isEmpty == false`.

**Ideal fix.** Put one `AgentIntegration` registry in DanTermProtocol (the leaf both core and support already depend on): a case per agent carrying its id, display name, home-directory resolver, hook file list, skill subpath, and resume-command template. `KnownAgent` becomes a thin core view over it, `DoctorFacts` carries `agents: [AgentIntegrationId: Agent]`, and DoctorProber keeps one probe function mapped over the registry.

**By construction.** "An agent is known to the toolbar chip but invisible to doctor" becomes unrepresentable -- both are derived from one registry, so a new case forces every consumer to handle it.

**Cheaper fallback.** Keep the two probe functions but parameterize them into one `gatherAgentFacts(root:hookFiles:skillPaths:)`, leaving the agent list still duplicated across core, protocol, and the CLI. This removes the copied algorithm but not the divergent enumerations.

**Verification.** A DanTermSupport test that populates a temp home with a fixture directory for every registry entry and asserts `gatherDoctorFacts` returns a fact per entry; adding a registry case without touching DoctorProber must make that test cover the new agent automatically.

**Risk.** `DoctorFacts` is a public protocol type consumed by the CLI's report, so changing the two named fields to a keyed collection changes the doctor JSON shape -- external in the sense that the shipped skill documents it, so `integrations/danterm/SKILL.md` must change in the same commit.

### Area: App runtime and reconcile (`RUNTIME`)

_Scope: AppKit runtime: Command interpreter and reconcile passes (app/AppRuntime.swift, app/Reconcile.swift, app/ReconcileOutbox.swift, app/AppRuntimePorts.swift, app/AppRuntimeSchedulingLifecycle.swift, app/AppPresentationLifecycle.swift, app/AppDelegate.swift, app/AppLaunchPolicy.swift, app/MenuCommandPolicy.swift, app/ObserveOnMain.swift, app/main.swift)_

**Auditor's read on the area.** The reconcile layer is in good shape: every panel except one is projected from a model slot through a diffed cache, the outbox already forbids dispatching on a reporting stack, and `AppRuntimeSchedulingLifecycle` gives every timer/monitor/subscription a single census-backed teardown -- which is why I found no violation of docs/design/2026-06-09-appkit-lifetime-safety.md. The weak seams are all "two writers for one truth": restore writes `model` directly, the theme browser keeps its existence in a view field, alerts open nested modal run loops inside an open send frame, and several armed owners are stored as handle+token field pairs kept in lockstep by hand. I did not audit the pure projections in `lib/DanTermCore` beyond what the passes read, nor the sidebar driver, nor `IpcServer` internals.

<a id="runtime-1"></a>

#### RUNTIME-1. Make the restore commit a Msg so `update()` is the only writer of `model`

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

#### RUNTIME-2. Give the theme browser a model slot so `reconcileThemeBrowser` owns its existence

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

#### RUNTIME-3. Stop opening nested modal run loops from inside an open send frame

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

#### RUNTIME-4. Give each armed timer one owner instead of a handle field plus a token field

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

#### RUNTIME-5. Derive the previously visible tab from the reconcile cache, not from `isHidden`

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

#### RUNTIME-6. Move the pane-tape follow broker out of AppRuntime into its own owner

`structural` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/AppRuntime.swift#beginPaneTapeFollow`, `app/AppRuntime.swift#finishPaneTapeFollowStart`, `app/AppRuntime.swift#deliverPaneTapeFollowBatch`, `app/AppRuntime.swift#retirePaneTapeFollowTransport`, `app/AppRuntime.swift#tearDownSession`, `app/AppRuntime.swift#shutdown`

**Problem.** `AppRuntime` is 2155 lines holding at least six unrelated jobs: the Elm dispatch frame, the Command interpreter, the IPC request registry, the pane-tape follow streaming broker, checkpoint scheduling, and restore staging. The tape broker alone is roughly 330 lines, nine private methods, two private tables, and one private struct, and its invariants (retire a transport with `run` not `cancel`; a sibling stream on the same socket must keep its notice) are enforced only by comments on runtime fields every other part of the runtime can also reach. Its lifecycle leaks into unrelated methods as well.

**Evidence.** `private var paneTapeFollowSubscriptions`, `private var paneTapeFollowTransports`, `private struct PaneTapeFollowTransport`, plus `streamFinitePaneTape`, `beginPaneTapeFollow`, `finishPaneTapeFollowStart`, `paneTapeFollowEventsAvailable`, `fetchPaneTapeFollow`, `deliverPaneTapeFollowBatch`, `failPaneTapeFollow`, `dropPaneTapeFollow`, `endPaneTapeFollowers`, `writePaneTapeFollowEnd`, and `retirePaneTapeFollowTransport` all live on `AppRuntime`. `shutdown()` contains `for subscriptionId in paneTapeFollowSubscriptions.removeAll() { retirePaneTapeFollowTransport(subscriptionId)?.close() }`, and `tearDownSession(_:)` opens with `endPaneTapeFollowers(for: paneId)`.

**Ideal fix.** Extract a `@MainActor final class PaneTapeFollowBroker` owning both tables, taking the scheduling lifecycle and a session-lookup closure at init, and exposing four entry points: `begin(reqId:paneId:...)`, `paneClosed(_:)`, `connectionClosed(_:)`, and `shutdown()`. `AppRuntime` keeps one field and forwards, so the `.streamPaneTape` arm, `tearDownSession`, `ipcConnectionClosed`, and `shutdown()` each become a one-line call. Follow on by extracting the checkpoint scheduler (`RecoveryCheckpointPolicy`, the two timers, the two capture helpers) the same way.

**By construction.** The transports table stops being reachable from unrelated runtime code, so "another method retired a transport without its notice registration" and "a sibling stream's census token was cancelled" become impossible to write outside one small type whose only exit is `retire`. The broker's shutdown obligation becomes a single visible call rather than a loop buried in `AppRuntime.shutdown()`.

**Cheaper fallback.** none -- the extraction is mechanical because the broker's state is already private and reached only through these methods.

**Verification.** Existing behavior must hold: app-tests/PaneTapeFollowEncodingTests.swift plus a census test -- open two follow streams on one connection, close one pane, assert the surviving stream still receives batches and that `captureOwnerCensus()[.subscription]` drops by exactly one; then close the connection and assert the census returns to its baseline.

**Risk.** The broker must arm its tokens on the runtime's own lifecycle; if the extraction gives it a separate one, a stream could stay armed after `AppRuntime.shutdown()`. The census test above is what catches that.

### Area: Pane views and geometry (`PANE`)

_Scope: Pane presentation: terminal view, pane host, and pane geometry interaction_

**Auditor's read on the area.** The presentation core of this area is in good shape: `SwiftTerminalSessionView.synchronizePresentation` is a genuinely single geometry/scale detector with the display-scaling invariant stated where it binds, `SplitContainerView` applies the pure `paneLayout` and nothing else, and `PaneDividerView` reports gestures without owning a ratio. The weak seam is everything the model-owned-geometry lift did not reach: pane drag-and-drop still hit-tests live AppKit wrapper frames, and the pane wrapper still keeps its own copies of zoom/splits facts. I did not audit the terminal engine packages under `lib/`, `AppRuntime` beyond the two pane-drag/lookup entry points the area's files call, or the sidebar.

<a id="pane-1"></a>

#### PANE-1. Resolve the pane drop target from the model layout, not from live wrapper frames

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

#### PANE-2. Type the container's leaf cache as the wrapper it needs, so a missing wrapper is retried, not cached

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

#### PANE-3. Record which button a press forwarded, replacing the two ad-hoc pairing booleans

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

#### PANE-4. Give the pane toolbar one projection argument instead of thirteen optional parameters and two model mirrors

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

#### PANE-5. Collapse the four duplicated fire-and-forget input methods into one completion-taking path

`simplification` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputKey`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendText`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputText`, `app/SwiftTerminalSessionView.swift#SwiftTerminalSessionView.sendInputWheel`, `app/TerminalSession.swift#TerminalSession`

**Problem.** Every pane input verb exists twice -- once fire-and-forget, once with a completion -- giving four verbs, eight protocol requirements, eight implementations in the session view, four default implementations, and a matching pair in each shim. The two forms of a verb must stay behaviorally identical by hand, and they already differ in one place: the unmappable-key rejection is expressed in the completion form and expressed as a silent `return` in the other, while the protocol's default extension answers `.delivered` for an input the fire-and-forget form may have dropped.

**Evidence.** In the session view: `func sendInputKey(_ key: KeyName, modifiers: KeyMods) { guard let key = Self.terminalKey(for: key) else { return } ... }` beside `func sendInputKey(_:modifiers:onCompletion:) { guard let key = ... else { ... onCompletion(.rejected) ... } ... }`; the same doubling for `sendText`, `sendInputText`, `sendInputWheel`. `TerminalSession`'s extension defines each completion form as `sendX(...); DispatchQueue.main.async { MainActor.assumeIsolated { onCompletion(.delivered) } }` -- a report that cannot know whether the call it wrapped delivered anything.

**Ideal fix.** One requirement per verb, with an optional completion: `func sendInputKey(_ key: KeyName, modifiers: KeyMods, onCompletion: (@MainActor @Sendable (TerminalInputSubmissionResult) -> Void)?)`. Better still, one requirement total -- `func send(_ input: PaneInput, onCompletion: ...)` over a `PaneInput` enum with `.text`, `.paste`, `.key`, `.wheel` cases -- so a new input kind adds one enum case rather than two protocol requirements, two implementations, and one default.

**By construction.** Two forms of one verb cannot disagree about what they reject, and no default implementation can claim `.delivered` for a submission it did not observe, because there is only one submission path to observe.

**Cheaper fallback.** Keep the four verbs but delete the fire-and-forget requirements, letting callers pass an ignoring completion. Halves the surface without introducing the input value type.

**Verification.** Existing IPC-level behavior tests for `input`/`text` submission results must pass unchanged; add one asserting that an unmappable key name reports `.rejected` on every entry point that reports at all.

**Risk.** Touches the `TerminalSession` protocol and both UI-harness shims; the compiler enumerates every site, and no observable IPC behavior changes.

### Area: Window chrome and auxiliary UI (`CHROME`)

_Scope: Window chrome and auxiliary UI (sidebar, TODO/alerts popovers, preferences, confirmation, theme browser, chips, chrome bar)_

**Auditor's read on the area.** Most of this area is in good shape: the chip stack (ChipArtwork/ChipRenderer/ChipView), SingleLineLabel, SidebarCellViews, SidebarReconcileDriver, and SidebarView's rename slot are careful, well-owned code with their invariants written down. The weak spots are all at boundaries where a typed fact is flattened before it crosses: the two TODO popover controllers share an abstract base Swift cannot check, ConfirmationPanel re-derives which answer it is sending from a button's visibility, sidebar menu items carry bare UUIDs, and PreferencesPanel addresses grid rows by literal index. I did not audit TerminalPaneView/PaneWrapper or Reconcile.swift/AppRuntime.swift themselves (other owners), citing them only as call sites; I also did not review layout constants or visual design.

<a id="chrome-1"></a>

#### CHROME-1. Replace the fatalError-based TODO popover base class with one controller parameterized by a scope value

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

#### CHROME-2. Make the confirmation projection carry each button's answer instead of inferring it from button visibility

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

#### CHROME-3. Carry typed ids in sidebar menu items instead of bare UUIDs

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

#### CHROME-4. Build the preferences grid from declared rows so warning rows and padding stop being addressed by literal index

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

#### CHROME-5. Extract the theme list (filter, selection, cell vending) shared by the browser and the picker sheet

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

#### CHROME-6. Give the alerts popover a typed, reusable row cell and stop computing row age at build time

`structural` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `app/AlertsPopoverView.swift#makeAlertRow`, `app/AlertsPopoverView.swift#relativeTime`, `app/AlertsPopoverView.swift#apply`

**Problem.** Every alert row is assembled from scratch on every reload -- six subviews and about twenty constraints per row, with no reuse identifier -- which is the one place in this area that ignores the typed-cell pattern the rest of the app uses (SidebarTabCellView, SidebarGroupCellView, TodoRowView, ThemeBrowserCellView). The same ad-hoc construction bakes the relative timestamp into the view at build time, so an open popover's "now" or "5m" labels are frozen until some unrelated model change re-pushes the projection; nothing in the runtime reconciles on a clock tick.

**Evidence.** `makeAlertRow(_:)` returns a bare `NSView` built from an `NSImageView`, two `NSTextField`s, a `SingleLineLabel`, a dot `NSView`, and an `NSBox`, then activates the full constraint set -- and never sets an `identifier`, so `tableView(_:viewFor:)` cannot reuse it. `apply(_:)` ends with an unconditional `tableView.reloadData()`. The time text comes from `relativeTime(alert.createdAt)`, evaluated once inside `makeAlertRow`; `AlertsPopoverProjection` carries `createdAt: Date` per row (Projections.swift) and nothing re-renders on a timer.

**Ideal fix.** Add an `AlertRowCellView` in the SidebarCellViews mould -- it owns its whole view tree once and exposes a single `apply(_ row: AlertRowProjection)` -- and vend it through `makeView(withIdentifier:)`. For the timestamp, project the display string in the core alongside the other row text (the model already owns wall clock through CoreEnv), so a row's age is a projected fact that changes when the projection changes, exactly like the unread flag.

**By construction.** With the age projected, "a row shows a time that no longer matches the model" stops being expressible -- the label is a projected string, not a value computed during view construction. The typed cell also removes the class of bug where a rebuilt row keeps a stale subview because one path forgot to set it.

**Cheaper fallback.** Keep the view-side `relativeTime` but drive a refresh while the popover is open (recompute the visible rows' time labels on a coarse timer owned by the controller and torn down in `viewWillDisappear`). That fixes the staleness without moving the clock read, at the cost of a timer where a projection would do.

**Verification.** In tests-ui/AlertsPopoverViewTests.swift, apply a projection twice with different row content and assert the row views are the same reused instances carrying the new text; and assert a row's time text equals the value the projection supplies rather than one derived at construction.

**Risk.** Low. The row is presentation-only; the main care is keeping click-to-activate working with reused cells, since it currently rides `tableViewSelectionDidChange` with `selectionHighlightStyle = .none`.

### Area: PTY host and session boundary (`PTY`)

_Scope: Process lifecycle and the engine/app session boundary (lib/TerminalPTY, app/TerminalSession.swift, DanTermCore boundary files)_

**Auditor's read on the area.** The lifecycle reducer (PaneProcessLifecycle.swift) and the launch policy are genuinely clean: pure, exhaustively cased, and well covered by LifecycleReducerTests/LaunchPolicyTests. InFlightLaunch and ResizeCoalescer are exemplary -- each is a single ownership rule in its own file with the argument written down. The tests do not re-implement production; the spawner, exit probe, and resource-lifecycle protocols are real injected seams and the suite drives real PTY descriptors through them (scripts/terminal-pty-host-test-seam-lint.sh enforces that). The weight of my findings is in TerminalPTYHost.swift, where several facts are stored twice and two teardown paths hand-enumerate the same source set. I did not audit rendering, the flight recorder's internals, DoctorPermissionProber (self-contained and outside process lifecycle in any meaningful sense), or TerminalHostTools' two standalone executables.

<a id="pty-1"></a>

#### PTY-1. Cancel every retained dispatch source from the one registry that already holds them

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

#### PTY-2. Give TerminalPTYHost its geometry from the launch input instead of storing a second copy

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

#### PTY-3. Record every applied transition on the flight tape and delete the five parallel capture buffers

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

#### PTY-4. Read the PTY through one loop instead of one per drain reason

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

#### PTY-5. Dedupe grid submissions on the applied fact, not on an optimistic mirror in the controller

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

#### PTY-6. Give viewport navigation its own three-case type instead of a nine-case enum guarded by preconditionFailure

`api-shape` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyViewportNavigation`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYAppliedTransition`

**Problem.** `applyViewportNavigation` takes the full nine-case `TerminalPTYAppliedTransition` but accepts only three of them, and enforces that at runtime with a `preconditionFailure` -- a crash in a shipping pane, reachable from any future call site that passes the wrong case. The parameter type is documenting a contract the compiler could enforce instead.

**Evidence.** The function's switch ends with `case .feed, .input, .paste, .focus, .mouse, .resize: preconditionFailure("applyViewportNavigation takes only .scrollByRows, .scrollToTopRow, .scrollToBottom")`. It is called with a literal case at five sites (`send`, `applyKey`, `applyPaste`, `scroll(byRows:)`, `scroll(toTopRow:)`, `scrollToBottom`, `applyWheel`, and the test interaction switch), so the wide type buys nothing at any of them.

**Ideal fix.** Declare a three-case `ViewportNavigation { case byRows(Int); case toTopRow(Int); case toBottom }`, take that as the parameter, and map it to a `TerminalPTYAppliedTransition` only where the transition is appended for capture. The `preconditionFailure` and its six dead cases delete.

**By construction.** Passing a non-navigation transition to the navigation path stops compiling, so the crash it currently guards against cannot be written.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** Existing behavior must not move: `TerminalPTYHostTests` already asserts that a scroll that changes the projection appears in `transitions()` as `.scrollByRows(-1)` and that a key press snaps the viewport to the bottom before writing. Both keep passing unchanged.

**Risk.** None beyond mechanical churn; `NeutralTerminalViewportNavigation` in TerminalCoreRecording already has this exact shape, so the mapping in `neutralEvents(_:)` gets shorter rather than longer.

### Area: iOS client (`IOS`)

_Scope: The iOS client (ios/DanTermMobileKit/Sources, ios/DanTermMobileApp)_

**Auditor's read on the area.** This is the cleanest area I have audited in this repo: the pure kit really does hold every session decision, the shell really does hold only effects, and the recent keyboard work is finished properly -- `MobileContentBox` is keyboard-absent by construction and `MobileSurfacePlacement` is the single presentation offset that the drawn layer, the scroll chrome, and hit-testing all read, so no grid, claim, or frame-store allocation can see the keyboard. The findings below are about facts that still have two owners (pinnedness, the connection identity), one gesture the reconnect policy drops, one hand-maintained integer table, and vocabulary that only tests reach. I did not audit the render-execution or TerminalCore packages the surface links against, `PaneReplica`'s event-application arithmetic beyond its pinnedness bit, or the checkpoint digest/plist envelope.

<a id="ios-1"></a>

#### IOS-1. Let the replica report pinnedness instead of re-decoding tape JSON in the session model

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

#### IOS-2. Make an authorized attempt carry its target so a Go tap can never be dropped against a stale one

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

#### IOS-3. Give the model one connection identity instead of four optionals a nil response id can match

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

#### IOS-4. Build the accessory key row from the key enum instead of matching two hand-numbered tag tables

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

#### IOS-5. Delete the session vocabulary only tests can reach

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileConnectionState.swift#MobileConnectionState`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileReconnectPolicy.swift#MobileReconnectEvent`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileResumePolicy.swift#resumeCheckpoint`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDeadlineTimer.swift#isPending`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplicaCheckpoint.swift#PaneReplicaCheckpointStore`

**Problem.** Five public entry points are produced or called by nothing but their own tests, and two of them carry doc comments describing callers that no longer exist. Because they are tested, they read as live contracts: a future reader extending the reconnect or resume story will reason about states the app can never enter, and the `MobileDeadlineTimer.isPending` comment actively points at a scheduling pattern the model replaced with its own `checkpointDeadlineIsArmed` flag.

**Evidence.** `MobileConnectionState.listingPanes` appears only in `MobileStatus`'s two switches and `StatusLineTests`; nothing calls `status.noteConnection(.listingPanes, ...)`. `MobileReconnectEvent.userCancelled` is handled in `MobileReconnectPolicy.handle` and asserted in `ReconnectPolicyTests` but is never dispatched -- the model has no cancel gesture. `MobileResumePolicy.resumeCheckpoint(stored:)` is used only by `ResumePolicyTests`; production asks `trustsStoredPosition` instead and the shell does the `? load : nil` itself. `MobileDeadlineTimer.isPending` is referenced only in `DeadlineTimerTests`, while its comment says "Callers that schedule one flush per dirty period use it to leave a pending deadline alone". `PaneReplicaCheckpointStore.remove()` has no caller at all.

**Ideal fix.** Delete all five, with the assertions that only exercised them, and let the compiler prove nothing else wanted them. If a cancel gesture or a pane-listing status is wanted, add it with the code that produces it.

**By construction.** n/a

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** `swift test --package-path ios/DanTermMobileKit` and `./scripts/ios-portability-gate.sh` after the deletions; the remaining suites must pass untouched, which is what shows nothing behavioral was carried by these symbols.

**Risk.** `userCancelled` may be a placeholder for a planned disconnect gesture; if so it should be raised with the user rather than deleted quietly, since the surrounding policy comments treat cancel as part of the design.

### Area: Build, gate, CI, docs (`BUILD`)

_Scope: Build, gate, CI, and the documentation contract_

**Auditor's read on the area.** This area is unusually well engineered: the bundle layout is generated from a Swift declaration rather than restated in YAML, the ADR index is machine-checked against the notes it lists, and two of the biggest hand-copied inventories (Swift test-estate coverage, manifest ownership) already have dedicated lints with their own self-tests. The remaining weaknesses are all the same shape -- an inventory that lives in prose or in a step string with no generator or executable check behind it. I did not audit Swift sources, the benchmark harness internals, or docs/research/.

<a id="build-1"></a>

#### BUILD-1. Declare each source target's purity profile once, and make the gate enumerate targets

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

#### BUILD-2. Make an orphaned gate self-test fail the gate instead of silently never running

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

#### BUILD-3. Put every gate scratch tree under one root so `just clean` cannot miss one

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

#### BUILD-4. Lint the Swift file-header rule AGENTS.md states, which is already violated nine times

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

#### BUILD-5. Give the three manifest-discovery lists one owner so a new package root cannot be skipped

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `scripts/gate-test-coverage-lint.py#MANIFEST_GLOBS`, `scripts/manifest-ownership-lint.py#MANIFEST_GLOBS`, `scripts/ios-portability-gate.sh#MANIFESTS`, `scripts/manifest_targets.py`

**Problem.** Three separate checks each carry a private copy of 'where first-party packages live'. Each guards against an empty result, so a wholesale move is caught -- but adding a package root none of the three globs matches is caught by none of them, and each check keeps reporting success over a smaller tree than it claims to police.

**Evidence.** scripts/gate-test-coverage-lint.py has `MANIFEST_GLOBS = ("Package.swift", "lib/*/Package.swift", "ios/*/Package.swift")`; scripts/manifest-ownership-lint.py has the identical tuple with an identical comment; scripts/ios-portability-gate.sh has `MANIFESTS=(Package.swift lib/*/Package.swift ios/*/Package.swift)`. All three fail only when the list resolves to nothing -- e.g. gate-test-coverage-lint's 'no first-party manifest found, so this check is checking nothing'. A package added at, say, tools/Foo/Package.swift would have no ownership check, no test-estate coverage check, and no iOS-pin check, while all three lints keep printing a pass.

**Ideal fix.** Declare the package roots once -- scripts/manifest_targets.py is already the shared reader for two of the three -- and have it expose both a Python API and a `--list` mode the shell gate consumes. Then add the assertion the current 'empty means failure' guard cannot make: every tracked Package.swift outside references/ must be matched by the declared roots, so a manifest in an undeclared location fails the gate rather than being ignored.

**By construction.** A first-party Package.swift that no gate check ever looks at becomes unrepresentable: every tracked manifest is either matched by the declared roots or fails the gate.

**Cheaper fallback.** Keep three copies but add a single check that `git ls-files '*Package.swift'` (minus references/) equals the declared set. Drift can still happen, but it can no longer be silent.

**Verification.** Create tools/Scratch/Package.swift declaring a target and a test target, run `just test`, and confirm the gate fails saying the manifest sits outside the declared package roots. Move it to lib/Scratch/ and confirm the failure becomes the real coverage complaint (no gate lane runs its tests) instead.

**Risk.** scripts/terminal-headless-draw-compare.py writes a synthetic Package.swift into a temporary tree; the new completeness assertion must read tracked files only, or that scratch manifest becomes a spurious failure.

## Cost findings

### Area: Terminal feed hot loop (`FEED`)

_Scope: Terminal.feed hot loop: per-byte and per-cell ingestion cost (Terminal.swift print/scroll/erase, TerminalInputStream, EscapeAbsorber, UTF8Decoder, TerminalScalars, GraphemeBreak)_

**Auditor's read on the area.** This path has clearly been worked over: the ASCII-run granularity, the packed two-stage Unicode table, the word-based damage bitset, the interned style pen, the inline CSI parameter storage, and the carried-forward damage snapshot are all deliberate and documented, and I found nothing wrong with any of them. The remaining cost is concentrated in three representations that were never lifted: rows as a flat `[GridCell]`-of-`[GridRow]` reached by a two-level CoW subscript per cell, the viewport as a fixed array that must physically shift on every scroll, and tab stops as a `Set<Int>` over a dense bounded column domain. I did not audit `LogicalLineStore.admit` / scrollback retention, the frame planner, or the render path -- other auditors own those, and I stopped at `history.admit` even though the scroll path calls straight into it.

<a id="feed-1"></a>

#### FEED-1. Represent the viewport as a rotating row ring so a scroll advances a head index instead of moving every row

`data-modeling` &middot; impact 5, confidence 5 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `ScreenState.rows` is a flat `[GridRow]` whose physical index is its viewport row, so scrolling by one row must physically move every surviving row. `Terminal.moveInPlace` runs one `screen.rows[destination] = screen.rows[source]` per row in the region, each a `GridRow` copy that retains the source's `cells` buffer and releases the destination's; the vacated row is then a freshly allocated 179-cell array from `makeBlankRow`, and the evicted prefix is copied into a throwaway `Array` just to be iterated once. This runs once per line feed that reaches the bottom of the region. Two of the four committed `terminal-feed` corpora hit it on essentially every record: `scrollback-stream` is 25,000 `\n`-terminated lines against the full 0..<66 region (65 row moves + one 5,728-byte row allocation + one 1-element `Array` allocation each), and `incremental-screen-updates` is 100,000 repeats that each end with `ESC[23;1H...\n` inside the `ESC[2;23r` region, putting the cursor on `region.upperBound - 1` and scrolling 22 rows every iteration.

**Evidence.** `Terminal.moveInPlace`: `if delta > 0 { for destination in range.reversed() { body(destination, source(for: destination)) } } else { for destination in range { body(destination, source(for: destination)) } }`, whose body in `Terminal.moveAndFillRows` is `if let source { let moved = screen.rows[source]; screen.rows[destination] = moved } else { screen.rows[destination] = makeBlankRow(columns: columnCount, styleId: styleId) }`. `Terminal.makeBlankRow` is `GridRow(cells: (0..<columns).map { _ in GridCell(styleId: styleId) })` -- one allocation plus one closure call per column. `Terminal.moveAndFillRows` also does `appendToScrollback(Array(screen.rows[range.lowerBound..<(range.lowerBound + amount)]))`, with the comment "It must be materialized rather than passed as a slice of `rows`: `appendToScrollback` is mutating".

**Ideal fix.** Give `ScreenState` a `firstRowSlot` head index over a fixed-size row store and reach rows through one `slot(for:)` translation, so a scroll whose region is the whole viewport is a head advance plus blanking exactly `amount` recycled rows in place -- O(amount * columns) cell writes, zero row moves, zero allocation. `DequeModule` is already a declared dependency of `TerminalCore` and `TerminalSearch` already uses `Deque`, so a `Deque<GridRow>` with `removeFirst()`/`append()` is the off-the-shelf spelling if the recycling is dropped; the hand-rolled head index is what additionally lets the evicted row's `[GridCell]` buffer be blanked and reused rather than freed and reallocated. Sub-region scrolls (`ESC[2;23r`) still shift, but only within the region, which is what they already do.

**By construction.** A viewport row's identity stops being its storage slot, so "scroll" stops being expressible as a bulk permutation of storage at all -- and with it the whole class of bugs where a shift and the damage recorded for it disagree about which rows moved.

**Cheaper fallback.** Leave the array but kill the two per-scroll allocations: admit the evicted rows one at a time from a local copy (`let row = screen.rows[i]; history.admit(row)`) instead of materializing an `Array`, and build the blank row with `Array(repeating:count:)` rather than `map`. That removes the allocations and the per-column closure but keeps the O(region) row moves.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed`. The number that must move is `feedDurationNanoseconds`; the corpus contains 25,000 full-region scrolls and 100,000 sub-region scrolls, so this is the workload's own dominant structure and not a corner of it. `just terminal-memory-probe --payload scrollback-plain --vmmap` is the secondary read: removing the per-scroll blank-row allocation should show up in allocator churn, not in the exact census, which is unchanged by construction.

**Regression risk.** Every row lookup gains one add and one conditional subtract. That is charged per row access, and the print path already hoists the row (`printBulkASCII` reads `screen.cursor.row` once per run), but `screen.rows[row].cells[...]` appears 95 times in `Terminal.swift` and any site that indexes rows inside a per-cell loop would pay it per cell. Finding 2's row-scoped mutable view is the prerequisite that keeps that from happening. The workloads that would show a regression are `retained-browse` and `content-churn`, which walk rows without scrolling.

**Verification.** `TerminalScrollbackTests` and `TerminalEditingTests` already pin IL/DL/scroll-region behavior against overlapping moves with distinct per-position content, per the `moveInPlace` doc comment; those must pass unchanged. Add a behavioral test that a full-region scroll followed by a sub-region scroll followed by a resize projects the same `viewportText` and the same `drainDamage()` value as the array implementation for a scripted byte stream.

**Risk.** Largest change here by far. `screen.rows` is also read by resize/reflow, state synchronization, and the projections, all of which currently assume slot == row.

<a id="feed-2"></a>

#### FEED-2. Reach a row's cells once per run, not once per cell, on the bulk ASCII write and scan loops

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `writeNarrowCells` stores each cell through `screen.rows[row].cells[column + offset]`, and `printBulkASCII`'s pre-scan reads each cell's kind through `screen.rows[row].cells[column + count]`. Both are two-level array accesses inside a per-cell loop, so the write loop re-proves uniqueness of the `rows` array and of the `cells` array on every single cell. This is the innermost loop of the hot path: the ASCII-run granularity exists precisely to make everything else per-run, and this is the one thing left that is still per-cell. `scrollback-stream` alone writes roughly 1.5 million cells through it, and `styled-screen-redraw` writes a full 179x66 screen 3,500 times.

**Evidence.** `Terminal.writeNarrowCells`: `for offset in 0..<count { screen.rows[row].cells[column + offset] = GridCell(scalars: .single(scalar(offset)), kind: .narrow, styleId: styleId, hyperlinkId: hyperlinkId, contentIdentity: baseIdentity + ContentIdentity(offset)) }`. The repo already names this exact cost and already fixed it for erase -- `Terminal.eraseCells` carries the comment "whose two nested array subscripts cost a COW uniqueness check on the row array and another on the cell array for every single cell erased" and writes through `screen.rows[row].cells.withUnsafeMutableBufferPointer { cells in for column in lower..<upper { cells[column] = blank } }`.

**Ideal fix.** Make "a mutable view of one row's cells" a real thing the grid vends -- `withRowCells(row:_:)` -- and route every per-cell loop through it, so the row is resolved and proved unique once per run and the two-level subscript is not expressible inside a cell loop at all. `writeNarrowCells` already takes everything it needs (`styleId`, `hyperlinkId`, the `scalar` supplier) before the loop and touches no other part of `self` inside it, and the pre-scan is a pure read, so both convert directly. This also becomes the single seam the row-ring in finding 1 has to teach, instead of 95 open-coded subscripts.

**By construction.** A per-cell loop can no longer be written that re-resolves the row, because the loop body only has the cell buffer in scope.

**Cheaper fallback.** Apply `withUnsafeMutableBufferPointer` inline at `writeNarrowCells` and hoist a borrowed row for the scan loop, copying the `eraseCells` pattern verbatim without introducing the shared accessor.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed`, reading `feedDurationNanoseconds`. If it comes back `inconclusive`, escalate to `just benchmark-confirm baseline=HEAD`. `just benchmark-feed-sample` is the diagnostic that would show the uniqueness-check frames disappearing from the `writeNarrowCells` stack before deciding.

**Regression risk.** None identified for the write loop: it is strictly fewer checks over the same stores, and it introduces no cache, mirror, or side table. The one hazard is correctness, not speed -- the closure must not touch `self` -- and `printBulkASCII` already guarantees `screen.rows[row].cells.count == columnCount` and `column + count <= columnCount` before calling.

**Verification.** `TerminalASCIIRunTests` already pins that a run produces exactly the token stream one `.print` per byte would; it must pass unchanged. Add nothing new -- the point of the change is that observable behavior is identical, and a test that could tell the two apart would be structure-sensitive.

**Risk.** Unsafe buffer access, so an off-by-one becomes memory corruption rather than a trap. Mitigated by the existing bounds guarantees at the single call site and by the identical precedent in `eraseCells`.

<a id="feed-3"></a>

#### FEED-3. Store tab stops as a column bitset instead of a Set<Int>, so HT is a word scan rather than an allocation

`data-modeling` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `tabStops` is a `Set<Int>` over a dense bounded domain (columns `0..<columnCount`), and every ordered query over it is expressed as a filter that materializes a new collection. Handling one HT byte allocates a whole new `Set<Int>` -- `Set.filter` returns a `Set`, so it rehashes every retained stop -- and then scans it for a minimum. At the default 179 columns that is 22 stops rehashed into a fresh hash table per tab character. `moveCursorAcrossTabStops` (CHT/CBT) is worse: an array allocation plus a sort per sequence. The domain is bounded, dense, and ordered; the representation is unordered, sparse, and heap-allocated.

**Evidence.** `Terminal.execute`, case 0x09: `screen.cursor.column = tabStops.filter { $0 > screen.cursor.column }.min() ?? columnCount - 1`. `Terminal.moveCursorAcrossTabStops`: `let candidates = tabStops.filter { forward ? $0 > screen.cursor.column : $0 < screen.cursor.column }.sorted(by: forward ? (<) : (>))`. Declared as `private var tabStops: Set<Int>`, seeded by `Set(stride(from: 0, to: columns, by: 8))`.

**Ideal fix.** Represent tab stops as a bitset over columns -- one `[UInt64]` of `(columnCount + 63) / 64` words, or `BitCollections.BitSet` (AGENTS.md says to prefer swift-collections over hand-rolling a bitset; only `DequeModule` is currently a declared product dependency, so this adds one). "Next stop after column c" becomes mask-off-the-low-bits plus `trailingZeroBitCount` across at most three words at 179 columns, with no allocation and no hashing; "previous stop" is the symmetric `leadingZeroBitCount` scan; `resizeTabStops` becomes a truncate-and-fill instead of `Set(tabStops.filter { $0 < newColumnCount })`; and `appendControlState`'s `tabStops.sorted()` becomes an in-order word walk with the sort deleted.

**By construction.** Answering an ordered query by materializing a filtered copy stops being possible, because the representation is already ordered. The `sorted()` in `appendControlState` and both `filter`s disappear rather than getting faster.

**Cheaper fallback.** Keep the `Set` for membership but maintain the ordered column list alongside it. Rejected: that is exactly the hand-maintained mirror this audit is told to avoid, and it must be invalidated on TBC/TBC-all/HTS/resize -- four sites, each a chance to desynchronize.

**Measurement.** No existing instrument can see this, and I want to be plain about that: none of the four committed `terminal-feed` corpora contains a single HT byte (I checked `benchmarks/fixtures/terminal-app.json` for `\t`; it is absent), so `just benchmark-quick baseline=HEAD workload=terminal-feed` would correctly report `equivalent`. Deciding it would mean either adding a tab-bearing segment to the committed corpus -- which redefines the workload and forces recalibration before directional claims resume -- or a one-off `Terminal.feed` timing in a test process, which the measurement rules do not treat as decision-bearing. Report it as an unmeasured structural win, not a measured speedup. The workloads that would contain it in real use are tab-emitting output: `git diff`, `make`, and `cat` of tab-indented source.

**Regression risk.** Memory grows by a few words per terminal (three `UInt64`s at 179 columns) against a `Set<Int>` holding 22 boxed-in-a-hash-table entries, so it is a reduction, not a cost. No path gets slower: every current operation is a hash lookup or a full-set materialization, and both are strictly more work than a word test. `just terminal-memory-probe` will not see it -- it is fixed per-terminal state, not per-cell.

**Verification.** `TerminalEditingTests`-style behavioral coverage of HT at the last stop, HT with all stops cleared (`ESC[3g`), HTS at the current column, CHT/CBT with counts past the end, and a resize that both grows and shrinks the column count -- all asserted through `Terminal.feed` and the resulting cursor column, never through the stop representation.

**Risk.** Low. The one behavior to preserve exactly is what happens when no stop lies ahead (`?? columnCount - 1`) and when the stop set is empty.

<a id="feed-4"></a>

#### FEED-4. Make TerminalStreamAction trivial and small by referencing parser-owned payloads, as the ASCII run already does

`perf-hot-path` &middot; impact 3, confidence 3 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift`, `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `TerminalStreamAction` is returned by `nextAction` and passed to `apply` once per token. Its `csi` case carries a `CSISequence` holding an `InlineArray<24, UInt16>` (48 bytes) plus three small fields, so the enum is roughly 70 bytes wide -- every action, including the hot `.printASCIIRun`, is copied at that width across the `nextAction` return and the `apply` call. Worse, the `osc([UInt8])` case holds a reference, which makes the whole enum non-trivial: copying and destroying it runs a value witness that switches on the tag, so the two calls per token cost an outlined copy and an outlined destroy even for the payload-free cases. `apply` is deliberately `@inline(never)`, so neither can be optimized away by inlining. The `incremental-screen-updates` corpus is 100,000 repeats of five CSI sequences plus short text, so `terminal-feed` is materially a per-CSI-token workload.

**Evidence.** `TerminalStreamAction` declares `case printASCIIRun(Range<Int>)`, `case csi(CSISequence)`, and `case osc([UInt8])`; `CSIParameters` holds `private var storage = InlineArray<24, UInt16>(repeating: 0)`. `Terminal.apply` is annotated `/// `@inline(never)` from measurement, not taste: letting the optimizer inline this dispatch into the pull loop cost a further 1.5 points on the drain (`research/33/F15`).` The precedent for the fix is in the same file: `.printASCIIRun(Range<Int>)` is documented as "A range rather than the bytes keeps the action POD and copies nothing; it is only meaningful to the caller that supplied the chunk, which is the same call that receives it."

**Ideal fix.** Apply that same rule to the two remaining payloads. Let `.osc` carry nothing (or a length) and have `Terminal.dispatchOSC` read the payload back out of `inputStream`'s absorber, which owns and retains it until the next `clearCollection`; let `.csi` carry the small dispatch key (`intermediates.key`, `final`, parameter count) and have the parameter values read from the absorber the same way. The enum then becomes POD and drops to a couple of words: the per-token copy is a register move with no value witness, and the `@inline(never)` boundary costs a call rather than a call plus an outlined copy and destroy. This also removes a real allocator effect at OSC dispatch, where `dispatchOSC` returns `.osc(oscPayload)` and `clearCollection` then calls `oscPayload.removeAll(keepingCapacity: true)` on a now-shared buffer, forcing a fresh allocation on every OSC -- and shells emit OSC 133 prompt marks, OSC 7, and OSC 0/2 titles constantly.

**By construction.** The token stream stops being able to own heap storage at all, which is the same invariant `.printASCIIRun` was introduced to establish. It also removes the current split personality where one case points into caller-owned bytes and another owns a copy.

**Cheaper fallback.** Split only the `osc` case out, leaving `.csi` inline. That restores triviality (removing the outlined copy/destroy and the OSC re-allocation) without touching CSI dispatch, at the cost of leaving the enum ~70 bytes wide.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed`, reading `feedDurationNanoseconds`; `incremental-screen-updates` gives the corpus its CSI density, and `styled-screen-redraw` its SGR density. Note that no committed corpus emits OSC, so the OSC re-allocation half is unmeasurable on this ladder -- say so rather than folding it into the verdict. `just benchmark-feed-sample` is the diagnostic that would confirm outlined copy/destroy frames around `apply` before the change and their absence after; that check should run first, because the claim that the compiler is emitting them is a reading of the calling convention, not something I disassembled.

**Regression risk.** This trades a self-contained value for one whose meaning depends on the parser it came from -- if a future caller buffers actions, the payload is already gone. The current design forbids buffering anyway (`feedBuffer` applies each action before pulling the next, and the doc says so), but the coupling becomes load-bearing where today only `.printASCIIRun` carries it. The parser also gains a read-back API surface, which is more code, not less.

**Verification.** The existing token-stream tests state actions as values and compare them; they must keep passing with the payload read through the new accessor, which means the assertions move from the enum to `expandedFeed`-style expansion. Behaviorally, a byte-for-byte replay of all four corpora must produce an identical `viewportText`, `drainDamage()`, and `stateSynchronization` -- that is the real proof, and it is structure-insensitive.

**Risk.** Medium. Chunk-boundary correctness is the hazard: an action must be consumed before the absorber's `clearCollection` runs, and the current code clears in a `defer` inside `dispatchCSI`.

<a id="feed-5"></a>

#### FEED-5. Test grapheme-break class membership with a bitmask instead of array-literal `contains`

`perf-hot-path` &middot; impact 3, confidence 3 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/GraphemeBreak.swift`

**Problem.** `GraphemeBreakState.shouldBreak` runs once per adjacent scalar pair -- that is, once per non-ASCII scalar printed, since ASCII goes through the run path and never reaches the segmenter. Five of its rules express "is this class one of these" by building an `Array` literal of enum cases and doing a linear `contains` over it, which for a `UInt8`-backed enum with 18 cases is the wrong shape twice over: a heap-capable collection for a compile-time-constant set, and a linear scan for a membership test. The `unicode-wrapping` corpus is 9,000 repeats of a line carrying combining marks, a ZWJ emoji sequence with a skin-tone modifier, and CJK, so this function runs tens of scalars deep per record for the whole corpus.

**Evidence.** `GraphemeBreakState.shouldBreak`: `if previous == .l && [.l, .v, .lv, .lvt].contains(current) { return false }` / `if [.lv, .v].contains(previous) && [.v, .t].contains(current) { return false }` / `if [.lvt, .t].contains(previous) && current == .t { return false }`. The enum is `enum GraphemeBreakClass: UInt8` with 18 cases, and the neighbouring predicates in the same file are already written as `==` chains (`var isExtend: Bool { self == .zwnj || self == .indicConjunctBreakExtend || self == .indicConjunctBreakLinker }`), so the file is internally inconsistent about how it spells the same idea.

**Ideal fix.** Give `GraphemeBreakClass` a `var bit: UInt32 { 1 << rawValue }` and express each rule's class set as a `static let` mask, so membership is one `and`. That makes the whole of UAX #29's set-shaped rules -- `isControl`, `isExtend`, `isIndicExtend`, `isEmojiSequenceClass`, `isIndicSequenceClass`, and the Hangul rules -- one uniform representation and one instruction each, instead of some as `==` chains and some as array scans.

**By construction.** A set of enum cases stops being representable as a collection literal in this file, so no future rule can reintroduce a scan; and the Hangul rules end up spelled the same way as the emoji and Indic ones, which is currently not true.

**Cheaper fallback.** Rewrite the five array literals as `==` chains, matching the predicates already in the file. Same effect on the generated code in the likely case, without introducing the mask vocabulary.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed`, reading `feedDurationNanoseconds`; `unicode-wrapping` is the corpus that contains it, and the other three barely reach the segmenter at all, so a small whole-workload move is the expected shape. Be honest about the prior: the optimizer may already stack-promote and unroll these literals into comparison chains, in which case the correct result is `equivalent` and the finding reduces to a representation cleanup. `just benchmark-feed-sample` over the corpus, checking whether `swift_allocObject` or an array-literal frame appears under `shouldBreak`, is the cheaper question and should be asked first.

**Regression risk.** None identified. The masks are compile-time constants in the binary's data section; nothing is allocated, cached, or invalidated, and the per-terminal footprint is unchanged. `just terminal-memory-probe` cannot see it and should not be expected to.

**Verification.** The generated `GraphemeBreakTest.txt` conformance suite is the test that decides this -- the file header pins `GraphemeBreakTest.txt e2d134d2...`, so the full UAX #29 break corpus must pass unchanged. That is exactly the right bar: it is behavioral, exhaustive over the rules being rewritten, and completely insensitive to how membership is spelled.

**Risk.** Low, and the conformance suite makes a transcription error loud rather than subtle.

### Area: Cell, row, and style layout (`ROW`)

_Scope: TerminalCore cell/row/style in-memory representation (GridCell, GridRow, TerminalScalars, TerminalStyle, PackedRetainedRow, the style intern table)_

**Auditor's read on the area.** This area has already been through four documented shrink rounds and one reverted stride experiment, so the *retained* side (LogicalLineStore's C1 word, the 8-byte header, the arena) is genuinely tight and I found nothing worth reporting in it. What is not tight is the seam between the two: the live grid still carries the pre-doc-28 representation (a 32-byte `GridCell` that owns a heap allocation, nested `[GridRow].cells` arrays), and `PackedRetainedRow` -- the representation doc 31 replaced -- is still compiled and tested. I did not cover the render-plan types (`RenderTextCell`, `PlannedCell`), damage, the parser, or the arena's own byte layout; other auditors own those. I also did not run any probe or benchmark, per the brief.

<a id="row-1"></a>

#### ROW-1. Delete PackedRetainedRow's store and readers; keep only the shared C1 cell-word constants

**Dropped into [STORE-2](#store-2).** It proposes the same deletion and the same move of the cell-word constants, and its own measurement section concedes no instrument can see it, so it carries no cost angle STORE-2 lacks. Track the work under STORE-2.

`structural` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/PackedRetainedRow.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Tests/TerminalCoreTests/TerminalPackedRetainedRowTests.swift`

**Problem.** `PackedRetainedRow` is a complete second retained-row representation -- blob encoder, four readers, two side-table searches, byte accounting -- and no production path constructs one. Doc 31's `LogicalLineStore` replaced it and reuses only its `Header` constants. Every one of its methods runs zero times per byte, per row, per frame; the file's cost is entirely carried as a live representation a reader must keep in their head and a maintainer must keep correct.

**Evidence.** `grep -rn PackedRetainedRow lib app --include=*.swift` outside its own file returns only comments in Terminal.swift and constant references in LogicalLineStore.swift (`word & PackedRetainedRow.Header.cellSpillBit`, `>> PackedRetainedRow.Header.cellStyleShift`, ...) plus test files. `static func pack(_ row: GridRow) -> PackedRetainedRow`, `func unpacked() -> GridRow`, `func cell(at column: Int) -> GridCell`, `func forEachCell`, `func forEachContentCell`, `func forEachKind`, `private func search(offset:count:width:for:)` and `private func contentIdentity(at:)` have no non-test caller. Its own file header still describes it as what history stores ("a retained row is one byte blob holding a fixed 8-byte cell per stored column"), which is no longer true.

**Ideal fix.** Delete the `PackedRetainedRow` type. Move the C1 cell-word layout (`cellBytes`, `cellScalarMask`, `cellKindShift`, `cellKindMask`, `cellSpillBit`, `cellStyleShift`, the two side-table entry widths) into one `C1CellWord` enum that `LogicalLineRecord` and `LogicalLineStore` name directly -- `LogicalLineRecord` already re-exports four of them -- and delete the tests that exercise the vanished store, keeping only the cell-word round-trip cases retargeted at `LogicalLineStore`.

**By construction.** Two cell encodings can no longer drift, because there is only one. The file-header claim that this type is what history stores stops being wrong because the claim stops existing.

**Cheaper fallback.** If a reason to keep a standalone packer surfaces (a fixture serializer, a future off-arena store), keep `pack`/`unpacked` alone and delete the four readers and both searches, and rewrite the file header to say it is not the production store.

**Measurement.** No instrument on the ladder can see this, and I am reporting it as unmeasurable on purpose: no production path executes the deleted code, so `benchmark-quick` on every workload must read `equivalent` and `terminal-memory-probe` must print byte-identical census numbers. The only numbers that move are `just test` wall time and the TerminalCore object size, neither of which is a calibrated instrument here.

**Regression risk.** None identified. The change removes code no production call reaches; the constants it preserves are the ones LogicalLineStore already reads.

**Verification.** `just test` unchanged apart from the deleted suite. `TerminalLogicalLineStoreTests` and `TerminalRetainedRowReadPathTests` continue to pin the retained read contract, and the cell-word round-trip cases retargeted from `TerminalPackedRetainedRowTests` continue to pin the encoding.

**Risk.** Deleting tests always risks deleting the only cover for something. Read `TerminalPackedRetainedRowTests` case by case and retarget -- rather than drop -- any case whose subject is the cell word, canonical trimming, or the two identity encodings, all of which LogicalLineStore still implements.

<a id="row-2"></a>

#### ROW-2. Move multi-scalar spills out of GridCell so a live cell is trivially copyable and 16 bytes

`perf-memory` &middot; impact 5, confidence 4 &middot; effort large

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalScalars.swift`

**Problem.** `GridCell` stores a `TerminalScalars`, whose `.spill([Unicode.Scalar])` case makes the whole struct non-POD. Every cell copy is therefore a tag test plus a conditional retain, and every overwrite a conditional release -- paid on the two per-printed-character stores in `writeNarrowCells`/`clearCellAndPair`, on each of the ~11,800 per-frame cell copies in `forEachViewportRow`'s live branch, and on every `[GridCell]` array copy in resize and reflow. Doc 28 measured multi-scalar cells at 0.12% of rows, so the rare case sets the cost of the common one. The same cell also spends 8 of its 25 bytes on two Optional payloads whose "none" is already spelled as 0 everywhere else: `nextHyperlinkId = 1` and `nextContentIdentity = 1` reserve zero, and `PackedRetainedRow.decode` reads it back as `value == 0 ? nil : value`.

**Evidence.** `struct GridCell: Equatable, Sendable { var scalars = TerminalScalars.empty; var kind: TerminalCellKind = .padding; var styleId: StyleId = Terminal.defaultStyleId; var hyperlinkId: HyperlinkId?; var contentIdentity: ContentIdentity? }` against `enum Storage: Sendable { case empty; case single(Unicode.Scalar); case spill([Unicode.Scalar]) }`. The retained side already solved this: `bits 0..20 scalar value, or a spill index when cellSpillBit is set / bits 21..23 kind / bit 24 spill flag / bits 32..63 interned StyleId`, with `spills: [[Unicode.Scalar]]` held beside the blob because it "is empty for the 99.88% of rows with no multi-scalar cell".

**Ideal fix.** Give the live grid the same cell word history already uses: `GridCell` holds a `UInt32` (21-bit scalar or spill index, 3-bit kind, spill flag), a `StyleId`, a sentinel-0 `ContentIdentity`, and a sentinel-0 `HyperlinkId` -- 14 bytes, stride 16, no reference field. Spill payloads move to a `Terminal`-owned side array indexed by the word, exactly as `PackedRetainedRow.spills` does, and `TerminalScalars` is reconstructed only at the public read boundary (`cell(row:column:)`, `forEachViewportRow`), which is where the render plan needs a value that outlives the grid anyway. That is one cell encoding across the live grid and both history readers instead of two.

**By construction.** A live cell can no longer own a heap allocation, so "copying a row retains N cells" and "cell equality is not a byte compare" stop being representable. `hyperlinkId == 0` and `contentIdentity == 0` mean absent in one way everywhere instead of three.

**Cheaper fallback.** If the spill side table cannot be made to reclaim cleanly, do neither half: the sentinel-encoding alone takes the cell from 25 to 23 bytes and leaves the stride at 32, and the word alone lands the struct at stride 20, which does not divide 64 -- the exact hazard `agent-docs/terminal-performance.md` records from the doc 16 revert. The two land together or not at all.

**Measurement.** `just terminal-memory-probe --payload full-screen --json`: `cellStrideBytes` must read 16 rather than 32, and the live-screen term of `cellStorageBytes` must halve; `multiScalarAllocationCount` must not rise. Then `just benchmark-quick baseline=<pre-change rev> workload=terminal-feed` and `workload=incremental-mixed`, because `incremental-mixed` is the cell that rejected stride 24 and its scattered per-cell draw reads are the pattern a new stride can hurt. `retained-browse` is the control: history's bytes do not change, so it must read `equivalent`.

**Regression risk.** A stride change can go the wrong way on scattered reads -- that is exactly how stride 24 was reverted, at +1.95% and +3.39% on `incremental-mixed` in two confirm runs. 16 divides 64 where 24 did not, so the straddling mechanism does not apply, but that is an argument for measuring, not for skipping. Second risk: the spill side table needs reclamation as live cells are overwritten, and reclaiming it by scanning the grid would recreate the defect in the next finding -- bound it per row or refcount it at the write, do not sweep it.

**Verification.** `TerminalGraphemeTests`, `TerminalGraphemeRetentionTests` and `TerminalGraphemeWidthTests` prove multi-scalar clusters survive the indirection; `TerminalHyperlinkTests` and `TerminalContentIdentityShapeTests` prove the sentinel encoding does not turn a real id 0 into absent; `TerminalMemoryCensusTests` pins the census arithmetic against the new stride.

**Risk.** This is the largest change in the area and it touches the print path, the resize path and the public read boundary at once. It is only worth starting if the memory probe's stride line and the `incremental-mixed` verdict are both collected before and after.

<a id="row-3"></a>

#### ROW-3. Stop recovering style liveness by rescanning the whole retained arena on the feed path

`perf-hot-path` &middot; impact 4, confidence 3 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`

**Problem.** `internStyle` runs on the print path whenever the SGR pen changes. When the table reaches `styleSweepThreshold` it calls `reclaimDeadStyleEntries`, whose `liveStyleIds()` walks every cell word in the 16 MiB arena -- on the order of two million cells at the production budget -- plus both live screens, doing a `Set<StyleId>.insert` per cell. The trigger is a table count; the cost is proportional to retained content, so the two are unrelated. Content with a high distinct-style rate that does not survive in history -- truecolor image or video output in the alternate screen, which is retained by neither screen nor arena -- holds the surviving set near one screenful, pins the threshold near twice that, and so fires a full-arena scan roughly once per frame, from inside `feed`.

**Evidence.** `private mutating func internStyle(_ style: TerminalStyle) -> StyleId { if let existing = styleIds[style] { return existing }; if styleTable.count >= styleSweepThreshold { reclaimDeadStyleEntries() } ... }` and `private func liveStyleIds() -> Set<StyleId> { ... history.forEachStyleId { live.insert($0) }; collect(screen.rows, into: &live); if let inactiveScreen { collect(inactiveScreen.rows, into: &live) } }`, against `func forEachStyleId(_ body: (Terminal.StyleId) -> Void) { for index in 0..<offsets.count { ... for cell in 0..<record.cellCount { body(...words[cellsBase + cell] >> ...cellStyleShift) } } }`.

**Ideal fix.** A style id's liveness is a fact about the two places cells live, and both already touch every cell they gain or lose: admission writes each cell word into the arena and eviction drops whole records. Maintain the retained side's per-id live count on those two existing walks -- no extra traversal, no new pass -- and keep the scan only for the two live screens, which are `columns * rows * 2` cells (~24k at 179x66) and cheap to walk exactly. The sweep then costs what the live screens cost, independent of history depth.

**By construction.** A style sweep can no longer cost more because history is deep. The coupling between "how many distinct styles have been minted" and "how many cells exist" is removed rather than tuned.

**Cheaper fallback.** Keep the scan and make its trigger proportional to what it scans: sweep when the table has grown past a threshold derived from retained cell count rather than the fixed 512, so the O(arena) cost is amortized against the arena rather than against a constant.

**Measurement.** No frozen workload contains this cost, and I am saying so rather than naming one that would answer `equivalent` by construction: `style-churn` changes truecolor attributes but runs against a shallow history, and `retained-browse` has a deep history but feeds nothing. The instrument that would show it today is `just benchmark-feed-sample` over a truecolor corpus fed after a full 16 MiB history, where `liveStyleIds` and `LogicalLineStore.forEachStyleId` must appear as self-time frames and must be absent afterwards. Deciding it directionally needs a new ladder workload (deep retained history plus a high distinct-style feed rate), screened per the calibration rules before any verdict.

**Regression risk.** A maintained count is state that can drift from the cells it describes, and a drift that under-counts frees an id a cell still holds -- which `allocateStyleId`'s comment identifies as repainting live cells. Guard it with the same shape as `independentScrollbackRowRecount`: an independent recount the tests assert against after each trigger point. Per-cell counting at admission also adds work to the admission walk itself, which `scrollback-stream`'s drain rate would show.

**Verification.** `TerminalStyleTableTests`' existing sweep proofs (table cardinality after styles die, no live cell left pointing at a reclaimed id) must pass unchanged, plus a new behavioral test that feeds N distinct styles against a deep history and asserts the resulting cell styles, not the table's internals.

**Risk.** The pathological workload is inferred from the code, not observed. Profile it first with `benchmark-feed-sample` on a truecolor corpus; if the sweep does not appear, this is a latent cliff rather than a current cost and should be recorded as such instead of fixed.

<a id="row-4"></a>

#### ROW-4. Write each printed cell once: clearCellAndPair's store at the target column is immediately overwritten

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `printNarrow` calls `clearCellAndPair` at the cursor column and then `writeNarrowCells` writes the same column. For the `.padding`/`.narrow`/`.spacerHead` case -- every ordinary character printed over ordinary content -- the only effect of the first call that survives is `clearPreviousSpacer`, which is itself a no-op above column 1. So each printed character pays an extra 32-byte `GridCell` construct, an extra store through `screen.rows[row].cells[column]` (a COW uniqueness check on the row array and another on the cell array, per the comment `eraseCells` already carries), and an extra destroy of the outgoing cell. This runs once per printed character on `terminal-feed` and `scrollback-stream`.

**Evidence.** `clearCellAndPair(row: screen.cursor.row, column: screen.cursor.column)` immediately followed by `writeNarrowCells(row: screen.cursor.row, column: screen.cursor.column, count: 1, ...)`, where `clearCellAndPair`'s common branch is `case .padding, .narrow, .spacerHead: screen.rows[row].cells[column] = GridCell(styleId: replacementStyleId)`. `eraseCells` documents the same cost it is avoiding: "two nested array subscripts cost a COW uniqueness check on the row array and another on the cell array for every single cell erased".

**Ideal fix.** A write to a column has exactly one obligation to its neighbours: if the column it lands on is half of a wide pair, the other half must stop claiming a partner. Express that as `severWidePartner(row:column:replacementStyleId:)`, which touches only the partner column and never the target, and let the printer own the target column. Structurally deeper, and worth naming: the repair exists at all because a wide glyph's occupancy is encoded as two independent cells joined only by their `kind` values. `LogicalLineFold` already derives the spacer from width rather than storing it; a live row that stored heads with a width, deriving the tail, could not leave a stale partner behind and would need no repair pass.

**By construction.** With the derive-the-tail form, "a stale wide partner survives a write" stops being representable. With the narrow split, a printed cell is written exactly once by construction rather than by the two call sites happening to agree.

**Cheaper fallback.** Keep `clearCellAndPair` and give the print sites a `clearsTargetColumn: false` parameter, so the dead store disappears without restructuring the wide-pair representation.

**Measurement.** `just benchmark-quick baseline=<pre-change rev> workload=terminal-feed` -- the per-byte grid-mutation workload, threshold 2.50%, and its own A/A guidance says distrust differences under 0.9 points. `just benchmark-quick baseline=<pre-change rev> workload=scrollback-stream` for the end-to-end reading, where the number to watch is the reported drain MB/s per arm rather than the verdict, since ~96% of that block is drain.

**Regression risk.** None identified for the narrow split -- it removes a store and changes no reader. The derive-the-tail variant touches every consumer of `.wideTail` (erase expansion, reflow's `repairClippedCells`, the packers, the render plan's width logic) and could easily cost more than it saves; it belongs in the plan as the ideal, measured before it is chosen.

**Verification.** The existing wide-glyph overwrite behavior: printing a narrow character over a wide head must blank both columns, over a wide tail must blank the head, and a spacer before a wrapped wide glyph must clear when column 0 or 1 is written. `TerminalGraphemeWidthTests` and `TerminalEditingTests` carry these; assert grid content through `TerminalGridAssertions`, never the call structure.

**Risk.** Low, provided the partner-clearing branches are moved rather than reasoned about -- the `.wideTail` branch reaches backwards to `column - 1`, and dropping that is a visible corruption, not a slowdown.

<a id="row-5"></a>

#### ROW-5. Recycle the vacated row's cell buffer on scroll instead of allocating a fresh one per line

`perf-hot-path` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** Every scrolled line allocates a whole new row. `moveAndFillRows` fills the vacated destination with `makeBlankRow(columns: columnCount, styleId:)`, which is `GridRow(cells: (0..<columns).map { _ in GridCell(styleId: styleId) })` -- one heap allocation of `columns * 32` bytes (5,728 at 179 columns) plus 179 non-POD cell initializations -- while the row whose buffer just left the region is released. On `scrollback-stream`'s 25,000 lines that is 25,000 malloc/free pairs of ~5.7 KB, once per newline, on the drain path. The screen is a fixed rows-by-columns rectangle whose storage never needs to change size, so none of those allocations buy anything.

**Evidence.** `Self.moveInPlace(range, by: delta, amount: amount) { destination, source in if let source { let moved = screen.rows[source]; screen.rows[destination] = moved } else { screen.rows[destination] = makeBlankRow(columns: columnCount, styleId: styleId) } }`, with `private func makeBlankRow(columns: Int, styleId: StyleId = Terminal.defaultStyleId) -> GridRow { GridRow(cells: (0..<columns).map { _ in GridCell(styleId: styleId) }) }`. The census counts the standing cost: `rowStorageAllocationCount` -- "Separate heap allocations backing live rows -- one per row with cells".

**Ideal fix.** Represent the live screen as what it is: one contiguous `rows * columns` cell buffer plus a ring base row, so a scroll is a base increment and one row filled in place. No allocation per line, no `GridRow` value assignment per moved row, `rowStorageAllocationCount` drops from rows-per-screen to one, and a row-major scan stays contiguous across row boundaries instead of chasing 66 separate buffers.

**By construction.** A scroll can no longer allocate, because there is nothing left to allocate: the screen's storage is fixed at construction and resize.

**Cheaper fallback.** Keep `[GridRow]` and rotate rather than reallocate: move the departing row's array into the vacated slot and refill it in place through `withUnsafeMutableBufferPointer`, which is the technique `eraseCells` already uses for exactly this reason. That removes the per-line allocation without introducing a ring index.

**Measurement.** `just benchmark-quick baseline=<pre-change rev> workload=scrollback-stream`, reading the per-arm `drain ... MB/s` line, which is the PTY throughput marker and ~96% of that block; and `just benchmark-quick baseline=<pre-change rev> workload=terminal-feed`, whose corpora scroll. `just terminal-memory-probe --payload scrollback-plain --json` must show `rowStorageAllocationCount` fall to 1 per live screen under the ideal fix, and `--vmmap` should show less allocator churn in the malloc regions.

**Regression risk.** A ring base adds an index translation to every row access, including the per-cell read in `forEachViewportRow` and every `screen.rows[row]` in the print path -- `content-churn` and `incremental-mixed` are where that would show. The flat buffer also changes what a resize costs (one reallocation and a copy rather than per-row work), which `just test`'s resize and reflow suites exercise but no benchmark workload does.

**Verification.** The scroll-region suites -- `TerminalRegionScrollbackTests`, `TerminalScrollTests`-equivalents, `TerminalEditingTests` for IL/DL/ICH/DCH -- must pass unchanged, since they assert grid content after moves rather than storage shape. `TerminalMemoryCensusTests` needs updating for the new `rowStorageAllocationCount`, which is itself the behavioral statement that the allocations are gone.

**Risk.** A ring base is a second coordinate system, and every existing `screen.rows[...]` site becomes a place it can be applied twice or not at all. The fallback carries almost none of that risk and captures the allocation win, so it is the honest first experiment even though the flat buffer is the ideal.

### Area: Scrollback store: append, retention, reflow (`HIST`)

_Scope: LogicalLineStore: append, retention, eviction, and reflow cost_

**Auditor's read on the area.** This store is unusually tight already -- the arena, the chunked backing, the packed index word, the borrowing reads (`withPaintedCells`, `forEachKind`, `forEachClosedRecordCell`) and the byte-level `==` are all measured, documented decisions, and I found no scan over history where an index or a swift-collections structure would obviously do better (`RingBuffer` is hand-rolled for a stated reason: it must report an allocator-truthful `capacity`, which `Deque` does not). What I did find is a consistent pattern of re-derivation: quantities the code computes and discards, then recomputes one call later, plus one place where a header bit already proves the answer to a loop that runs anyway. I did not cover the search index, anchors/selection, `PackedRetainedRow`, or the render planner -- other auditors own those -- and I deliberately proposed no new stored table, since every candidate I considered would have been a mirror of arena bytes.

<a id="hist-1"></a>

#### HIST-1. Give the open tail record one home: move its header and spills into the open scratch

`data-modeling` &middot; impact 4, confidence 4 &middot; effort large

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`

**Problem.** The open tail record's mutable state is split across two representations. Its side tables already live outside the arena in scratch (`openHyperlinks`, `openIdentityRuns`, flushed by `flushOpenTables` at close), but its header lives in the arena and is read-modify-written on every appended row, and its spills live in the sequence-keyed dictionary that is otherwise for closed records. Per admitted display row, `admit` decodes the tail header roughly seven to eight times -- `openTailRecord()` in the forced-split test, again inside `makeRoom`'s loop, again via `projectedTableBytes` -> `openRecordCellCount`, again in `openRecordIfNeeded`, again in `appendCells`, again in `setTrailingFillOnTail`, again in `closeOpenRecord` -- each a masked nested-array load `chunks[a][b]` plus eleven field extractions, and `writeHeader` re-encodes and re-validates the word (three preconditions) after each append. Separately, `appendCells` does `var spills = sideTables.spills(at: sequence) ?? []` per row; on a row that stores a multi-scalar cluster the following `spills.append` copy-on-writes the whole outer array, because the dictionary still holds a reference -- so a logical line that accumulates S spills copies O(S) array references per admitted row, O(S^2) over the record, up to the 65,536-cell forced-split cap.

**Evidence.** `private func openTailRecord() -> LogicalLineRecord? { guard offsets.count > 0 else { return nil }; let record = self.record(at: offsets[offsets.count - 1]); return record.isOpen ? record : nil }` and `private func record(at offset: Int) -> LogicalLineRecord { LogicalLineRecord(word: word(at: offset)) }`; in `appendCells`: `var spills = sideTables.spills(at: sequence) ?? []` ... `spills.append(Array(cells[index].scalars))` ... `if spills.count != spillsBefore { sideTables.setSpills(spills, at: sequence) }`.

**Ideal fix.** Complete the split the design already started: hold the open tail record as a decoded `LogicalLineRecord` in scratch beside `openHyperlinks`/`openIdentityRuns`, and hold its spills in an `openSpills: [[Unicode.Scalar]]` scratch array. The arena slot for an open record's header is then written exactly once, at close, alongside `flushOpenTables` and the spill-table insert. Readers already branch on `record.isOpen` for hyperlinks and identities (`hyperlinkId`, `contentIdentity`), so the open-spill read follows the same shape. The invariant strengthens from "the middle is immutable" to "the arena is immutable except the head trim", which is a smaller contract to defend, and admission stops paying an arena round-trip per header field it needs.

**By construction.** An open record's header can no longer be stale-in-the-arena, because the arena holds no open-record header at all. The bug class where a mutation forgets a `writeHeader` after changing a header field stops being representable for the one record that is ever mutated.

**Cheaper fallback.** Take only the spill half: keep the open record's spills in scratch and flush at close. That removes the per-row dictionary probe and the O(S^2) copy on its own and is a much smaller change.

**Measurement.** `just benchmark-quick baseline=HEAD workload=scrollback-stream` -- the number that must move is the per-arm `drain ... MB/s` line, which is ~96% of that block. Resolution caveat: scrollback-stream's worst A/A estimate is 3.48 points, so the header half (a constant-factor saving on a path that also parses and writes cells) may land under the noise and read `equivalent`. The spill half is not measurable by any calibrated workload -- no ladder workload feeds sustained multi-scalar clusters, and `just terminal-memory-probe --payload scrollback-unicode` reports bytes, not time.

**Regression risk.** The open record's byte length is currently derivable from the arena by any reader; after the change some internal call sites must consult scratch instead, and getting one wrong is a correctness bug rather than a slowdown. No workload should get heavier: scratch is uniquely referenced, so an append is amortized O(1) where the dictionary path was a hash plus a possible copy. Watch `scrollback-stream` drain and `terminal-feed` for the admission path.

**Verification.** The existing store-level oracles carry this: `independentDisplayRowRecount()`, `independentContentUnitRecount()`, and `census`'s recount assertion must all still agree after a mixed admit/close/reopen/force-split/truncate sequence that includes multi-scalar clusters, and `LogicalLineStore.==` (which compares stored bytes) must still report two identically-fed stores equal.

**Risk.** Large refactor across the five mutating operations, and `reopenTailRecord`/`reopenTailRecordForTruncation` must repopulate the scratch header the way `loadOpenScratch` already repopulates the tables.

<a id="hist-2"></a>

#### HIST-2. Skip the per-cell content-unit walk when the record's hasWideCells bit proves the count

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`

**Problem.** `contentCellCount` decodes every cell in its range to classify the kind, but the only stored kinds that are not content units are `.wideTail` and `.spacerHead`, and both imply a wide head in the same record -- which the header's `hasWideCells` bit already reports. For a record with that bit clear the answer is exactly `range.count`, so the loop is provably a no-op that still pays one masked nested-array load, one shift and one mask per cell. It runs on the eviction path: at steady state on a full scrollback, every admitted display row triggers `evictOneDisplayRow`, which calls either `trimHeadRecord` (walking `0..<cut`, and `cut` is the width) or `dropHeadRecord` -> `contentContribution` (walking the whole head record). It also runs per record inside `contentRank`, which walks up to 63 earlier records in a block for every search coordinate resolved.

**Evidence.** `private func contentCellCount(recordIndex: Int, range: Range<Int>, recordingWork: Bool = false) -> Int { let offset = offsets[recordIndex]; var total = 0; for cellOffset in range { ... switch cellKind(recordAt: offset, cell: cellOffset) { case .narrow, .wideHead, .padding: total += 1; case .wideTail, .spacerHead: break } }; return total }` -- with no `hasWideCells` guard, unlike `LogicalLineFold.rowCount`, `firstRowCellEnd`, `foldedRow` and `position(ofRecord:cellOffset:)`, which all take exactly that fast path.

**Ideal fix.** Read the record header once at the top of `contentCellCount` and return `range.count` when `hasWideCells` is false; keep the walk for the wide case. This is the same fast path, justified by the same header bit and the same `research/31/DD4` reasoning, that four other call sites in the file already take -- so it is a consistency fix as much as a speed one, and it removes the possibility that the counter and the fold disagree about what a record contains.

**By construction.** Nothing stops being representable, but the two derivations of "what does this record contain" stop being able to disagree about wide cells, since both then key off the same header bit.

**Cheaper fallback.** None needed; there is no cheaper version. If the invariant is judged too subtle, hoist the chunk pointer for the walk the way `forEachClosedRecordCell` does -- that keeps the loop but removes the per-cell nested-array subscript.

**Measurement.** `just benchmark-quick baseline=HEAD workload=scrollback-stream` -- the number that must move is the per-arm `drain ... MB/s`, because eviction runs once per admitted row there. `terminal-feed` cannot see it: its four corpora total ~1.52 MB against a 15,728,640-byte arena capacity, so it never evicts. Expect a small absolute effect on that corpus (its numbered lines are short, so the head record is ~10 cells, not 179), possibly under scrollback-stream's 3.5-point A/A floor; a long-line or wide-content stimulus would show it far better but no such calibrated workload exists.

**Regression risk.** None identified. The wide path is unchanged, and the fast path adds one header read that `contentContribution` already performs for its boundary test. The only hazard is correctness if a record could hold a `.wideTail` or `.spacerHead` without `hasWideCells` -- admission sets the bit on every `.wideHead` it stores, drops the trailing `.spacerHead` at `admissionExtent`, and forced splits cut on display-row boundaries where a wide pair cannot straddle, so it cannot.

**Verification.** `independentContentUnitRecount()` and `independentContentRank(of:)` already exist as full-materialization oracles that classify cells from decoded `GridCell`s; a test that feeds CJK and emoji content, evicts past the budget, and asserts the maintained totals equal the oracles proves the fast path changed no answer.

**Risk.** The fast path rests on an invariant (no `.wideTail`/`.spacerHead` without `hasWideCells`) that is currently implicit. State it as a debug assertion at the append site so a future admission change fails a test rather than silently miscounting.

<a id="hist-3"></a>

#### HIST-3. Carry the fold's result in DisplayRowCursor so a row is folded once, not three times

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** `DisplayRowCursor` stores only `(recordIndex, rowWithinRecord)`, so every read re-derives the record's row count and the row's cell range from scratch. `foldedRow` computes the record's total row count into a local `rows` and discards everything but the one row's range; `isSoftWrapped` then recomputes the same total via `displayRowCount`; `advance` recomputes it a third time. `Terminal.presentedRowGeometry` calls all three per visible row -- `forEachKind`, then `isSoftWrapped`, then `advance` -- so a 66-row browse frame pays about 200 record-header decodes and 200 folds where 66 would do, and the style path adds `withPaintedCells`' own `foldedRow` on top. On a record whose `hasWideCells` bit is set the fold is not arithmetic but a walk over every cell in the record, so traversing one record's R rows costs O(R * cells) -- quadratic in the record, up to the 65,536-cell forced-split cap.

**Evidence.** In `foldedRow`: `rows = counted` ... `if includeFill, cursor.rowWithinRecord == max(1, rows) - 1 { shape.fillStyle = ... }` -- `rows` is computed then dropped. In `isSoftWrapped`: `let rows = displayRowCount(recordIndex: cursor.recordIndex); return cursor.rowWithinRecord + 1 < rows || record.isOpen || record.isForcedSplit`. In `advance`: `let rows = displayRowCount(recordIndex: cursor.recordIndex)`. And in `Terminal.presentedRowGeometry`: `history.forEachKind(at: at) { ... }` / `let wrapped = history.isSoftWrapped(at: at)` / `cursor = history.advance(at)`.

**Ideal fix.** Widen the transient cursor to carry what the fold already produced: the record's row count and this row's `(cellStart, cellEnd, spacerAtEnd)`. `locate` folds once to build it; `advance` steps the range forward incrementally -- one boundary probe on the wide path, pure arithmetic otherwise -- and `foldedRow`, `isSoftWrapped` and `advance` all read the cursor instead of re-walking. This is not a cache: the cursor is produced on demand and never stored (the file is explicit that it is kept out of anchors), and no store mutation outlives one traversal, so there is nothing to invalidate. It also turns the wide-record traversal from O(cells^2 / width) into O(cells).

**By construction.** "Which display row am I on" and "which cells does it hold" stop being separately derivable facts that three call sites can compute inconsistently -- there is one derivation, at cursor construction, and every reader consumes it.

**Cheaper fallback.** Return the row count in `FoldedRow` and derive soft-wrap from it inside `gridRow`/`paintedRow`/`forEachKind`, leaving `advance` alone. That removes one of the three folds per row for a fraction of the effort, and leaves the wide-record quadratic in place.

**Measurement.** `just benchmark-quick baseline=HEAD workload=retained-browse`, reading the `planNanosecondsPerFrame` estimate against that cell's 1.05% threshold -- it is the only ladder workload that plans frames over history. Hold the arm slot fixed when re-running: the doc records ~0.6 points of movement from `physical_candidate_arm` alone. The wide-record half is not measurable by any existing instrument: `retained-browse`'s frozen stimulus is 10,000 short hard-terminated ASCII lines (`BrowseBenchmarkStimulus.standard`), so no record in it has `hasWideCells` set and the quadratic path never executes. Deciding that half needs a new CJK browse stimulus and a screening pass.

**Regression risk.** The cursor grows from two `Int`s to about five, so it stops fitting in registers as easily and `Terminal`'s per-frame cursor copies get slightly wider. That would show, if anywhere, on `retained-browse`'s plan time -- the same number the win must show on, so the measurement is self-checking. No memory risk: the cursor is transient and one exists per traversal.

**Verification.** `TerminalFrameLocateTests` already pins the traversal rule; extend it so that for every retained display row, the row produced by `locate` alone equals the row produced by `locate` plus N `advance` steps, over a history containing wide cells, a forced split and a trimmed head -- exactly where an incrementally advanced range could drift from a freshly folded one.

**Risk.** The incremental `advance` must reproduce `enumerateRows`' spacer rule at a record boundary and across a forced-split seam, which is the subtlest arithmetic in the file; get it wrong and a wide cluster loses its deferred column.

<a id="hist-4"></a>

#### HIST-4. Take one locate for the whole truncated tail instead of one per row

`perf-occupancy` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`

**Problem.** `truncateTail(displayRows:)` materializes the rows it hands back with `paintedDisplayRow(at: index)` in a loop, and `paintedDisplayRow` calls `locate(displayRow:)` every time. Each `locate` is a binary search over the block ring followed by a linear scan of up to 63 records inside the block, folding each one for its row count -- so handing back N rows costs N * O(blockSize) folds where the file's own stated traversal rule (one locate, then `advance`) costs one locate plus N-1 advances. This is the height-grow half of a window resize, so it runs on the main thread on every step of a live resize drag, not once.

**Evidence.** `for index in (grandDisplayRowTotal - count)..<grandDisplayRowTotal { guard let row = paintedDisplayRow(at: index) else { break }; handedBack.append(row) }`, against `func paintedDisplayRow(at index: Int) -> Terminal.GridRow? { guard let cursor = locate(displayRow: index) else { return nil }; return paintedRow(at: cursor) }`. `Terminal.primaryProjectionRows` already does it the right way in the same codebase: "One `locate` for the start row and `advance` for the rest, which is the traversal rule retained-history readers follow".

**Ideal fix.** Locate the first row of the truncated range once and walk it with `advance`, exactly as `primaryProjectionRows` and the search projection's `forEachRow` do. The fold-then-cut ordering the comment above the loop protects is unaffected -- the whole read still happens before any mutation.

**By construction.** Nothing stops being representable. It makes the store's own documented traversal rule hold at every internal call site rather than at most of them, so "which reads may spend a locate per row" stops being a per-call-site judgement.

**Cheaper fallback.** None; this is already the small fix. There is no version that keeps the per-row locate and gets the win.

**Measurement.** No existing instrument sees this, and I will say so plainly. None of the six ladder workloads resizes the terminal, and `retained-browse` is headless and never calls `truncateTail`. The argument is the call-count one above (N locates -> 1); confirming it needs either a new resize stimulus or a `just benchmark-sample` / `just benchmark-trace` capture taken during a live resize drag, where `locate` should stop appearing under `truncateTail` in `profile-folded.txt`.

**Regression risk.** None identified. The advance walk visits strictly fewer records than the repeated locates and reads the same rows in the same order.

**Verification.** The existing tail-truncation tests already assert the exact `[GridRow]` handed back for a height grow across a record boundary, a forced-split seam, and a wide-cell row whose spacer is re-derived from the row below; those must pass unchanged, since only the addressing changes.

**Risk.** Very low. The only trap is that `advance` must not be called after the last row of the range, which the existing loop bound already states.

<a id="hist-5"></a>

#### HIST-5. Price the memory census by walking records, not by materializing every retained row

`perf-memory` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalMemoryProbeSupport/TerminalMemoryProbeSupport.swift`

**Problem.** `Terminal.memoryCensus` builds `history.allPaintedDisplayRows()` -- one `GridRow` with its own `[GridCell]` allocation for every retained display row, roughly 6,756 rows of up to 179 cells at the production budget -- then concatenates it with a flattened copy of both screens, so the peak holds the materialized history plus a second array of the same references. This happens inside the instrument that measures footprint: `runPayload` reads `processPhysicalFootprintBytes()` after taking the census, so the transient allocation lands in the same window the probe attributes to retained cost. That is the shape `research/15/F7` already cost this repo once (a single-shot feed's ~37 MB of transient blocks read as resident cost). `settleAllocator()` between them mitigates but does not eliminate it, and the census also re-evaluates `screens.flatMap({ $0 })` three separate times.

**Evidence.** `for row in history.allPaintedDisplayRows() + screens.flatMap({ $0 }) { census.cellCount += row.cells.count; for cell in row.cells { ... } }`, and in `TerminalMemoryProbeSupport.runPayload`: `let census = terminal.memoryCensus` followed by `let releasedAfter = settleAllocator()` / `let after = processPhysicalFootprintBytes()`.

**Ideal fix.** Count history from the store rather than from materialized rows. The store already exposes the borrowing walks this needs -- `forEachClosedRecordCell` for kinds and scalars, `forEachStyleId` for styles including the trailing fill, `forEachHyperlinkId` for links -- and the missing term (content identities) wants the same treatment. The census then allocates nothing proportional to history, and its numbers become a function of the arena's bytes rather than of a re-fold of them, which is what a memory census should be. Hoist `screens.flatMap({ $0 })` into one local while you are there.

**By construction.** The census stops being able to perturb the quantity it reports, because it no longer allocates in proportion to what it is measuring. It also removes the census's dependence on the width-dependent fold: counting from records makes the reported cell census width-free, matching what the arena actually charges.

**Cheaper fallback.** If the identity walk cannot be added cheaply, at minimum drop the concatenation and iterate the two sources in sequence, streaming history through a locate-and-advance walk so at most one row is live -- that removes the whole-history peak without needing a new store read.

**Measurement.** `just terminal-memory-probe --payload scrollback-plain`, then again with `--payload scrollback-mixed` (single-payload runs only -- the doc is explicit that only a `--payload` run has an attributable footprint delta). Two numbers must move in opposite ways: `footprintAfterBytes - footprintBeforeBytes` must fall, while every `census` field must come back byte-identical to the current run. If a census field changes at all, the walk changed what it counts and the result is void.

**Regression risk.** None on any hot path -- `memoryCensus` is diagnostic-only and is called by the probes, not by the engine or the render path, so it cannot regress a ladder workload. The real risk is to the instrument: a hand-written record walk could silently stop counting a term (a multi-scalar spill, a fill style) and report a smaller census that looks like a memory win. That is exactly the blind-spot-reads-as-zero failure `measurement-discipline.md` warns about, so every counted term's presence has to be proved, not assumed.

**Verification.** Pin the current census as a fixture: feed each probe payload, record every field, then assert the rewritten walk reproduces all of them exactly. `independentDisplayRowRecount()` and `independentContentUnitRecount()` give an independent check that the walk visited every record.

**Risk.** Medium: the census's per-cell terms (styled, multi-scalar, hyperlink, identity, distinct counts) must each find a home in a record-level walk, and content identities have no existing `forEach` read to borrow.

### Area: Damage and the per-frame snapshot (`FRAME`)

_Scope: Damage tracking and the per-frame presentation snapshot handed to the app_

**Auditor's read on the area.** The damage value itself is in good shape: `TerminalDamageRowBits` is a word-scan bitset end to end, the shift composition is exact, and the delivery seam is already paced to one main-actor fence per display refresh (33/D8), so I found nothing worth reporting in delivery cadence or actor hops. The weak seam is the shape of the snapshot the damage travels with: `RenderFramePlan` is four flat whole-viewport run arrays, so both the planner's flatten and the executor's clip/reach passes do viewport-sized work per frame no matter how few rows are damaged. I did not audit the per-cell traversal inside `FramePlanner.plan` (the glyph/style/coalescing work), the search and selection projections it consults, `TerminalFrameBackingStore`'s pixel writes, or `Terminal`'s recordDamage call sites -- other auditors own those.

<a id="frame-1"></a>

#### FRAME-1. Publish the frame plan row-indexed so a row copy and a clip stop scanning the whole viewport

`data-modeling` &middot; impact 4, confidence 5 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`, `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`

**Problem.** The planner keeps its reusable state per row (`RetainedFrameRows` holds `[[RenderBackgroundRun]]`, `[[RenderTextRun]]`, ...) but publishes a flat, whole-viewport plan: four `Array(...joined())` flattens run once per published frame and copy every run in the viewport, including the runs of rows that were only copied forward from the retained frame. Every consumer then has to undo that flattening: `clipFramePlan` filters all four arrays with `rows.contains(row:)` per run, once per incremental `apply`, i.e. once per frame per pane. So a frame whose damage is 4 rows out of 66 still pays O(runs in the whole viewport) three times -- copy forward, flatten, filter -- plus four fresh viewport-sized array allocations on the plan side and four more on the clip side. Copying a `RenderTextRun` also retains its `cells: [RenderTextCell]` array, so the flatten is a refcount operation per text run per frame, not just a memcpy.

**Evidence.** `FramePlanner.plan`: `backgroundRuns: Array(background.joined()), overlayRuns: overlays.map { Array($0.joined()) } ?? [], textRuns: Array(text.joined()), decorationRuns: Array(decorations.joined())`. `clipFramePlan`: `backgroundRuns: plan.backgroundRuns.filter { rows.contains(row: $0.row) }` and the same for the other three layers. `RetainedFrameRows`' own doc already states the principle the plan discards: "Row-major arrays rather than one flat plan: reuse is decided per row, and keeping the rows separate is what makes copying a row an array append instead of a filter over the whole frame."

**Ideal fix.** Make `RenderFramePlan` row-indexed -- `rows: [RenderPlanRow]` where a row owns its four run arrays -- and let the plan share the planner's retained row values directly instead of flattening them. Reuse then costs one array retain per undamaged row, `clipFramePlan` becomes a selection of the damaged row indices with no per-run predicate and no filtering allocation, and the executor iterates rows within each layer (`for row in plan.rows { for run in row.background }`), keeping the existing global layer order. The plan and the retained state become one representation, so they cannot disagree about a row.

**By construction.** A plan row whose runs name a different row number stops being representable, and so does a clip that is not a subset of the published rows -- today both are only guaranteed by every run carrying a correct `row` field that consumers re-check with a predicate.

**Cheaper fallback.** Keep the flat arrays but add per-layer row-start offsets to the plan (a `[Int32]` index built during the flatten), so `clipFramePlan` and every other row-scoped consumer slices instead of filtering. This removes the clip scan but keeps the flatten and the two representations.

**Measurement.** `just benchmark-quick baseline=HEAD workload=content-churn` -- the separately calibrated plan line (2 pairs at +/-2.5%, band 1.0%) must go down; the flatten is pure overhead on top of a full replan there. Then `just benchmark-quick baseline=HEAD workload=incremental-mixed`, whose plan line is descriptive-only: that is where the damage-disproportionate copy-plus-flatten term dominates, and its per-draw plan number must fall. The draw half (the clip scan) has no calibrated instrument: `incremental-mixed`'s draw verdict is uncalibratable by construction and `just benchmark-headless-draw` times `drawRenderFrame` on an already-clipped plan, so it cannot see `clipFramePlan` at all. Report that half as measured-but-undecidable, not as a win.

**Regression risk.** Iterating nested per-row arrays is less cache-friendly than one flat array, and a layer pass now visits every row including the empty ones; a sparse-content full-screen draw (`style-churn`, `content-churn`) is where that would show. `drawTextRuns`/`drawDecorationRuns` take `[RenderTextRun]`/`[RenderDecorationRun]` today, so a naive port that rebuilds a flat array to call them would reintroduce exactly the copy being removed -- the signatures must change with the plan.

**Verification.** The existing `TerminalRenderPlanningTests` (`RenderFramePlanningTests`, `PaneFramePlanningTests`, `ShiftDamagePlanningTests`, `RenderCorpusPlanningTests`) assert plan content and reuse behavior; they must pass with only the plan-shaped assertions restated. Add a behavioral test that a clipped plan for a 4-row damage set contains exactly the runs of those rows and that clipping a full-viewport damage returns the identical plan value.

**Risk.** Large refactor across three modules and the executor's drawing entry points; the plan type is public API of `TerminalRenderPlanning` and is consumed by the benchmark marker scanner, which must keep scanning scalars in place rather than rebuilding strings.

<a id="frame-2"></a>

#### FRAME-2. Recompute ink reach only for the damaged rows instead of the whole plan on every incremental apply

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderInkReach.swift`

**Problem.** `TerminalFrameBackingStore.apply` -- the incremental render path, run once per published frame per pane -- calls `renderRowReaches(of: plan, ...)`, which walks every text run in the viewport and, inside each, every `RenderTextCell` to classify its scalars, plus every background, overlay and decoration run. That is O(all cells in the viewport) per frame on the path whose entire purpose is to touch only the damaged rows. The result is then thrown away except at the damaged indices: `for row in indices { rowReaches[row] = newReaches[row] }`.

**Evidence.** In `apply`: `let newReaches = renderRowReaches(of: plan, envelope: metrics.asciiInkEnvelope, cellHeightPixels: metrics.cellHeightPixels)` followed by `for row in indices { rowReaches[row] = newReaches[row] }`. In `renderRowReaches`: `for run in plan.textRuns { ... for cell in run.cells { if cell.scalars.count == 1, let scalar = cell.scalars.first { ... } } }`. And `renderApplyShape`'s own doc states the invariant that makes the full scan redundant: "undamaged rows' content is unchanged between the two frames, so their old and new reaches agree by construction."

**Ideal fix.** Treat reach as a property of a plan row rather than of a whole plan: with a row-indexed plan (see the row-indexed finding) the store computes a reach for each row it is about to redraw and reads the rest from its own ledger, which the apply contract already guarantees is current for every row outside `damage` (the ledger is translated with the pixels on a shift, and `staleDamage` names every row that changed since this buffer last presented). The `newReaches` argument to `renderApplyShape` then becomes the ledger with the damaged rows overwritten.

**By construction.** Nothing: the ledger is still a store the code maintains. What stops being representable is a reach entry that was recomputed from a plan row whose pixels this buffer never rendered -- the fix makes the ledger's per-row lineage the only source, instead of computing a second whole-frame answer and using one row of it.

**Cheaper fallback.** Add `renderRowReaches(of:rows:into:)` that fills only the given rows of an existing ledger, and have `apply` pass `damage`'s rows. Same saving, but the reach stays a whole-plan free function that a future caller can still invoke over the viewport by habit.

**Measurement.** No calibrated cell can decide this. `just benchmark-quick baseline=HEAD workload=incremental-mixed` is the workload that contains the cost, and both its draw verdict and its plan line are descriptive-only; read `drawNanosecondsPerDraw` and `processCPUNanosecondsPerDraw` as diagnostics and say so. `content-churn` and `style-churn` damage every row, so their calibrated verdicts should read `equivalent` -- that is the prediction, not the evidence. The number that would actually decide it is a new counter (cells inspected per `apply`), asserted in a unit test the way `Instrument` pins the engine's other work claims.

**Regression risk.** None identified for the incremental path; `renderFull` keeps the whole-plan computation. The risk is correctness, not speed: if a row's plan content can change without appearing in the composed `staleDamage`, its stale reach would survive and an erase span would be sized wrong, showing as leftover glyph ink on a neighbor row.

**Verification.** The `FrameBackingStoreTests` and `SearchMatchExecutionTests` bitmap comparisons already pin apply's pixels; add a test that applies a multi-row-damage frame after a shift and asserts the resulting surface is byte-identical to a `renderFull` of the same plan, which is the property the ledger exists to preserve.

**Risk.** The ledger invariant becomes load-bearing where today a full recompute papered over any lineage slip, so a latent bug in `staleDamage` composition would surface as visible stale ink rather than as wasted work.

<a id="frame-3"></a>

#### FRAME-3. Give TerminalDamage the predicates its consumers ask for, so no hot caller materializes a folded copy or a row array

`simplification` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`

**Problem.** The public damage value cannot answer its two hottest questions without building something. `TerminalFrameSwapchain.publish` asks "does this cover the viewport" by calling `expandingShift()`, which copies the word storage to fold the shift in (`var folded = bits; folded.fill(shift.region)` -- a copy-on-write allocation because `bits` was just handed out), then popcounts it; this runs on every scroll publish. `TerminalFrameBackingStore.apply` asks "which rows" via `damage.rowIndices`, allocating an `[Int]` per frame, against the type's own instruction that hot paths use `forEachRow` or `maximalContiguousSpans`. The internal accumulator already has the exact non-allocating predicate (`coversViewport(rowCount:)`) that the public value lacks, so the same question is answered two different ways on the two sides of the seam.

**Evidence.** `TerminalFrameSwapchain.publish`: `if damage.isFull || damage.expandingShift().damagedRowCount == plan.rows { latestWholeFrameDamageGeneration = generation }`. `TerminalDamage.expandingShift`: `var folded = bits; folded.fill(shift.region); return TerminalDamage(bits: folded, shift: nil)`. `TerminalFrameBackingStore.apply`: `let indices = damage.rowIndices; guard indices.allSatisfy({ $0 < rows })`. `TerminalDamage.rowIndices` doc: "A materializing convenience for tests and diagnostics; hot paths use `forEachRow` or `maximalContiguousSpans`." `TerminalDamageAccumulator.coversViewport(rowCount:)` is the word-scan predicate that already exists, privately.

**Ideal fix.** Promote the predicate to the public value: `covers(rowCount:)` answered by a word scan over `bits` plus the shift region, with no fold and no allocation, and have `publish` call it. Have `apply` and `renderApplyShape` consume `maximalContiguousSpans()` (or `forEachRow`) instead of `rowIndices`, which also lets `renderApplyShape` drop its `[Bool]` damage marking in favor of walking spans.

**By construction.** A consumer that has to fold a value to inspect it can fold it wrongly; making the questions answerable on the value removes the folded intermediate entirely, and with it the possibility of asking about a fold that does not match the value published.

**Cheaper fallback.** Keep `rowIndices` at the apply seam but make it fill a caller-owned buffer, and add only `covers(rowCount:)`. Less of the allocation goes away and the two spellings of the coverage question remain, one internal and one public.

**Measurement.** Below the resolution of every frozen cell on the ladder: the allocations are a handful of small arrays per published frame, and the workload that contains them (`incremental-mixed`) carries no directional rule. State it as unmeasurable rather than benchmarking it -- `just benchmark-quick baseline=HEAD workload=scrollback-stream` would exercise the shift-fold path but its draw tail is only ~4-7% of the block, so it cannot resolve this.

**Regression risk.** None identified: no store is added and no value is cached; the predicates read the same words the current code reads after copying them.

**Verification.** `TerminalDamage`'s existing suite covers `expandingShift` and span enumeration; add tests that `covers(rowCount:)` agrees with `expandingShift().damagedRowCount == rowCount` across shift-carrying, full, empty, and region-saturated values, and keep the existing frame-store bitmap tests green to prove the span-based apply draws the same pixels.

**Risk.** `covers` must account for the shift region the same way the fold does, or a whole-frame publish would stop installing the convergence barrier and a cold buffer could surface stale setup.

<a id="frame-4"></a>

#### FRAME-4. Store damage rows inline for grid-sized viewports instead of a heap array per damage value

`perf-memory` &middot; impact 2, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift`

**Problem.** Every `TerminalDamage` and every accumulator owns `words: [UInt64]` -- a heap allocation whose payload at 66 rows is two words. The value is copied and mutated several times per published frame: `TerminalDamageAccumulator.drain` hands the array out and then calls `bits.removeAll()`, which is a copy-on-write reallocation because the drained value now shares the buffer, so the accumulator's advertised "reusable words" are in fact re-allocated at every drain; `TerminalDamage.formUnion` is then run once per swapchain buffer per publish, each a uniqueness check and, for a shared buffer, another allocation; `haloed` and `expandingShift` allocate again. The engine paid a documented ~20% feed win to get rid of per-scalar `Set<Int>` allocation, and this is the residue of that same shape at the frame seam.

**Evidence.** `struct TerminalDamageRowBits { private(set) var words: [UInt64] ... init(rowCount: Int) { words = Array(repeating: 0, count: (rowCount + 63) / 64) } }`; `TerminalDamageAccumulator.drain`: `let drained = TerminalDamage(bits: bits, shift: shift); shift = nil; bits.removeAll(); return drained`; `TerminalDamageAccumulator`'s doc claims it "Keeps hot-path damage in reusable words".

**Ideal fix.** Give the bitset the same inline/spill representation the grid cell already uses in this engine: two inline `UInt64` fields covering viewports up to 128 rows, spilling to the array only above that. Every damage value on the frame path then copies by value with zero allocation and zero refcount traffic, and `drain` genuinely reuses the accumulator's words because handing out an inline value shares nothing.

**By construction.** The inline case removes shared mutable storage from the common path, so a drained value and the accumulator can no longer alias -- today they always do, briefly, and the removeAll copy is what hides it.

**Cheaper fallback.** Keep the array but have `drain` swap in a spare pre-allocated buffer it owns, so the reallocation happens once at reset rather than at every drain. This fixes the drain seam only; `formUnion` into each swapchain buffer still allocates.

**Measurement.** No instrument on the ladder can see it. `just terminal-memory-probe` censuses grid storage, not damage values; `terminal-feed` never drains (drain is caller-driven), and the per-frame allocation count is far below `incremental-mixed`'s noise. Report it as an unmeasurable structural cleanup, or add an allocation count to a unit test around `drain`/`formUnion` as the deciding number.

**Regression risk.** A taller viewport (>128 rows -- a full-screen pane on a large display at a small font is within reach) falls into the spill case, so the spill path must be as correct and as cheap as today's; the word-scan helpers (`translate`, `regionMask`, `haloed`) all index `words` directly and would each need an inline spelling, which is where a subtle bug would land.

**Verification.** The existing `TerminalDamage` suite (shift composition, translate, halo, span enumeration, set equality across storage widths) must pass unchanged, exercised at both an inline row count and a spilling one -- `sameRows(as:)` explicitly exists to compare values of different storage width, so that property is already the contract to hold.

**Risk.** Duplicated word logic across two storage cases is exactly the kind of specialization the engine only accepts with a measurement behind it, and here there is none -- which is an argument for reporting it and letting the user decide, not for doing it quietly.

<a id="frame-5"></a>

#### FRAME-5. Derive each swapchain buffer's missed damage from its presented generation instead of mirroring damage into every buffer

`data-modeling` &middot; impact 3, confidence 3 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift`

**Problem.** Each of the three buffers keeps its own `staleDamage` accumulator, and every publish unions the new damage into all of them -- a hand-maintained mirror of one publish sequence, replicated per buffer, alongside three more fields (`isCurrent`, `lastPresented`, and the swapchain-level `latestWholeFrameDamageGeneration`) that all encode the same underlying fact: how far behind this buffer is. The per-publish cost is one shift-composing `formUnion` per buffer (each a potential copy-on-write allocation), and the correctness cost is that a mirror can escalate or drop independently of the others with nothing to cross-check it.

**Evidence.** `publish`: `for index in buffers.indices { buffers[index].staleDamage.formUnion(damage) }`, and `Buffer` holds `var staleDamage = TerminalDamage.none` documented as "Damage composed (per `TerminalDamage.formUnion`) over every publish since this buffer last presented" beside `var lastPresented = -1`, which already records exactly when that was.

**Ideal fix.** Keep one ordered list of published damage keyed by the generation counter the swapchain already maintains, and give each buffer only its presented generation. "What this buffer misses" becomes a fold over the suffix from that generation -- computed once, at acquisition, for the one buffer that renders -- rather than a value maintained in N places on every publish. The list is trimmed at the oldest presented generation, and a buffer that falls further behind than the list keeps simply renders full, which is the existing `isCurrent == false` behavior.

**By construction.** A buffer whose recorded staleness disagrees with the publish sequence stops being representable: staleness is read from the sequence rather than accumulated beside it, so it cannot drift, escalate early, or miss a publish for one buffer only.

**Cheaper fallback.** Leave the mirrors and add a debug-only invariant check that every buffer's `staleDamage` is consistent with its `lastPresented` against a recorded publish log. That buys the cross-check without the representation change, at the cost of carrying both.

**Measurement.** `just benchmark-quick baseline=HEAD workload=incremental-mixed` is the only workload where the per-publish union cost is a visible share, and it carries no frozen rule -- so this is not decidable on the ladder either. The honest claim is representational; treat any draw-number movement as diagnostic.

**Regression risk.** Real and specific: the fold at acquisition is O(publishes missed), so a buffer the compositor holds cold for many frames pays a longer fold than today's incremental union, and an unbounded log would grow while a buffer stays cold. Trimming plus a fall-back-to-full rule bounds both, but this is the one finding here that can make a path slower, and `incremental-mixed`'s descriptive draw number is the only place it would show.

**Verification.** `FrameSwapchainTests` already pins acquisition order, staleness composition, and the convergence barrier; the behavioral property to add is that after any interleaving of publishes and acquisitions, the damage a buffer renders with equals the composition of every publish since it last presented -- asserted against a reference fold, not against the implementation's own bookkeeping.

**Risk.** Shift composition is order-dependent, so the fold must replay publishes in order; a log replayed out of order would produce a value that looks plausible and renders wrong rows.

### Area: AppKit draw path (`DRAW`)

_Scope: AppKit drawing path: text runs, glyphs, and chrome painting_

**Auditor's read on the area.** The glyph submission core is genuinely tight -- ASCII glyphs are pre-resolved per face, the sprite router rejects text with one comparison, per-run scratch buffers are hoisted and reset, and the fallback attribute dictionary is built only inside the guard that reads it. The weak seam is one level up: the plan hands the executor four flat, row-unstructured run arrays, so every incremental render re-derives whole-frame facts (ink reach, row filtering) that the planner already knows per row. I deliberately did not audit the sprite geometry files (BoxDrawing/Braille/Powerline/etc.), the swapchain's buffer-acquisition policy, ChipRenderer/ChipArtwork/BadgeLabel/SingleLineLabel (chrome drawn on chrome invalidation, no named hot path), ThemeCatalog/ThemeRenderBridge, or GlyphPreview.

<a id="draw-1"></a>

#### DRAW-1. Carry each row's ink reach in the retained row product instead of rescanning the whole plan per apply

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderInkReach.swift`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`

**Problem.** `TerminalFrameBackingStore.apply` -- the incremental render path, run once per presented frame -- calls `renderRowReaches(of: plan, ...)` on the *complete* plan. That function loops every text run and, inside it, every `RenderTextCell`, classifying each cell's scalar. At 179x66 that is a ~11,800-cell scan per frame, performed to learn facts about rows the frame did not damage. `incremental-mixed` damages 4 rows and still pays the full scan; a 4-row damage does 16x more reach classification than drawing.

**Evidence.** In `TerminalFrameBackingStore.swift#apply`: `let newReaches = renderRowReaches(of: plan, envelope: metrics.asciiInkEnvelope, cellHeightPixels: metrics.cellHeightPixels)` -- unconditioned on `damage`. In `RenderInkReach.swift#renderRowReaches`: `for run in plan.textRuns { ... for cell in run.cells { if cell.scalars.count == 1, let scalar = cell.scalars.first { if scalar.value >= 0x20, scalar.value <= 0x7E { ... } } } }`. The result is then used only per damaged row: `for row in indices { rowReaches[row] = newReaches[row] }`, plus `renderApplyShape`'s neighbor lookups, which reach at most one row past a span.

**Ideal fix.** A row's reach is a pure function of that row's runs, and the planner already owns rows individually: `RetainedFrameRows` holds `text: [[RenderTextRun]]` and copies undamaged rows forward untouched (`RenderFramePlanner.swift#plan(reusing:damage:)` via `reuseSource`). Compute each row's `RenderRowReach` in the planner at the exact moment it inspects that row's cells, store it as a fifth per-row field of `RetainedFrameRows`, and let it ride the same copy-forward and `translated(to:)` relocation the runs already ride. `RenderFramePlan` then publishes `rowReaches: [RenderRowReach?]` as a first-class field and `apply` reads it. The reach is then derived at exactly the granularity at which it can change.

**By construction.** A plan whose row runs and row reaches disagree stops being representable: the two are produced by the same per-row pass and copied forward as one unit. The current shape permits a reach computed from a different plan than the one being drawn, and permits the store's ledger to drift from the plan's content, both caught only by pixel-level tests.

**Cheaper fallback.** Keep the free function but give it a row set: `renderRowReaches(of:rows:envelope:cellHeightPixels:)` scanning only the damaged rows plus the one-row neighborhood `renderApplyShape` consults, merged into the store's existing `rowReaches` ledger. Cheaper diff, but it leaves reach derivation split across two owners and re-scans on every apply rather than only when a row is replanned.

**Measurement.** `just benchmark-quick baseline=HEAD workload=incremental-mixed` -- `drawNanosecondsPerDraw` must fall. Read it as descriptive only: that cell carries no frozen rule and prints `descriptive, no verdict -- uncalibratable`, so it cannot license a directional claim. `just benchmark-headless-draw` also cannot decide it, because its timed region is `drawRenderFrame` on an already-clipped plan and this cost sits in `apply` above that. The instrument that can actually name it is `just benchmark-trace btop-scroll "Time Profiler" 20`: `renderRowReaches` must lose essentially all of its self time in `profile-report.json`. On `content-churn` (full damage) expect `equivalent` -- the full scan is required there.

**Regression risk.** None identified for drawing. It moves per-cell classification from the draw path into the planner, which shows up on the separately decided plan-time line: `content-churn`/`style-churn` plan time could rise, since a full replan now also computes reaches. That cell has its own calibrated rule (2 pairs at +/-2.5%), so watch the `plan time:` line on `benchmark-quick content-churn`. On full-damage frames the total work is unchanged, only relocated.

**Verification.** The existing byte-exactness pins for incremental render: an apply-rendered store must be pixel-identical to a `renderFull` of the same plan, over ASCII rows, descender-spilling rows, a row whose old content had wider reach than its new content, and across a translation with stale strips. Those are structure-insensitive -- they compare pixels, not who computed the reach -- so they must pass unchanged.

**Risk.** The reach must survive `translated(to:)` relocation across a recorded shift with the run it describes, or a scroll will erase the wrong band. The nil-envelope degradation (every ASCII cell falls back to full-cell reach) has to be reproduced in the planner, which currently reads the envelope from `TerminalRenderMetrics` -- a value the planner does not otherwise see, so the envelope has to become a planning input.

<a id="draw-2"></a>

#### DRAW-2. Give RenderFramePlan row-indexed run ranges so drawing a row set is an index, not a filter of every run

`data-modeling` &middot; impact 4, confidence 4 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`

**Problem.** The planner builds four row-indexed arrays and then throws the row structure away (`Array(background.joined())` and three siblings). Every consumer that wants rows has to rebuild it by linear scan. `clipFramePlan`, called once per incremental render, filters all four flat arrays and allocates four fresh arrays plus a new `RenderFramePlan` -- O(all runs in the frame) work and four heap allocations to select the runs of 4 damaged rows. `drawRenderFrame` then iterates those arrays again.

**Evidence.** `RenderFramePlanner.swift#plan(reusing:damage:)`: `backgroundRuns: Array(background.joined()), overlayRuns: overlays.map { Array($0.joined()) } ?? [], textRuns: Array(text.joined()), decorationRuns: Array(decorations.joined())` -- immediately after `background[row] = backgroundRuns; text[row] = textRuns; decorations[row] = decorationRuns`. Then `RenderFramePlanner.swift#clipFramePlan`: `backgroundRuns: plan.backgroundRuns.filter { rows.contains(row: $0.row) }, overlayRuns: plan.overlayRuns.filter { ... }, textRuns: plan.textRuns.filter { ... }, decorationRuns: plan.decorationRuns.filter { ... }`, invoked from `TerminalFrameBackingStore.swift#apply` as `drawRenderFrame(clipFramePlan(plan, to: shape.planDamage), metrics: metrics, in: context)`.

**Ideal fix.** Keep the row partition the planner already computed. Store each channel as its flat array plus a `[Int]` of per-row start offsets (rows are emitted in ascending order, so the flat array is already row-sorted and the offsets are free to build). `drawRenderFrame` then takes a row set and iterates `rowStarts[r]..<rowStarts[r+1]` per damaged row. `clipFramePlan` and its allocations disappear entirely -- there is no clipped plan value any more, only a row set handed to the executor -- and the `row` field on each run becomes derivable rather than stored.

**By construction.** "A run whose `row` field disagrees with the row bucket it sits in" stops being representable, and so does an out-of-order run array -- which the current `clipFramePlan` fast path already silently assumes (`rows.contains(row: 0)` plus one maximal span implies whole-viewport coverage only if runs are row-sorted). It also removes the notion of a "clipped plan": a value that looks like a complete frame plan but is not one, and that only the executor knows how to interpret.

**Cheaper fallback.** Keep `clipFramePlan` but make it slice rather than filter: binary-search the row-sorted flat arrays for each maximal contiguous damage span and copy only those subranges. Same asymptotics for the copy, but it still allocates four arrays per frame and still leaves the plan claiming to be an unordered bag of runs.

**Measurement.** `just benchmark-quick baseline=HEAD workload=incremental-mixed` -- `drawNanosecondsPerDraw` must fall. That number is descriptive only for this cell (no frozen rule), so it cannot license a directional claim on its own. `just benchmark-headless-draw` explicitly cannot see this: its timed region starts at `drawRenderFrame` on an already-clipped plan, so `clipFramePlan`'s own cost is outside its bracket by construction. The deciding evidence available today is a `just benchmark-trace btop-scroll "Time Profiler" 20` in which `clipFramePlan` and `Array.filter` frames vanish from the main thread's self time. On `content-churn` expect `equivalent` -- full damage takes `clipFramePlan`'s early return already.

**Regression risk.** Building the per-row offset array costs one `[Int]` of `rows + 1` entries per plan, allocated on the planning path -- watch the `plan time:` line on `benchmark-quick content-churn`, which has a calibrated rule. Full-frame draws gain nothing and pay one extra indirection per row; `content-churn` and `style-churn` are the workloads that would show that as `slower`.

**Verification.** Rendered-pixel equality between an incremental render and a full render of the same plan, over the same damage shapes as the reach tests, plus the existing planner tests asserting run contents for a given terminal state. Both are about pixels and run values, not about how runs are stored.

**Risk.** `RenderFramePlan` is public and `Equatable`; two plans that differ only in offset-array representation must still compare equal, so equality has to be written against the logical run sequences. Every consumer of the flat arrays (the benchmark marker scanner walks the plan's runs, and `RenderInkReach` iterates them) has to move to the row-indexed accessor in the same change.

<a id="draw-3"></a>

#### DRAW-3. Lower RenderColor straight into the context as components, deleting both the per-run CGColor allocation and the memo dictionary

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameBackingStore.swift`

**Problem.** Every filled run materializes a heap `CGColor` object. `drawRenderFrame` allocates one per background run, one per overlay run, and two per decoration run (fill and stroke, built separately from the same value); `drawTextRuns` allocates one per distinct foreground behind a per-draw `[UInt32: CGColor]` memo. That memo is the shape agent-docs/perf-granularity-mismatch.md names as the fallback: it is a hand-built side table, it is rebuilt and discarded every draw, and on truecolor churn -- the `style-churn` workload's entire premise -- every lookup misses by construction, so it adds a hash and an insert per run and returns nothing. Separately, the colors are always built in sRGB while the destination context may be in the window's space, so CoreGraphics converts at every fill.

**Evidence.** `TerminalRenderExecution.swift#cgColor(in:)`: `CGColor(colorSpace: colorSpace, components: [CGFloat(red)/255, ...])!` -- a heap object plus a Swift array literal per call. Call sites: `for run in plan.backgroundRuns { context.setFillColor(run.color.cgColor(in: colorSpace)) ... }`, the identical `overlayRuns` loop, and in `drawDecorationRuns`: `setFillColor(run.color.cgColor(in: colorSpace)); setStrokeColor(run.color.cgColor(in: colorSpace))` -- the same value converted twice. The memo in `drawTextRuns`: `var colors: [UInt32: CGColor] = [:]` ... `if let cached = colors[colorKey] { foreground = cached } else { foreground = run.foreground.cgColor(in: colorSpace); colors[colorKey] = foreground }`. The space mismatch: `drawRenderFrame` hardcodes `let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)`, while `TerminalFrameBackingStore.init` builds its context with `space: space` where `space` is the window's `CGColorSpace` ("the view passes its window's space so displaying the surface is conversion-free").

**Ideal fix.** A `RenderColor` is three bytes; it should reach CoreGraphics as three numbers, never as an object. Set the context's fill and stroke color space once per frame in `drawRenderFrame`, then pass components per run via the pointer-taking `setFillColor`/`setStrokeColor` from a fixed-size stack tuple. No allocation, so nothing to memoize and the dictionary is deleted rather than tuned. Name the space in one place -- the store owns its context's space, so `drawRenderFrame` should take that space rather than assert sRGB -- and keep sRGB *values* by converting once at plan resolution if the destination differs, instead of converting at every fill.

**By construction.** Two things stop being representable: a color object whose space disagrees with the context it is filled into (the space becomes a property of the destination, stated once), and a per-draw cache that can be keyed wrongly or grow unbounded within a draw -- there is nothing left to cache.

**Cheaper fallback.** Keep `CGColor` but hoist the four decoration conversions to one per run and drop the `colors` memo, keeping only a one-entry "same as the previous run" comparison. That removes the guaranteed-miss hashing on truecolor churn without touching the allocation itself.

**Measurement.** `just benchmark-quick baseline=HEAD workload=style-churn` -- `drawNanosecondsPerDraw` must fall; that cell has a frozen rule (1.75% directional threshold, worst A/A estimate 1.75 points), so a real move is decidable there. Be honest about the size: the fixture writes one truecolor fg/bg pair per row, so a 179x66 frame carries only ~66 background and ~66 text runs, and the saving may sit inside the equivalence band -- escalate to `just benchmark-confirm baseline=<pre-change rev>` before claiming anything. A dense real TUI (`just benchmark-trace btop-scroll "Time Profiler" 20`) is where the per-run allocation count is actually large; `CGColor` creation and color-conversion frames must leave the main thread's self time there.

**Regression risk.** Changing which color space the components are interpreted in changes rendered pixels on a wide-gamut display. If the destination space is adopted without converting the values, every color shifts -- that is an appearance regression no benchmark reports. The safe form keeps sRGB semantics and only moves where the conversion happens. Nothing here should slow a workload; the paths removed are pure overhead.

**Verification.** Golden-pixel comparison of a rendered frame before and after, on both an sRGB and a wide-gamut destination space, covering a default-background fill, a truecolor background run, an overlay run, a decoration run with both fill and stroke kinds (strikethrough uses a second color), and a shaded block-element run that still needs an alpha-modified color.

**Risk.** Two paths genuinely need a `CGColor` object and must keep one: `foreground.copy(alpha:)` for shaded block elements, legacy sprites, and branch-drawing rects, and the `kCTForegroundColorAttributeName` entry in the fallback and symbols attribute dictionaries. Those should build a color lazily, only in the runs that reach them.

<a id="draw-4"></a>

#### DRAW-4. Route single-scalar astral cells through the batched cmap path instead of one CTLine per cell

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`

**Problem.** `drawTextRuns` batches glyph resolution only for scalars that fit in one UTF-16 code unit; anything above `UInt16.max` is pushed to `fallbackCells` and drawn by `drawTextCell`, which per cell builds a `String.UnicodeScalarView`, a `String`, an `NSAttributedString`, a `CTLine`, saves/clips/restores the graphics state, and runs full CoreText layout and shaping. That is one complete shaping pipeline per cell per frame, repeated every frame for text that did not change. A screen of emoji or CJK Extension B pays it on every one of ~11,800 cells; the same happens for any cell the face's cmap cannot map.

**Evidence.** In `drawTextRuns`: `} else if scalar.value <= UInt16.max { characters.append(UniChar(scalar.value)); candidateCells.append((cell, column)) } else { fallbackCells.append((cell, column)) }`. And `drawTextCell`: `var scalarView = String.UnicodeScalarView(); scalarView.append(contentsOf: cell.scalars); let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(scalarView), attributes: attributes))` followed by `saveGState(); clip(to: rect); textMatrix = ...; CTLineDraw(line, self); restoreGState()` -- inside `for fallback in fallbackCells`.

**Ideal fix.** `CTFontGetGlyphsForCharacters` maps surrogate pairs, so the batch's representation should be "UTF-16 code units" rather than "one code unit per cell". Append the pair for an astral scalar and record each candidate's code-unit count alongside its column, so the result walk reads the glyph at the candidate's own offset (a surrogate pair yields the glyph in the first slot and zero in the second). A single-scalar cell then never needs shaping regardless of plane, and `drawTextCell` is left owning only what genuinely needs shaping: multi-scalar grapheme clusters.

**By construction.** The "can this cell be drawn as one nominal glyph" question stops depending on which Unicode plane the scalar happens to live in. Today an emoji and a Latin letter take structurally different draw paths for a reason that is an artifact of the buffer's element type, not of the text.

**Cheaper fallback.** Keep the per-cell CTLine but hoist the `String`/`NSAttributedString`/`CTLine` construction behind a per-draw memo keyed on the cell's scalars. That is precisely the cache this repo prefers not to add -- it needs invalidation on font, size, and foreground change, and it would miss on exactly the content-churning frames it is meant to help.

**Measurement.** No instrument on the ladder can see this. All four serialized-draw fixtures are ASCII (`terminal-benchmark-producer.py#redraw_screen` writes `f" {row+1:02d}  branch feature/redraw  item ..."` padded with `.`), so `content-churn` and `style-churn` will read `equivalent` no matter how good the change is, and that reading would carry no information. Deciding it requires a new fixture -- a `content-churn` variant whose cells are astral scalars -- screened and frozen through `scripts/terminal-benchmark-candidate-screen.py` before any directional claim. Until then the honest statement is: the change removes one `CTLineCreateWithAttributedString` plus one `CTLineDraw` per astral cell per frame, and no existing number reports it.

**Regression risk.** Cells that reach the batch now skip `drawTextCell`'s per-cell `clip(to: rect)`, so an astral glyph wider than its cell can spill into a neighbor where it was previously shaved. That also widens the ink reach class those rows fall into -- `renderRowReaches` already assumes a full cell of reach for any non-ASCII single-scalar cell, so the ledger is already conservative enough, but the interaction must be checked. ASCII-only workloads are untouched, so no ladder workload should move.

**Verification.** Rendered-pixel equality for a frame containing an astral single-scalar cell (an emoji present in the base face), an astral cell the face cannot map (must still reach the fallback), a BMP private-use cell (must still reach the symbols face), and a multi-scalar cluster (must still shape through CTLine) -- compared against the current output.

**Risk.** The candidate-index-to-glyph-slot mapping is the whole correctness of the change: getting the offsets wrong draws the right glyph at the wrong column, or draws a lone surrogate's `.notdef`. The existing glyph-zero-means-fallback convention has to survive per code-unit rather than per candidate.

<a id="draw-5"></a>

#### DRAW-5. Stop driving a full NSScrollView geometry transaction from every viewport-state delivery

`perf-occupancy` &middot; impact 2, confidence 3 &middot; effort medium

**Files.** `app/ScrollableTerminalView.swift`, `app/SwiftTerminalSessionView.swift`

**Problem.** During sustained output the viewport's total row count changes on essentially every delivery, so `terminalSessionStateDidChange` fires per delivery and runs the whole scroll transaction: it resizes the document view's frame, calls `scroll(to:)`, and calls `reflectScrolledClipView`. The bounds-changed notification that resizing posts re-enters `synchronizeSessionView`, which writes the terminal host view's frame origin. That is an AppKit layout and notification round trip on the main thread, per delivery, competing with the PTY drain -- to move a scroller whose on-screen position may not have changed by a pixel.

**Evidence.** `ScrollableTerminalView.swift#terminalSessionStateDidChange`: `scrollView.hasVerticalScroller = state.scrollbarEnabled; layer?.backgroundColor = state.background; synchronizeScrollView()`. `#synchronizeScrollView` then does `documentView.frame.size.height = scrollbarDocumentHeight(...)`, `scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))`, `scrollView.reflectScrolledClipView(scrollView.contentView)` unconditionally. The re-entry is the constructor's `observeOnMain(NSView.boundsDidChangeNotification, object: scrollView.contentView) { self?.synchronizeSessionView() }`, and `#synchronizeSessionView` writes `terminalSession.hostView.frame.origin = visibleRect.origin`. Upstream, `SwiftTerminalSessionView.swift#emitStateIfNeeded` only suppresses an emit when the *whole* `TerminalSessionState` is unchanged, and `scrollPosition.total` grows with every delivered line.

**Ideal fix.** The pane's scroll position is terminal row state, and the model already owns pane geometry (docs/design/2026-08-16-model-owned-pane-geometry.md). Represent the scrollbar as a projection of `TerminalScrollPosition` and drive a scroller directly from it, rather than encoding it as a mutated document-view frame that AppKit must re-derive a scroll offset from and that posts a notification the same object then reacts to. That removes the round trip and the re-entrant frame write, not just their frequency.

**By construction.** The feedback edge disappears: today a state emit writes a frame, whose notification writes another frame, and nothing in the types says that loop terminates. A projection-driven scroller has one direction of flow, which is what the architecture claims everywhere else.

**Cheaper fallback.** Split the state channel so the three consumers move independently: only resize the document view when `total` or `length` changed, only `scroll(to:)` when the computed `offsetY` differs from the current one, and only touch `hasVerticalScroller`/`backgroundColor` when those fields changed. Cheap and safe, but it leaves the scrollbar's truth living in an AppKit frame that a bounds notification feeds back into the terminal host's origin.

**Measurement.** `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` is the deciding instrument: `reflectScrolledClipView`, `NSView.setFrameSize`, and the bounds-notification frames must lose their main-thread self time in `profile-report.json`, filtered to the Main thread. `just benchmark-quick baseline=HEAD workload=scrollback-stream` reports the `drain (candidate)` MB/s line, which is where a main-thread saving during drain would show -- but that line is explicitly descriptive and issues no verdict, and the workload's own verdict has the worst A/A behavior on the ladder (3 directional false positives in 8 A/A invocations, distrust under 3.5 points), so it cannot decide this. No calibrated cell measures per-delivery chrome work.

**Regression risk.** Suppressing a transaction on an unchanged value risks the scroller lagging a real change -- the failure would be a stale scrollbar thumb, invisible to every performance number. The serialized-draw workloads are unaffected (they write one update and wait for one draw), so nothing on the draw ladder should move in either direction.

**Verification.** Behavioral pins on the scrollbar's reported position: after N lines of output the thumb's offset and proportion must match the terminal's projection; dragging the scrollbar must still deliver `scroll(toRow:)` for each distinct row; and scrolling back into history then resuming output must land at the same position as today.

**Risk.** `isLiveScrolling` already suppresses the `scroll(to:)` half during a user drag, so any change here has to preserve that arbitration -- the model must not fight the user's drag. The re-entrant bounds notification is load-bearing today for keeping the host view pinned to the visible rect, so removing it means the host's origin needs an explicit owner.

### Area: PTY transport (`XPORT`)

_Scope: PTY read path and its delivery into the terminal_

**Auditor's read on the area.** The path is carefully thought through where it has been measured: the 16 KiB read-turn cap, the 33/D8 publish deadline, and the coalesced main hop each carry a documented experiment behind them, and there is no unbounded buffering anywhere (output backpressure is by design absent, input is bounded at 8 MB). What is not thought through is the granularity *below* the turn: xnu caps a pty master read at 1024 bytes (`references/xnu/bsd/sys/tty.h#TTYCLSIZE`, `references/xnu/bsd/kern/tty.c` `clalloc(&tp->t_outq, TTYCLSIZE, 0)`, drained by `references/xnu/bsd/kern/tty_dev.c#ptcread`), so the app's per-chunk pipeline runs up to 16x per turn on a boundary the kernel picked, and that boundary is then written into the flight tape as if it meant something. I did not audit `Terminal.feed` internals, the frame planner, the render path, `PTYSpawner`, launch policy, or teardown/quiescence -- other auditors own those. I deliberately left the `TerminalPTYFrameState`-carries-a-whole-`Terminal` question alone: the copy-on-write consequence is real but it lands in engine storage (`LogicalLineStore` already has a chunked arena explicitly designed for it), so it is the engine auditor's call, not mine.

<a id="xport-1"></a>

#### XPORT-1. Make the read turn, not the read() syscall, the unit that is fed and published

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`, `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift`

**Problem.** `readReady` runs the entire per-chunk pipeline once per `read()` syscall, not once per turn. xnu allocates the pty master's readable queue at `TTYCLSIZE` = 1024 bytes and `ptcread` drains only that queue, so a single `read()` can never return more than 1024 bytes no matter how large the caller's buffer is. The turn cap is 16 KiB, so a saturated turn does up to 16 reads, and each one pays: an `Array` allocation and copy, a `PaneProcessLifecycleEvent` append plus `Array.removeFirst`, a full pass through the lifecycle reducer producing a fresh `[PaneProcessLifecycleCommand]`, a `TerminalFlightRecorder.record` (clock read, Deque append, eviction check, follow-notice loop), a `Terminal.feed` entry, a `drainReplyBytes`, and a `publishPendingUpdate` that builds a `TerminalPTYUpdateSignal`, drains clipboard and semantic accumulators, and takes the delivery boundary's `Mutex`. On the `scrollback-stream` corpus (1,525,000 bytes) that is roughly 1,490 trips instead of roughly 95 -- once per 1 KB of child output, on the serial queue that every main-actor fence blocks behind. Separately, the same function allocates and zero-fills a fresh 16 KiB `[UInt8]` on every turn, an allocation and a 16 KiB `memset` per turn that no single read can ever fill.

**Evidence.** `private func readReady() { ... var buffer = [UInt8](repeating: 0, count: 16 * 1024); while bytesReadThisTurn < turnLimit { let result = buffer.withUnsafeMutableBytes { Darwin.read(masterFD, $0.baseAddress, min($0.count, turnLimit - bytesReadThisTurn)) }; if result > 0 { bytesReadThisTurn += result; process(.output(Array(buffer.prefix(result)))); continue } ... } }` in `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readReady`. `process` ends in `defer { publishPendingUpdate(); isReducing = false }` (`#process`), and `applyOutput` re-arms the pending flag on every chunk whose generation moved: `if terminal.hasPendingConsumerWork, consumerWorkWasSignaled == false || terminal.pendingConsumerWorkGeneration != previousConsumerWorkGeneration { markUpdatePending() }` (`#applyOutput`). Kernel bound: `references/xnu/bsd/sys/tty.h#TTYCLSIZE` is 1024, `references/xnu/bsd/kern/tty.c#ttyinit` does `clalloc(&tp->t_outq, TTYCLSIZE, 0)`, and `references/xnu/bsd/kern/tty_dev.c#ptcread` reads only `q_to_b(&tp->t_outq, ...)`. The same per-read shape repeats in `#drainCommittedOutput`.

**Ideal fix.** Hold one turn buffer on the host, allocated once for the host's lifetime, and read successive `read()` returns into successive offsets of it. When the turn ends -- 16 KiB reached, `EAGAIN`, or EOF -- emit exactly one `.output` for the whole turn. `Terminal.feed` already reduces to `feedBuffer(UnsafeBufferPointer<UInt8>)` internally, so give it a buffer-pointer entry point and hand it the turn's filled prefix directly. That makes the delivered unit something the app chose (the fence-bound turn, whose 16 KiB size is already justified by measurement in `readReady`'s own comment) instead of the size of a BSD clist.

**By construction.** An `.output` event whose byte count is an artifact of the kernel's buffer size stops being representable: the only chunk boundary in the system becomes the turn boundary, which is the same boundary the fence-latency argument is already written against. The flight tape stops recording clist sizes as if they were events (see the recorder finding).

**Cheaper fallback.** Keep `.output([UInt8])` as it is and only hoist the scratch buffer to a stored property, reading into it at an offset and emitting one `Array` per turn. This removes the per-turn allocation and `memset` and cuts the pipeline trips 16x, without touching the `Terminal.feed` signature or the reducer's event shape.

**Measurement.** `just benchmark-quick baseline=HEAD workload=scrollback-stream`; the number that must move is the reported `drain (candidate): ... MB/s` line against the baseline arm's, and the block verdict. State the limit honestly: `scrollback-stream`'s worst A/A estimate is 3.48 points, so a move smaller than that is not decidable there and this change may well be smaller. The instrument that can actually see it is `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` -- in `profile-report.json`, the inclusive shares of `publishPendingUpdate`, `TerminalFlightRecorder.record`, and `swift_allocObject`/`malloc` beneath `readReady` on the PTY host queue must fall roughly in proportion to the 16:1 call-count reduction, and the count of `Terminal.feed` frames must fall with them. Collect two traces before treating either as stable, per the guide.

**Regression risk.** Latency for a trickling child must not change: a turn that reads once and then gets `EAGAIN` has to publish immediately rather than waiting for anything, so the turn-end condition must include `EAGAIN`, not just the 16 KiB cap. Total bytes per turn is unchanged at 16 KiB, so the worst-case fence wait that `readReady`'s comment bounds (1.78 ms at 16 KiB) is unchanged. Feeding 16 KiB in one `Terminal.feed` instead of sixteen 1 KiB calls changes where chunk boundaries fall inside the parser; a sequence split across two old chunks now falls inside one, which the input stream already handles, but `synchronized-frames` and `terminal-feed` should be watched for a surprise. No workload gets a larger transient allocation: `feed` materializes one action at a time, not a token array.

**Verification.** The PTY host's existing byte-plane tests already drive real PTY masters (the test-seam lint forbids bypassing them), so a test that writes a known multi-kilobyte sequence spanning several kernel buffers and asserts the resulting screen and the recorded neutral transitions is structure-insensitive and behavioral. Add one that writes a sequence deliberately straddling the old 1024-byte boundary -- an OSC 8 hyperlink or a long SGR run -- and asserts identical screen state. `TerminalPTYAppliedTransition.feed` chunking is test-visible, so any test asserting exact chunk boundaries is asserting the kernel's buffer size and should be rewritten to assert the concatenation.

**Risk.** Medium. The change moves a boundary that a handful of test-support surfaces (`appliedTransitions`, `capturedOutput`, the flight tape's per-event byte spans) currently expose verbatim, so those assertions have to be restated in terms of concatenated bytes rather than chunk lists.

<a id="xport-2"></a>

#### XPORT-2. Store flight-recorder payloads in one bounded byte ring instead of one array per chunk

`data-modeling` &middot; impact 3, confidence 4 &middot; effort large

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`

**Problem.** The recorder is always on in production and retains up to 8 MB of raw PTY bytes per pane, held as one separately malloc'd `[UInt8]` per event inside `NeutralTerminalRecordingEvent.feed`/`.write`, with up to 32,768 events retained. Because each chunk is its own allocation, three things follow. The read path must copy every chunk out of the read buffer purely so the recorder has something to retain (`Array(buffer.prefix(result))`), which is the only reason a copy exists between `read()` and `feed` at all. The retention budget charges `payloadBytes + 128` per event while the process actually pays a `_ContiguousArrayStorage` header plus malloc-bucket rounding per chunk, so the accounted number and the resident number are different quantities that can drift apart with chunk size. And eviction frees N allocations to reclaim N bytes instead of moving one index. At the current per-`read()` granularity the recorder is doing this roughly 1,490 times per `scrollback-stream` corpus, per pane.

**Evidence.** `slots.append(slot); accountedBytes += payloadBytes + configuration.eventOverheadBytes; enforceBounds()` and `private func enforceBounds() { while accountedBytes > configuration.budgetBytes || slots.count > configuration.eventLimit { ... let evicted = slots.removeFirst(); accountedBytes -= evicted.payloadBytes + configuration.eventOverheadBytes } }` in `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#TerminalFlightRecorder`. Payload size is read straight off the array: `case .feed(let bytes): return PayloadDirection(isFeed: true, byteCount: bytes.count)` (`#direction`). Budget: `budgetBytes: 8 * 1_024 * 1_024, eventLimit: 32_768` (`#TerminalFlightRecorderConfiguration`). The forced copy: `process(.output(Array(buffer.prefix(result))))` in `TerminalPTYHost.swift#readReady`, and `flightTape.record(.write(Array(pendingInput[start..<spanEnd])), origin: span.origin)` in `#recordWrittenInput`.

**Ideal fix.** Give the recorder one contiguous ring of exactly `budgetBytes`, and let each slot hold a `(direction, ringOffset, length)` span instead of an array. Retention then is the ring: eviction advances the head and drops the slots whose spans fall behind it, and the accounted footprint is the ring, exactly, with no per-chunk allocator overhead to account for separately. The read path then reads straight into the ring's tail and feeds the terminal from that same region, so the byte crosses from kernel to parser exactly once and the `Array(prefix)` copy disappears rather than being optimized. Snapshot and stream readers materialize `[UInt8]` only when a caller actually asks for a capture, which is a debugging action, not a per-chunk one.

**By construction.** A retained payload can no longer be a separate heap object whose real size differs from its charged size, so 'the tape says 8 MB and the process pays more' stops being representable. Combined with the turn-coalescing finding, the read path holds zero byte buffers of its own.

**Cheaper fallback.** Keep the per-event arrays but charge the recorder its real cost -- round `payloadBytes` up to the allocation the chunk actually takes -- so the 8 MB budget means 8 MB resident. That fixes the accounting honesty without removing the copy or the allocation churn.

**Measurement.** `just terminal-memory-probe` cannot see any of this and should not be quoted for it -- it feeds a bare `Terminal` with no PTY host and no recorder in the process. The instrument that can is `just benchmark-memory scrollback-stream 90 15`: read `growthBytes`/`growthBytesPerSecond` first to establish the curve is flat in both arms, then use `heap-diff.txt` to compare the count and total size of `_ContiguousArrayStorage<UInt8>` nodes, which should collapse to a single ring allocation. For the removed copy, the same `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` trace as the turn-coalescing finding: `TerminalFlightRecorder.record` and the `Array` copy beneath `readReady` should leave the top self-frames. Read the growth number before the diff, per the guide's ordering rule.

**Regression risk.** A ring makes a capture read cost a copy out of the ring, where today a snapshot can share the existing array storage. Captures are user-initiated (`danterm pane tape`), not per-chunk, so this trades a per-byte cost for a per-command one -- but a `danterm pane tape follow` subscriber polling at high frequency would pay it repeatedly, and that is the workload to watch. Nothing on the ladder exercises it, so it needs a direct check rather than a benchmark.

**Verification.** The recorder's existing behavioral contract is the observable one: exact per-direction byte offsets, exact whole-event and byte loss between a cursor and the retained head, and replay equality of the neutral recording. Tests that feed past the budget and assert `droppedEventCount`, `feedBytesBeforeNextSequence`, and the reconstructed byte stream must pass unchanged; those assert what a reader observes, not how the payload is stored. Add one that fills the ring exactly to `budgetBytes` and asserts the retained suffix is byte-identical to the tail of what was fed.

**Risk.** High. `NeutralTerminalRecordingEvent` is a shared public replay type used well beyond the recorder, so either the recorder stops storing that type directly (storing spans and reconstructing on read) or the type changes. The first is the right shape and is still a substantial refactor of the snapshot, cursor, and follow paths.

<a id="xport-3"></a>

#### XPORT-3. Give pending-input spans absolute byte coordinates so a partial write never rewrites the queue

`data-modeling` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`

**Problem.** `PendingInputSpan.endOffset` is an index into the `pendingInput` array, so the moment the array's start moves, every span is wrong and has to be rebased. `compactPendingInputIfNeeded` therefore runs on every `enqueueInput` whenever a previous write left bytes behind, and it does two O(n) things: `Array(pendingInput.dropFirst(consumed))` reallocates and copies the entire unwritten remainder, and the span queue is rebuilt by mapping every element into a brand-new `Deque`. The remainder is bounded at 8 MB, and the trigger is common whenever the child is not draining -- a large paste, a stopped or slow child, a stream of `danterm pane send` calls -- because `flushInput` also stops voluntarily at its own 64 KiB turn limit and leaves `pendingInputOffset > 0`. N enqueues against a backed-up queue cost O(N * remaining), quadratic, and it runs on the PTY owner's serial queue, which is exactly what every main-actor `queue.sync` fence blocks behind, so the cost lands as main-thread occupancy and not merely as background work.

**Evidence.** `private func compactPendingInputIfNeeded() { guard pendingInputOffset > 0 else { return }; let consumed = pendingInputOffset; pendingInput = Array(pendingInput.dropFirst(consumed)); pendingInputOffset = 0; pendingInputSpans = Deque(pendingInputSpans.map { PendingInputSpan(endOffset: $0.endOffset - consumed, origin: $0.origin, submissionId: $0.submissionId) }) }` in `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#compactPendingInputIfNeeded`, called unconditionally at the top of `#enqueueInput` before `pendingInput.append(contentsOf: bytes)`. The turn limit that leaves the offset non-zero: `let turnLimit = 64 * 1024 ... while pendingInputOffset < pendingInput.count, writtenThisTurn < turnLimit` in `#flushInput`. The bound the remainder can reach: `public static let pendingInputByteLimit = 8 * 1024 * 1024` in `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift#PaneProcessLifecycleReducer`.

**Ideal fix.** Count spans in lifetime bytes enqueued -- a monotonic `UInt64` total that never rebases -- and hold the unwritten bytes in a structure whose head can be released in O(1). `swift-collections`' `Deque<UInt8>` gives exactly that (`references/swift-collections`, already a dependency and already used for `pendingInputSpans` and the recorder's slots): append at the tail, `removeFirst(n)` after a successful write, and no compaction step at all. `recordWrittenInput` then converts absolute span ends into a relative slice once per write, which it already effectively does. The whole `compactPendingInputIfNeeded` function and the `pendingInputOffset` field disappear.

**By construction.** A span coordinate that is only meaningful relative to the current buffer start stops existing, so the class of bug where a compaction and a span rewrite get out of step -- which the code already guards against with `assertionFailure("pending input span ends before the bytes it covers")` and `assert(start == end, "written pending input outran its origin spans")` -- becomes unrepresentable rather than asserted.

**Cheaper fallback.** Keep the array and the offset, but stop rebasing on every enqueue: compact only when `pendingInputOffset` exceeds some fraction of the buffer, amortizing the copy. This bounds the quadratic term without removing it and leaves the relative-coordinate representation in place, so the invariant 'a span index is only valid until the next compaction' still has to be held by hand.

**Measurement.** No instrument in the ladder can see this: every workload's PTY traffic runs child-to-app, and none of the six drives sustained app-to-child input against a backed-up queue. Say so plainly rather than reporting a flat verdict as evidence. The honest measurement is a direct one that does not exist yet -- a harness that `SIGSTOP`s the child, issues N small `danterm pane send` submissions, and reports wall time per submission; the number that must move is that time going from growing with N to flat. Absent that, the claim rests on reading the two O(n) operations and their call site.

**Regression risk.** `Deque<UInt8>` cannot hand `write()` a single contiguous pointer for its whole contents, so `flushInput` writes the first contiguous run per syscall instead of the whole remainder. Deque's storage is one ring buffer, so that is at most two runs and at most one extra `write()` per flush turn -- against a 64 KiB turn limit that is negligible, but it is a real change to the syscall count and should be stated. Nothing gets heavier in memory: capacity is bounded by the same 8 MB limit.

**Verification.** The observable contract is per-submission completion ordering and the recorded write tape: each submission completes exactly once, in order, only after its own bytes crossed, and each `.write` tape event carries the origin of its own bytes. Existing tests that submit several inputs against a master that accepts partial writes and assert both the completion sequence and the tape's per-event byte offsets cover this and must pass unchanged. Add one that forces a partial write, enqueues again, and asserts the second submission's tape span offsets are still correct -- that is the exact case compaction exists to keep right.

**Risk.** Low. The change is local to five private members of one actor, and the completion/tape contract it must preserve is already directly asserted.

<a id="xport-4"></a>

#### XPORT-4. Accumulate coalesced update payloads instead of rebuilding the merged signal per hop

`structural` &middot; impact 2, confidence 4 &middot; effort small

**Files.** `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`

**Problem.** The delivery boundary coalesces host signals into one pending value while a main hop is outstanding, and it does so by building a whole new `TerminalPTYUpdateSignal` per merge, concatenating the semantic-event arrays with `+`. Every merge allocates a fresh array holding all events accumulated so far, so K merges before main runs cost O(K^2) copying in the number of retained events. The producer side is the host's serial queue, which under a flood publishes once per chunk -- currently once per `read()`, so up to 1,490 merges per `scrollback-stream` corpus -- while the consumer side only drains when the main actor gets a turn. The pending payload is also the one place in the read path with no bound at all: a long main-thread stall lets `semanticEvents` grow without limit, and it grows quadratically while it does.

**Evidence.** `state.pendingSignal = state.pendingSignal.map { $0.merging(newer: signal) } ?? signal` in `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#TerminalPaneDeliveryBoundary`, against `package func merging(newer: TerminalPTYUpdateSignal) -> TerminalPTYUpdateSignal { TerminalPTYUpdateSignal(processStarted: processStarted || newer.processStarted, clipboardWrite: newer.clipboardWrite ?? clipboardWrite, semanticEvents: semanticEvents + newer.semanticEvents, ...) }` in `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYUpdateSignal`. The producer publishes once per `process` call: `defer { publishPendingUpdate(); isReducing = false }` (`#process`), which drains the accumulators every time via `clipboardWrite: terminal.drainPendingClipboardWrite(), semanticEvents: terminal.drainSemanticEvents()` (`#publishPendingUpdate`).

**Ideal fix.** The pending state is an accumulator, not a signal, so represent it as one: hold the fields directly in `State` -- a `[TerminalSemanticEvent]` appended to with `append(contentsOf:)`, a newest clipboard write, a max generation, a newest result, an OR'd started flag -- and build a `TerminalPTYUpdateSignal` exactly once, at the hop that delivers it. Merging then costs one amortized append per event rather than one full copy per merge, and the accumulator's growth is visible in one place where a bound can be stated if one is ever wanted.

**By construction.** 'A signal that is really several signals stacked up' stops being a signal. The coalescing point holds accumulator-shaped state, so the read that turns it into a delivered value happens exactly once per hop and cannot be repeated.

**Cheaper fallback.** Keep `merging` but make it `mutating` and use `semanticEvents.append(contentsOf: newer.semanticEvents)` so the existing array's capacity is reused. This removes the quadratic term without changing the boundary's state shape, at the cost of leaving 'the pending value is a signal' in place.

**Measurement.** No calibrated workload can decide this: `scrollback-stream`'s corpus is numbered plain lines and emits no semantic events at all, so the merged arrays stay empty there and the quadratic term is never exercised. State that plainly rather than running the ladder and reporting `equivalent`. The instrument that could see it is `just benchmark-sample scrollback-stream seconds=15` filtered to the PTY host thread with a stimulus that emits semantic events -- a shell emitting OSC 133 per prompt, or `just benchmark-trace btop-scroll "Time Profiler" 20`, which is diagnostic only and can decide nothing. The number that must move is the share of `TerminalPTYUpdateSignal.merging` and the `swift_arrayInit`/`memmove` beneath it.

**Regression risk.** None identified. The merge already runs under the boundary's `Mutex`, so moving field updates inside that same critical section adds no lock traffic, and the delivered value is byte-identical. The one thing to check is that `takePendingSignal`, which a synchronous checkpoint fence uses to flush the payload ahead of a `consume`, still returns and clears the whole accumulation atomically -- that ordering is what keeps semantics ahead of the frame.

**Verification.** The behavioral contract is ordering and exactly-once delivery: semantic events arrive in host order, no event is dropped or duplicated when several host signals collapse into one main hop, and a synchronous fence that overtakes a pending hop still delivers the urgent payload before the frame. Existing tests that stage several host updates without yielding main and then assert the observed `onSemanticEvents` sequence cover this and must pass unchanged.

**Risk.** Low. One private struct inside one `Sendable` final class, with the delivery contract already directly asserted by the pane session's own suite.

### Area: Core lookups and copies (`LOOKUP`)

_Scope: Data-structure choice in the pure core: lookups, scans, and copies in the reducer, model, and projections (Model.swift, ModelOperations.swift, PaneLayout.swift, Projections.swift, PaneRosterProjection.swift, Update.swift, PaneTree/split/tab structures)_

**Auditor's read on the area.** The tree-owns-panes model is genuinely tight on correctness -- pane existence, focus, and zoom cannot drift, and the projections are honest pure functions of the model. The costs that remain are all one shape: derived values (a snapshot DTO, a roster, a display string, a pane-id set) are rebuilt whole and deep-compared on every message or every AppKit layout pass, and the model's top-level containers are plain arrays whose invariants are re-verified by allocating sets per message. I did not audit Persistence.swift's codec beyond `toSnapshot`, IpcDispatch.swift, TabTodo.swift, SidebarItemStore.swift's AppKit-side row mounting, or anything in `app/` except the three call sites that establish how often core code runs (`AppRuntime.dispatchInFrame`, `Reconcile.reconcile`, `SplitContainerView.applyModelLayout`).

<a id="lookup-1"></a>

#### LOOKUP-1. Split AppModel into a persisted value and an ephemeral value so checkpoint change-detection stops rebuilding a DTO

`data-modeling` &middot; impact 5, confidence 4 &middot; effort large

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`, `lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift`, `app/AppRuntime.swift`

**Problem.** `AppModel` mixes ~18 persisted and ephemeral stored properties and states which is which only in line comments (`// ephemeral -- excluded from snapshots`, repeated 12 times). Because no value in the model answers "did persisted state change", the runtime answers it by serializing the entire model: `scheduleLightCheckpointIfNeeded()` runs at the end of every `send()` and, whenever no checkpoint timer is armed, calls `currentLightCheckpointProjection()` -> `toSnapshot(model)`, which walks every group, tab, split node, pane and todo, allocating a `uuidString` per entity and an `abbreviateHome` per pane cwd, then deep-compares the result against a stored baseline snapshot. That is one full model serialization per message -- per bell, per OSC title report, per cwd report, per focus change -- on the main thread, and the answer is "nothing changed" almost every time.

**Evidence.** `app/AppRuntime.swift#dispatchInFrame`: `scheduleLightCheckpointIfNeeded()` sits unconditionally after the reconcile switch. `app/AppRuntime.swift#scheduleLightCheckpointIfNeeded`: `guard lightCheckpointTimer == nil, schedulingLifecycle.isActive, currentLightCheckpointProjection() != lightCheckpointBaseline else { return }`. `app/AppRuntime.swift#currentLightCheckpointProjection`: `LightCheckpointProjection(snapshot: toSnapshot(model))`. `lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel` carries `var isAppActive` `// ephemeral -- excluded from snapshots`, `searchState` `// ephemeral`, `config` `// ephemeral`, `installedFontFamilies`, `mruOrder`, `jumpMode`, `pendingConfirmation` ... beside `groups` and `selectedTabId`, which are the only two `toSnapshot` reads.

**Ideal fix.** Give `AppModel` one stored `persisted: PersistedModel` (groups + selectedTabId) and keep the ephemeral fields beside it. "Excluded from snapshots" then stops being a comment and becomes a type: `toSnapshot` takes `PersistedModel`, and a new ephemeral field cannot leak into a checkpoint. The light-checkpoint policy becomes `model.persisted != baseline` against a stored `PersistedModel` -- a copy that is two retains, not a serialization -- and Swift's `Array.==` fast-path on identical buffer storage makes the comparison O(1) whenever no message touched the tree, which is the common case.

**By construction.** An ephemeral field can no longer be persisted, and a persisted field can no longer be forgotten by `toSnapshot`, because the snapshot function's parameter type contains exactly the persisted fields. The class of bug where a new `AppModel` field silently starts (or stops) triggering checkpoint writes stops being representable.

**Cheaper fallback.** Keep the DTO comparison but gate it on a cheap precondition first: compare `model.groups` and `model.selectedTabId` against a stored copy of those two fields and only serialize when they differ. Same effect on the hot path, but it leaves "which fields are persisted" duplicated between the comment block, `toSnapshot`, and the new gate -- three places to keep in agreement.

**Measurement.** No calibrated workload on the ladder drives app messages, so none can decide this: `terminal-feed` and `retained-browse` are headless engine work, and the draw workloads write one update per accepted draw. The honest instrument is `just benchmark-sample scrollback-stream 15` filtered to the main thread, looking for `toSnapshot`/`Foundation.UUID.uuidString` self-frames and for their disappearance; that is diagnostic only and cannot issue a verdict. If a decision is wanted, the workload does not exist yet -- a message-rate stimulus (a bell or OSC-2 storm) would have to be added first.

**Regression risk.** None identified for runtime behavior: the comparison gets strictly cheaper and the write path is unchanged. The nesting churns every `model.groups` / `model.selectedTabId` reference in Update.swift and the projections, so the risk is mechanical breakage, not performance. Memory is unchanged (same fields, one struct deeper).

**Verification.** Existing checkpoint tests must still pass unchanged, in particular the ones asserting that an ephemeral change writes no checkpoint and that a persisted change writes exactly one; add a behavioral test that mutating each ephemeral field in turn leaves `lightCheckpointCapture(current:baseline:)` returning nil, and that mutating a tab title returns a capture. Those assert observable write behavior, not the new struct's shape.

**Risk.** Large mechanical diff across the reducer. If any handler mutates `groups` through a path that also reads an ephemeral field, the split has to be done carefully to keep one `inout model` mutation per handler.

<a id="lookup-2"></a>

#### LOOKUP-2. Type snapshot identity fields as typed ids instead of String so capture stops formatting UUIDs

`data-modeling` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`

**Problem.** Every id in the snapshot DTOs is a `String`, so each capture formats one 36-character `uuidString` per group, per tab, per focused-pane reference, per split node, per pane, and per todo, and each load parses them back with `UUID(uuidString:)`. With the light-checkpoint policy above, that formatting runs once per message for the whole model; even after that policy is fixed it still runs on every real checkpoint. Equality on `AppModelSnapshot` -- which is the checkpoint scheduling policy -- then compares strings where it could compare 16-byte values.

**Evidence.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#TabSnapshot`: `let id: String?`, `let focusedPaneId: String?`. `lib/DanTermCore/Sources/DanTermCore/Persistence.swift#toSnapshot`: `id: tab.id.rawValue.uuidString`, `focusedPaneId: tab.paneTree.focusedPaneId.rawValue.uuidString`, and in `toPaneSnapshot` / `toSplitNodeSnapshot`: `id: pane.id.rawValue.uuidString`, `id: id.rawValue.uuidString`, plus `TodoSnapshot(id: $0.id.rawValue.uuidString, ...)`. The reverse: `lib/DanTermCore/Sources/DanTermCore/Model.swift#validateAndBuildDetailed` -- `guard let parsed = UUID(uuidString: idStr) else { print("[init] Invalid tab UUID: \(idStr)"); return nil }` -- repeated for group, tab, pane and split.

**Ideal fix.** Declare the DTO fields as the phantom-typed ids themselves (`TabId?`, `PaneId?`, `SplitId?`, `TodoId`). `TypedId` wraps `UUID`, whose `Codable` conformance already encodes as the same uppercase UUID string, so the on-disk JSON is byte-identical and no migration is needed. Capture then copies 16-byte values, equality compares them, and the whole `UUID(uuidString:)` + `print` + `return nil` validation ladder in `validateAndBuildDetailed` and `parseSplitNode` deletes itself.

**By construction.** A snapshot can no longer hold an id-shaped string that is not an id, so "invalid UUID in a persisted file" stops being a runtime branch that returns nil for the whole session and becomes a decode error at the one boundary that already handles decode errors. It also makes the phantom typing reach the persisted layer: a pane id can no longer be written into a tab id field, which today is just two `String`s.

**Cheaper fallback.** None worth taking. Keeping `String` and only skipping the formatting is not possible -- the format *is* the representation here.

**Measurement.** Same limitation as the finding above -- no ladder workload drives checkpoints, so nothing can issue a verdict. Diagnostically, `just benchmark-sample scrollback-stream 15` should show `UUID.uuidString` / `String` allocation frames under `toSnapshot` disappear from the main thread. The count that would move if an instrument existed is bytes allocated per capture: 36-byte strings times (groups + tabs + panes + splits + todos + 1).

**Regression risk.** None identified. The encoded JSON is unchanged because `UUID`'s Codable representation is the same string. Load-time behavior changes for a *corrupt* file: today one bad id string logs and falls back to a fresh session; after the change it throws a decoding error, which `loadAppInitFile` already handles as an invalid snapshot. Confirm that fallback is equivalent before landing.

**Verification.** The existing round-trip tests (snapshot -> JSON -> validateAndBuild -> snapshot) must pass byte-identically; add one test pinning the encoded JSON for a fixture model so the on-disk form is proven unchanged, and one that a file with a non-UUID id string still results in a fresh session rather than a crash.

**Risk.** The hand-authored id-less snapshot affordance must survive: the fields stay optional and the mint-on-decode path in `parseSplitNode` is unchanged.

<a id="lookup-3"></a>

#### LOOKUP-3. Make DisplayLine normalization allocation-free for text that is already a single clean line

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`

**Problem.** `DisplayLine.normalize` always does three passes and at least two heap allocations, plus one Unicode property-table lookup per scalar, and it is the constructor for every rendered string in every projection. One reconcile sweep builds roughly four `DisplayLine`s per pane (toolbar label, remote pill, agent pill, chip tooltip) and three per tab row (title, subtitle, group name) plus two for window chrome -- and a sweep runs after every non-coalesced message and at ~13 Hz for coalesced ones. Nearly every one of those inputs is a plain single-line title or path that the normalizer returns unchanged, after allocating a `[Substring]` array, a joined `String`, a fresh `UnicodeScalarView`, and a second split/join.

**Evidence.** `lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift#DisplayLine.normalize`: `let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")` / `for scalar in collapsed.unicodeScalars where !isRemoved(scalar) { kept.append(scalar) }` / `return String(kept).split(separator: " ").joined(separator: " ")`, with `isRemoved` opening with `if scalar.properties.generalCategory == .control { return true }`. Consumers: `Projections.swift#desiredPaneToolbar` builds `DisplayLine(paneCommandChromeText(...))`, `DisplayLine($0.displayString)`, `DisplayLine($0.toolbarLabel)`, `DisplayLine("\($0.kind) session \($0.sessionId)")` for every pane in every tab; `Projections.swift#desiredSidebar` builds three per row.

**Ideal fix.** Scan first, rewrite only if needed: walk the scalars once testing (a) any removed scalar, (b) any whitespace that is not a single interior U+0020, and return the original `String` when the scan finds nothing -- which is the normal case for a title, a cwd, or a `user@host`. Replace the `generalCategory` property lookup with the fixed code-point test it is equivalent to (`< 0x20 || (0x7F...0x9F)` -- general category Cc is exactly those code points and cannot change), keeping the bidi-override ranges as they are. The slow rebuild path stays for text that actually needs it.

**By construction.** n/a -- this removes work, not a representable state. It does not add any stored or cached value, so the projection stays a pure function of the model and the type keeps its single normalizing entry point.

**Cheaper fallback.** Hoist only the property lookup to the range test and leave the three passes. Cheaper to review, but it keeps two allocations per label per sweep, which is the larger term.

**Measurement.** No calibrated workload builds projections at a rate any verdict could see, so state it plainly: this is unmeasurable on the ladder. `just benchmark-sample btop-scroll 20` (diagnostic, never decision-bearing) is the instrument that can show the frames -- look for `DisplayLine.normalize`, `Unicode.Scalar.Properties.generalCategory`, and `String.split` self-samples on the main thread and confirm they leave. The number that must move is that frame group's self share within the main thread, not any workload verdict.

**Regression risk.** The scan adds one pass over text that does need rewriting; those strings are short and rare (control characters in a title), so the loss is bounded. Nothing gets heavier in memory.

**Verification.** `DisplayLine`'s existing normalization tests are the whole proof and must pass untouched -- collapsing runs of whitespace, stripping C0/C1 and bidi overrides, the "a\nb" -> "a b" ordering case, and trimming. Add cases for a scalar in 0x7F-0x9F and one already-normal string, asserting equality of text only (never identity), so the test stays structure-insensitive.

**Risk.** The Cc range test must be exactly equivalent to `generalCategory == .control`; get it wrong in the narrowing direction and a control character reaches a label.

<a id="lookup-4"></a>

#### LOOKUP-4. Answer pane-membership and layout questions with a tree walk instead of materializing pane-id arrays and sets

`perf-hot-path` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, `lib/DanTermCore/Sources/DanTermCore/Update.swift`, `lib/DanTermCore/Sources/DanTermCore/Model.swift`

**Problem.** `allPaneIds` flattens a split tree by concatenating arrays -- one array allocation per interior node -- and callers then use the result for a single membership test or throw it away. The worst instance is per-frame: `paneLayout` builds `Set(allPaneIds(tree))` at the top even though the set is only read in the zoomed branch (the unzoomed branch returns `hiddenPaneIds: []`), and `SplitContainerView.applyModelLayout` calls it from `layout()`, so a window resize or a divider drag pays the flatten plus the set build on every AppKit layout pass, for every mounted container. `SplitContainerView.reconcilePanes` then builds a second `Set(allPaneIds(rootNode))` from the same tree in the same pass. The rest are per-message: six call sites shaped `allPaneIds(tab.paneTree.root).contains(paneId)`.

**Evidence.** `ModelOperations.swift#allPaneIds`: `return allPaneIds(first) + allPaneIds(second)`. `PaneLayout.swift#paneLayout`: `let paneIds = Set(allPaneIds(tree))` followed by `if let zoomedPaneId, paneIds.contains(zoomedPaneId) {`; the unzoomed return is `PaneLayout(paneFrames: paneFrames, dividers: dividers, hiddenPaneIds: [])`. `app/SplitContainerView.swift#reconcilePanes`: `let desiredPaneIds = Set(allPaneIds(rootNode))`, reached from `override func layout()`. Membership-only callers: `ModelOperations.swift#tabForPane` (`if allPaneIds(tab.paneTree.root).contains(paneId) { return tab }`), `ModelOperations.swift#todoPopoverAnchorIsEligible`, `Update.swift` lines in `.paneFocused`/`.closePane`/`.movePaneToTab` handlers using the same expression, and `Model.swift#PaneTree.init` (`let paneIds = Set(allPaneIds(root))` used only for one `contains`).

**Ideal fix.** Add `containsPane(_ node: SplitNodeModel, _ id: PaneId) -> Bool` (a short-circuiting walk, no allocation) and make it the answer at every membership site, including `PaneTree.init`. Give `allPaneIds` an accumulating form that appends into one `inout [PaneId]` with `reserveCapacity`, so a genuine flatten costs one allocation instead of one per interior node. In `paneLayout`, move the pane-id set inside `if let zoomedPaneId`, where it is the only thing that reads it.

**By construction.** n/a -- no representation changes. `containsPane` narrows the API so a caller that only asks a yes/no question cannot accidentally pay for a materialized list, which is what every one of these sites did.

**Cheaper fallback.** Do only the `paneLayout` hoist and leave the concatenating flatten. That takes the per-frame allocation out and is a three-line change, but leaves the same shape everywhere else to be rediscovered.

**Measurement.** Nothing on the ladder resizes a window or drags a divider, so no benchmark verdict can decide the per-frame half; say so rather than implying otherwise. The observable that would decide it is a `just benchmark-sample btop-scroll 20` profile taken while the layout path is active, checking whether `allPaneIds`/`Set.init` frames appear under `SplitContainerView.layout`. The per-message half is below any instrument here.

**Regression risk.** None identified. Every changed site either allocates strictly less or is unchanged; no value is stored, so memory cannot grow.

**Verification.** Existing `paneLayout` tests (zoom hides the other panes, divider rectangles, minimum-extent clamping) and the pane-membership behavior tests in the reducer suites must pass unchanged -- they assert the returned geometry and the reducer's accept/reject decisions, which is exactly the behavior at stake.

**Risk.** `PaneTree.init` currently repairs an out-of-tree `focusedPaneId`; the containment walk must keep that repair identical, including for a root leaf.

<a id="lookup-5"></a>

#### LOOKUP-5. Key groups and tabs by id and make mruOrder an OrderedSet so per-message repair stops allocating sets

`data-modeling` &middot; impact 3, confidence 4 &middot; effort large

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, `lib/DanTermCore/Sources/DanTermCore/Update.swift`

**Problem.** `AppModel.groups` and `GroupModel.tabs` are plain arrays, so `tabById` is a nested linear scan through an intermediate `(groupIdx, tabIdx)` index pair, and "is this tab live" has no cheap answer. `update()`'s `defer` block therefore runs `reconcileTabState` on every message -- including every nested recursive `update(&model, ...)` call, of which there are 15 in Update.swift -- and that pass allocates a `Set<TabId>` in `liveTabIds`, then `tabStateIsCanonical` allocates a second `Set<TabId>` to re-verify that `mruOrder` has no duplicates and covers exactly the live tabs. Both sets are discarded immediately; in the overwhelmingly common case nothing changed and the answer is "already canonical".

**Evidence.** `ModelOperations.swift#reconcileTabState`: `let liveTabs = liveTabIds(in: model)` then `if tabStateIsCanonical(model, liveTabs: liveTabs) { return }`. `ModelOperations.swift#liveTabIds`: `var ids = Set<TabId>()` filled by a nested loop. `ModelOperations.swift#tabStateIsCanonical`: `var seen = Set<TabId>(); seen.reserveCapacity(liveTabs.count); for id in model.mruOrder { guard liveTabs.contains(id), seen.insert(id).inserted else { return false } }`. `ModelOperations.swift#tabLocation` is the `(groupIdx, tabIdx)` primitive every tab read goes through. `Update.swift#update` opens with the unconditional `defer { reconcileTabState(&model); ... }`.

**Ideal fix.** Add `OrderedCollections` (swift-collections is already pinned at 1.6.0 elsewhere in the repo) and hold `groups` as `OrderedDictionary<GroupId, GroupModel>` and each group's `tabs` as `OrderedDictionary<TabId, TabModel>` -- order preserved, membership O(1), no side index and no second store. `liveTabIds` then disappears: liveness is `groups.values.contains { $0.tabs[id] != nil }` with no allocation, and the canonicality check becomes membership tests plus a count comparison. Make `mruOrder` an `OrderedSet<TabId>`, which makes the duplicate half of the invariant structural and turns `moveToFront` from remove-all-then-insert into one ordered-set operation.

**By construction.** A duplicate tab id in one group, and a duplicate entry in `mruOrder`, both stop being representable -- today each is only prevented by `reconcileTabState` running after every message. The `(groupIdx, tabIdx)` pair, which is a location that a later mutation can invalidate, stops existing as a value callers can hold.

**Cheaper fallback.** Keep the arrays and give `reconcileTabState` an early exit that compares `mruOrder.count` against a running live-tab count before building any set. That removes most of the allocation without the churn, but leaves `tabLocation`'s index pair and leaves mruOrder's no-duplicates rule as a runtime check rather than a type.

**Measurement.** Unmeasurable on the existing ladder for the same reason as the other reducer findings: no workload drives messages. What would decide it is a message-rate stimulus that does not exist yet; the code-level quantity is two `Set<TabId>` allocations per `update()` call including nested ones, and the honest report is that only a profile (`just benchmark-sample`, diagnostic) could see them.

**Regression risk.** `OrderedDictionary` iteration and index arithmetic differ from `Array`, so tab insertion at a position and group reordering need care; a wrong `updateValue(forKey:insertingAt:)` can change visible tab order. Memory grows slightly per group (the hash table beside the ordered storage), which is negligible at tens of tabs but should be stated rather than assumed.

**Verification.** The reducer's tab-ordering and MRU behavior tests carry this: create/close/move tabs across groups and assert the resulting visible order and `mruOrder` contents, plus the existing idempotence assertions on `reconcileTabState`. All are behavioral and survive the container swap.

**Risk.** Adds a package dependency to DanTermCore (and to the app target that compiles the same files same-module), which the core has so far avoided; that must be weighed as its own decision.

<a id="lookup-6"></a>

#### LOOKUP-6. Resolve each sidebar row's chrome once per sweep instead of twice through separate title and subtitle accessors

`perf-hot-path` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`

**Problem.** `tabDisplayTitle` and `tabSubtitle` are separate accessors that each call `tabChrome`, and `tabChrome` resolves the focused pane by walking the tab's split tree and then abbreviates *both* the title and the cwd. `desiredSidebar` calls both per row, and `desiredWindowChrome` calls both again for the selected tab, so every sweep does two tree walks and two `abbreviateHome` pairs per row and discards half the result each time. `PaneTree.focusedPane` is itself a full `paneInNode` walk that copies out the whole `PaneModel`.

**Evidence.** `ModelOperations.swift#tabChrome`: `guard let session = tab.paneTree.focusedPane.session else ...; return sessionChrome(session)`, with `sessionChrome` computing `abbreviateHome(session.title)` and `session.cwd.map { abbreviateHome($0) }`. `ModelOperations.swift#tabTitle`: `tabChrome(tab).title`; `ModelOperations.swift#tabSubtitle`: `tabChrome(tab).subtitle`. `Projections.swift#desiredSidebar` uses both in one row literal: `displayTitle: DisplayLine(tabDisplayTitle(tab)), subtitle: tabSubtitle(tab).map { DisplayLine($0) }`. `Model.swift#PaneTree.focusedPane`: `paneInNode(root, id: focusedPaneId)!`.

**Ideal fix.** Call `tabChrome(tab)` once per row and read both halves from it, applying `tab.customTitle` over the title at that one site; keep `tabDisplayTitle`/`tabSubtitle` for the callers that genuinely want one. Have `tabChrome` take the already-resolved focused pane so the sweep's other per-row consumers (`tabChipKind`, `tabPaneChips`) share the single tree walk rather than each doing their own.

**By construction.** n/a -- pure call-shape change. Nothing is stored, so the projection remains a pure function of the model and no cache can go stale. That is also why it cannot regress the data model.

**Cheaper fallback.** None needed -- there is no cheaper variant; the alternative is leaving it.

**Measurement.** Unmeasurable on the ladder. The only instrument that can see it is a diagnostic `just benchmark-sample btop-scroll 20` main-thread profile showing `tabChrome`/`abbreviateHome`/`paneInNode` self-samples halve under `desiredSidebar`; no benchmark verdict applies.

**Regression risk.** None identified. Strictly fewer walks and fewer string allocations per sweep; no stored state added.

**Verification.** The sidebar projection tests that assert a row's `displayTitle` and `subtitle` for a custom-titled tab, an untitled tab, a home-relative cwd, and a tab with no session must pass unchanged -- they assert the projected values, which is the observable behavior.

**Risk.** Very low. The only trap is preserving the exact precedence of `customTitle` over the terminal-derived title when the two accessors are collapsed.

### Area: Reconcile cost per frame (`RECON`)

_Scope: Per-frame and per-event cost in the AppKit reconcile passes (app/Reconcile.swift, AppRuntime sweep, sidebar driver/view/cells, pane wrapper and strip)_

**Auditor's read on the area.** The pass structure itself is disciplined — every pass is a projection diffed against a cache, and the outbox correctly keeps a discovered fact off the reporting stack — but almost every projection is rebuilt whole over every tab and every pane on every sweep, so the sweep's cost is a function of how much state exists rather than of how much changed. Three of the projections additionally rebuild a mirror of a structure the model already holds (ContainerShape's two parallel trees) or recompute a normalization the model could have stored once (DisplayLine). I did not audit the terminal draw path, the pure `update()` reducer, Projections' correctness, or the popover/panel passes (switcher, confirmation, preferences, todo, theme browser), which are single-optional compares and structurally cheap.

<a id="recon-1"></a>

#### RECON-1. Make container visibility a diffed field of ContainerShape instead of an unconditional per-tab op

`perf-hot-path` &middot; impact 5, confidence 5 &middot; effort small

**Files.** `app/Reconcile.swift`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `app/SplitContainerView.swift`

**Problem.** `computeContainerOps` appends a `.setVisible` op for every tab unconditionally, outside the shape diff: `for tabId in new.keys { ops.append(.setVisible(tabId: tabId, visible: tabId == selectedTabId)) }`. `reconcileContainers` then executes every one of them with `container.isHidden = !visible; container.ensureLaidOut()`, and `ensureLaidOut` calls `applyModelLayout`, which runs the full pure `paneLayout(...)` solve, allocates `Set(allPaneIds(rootNode))`, and walks every leaf and divider. So one full pane-layout recomputation runs per tab -- including every hidden background tab -- on every reconcile sweep, whatever the sweep was actually about. Coalesced cosmetic sweeps fire at up to 1/0.075s (`AppRuntime.reconcileCoalesceInterval`), and every non-coalescing Msg sweeps inline, so with T tabs the app pays T layout solves per sweep to change one pane's title.

**Evidence.** app/Reconcile.swift#reconcileContainers: `case .setVisible(let tabId, let visible):\n    guard let container = tabContainers[tabId] else { break }\n    container.isHidden = !visible\n    container.ensureLaidOut()`. app/SplitContainerView.swift#ensureLaidOut: `func ensureLaidOut() { applyModelLayout() }` and `private func applyModelLayout() { let layout = paneLayout(in: PaneLayoutRect(bounds), tree: rootNode, zoomedPaneId: zoomedPaneId); reconcilePanes(with: layout); reconcileDividers(with: layout) }`, where `reconcilePanes` opens with `let desiredPaneIds = Set(allPaneIds(rootNode))`.

**Ideal fix.** Add `isVisible: Bool` to `ContainerShape` (derived from `tabId == model.selectedTabId` inside `desiredContainerShapes`) and emit `.setVisible` only when `oldShape.isVisible != shape.isVisible`, like every other field in that diff. Visibility then stops being a fact that lives outside the diffed representation, and an op that fires with nothing changed becomes unrepresentable. `setRootNode` and `setZoomedPane` already call `applyModelLayout` themselves, and the `layout()` override covers window resize, so the only remaining reason to force a layout is the hidden->visible transition -- which is exactly the case the diffed op still emits.

**By construction.** A `.setVisible` op for a tab whose visibility did not change stops existing, so no executor arm can do layout work for an unchanged container.

**Cheaper fallback.** Keep the op list shape and guard the executor arm: `if container.isHidden != !visible { container.isHidden = !visible; container.ensureLaidOut() }`. Same saving, but visibility stays outside the diffed representation, so the next field added beside it can reintroduce the same bug.

**Measurement.** No instrument on the ladder scales tab count -- every workload runs one tab and one pane, so this cost is near zero in all six of them and `benchmark-quick` cannot decide it. The honest check is a diagnostic profile: `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30`, then read `profile-report.json` for the main-thread self and inclusive share of `SplitContainerView.applyModelLayout` and `paneLayout`; the number that must move is that share going to zero on sweeps that changed no tree. At 1 tab it will be small either way, so state the result as "the frame is/is not present", not as a speedup.

**Regression risk.** A layout input that changes without changing the shape would stop being picked up. The three inputs to `applyModelLayout` are `bounds` (covered by the `layout()` override), `rootNode` (covered by `.setTree`/`.setLayout`), and `zoomedPaneId` (covered by `.setZoomedPane`), so none identified -- but a pane wrapper that becomes non-nil in `wrapperLookup` after its container was built would previously have been picked up by the next sweep's free relayout. Pane creation is a Command that runs before the sweep, so the same sweep's `.setTree`/`.build` already covers it; verify that specifically.

**Verification.** A UI-harness test that splits a pane in a background tab, selects that tab, and asserts both leaf wrappers land at the model-derived frames; plus a core test asserting `computeContainerOps` emits no ops at all when `old == new` and the selection is unchanged, and exactly one `.setVisible` pair on a selection change.

**Risk.** Low. The behavior contract is "the visible container is laid out", which the transition op still satisfies.

<a id="recon-2"></a>

#### RECON-2. Store ratios on one container tree instead of projecting two parallel indirect-enum mirrors per tab

**Merged into [MODEL-3](#model-3).** Track the work under MODEL-3; its section carries what this pass added.

`data-modeling` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `app/Reconcile.swift`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`

**Problem.** `ContainerShape` holds two structures that are the same tree: `tree: ContainerShapeNode` (structure, ratios erased) and `layout: ContainerLayoutNode` (structure plus ratios). `tree` is derivable from `layout` by dropping one field. Both are `indirect enum`s, so building one shape heap-allocates one box per node in each tree, and `desiredContainerShapes` rebuilds both for every tab in the model on every sweep -- then `computeContainerOps` compares them structurally to decide "tree changed" vs "ratio only". The allocation count is 2 x (2P-1) boxes per tab per sweep for P panes, all of it to discover that nothing moved.

**Evidence.** lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#ContainerShape: `let tree: ContainerShapeNode` / `let layout: ContainerLayoutNode`, built by `containerShapeNode(_:)` (`case .split(let id, let dir, let first, let second, _): return .split(id: id, direction: dir, first: containerShapeNode(first), second: containerShapeNode(second))`) and the near-identical `containerLayoutNode(_:)` which differs only by carrying `ratio`. Consumed in Projections.swift#computeContainerOps as `if oldShape.tree != shape.tree { ... } else if oldShape.layout != shape.layout { ... }`. Driven from app/Reconcile.swift#reconcileContainers: `let new = desiredContainerShapes(in: model)`.

**Ideal fix.** Keep one tree -- `ContainerLayoutNode` -- and replace the `tree` field with a comparison that ignores ratios: `func structurallyEqual(_ a: ContainerLayoutNode, _ b: ContainerLayoutNode) -> Bool`, recursing and skipping the ratio. `computeContainerOps` becomes `if !structurallyEqual(old, new) { .setTree } else if old.layout != new.layout { .setLayout }`. Halves the per-sweep allocation and removes the possibility of the two mirrors disagreeing about structure. The deeper lift, if it is on the table anyway: `SplitNodeModel` stores `PaneModel` in its leaves, which is the only reason the projection has to build a mirror at all. Leaves holding a bare `PaneId` with panes in a `[PaneId: PaneModel]` table would make `tab.paneTree.root` itself the container shape, and the projection would be a copy rather than a rebuild.

**By construction.** Two trees that could describe different structures for one tab stop existing; there is one tree and one predicate over it.

**Cheaper fallback.** None needed -- the reduced form is strictly smaller. If `structurallyEqual` reads worse than a derived value, keep `tree` but compute it lazily only on the branch where `layout` already differs, since a structural change implies a layout change.

**Measurement.** Same limit as the finding above: no ladder workload has more than one tab, so `benchmark-quick` cannot see it. `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` would show `containerShapeNode` / `containerLayoutNode` / `swift_allocObject` frames under `reconcileContainers` if they are hot; the number that must move is their combined main-thread share. Say plainly that the multi-tab case is unmeasurable with what exists -- deciding it would need a new sweep-cost harness that varies tab count.

**Regression risk.** None identified. The comparison is the only consumer of `tree`; nothing renders from it.

**Verification.** The existing container-op tests already pin the tree-vs-layout distinction (`desiredContainerShapesEagerProjectionIncludesBackgroundTabs` and the `computeContainerOps` cases): assert that a ratio-only edit yields `.setLayout` and a split/close yields `.setTree`, unchanged, against the single-tree form.

**Risk.** Low-medium. `structurallyEqual` must recurse over the same fields the erased tree carried (split id and direction), or a ratio-only change could be misread as structural.

<a id="recon-3"></a>

#### RECON-3. Normalize terminal-reported text once at ingress so DisplayLine is stored, not recomputed every sweep

`perf-hot-path` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `app/Reconcile.swift`, `lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `lib/DanTermCore/Sources/DanTermCore/Model.swift`

**Problem.** `DisplayLine.init` runs a three-pass normalization -- split-and-join on whitespace, a per-scalar filter that reads `scalar.properties.generalCategory`, then a second split-and-join -- allocating at least three Strings per construction. Every reconcile sweep constructs one per pane for the toolbar label (plus up to three more for the remote pill, agent pill, and chip tooltip), two per tab for the sidebar title and subtitle, one per group name, and two for the window chrome. The model stores the raw `String` (`PaneSessionModel.title`, `cwd`, `command`), so the normalization is redone from scratch on every sweep for text that has not changed since the last one, and the whole result is then thrown at `applyDiff`, which usually finds it equal to the cache.

**Evidence.** lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift#normalize: `let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")` ... `for scalar in collapsed.unicodeScalars where !isRemoved(scalar) { kept.append(scalar) }` ... `return String(kept).split(separator: " ").joined(separator: " ")`, with `isRemoved` opening `if scalar.properties.generalCategory == .control`. Called per pane per sweep at Projections.swift#desiredPaneToolbar (`label: DisplayLine(paneCommandChromeText(title: session?.title ?? "Terminal", cwd: session?.cwd, command: command))`) and per tab per sweep at #desiredSidebar (`displayTitle: DisplayLine(tabDisplayTitle(tab))`, `subtitle: tabSubtitle(tab).map { DisplayLine($0) }`). Both are reached from app/Reconcile.swift#reconcilePaneChrome and #reconcileSidebar on every sweep.

**Ideal fix.** Make `DisplayLine` the model's representation of every terminal-reported string: normalize in `update()` where `.sessionReport(.title/.cwd/.commandStarted)` arrives, and store `DisplayLine` on `PaneSessionModel` and `TabModel.customTitle`. Give `DisplayLine` combinators over already-normalized values (a `joined` that concatenates with a single space and skips the scan, since normalization is idempotent and closed under that join) so `paneCommandChromeText` composes without re-scanning. The projection then copies a value -- a retain -- instead of rebuilding one. This also strengthens the existing untrusted-text boundary: an un-normalized display string stops being representable anywhere past ingress, rather than being normalized by convention at each projection site.

**By construction.** A raw, un-normalized terminal string stops existing in the model, so no projection can forget to normalize and none can normalize twice.

**Cheaper fallback.** Leave the model on `String` and give `DisplayLine.normalize` an early-out that returns the input unchanged when a single scan finds no whitespace run, no leading/trailing space, and no removable scalar -- the overwhelmingly common case. This cuts the allocations but keeps the per-sweep scan and keeps normalization a projection-time convention.

**Measurement.** `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` -- the number that must move is the main-thread self share of `DisplayLine.normalize` and `Unicode.Scalar.Properties.generalCategory` in `profile-report.json`. Be honest about the limit: `scrollback-stream` is one pane in one tab and does not necessarily emit OSC title sequences, so this share may read at or near zero for reasons that have nothing to do with the change. If it does, say the ladder cannot see this and the claim rests on the code path alone. `just benchmark-sample btop-scroll 20` is the closer stimulus (a real TUI setting titles) but issues no verdict by construction.

**Regression risk.** Moving normalization to ingress runs it once per reported title rather than once per sweep. A pane reporting titles faster than the 0.075s coalesce window would normalize more often than today. That is bounded by the report rate, and the reports already allocate a Msg each; measure with `just benchmark-sample btop-scroll 20` if a title-storm case matters.

**Verification.** The existing `DisplayLine` normalization tests move to the ingress site unchanged (control stripping, bidi-override stripping, whitespace collapse, the newline-before-strip ordering), plus a new test that a title carrying C0 controls and a bidi override reaches the toolbar and the sidebar row already stripped.

**Risk.** Medium. It touches the model shape and the recovery snapshot codec, and the join combinator must preserve the exact ordering rule the current `normalize` documents (collapse first, strip second).

<a id="recon-4"></a>

#### RECON-4. Key the sidebar projection's tabs by id so row lookups stop being linear scans with intermediate arrays

`data-modeling` &middot; impact 3, confidence 5 &middot; effort medium

**Files.** `app/SidebarReconcileDriver.swift`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift`

**Problem.** `SidebarProjection` stores tabs only as nested arrays inside groups, so every lookup by id is a scan over every group's every tab, and the diff has to materialize flattened copies to do its work. `computeSidebarRowOps` builds `old.groups.flatMap(\.tabs)` into a dictionary and then flattens `new.groups.flatMap(\.tabs)` again to walk it -- two full array allocations plus a dictionary per sweep. `advanceSidebarCache.retainTabProjection` re-flattens `old.groups.flatMap(\.tabs)` once per unapplied id. `SidebarProjection.tab(_:)` is a scan per group, and `SidebarItemStore.apply` calls it for every `.insertTab` and `.reloadTab` op. All of it runs on every sweep, over every tab in the app, to produce a row-op list that is usually empty or one entry long.

**Evidence.** lib/DanTermCore/Sources/DanTermCore/Projections.swift#SidebarProjection: `func tab(_ id: TabId) -> SidebarTabProjection? { for group in groups { if let tab = group.tabs.first(where: { $0.id == id }) { return tab } }; return nil }`. #computeSidebarRowOps: `let oldTabById = Dictionary(uniqueKeysWithValues: old.groups.flatMap(\.tabs).map { ($0.id, $0) })` followed by `for newTab in new.groups.flatMap(\.tabs) { ... }`. #advanceSidebarCache: `guard let oldTab = old.groups.flatMap(\.tabs).first(where: { $0.id == id }) else { return }`, inside a function called once per entry of `unappliedTabIds`. Driven every sweep from app/SidebarReconcileDriver.swift#reconcile.

**Ideal fix.** Represent the projection as ordered ids plus a keyed table: `groups: [SidebarGroupProjection]` where a group holds `tabIds: [TabId]`, and one `tabs: OrderedDictionary<TabId, SidebarTabProjection>` on `SidebarProjection` (`references/swift-collections` `OrderedCollections` is already available and AGENTS.md prefers it to a hand-rolled structure). `tab(_:)` becomes a hash lookup, `retainTabProjection` becomes one subscript assignment, and the reload-attrs diff walks the two tables directly with no flattening. The ordering diff (`sidebarSequenceOps`) already works on id arrays, so it needs no change at all -- it currently receives `map(\.id)` copies it would then get for free.

**By construction.** A tab appearing in two groups, or a projection whose flattened tab list disagrees with its per-group lists, stops being representable -- the table is the single home for a tab's rendered attributes and the group holds only order.

**Cheaper fallback.** Keep the nested arrays and hoist the two flattened dictionaries into locals that `computeSidebarRowOps` and `advanceSidebarCache` share for one pass. That removes the repeated flattening but leaves `SidebarProjection.tab(_:)`'s scan and leaves the shape able to hold the same tab id in two groups.

**Measurement.** Unmeasurable with the current instruments: no benchmark workload creates more than one tab, and there is no sidebar-sweep harness. What would decide it is a new core-level benchmark over `computeSidebarRowOps(old:new:)` at, say, 50 tabs with one attribute changed, reporting allocations and wall time per call -- state that this instrument does not exist today rather than quoting the ladder.

**Regression risk.** None identified. Every consumer reads by id or by the group's order, both of which the keyed form serves directly. The one thing to watch is that `SidebarProjection` stays `Equatable` with the same semantics -- `OrderedDictionary` compares order-sensitively, so a pure reorder must still compare unequal exactly as the nested arrays do today.

**Verification.** The existing model-apply test for `computeSidebarRowOps` (apply the op script to a copy of `old` and assert it equals `new`) is the behavioral cover and must pass unchanged, plus the `advanceSidebarCache` retention tests for a suppressed rename row and an unapplied off-screen row.

**Risk.** Medium. `SidebarProjection` is compared wholesale as the driver's cache, so the equality semantics of the new container have to match the old nested-array semantics exactly.

<a id="recon-5"></a>

#### RECON-5. Separate the pane strip's overflow-label metrics from its color so fitting stops measuring text

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort small

**Files.** `app/PaneStripView.swift`

**Problem.** `PaneStripView.plan(width:)` calls `overflowLabel(count:).size().width` inside its shrinking loop. Each iteration resolves the effective appearance, builds a `ChipStyle` palette, allocates an `NSAttributedString`, and asks CoreText to measure it -- for a width that depends only on the digit count and a fixed 9pt system font. The loop runs up to `count` times, `draw(_:)` calls `plan` again and then builds the label a third time, and the whole thing repeats per multi-pane sidebar row on every repaint: a sidebar width drag repaints every visible row every frame, because `SidebarRowView.setFrameSize` resizes the hosted cells and `PaneStripView.setFrameSize` sets `needsDisplay` on any width change.

**Evidence.** app/PaneStripView.swift#plan: `while count > 1 {\n  let label = count < total ? overflowLabel(count: total - count).size().width : 0\n  ...\n  count -= 1\n}`; #overflowLabel builds `effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])`, `ChipStyle.paneStrip(isActive: false).palette(for: .terminal, appearance: appearance)`, and `NSAttributedString(string: "+\(count)", attributes: [...])` on each call. The repaint trigger is app/SidebarView.swift#SidebarRowView `override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resizeHostedCells() }` reaching app/PaneStripView.swift#setFrameSize `if widthChanged { needsDisplay = true }`.

**Ideal fix.** Split the label into the two independent things it currently bundles: its metrics, which depend only on the count and a fixed font, and its appearance, which depends only on the theme. Give the view a `static let overflowWidths: [CGFloat]` computed once from the fixed font for every count a strip can show (bounded by the pane count a tab can hold), and build the colored `NSAttributedString` only in `draw(_:)`, for the one count actually drawn. `plan(width:)` then allocates nothing and does no text measurement, which also makes it a pure function of `(chips.count, width)` -- exactly what the harness already tests it as.

**By construction.** A width question that has to build a colored string to be answered stops existing; metrics and appearance become separately derivable.

**Cheaper fallback.** Hoist the appearance resolution and palette out of the loop and reuse one attributed string, mutating only its string content. Fewer allocations, but the CoreText measurement stays in the loop.

**Measurement.** No instrument covers this -- the benchmark ladder never draws the sidebar, and `benchmark-headless-draw` is bound to `TerminalCore`'s `drawRenderFrame`. What would decide it is `just benchmark-sample btop-scroll 20` with a multi-pane tab open in the sidebar, reading `profile-report.json` for the main-thread self share of `PaneStripView.plan`, `NSAttributedString.size`, and the CoreText typesetter frames beneath them. That workload issues no verdict by construction, so this stays a diagnostic; say plainly that the sidebar-resize case has no calibrated instrument.

**Regression risk.** A static width table computed at first use bakes in the font's metrics at that moment. `NSFont.systemFont(ofSize: 9, weight: .medium)` does not vary with appearance, so none identified -- but confirm it does not vary with an accessibility text-size setting before making the table static; if it can, key it off the font's own identity rather than making it a constant.

**Verification.** The existing UI-harness test that the planned run plus the `+N` label fits inside the given width (it already calls `overflowLabelWidth(count:)` to account for the label the same way) must pass unchanged, plus a test that the table's width for a count equals the measured attributed string's width for that count.

**Risk.** Low. The fitting behavior is already pinned by a harness test that computes the label width independently.

<a id="recon-6"></a>

#### RECON-6. Compute the pane roster only when someone is subscribed, instead of on every send

`simplification` &middot; impact 2, confidence 5 &middot; effort small

**Files.** `app/AppRuntime.swift`

**Problem.** `pushRosterIfChanged` runs after every reconcile in `dispatchInFrame`, and its first act is `let roster = paneRoster(in: model)` -- an array of one `PaneRosterItem` per pane in the whole app, each carrying five ids and three strings, built by walking every group, every tab, and every leaf. It is then compared against `rosterBaseline` and, in the overwhelmingly common case where nothing subscribes, discarded. So the app pays an O(total panes) build and an O(total panes) structural comparison per send purely to advance a baseline nobody is reading.

**Evidence.** app/AppRuntime.swift#pushRosterIfChanged: `let roster = paneRoster(in: model)`, `guard roster != rosterBaseline else { return }`, `rosterBaseline = roster`, and only then `guard rosterSubscribers.isEmpty == false else { return }` -- the subscriber check is the last guard, after both the build and the compare. Called from #dispatchInFrame (`case .reconcileNow: ... reconcile(); pushRosterIfChanged()`) and #sweepAndDispatchFollowUps.

**Ideal fix.** Make the baseline's type say when it is meaningful: `rosterBaseline: PaneRoster?`, nil whenever there are no subscribers. `pushRosterIfChanged` returns immediately on an empty subscriber set without building anything; `subscribeToRoster` sets the baseline to the roster it just replied with, which is precisely the picture that subscriber now holds. A `nil` baseline then means "nobody is listening" rather than "the roster happens to be empty", so the reassuring and the blind cases stop rendering identically -- the instrument-coverage rule applied to state.

**By construction.** A baseline that describes a picture no subscriber holds stops being representable, so the ordering argument in the current comment ("deliberately does not touch rosterBaseline") becomes a property of the type rather than a comment someone must keep true.

**Cheaper fallback.** Move the `rosterSubscribers.isEmpty` guard above the `paneRoster(in: model)` call and leave the baseline stale while unsubscribed. Cheaper still, but a stale non-nil baseline is exactly the ambiguity the ideal removes, and the next subscriber could be told a change it never saw was already delivered.

**Measurement.** Unmeasurable on the ladder for the same reason as the rest of this area -- one pane, one tab. `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` would show `paneRoster` frames under `dispatchInFrame` if it is hot at that scale; the number that must move is that inclusive share to zero. Expect it to be small at 1 pane and say so rather than claiming a win.

**Regression risk.** The push semantics must not change: a subscriber that arrives, then sees a change, must still get exactly one notification for that change. Setting the baseline at subscribe time to the roster carried in the reply preserves that. None identified beyond it.

**Verification.** An IPC test that subscribes, makes one pane change, and asserts exactly one roster notification carrying the new roster; and a second that subscribes after several unobserved changes and asserts the reply carries the current roster and no notification follows until the next real change.

**Risk.** Low, but it is the ordering-sensitive part of a live protocol, so the two tests above are the gate rather than a formality.

### Area: Search index and scanning (`FIND`)

_Scope: Terminal search: index construction, incremental maintenance, and scanning_

**Auditor's read on the area.** This area is already unusually well-modeled: the closed-history half is keyed in width-free record coordinates so it never folds on an ordered read, the index-advance path uses `forEachClosedRecordCell` rather than painted projection rows, and `Instrument.searchIndexMaintenance` / `Instrument.projectionRow` / `Instrument.searchDistanceWork` already pin those contracts with behavioral tests. The remaining cost clusters at three seams the current representation does not name: needle-to-needle (a keystroke discards the whole index), read-to-read (three callers each rebuild the same per-frame snapshot), and unit-to-unit (the matcher stores a non-trivial key ring and re-compares the whole needle per unit). I did not audit `CanonicalCaseless.generated.swift`'s table shape, the grapheme segmenter, or `LogicalLineStore`'s arena/locate internals -- other auditors own those; I only followed the calls search makes into them.

<a id="find-1"></a>

#### FIND-1. Narrow the closed-history index on needle append instead of rebuilding it per keystroke

`data-modeling` &middot; impact 5, confidence 5 &middot; effort large

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/app/SearchOverlayView.swift`

**Problem.** Every character typed in the find field re-scans the entire retained closed history from record 0. `SearchOverlayView.controlTextDidChange` sends the whole field on each keystroke, `Update` routes it to `Terminal.beginSearch`, and `beginSearch` constructs a brand-new `Search`, whose `init` calls `builtSearchMatchIndex` -> `scanClosedRecordSearchUnits(records: 0..<closedCount)`. That loop visits every retained cell (`forEachClosedRecordCell` per record) and runs the matcher on each. At the documented 16 MiB retained budget (~1,552 charged B/row, so tens of thousands of retained rows at 179 columns) typing a five-character needle scans the whole history five times, once per keystroke, on the host's serial queue -- the queue that also applies PTY output, so the pane stops absorbing output while it runs. The information needed is already in hand and thrown away: match starts of "error" are a subset of match starts of "erro".

**Evidence.** `beginSearch`: `var newSearch = Search(query: query, position: TextAnchor(row: streamRows.upperBound, column: 0), history: history)`. `Search.init`: `index = builtSearchMatchIndex(needleKeys: needleKeys, history: history)`, which is `let prefixScan = scanClosedRecordSearchUnits(needleKeys: needleKeys, seededBy: [], records: 0..<closedCount, includesLeadingBoundary: false, history: history)`. The overlay side: `func controlTextDidChange(_ obj: Notification) { runtime?.send(.searchNeedleChanged(paneId: paneId, needle: searchField.stringValue)) }` with no debounce anywhere on the path.

**Ideal fix.** Make the retained index a property of a *needle prefix* rather than of a whole query, and give `Terminal` a `refineSearch(to:)` the app calls when the field text grows. On refine, compare `searchGraphemeKeys(for: newQuery)` against the stored `index.needleKeys`: when the stored keys are a strict prefix of the new keys, the new match starts are a subset of the stored `prefixMatches` starts, so the pass walks the existing `Deque<RecordSearchRange>` and asks the store for the units following each stored `end`, keeping only entries that extend. Work becomes proportional to the current match count and the appended key count, not to history depth. Any non-append edit (backspace, paste, an edit that re-segments the final cluster) falls through to today's full build, and comparing the *key arrays* rather than the strings is what makes that guard exact -- adding a combining mark rewrites the final key, which a `hasPrefix` on the string would not see.

**By construction.** An index whose stored `needleKeys` are the prefix it was built for cannot be silently reused for an unrelated needle: the refine path either extends or rebuilds, so there is no state in which the stored matches belong to a query the field no longer holds.

**Cheaper fallback.** Debounce the needle in `Update` so a burst of keystrokes builds one index instead of one per character. Strictly worse: it hides the cost behind latency rather than removing it, and the first press on a long needle still pays a full history scan.

**Measurement.** `just terminal-occupancy-probe --json`, sample `search: first press on a new needle`. Note plainly: **that case cannot see this change as written** -- it deliberately uses a distinct needle per iteration ("so no cache can serve the next one"), which is exactly the case that must still fall back to a full build. Deciding this needs a new `OccupancyCase` that types one needle character by character (`beginSearch("N")`, `beginSearch("NE")`, ...) and reports the summed milliseconds across those keystrokes at `OccupancyProbeDefaults.lines = 30_000`; the number that must move is that sum, from ~N full scans toward ~one full scan.

**Regression risk.** The refine path adds a per-match forward unit lookup in `LogicalLineStore`; a needle whose prefix matches nearly every position (a single space, a single `e`) has a match count comparable to the cell count, so refining could cost about as much as rescanning. Guard by falling back to a full build when `prefixMatches.count` exceeds a fraction of the retained cell count. The new probe case above is the only workload that would show it -- no workload on the benchmark ladder contains search at all.

**Verification.** For a corpus, assert `indexedSearchRecordRangesForTesting` and `searchStatus` are identical after `beginSearch("error")` and after the keystroke sequence `beginSearch("e")` ... `beginSearch("error")`, including for needles that cross a record boundary, contain a wide cell, and end in a combining mark whose addition re-segments the final grapheme.

**Risk.** Medium. The refine path must reproduce the newline boundary unit and the `boundaryWindow` trailing state exactly; a subtle divergence shows as silently missing matches rather than as a crash.

<a id="find-2"></a>

#### FIND-2. Build the per-frame match snapshot once and pass it to all three search reads

`perf-occupancy` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`, `/Users/dan/Code/danterm/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`

**Problem.** `currentMatches(in:)` re-scans the whole mutable suffix -- the open tail plus every live grid row, ~11.8k cells at 179x66 -- and it runs three separate times per delivered frame while a search is active, all on the main actor. `TerminalPaneSession.consume` calls `emitSearchStatusIfNeeded` -> `searchStatus` -> `currentMatches`; it then calls `planIfNeeded`, and `RenderFramePlanner` reads `terminal.activeSearchMatchRange` (a second `currentMatches`) and `terminal.searchMatchRanges(in: viewportRows)` (a third). The three reads see the same terminal value in the same turn, so the three scans are identical by construction and two are pure waste.

**Evidence.** `TerminalPaneSession.consume`: `emitViewportStateIfNeeded(); emitSearchStatusIfNeeded(); ... if isVisible, isRenderingAvailable { planIfNeeded(frameState.terminal) }`. `RenderFramePlanner`: `let activeSearchMatchRange = terminal.activeSearchMatchRange` then `let searchMatchRanges = terminal.searchMatchRanges(in: viewportRows)`. Each of `activeMatch`, `status`, `matchRanges` opens with `let matches = currentMatches(in: context)`, and `currentMatches` ends in `scanSearchUnits(... absoluteRows: suffixRows.lowerBound..<(suffixLastContentRow + 1) ...)`, which begins `Instrument.projectionRow.record(count: absoluteRows.count)`.

**Ideal fix.** Promote the snapshot to a value the frame reads once. Add a public `Terminal.searchReadout(rows:)` returning one `TerminalSearchReadout { status, activeMatch, matchRanges }` produced from a single `currentMatches` call, and have both the planner and `emitSearchStatusIfNeeded` read that one value. The three existing entry points become derivations of it rather than three independent scans. This is not a cache: nothing is stored across turns and nothing needs invalidating -- the snapshot is a local already built inside `Search`, handed to every consumer of one frame instead of rebuilt per consumer.

**By construction.** With one readout value there is no expressible way for a frame's counter, active-match highlight, and viewport highlights to come from three different scans -- the invariant `TerminalSearchStatus`'s own doc comment claims for the counter ("keeps a counter from ever showing a total and an index taken from different scans") but which the current call graph does not actually provide across the status/highlight boundary.

**Cheaper fallback.** Keep the three entry points and memoize the snapshot on `Terminal` keyed by a mutation generation. That is exactly the hand-invalidated mirror this repo does not want: the key would have to cover history mutation, viewport movement, alternate-screen toggles, and needle changes, and a missed input renders stale highlights.

**Measurement.** A `TerminalCore` test in the shape already used at `TerminalSearchTests` line ~1086: `Instrument.projectionRow.measure { _ = terminal.searchStatus; _ = terminal.activeSearchMatchRange; _ = terminal.searchMatchRanges(in: viewportRows) }`. The number that must move is that row count, from ~3x the suffix row count to ~1x. Wall clock: `just terminal-occupancy-probe --json`, case `search: held Enter, quiet pane`, which already brackets `searchNext()` plus `searchStatus` together for this reason.

**Regression risk.** None identified for scan cost. The readout carries `matchRanges` for the viewport, so a caller that wanted only the status now materializes a bounded viewport array it did not before; that array is already built on every planned frame, and a search is active in every case that reaches this code.

**Verification.** Existing search behavior tests unchanged (counter, active highlight, viewport highlights), plus a test that the readout's `status` total equals the count implied by walking `matchRanges` over the whole stream, so the fields cannot drift apart.

**Risk.** Low. The change is a re-plumbing of existing values; the main hazard is a caller left on an old entry point, which the test above would not catch -- delete the redundant public entry points rather than leaving them.

<a id="find-3"></a>

#### FIND-3. Replace NeedleWindow's key ring with a KMP state plus a POD ring of start positions

`perf-hot-path` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/NeedleWindow.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`

**Problem.** `NeedleWindow.consume` runs once per scanned unit -- per cell of the entire closed history on an index build, and per cell of the mutable suffix on every read -- and does O(needle length) work each time. It stores the whole `Unit` (which carries a `SearchGraphemeKey`, an enum with an `[Unicode.Scalar]` payload, so the ring element is non-trivial and every slot write runs a value-witness copy/destroy) and then re-compares all `needleKeys.count` keys with a modulo per index. Both the storage and the comparison follow from the representation, not from the problem: the only thing the ring must carry across units is where a candidate started.

**Evidence.** `private var window: [Unit?]` and `private mutating func consume(_ unit: Unit, recordsMatch: Bool) -> Match? { let slot = unitCount % needleKeys.count; window[slot] = unit; unitCount += 1; guard recordsMatch, unitCount >= needleKeys.count else { return nil }; let startIndex = unitCount - needleKeys.count; for offset in needleKeys.indices { guard window[(startIndex + offset) % needleKeys.count]?.key == needleKeys[offset] else { return nil } } ... }`. `enum SearchGraphemeKey { case scalar(UInt32); case scalars([Unicode.Scalar]) }` is what makes `Unit` non-trivial, while both `Position` types -- `TextAnchor { row, column }` and `RecordTextPosition { record, cellOffset }` -- are plain integers.

**Ideal fix.** Compute the needle's KMP failure table once in `init` (the needle is fixed for the matcher's whole life) and keep a single `matchedCount` plus a ring of `Position` starts. Per unit the matcher then does one key comparison amortized and one POD store, and a match reports the start held `needleKeys.count - 1` slots back. `trailingUnits` -- the only reason keys are retained at all -- is re-derivable at scan end by `recordSearchBoundaryWindow`, which already exists and already reads exactly the last `needleKeys.count - 1` units for the tail-regressed path; deleting `trailingUnits` moves an O(m) job from every unit to once per scan.

**By construction.** A matcher that holds no keys cannot report a match whose stored key ring has drifted from the needle it was built with, and the `window[...]?` optional -- a representably empty slot inside a window the code has already proved full -- stops existing.

**Cheaper fallback.** Keep the ring but store `[SearchGraphemeKey]` and `[Position]` in two parallel arrays and stop storing `end`. That removes the `Unit?` optional and one field but leaves the non-trivial key store and the O(m) re-comparison in place.

**Measurement.** `just terminal-occupancy-probe --json`, case `search: first press on a new needle` (median ms), because that case is dominated by `scanClosedRecordSearchUnits` running `consume` once per retained cell at `lines = 30_000`. Run `--iterations 40` on both trees in one session. `Instrument.projectionRow` will *not* move -- this changes cost per unit, not units visited -- so do not read a flat instrument count as the change having done nothing.

**Regression risk.** A long needle with a highly self-similar prefix makes KMP retry through failure links, so worst-case per-unit work is not strictly lower than today's fixed O(m); it is amortized O(1) and bounded by the same m. The occupancy probe case above with a pathological needle (`String(repeating: "ab", count: 12)`) is the workload that would show it.

**Verification.** `TerminalSearchTests` unchanged, plus a matcher-level test over overlapping needles (`aaa` in `aaaaa`, `abab` in `ababab`) asserting the same match starts and ends as today, and the existing assertions that `boundaryWindow.count <= max(0, needleKeys.count - 1)` still hold once the window is derived rather than carried.

**Risk.** Medium. Overlapping-match semantics are easy to change accidentally when moving from a fixed window to a failure-link automaton; the overlapping-needle tests are the guard.

<a id="find-4"></a>

#### FIND-4. Answer "does this projection row have content" without materializing a painted GridRow

`perf-memory` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift`

**Problem.** `lastProjectedContentRow` walks rows backwards through the `ProjectionRows` subscript purely to ask a boolean. That subscript is documented to materialize a `GridRow` per access, which for a history row means `locate(displayRow:)` plus `paintedRow(at:)` -- a fresh cell array plus per-cell style/hyperlink resolution -- and the predicate throws all of it away after finding one non-padding cell. It runs at least once per `currentMatches` (so, with finding 2 unfixed, three times per frame) and again inside `searchContentRank`. On a screen whose lower rows are blank -- right after `clear`, or any pane where the prompt sits above the last row -- the backward walk paints every empty row it rejects.

**Evidence.** `for absoluteRow in (lower..<upper).reversed() where context.rowContainsContent(stream[absoluteRow - context.evictedRowCount]) { return absoluteRow }`, with `static func rowContainsContent(_ row: GridRow) -> Bool { row.cells.contains { cell in cell.kind == .narrow || cell.kind == .wideHead } }`. `ProjectionRows`' own doc: "Materializes a `GridRow` per history subscript", and its subscript body calls `history.paintedDisplayRow(at: position)`.

**Ideal fix.** Give the projection the fact directly: `ProjectionRows.hasContent(at:)`, answered from the live row's own cells for the live half and from the store's record shape for the history half -- `RecordSummary` already carries `cellCount` and `trailingFillStyle`, so a display row's content-bearing status is a width-free question the store can answer without painting a cell, a style, or a hyperlink. `lastProjectedContentRow` then walks that instead of the subscript, and the search path stops allocating a row array per rejected row.

**By construction.** n/a -- this removes work, not a representable state. It does stop search being the only reader that needs a fully painted row to answer a question about emptiness, which is what currently couples search cost to the style and hyperlink side tables.

**Cheaper fallback.** Have `lastProjectedContentRow` use `stream.forEachRow(in:)` (one history locate for the whole range) instead of a per-row subscript. Cheaper than today but still paints every row it inspects.

**Measurement.** No existing instrument sees it: `Instrument.projectionRow` counts the rows `scanSearchUnits` walks, not the rows this predicate paints. Making it visible means adding a counter inside `lastProjectedContentRow`'s loop; the number that must move is that count on a terminal whose bottom rows are blank. Wall clock: `just terminal-occupancy-probe --json`, case `search: held Enter, quiet pane`. Say plainly that this is small relative to findings 1-3 and may sit under the probe's noise.

**Regression risk.** None identified for the search path. The risk is semantic: a `hasContent` derived from record shape must agree with `rowContainsContent`'s exact rule (narrow or wideHead present; padding, wideTail and spacerHead do not count), and disagreement at the seam row would move where search believes the stream ends.

**Verification.** A test asserting `hasContent(at:)` equals `Terminal.rowContainsContent(projection[row])` for every row of a corpus containing trailing-filled rows, a soft-wrap seam, a wide cell at the row end, and a padding-only row -- then the existing search tests unchanged.

**Risk.** Medium. The seam and alternate-screen rules `ProjectionRows` owns must be honoured by the new accessor; getting the seam row wrong changes match results, not just cost.

<a id="find-5"></a>

#### FIND-5. Carry each suffix match's content ordinal out of the scan that already counts it

`simplification` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`

**Problem.** `searchContentRank` re-walks the mutable suffix unit by unit to turn a live anchor into a content rank, incrementing a counter for every unit at or before the anchor. `currentMatches` has just walked the same units through the same `forEachSearchUnit` and could have handed each suffix match its ordinal for free, since the walk *is* the counter. Because `resolvedSearchMatch` may need ranks for the position and for both neighbouring candidates, one status read can walk the suffix up to three extra times on top of the scan that produced the matches -- and each of those also calls `lastProjectedContentRow` (finding 4).

**Evidence.** `forEachSearchUnit(in: context.projection, absoluteRows: rows, lastContentRow: lastContentRow, context: context) { _, start, end in Instrument.searchDistanceWork.record(); if end <= anchor { rank += 1 } }` in `searchContentRank`, against `scanSearchUnits`'s body `forEachSearchUnit(...) { key, start, end in if let match = matcher.record(NeedleWindow.Unit(key: key, start: start, end: end)) { ... } }` -- the same traversal, one counting and one matching, run separately.

**Ideal fix.** Extend the suffix half of `SearchMatchSnapshot` to carry `(range, contentOrdinal)` per match, filled from the counter the scan already maintains, with the base ordinal (`closedContentUnitTotal`) recorded once. `searchContentRank` for a suffix anchor that is a match start -- which is every anchor `resolvedSearchMatch` compares, since navigation always leaves `position` on an occurrence -- then reads the stored ordinal instead of re-walking. This is not a side table: the ordinal travels inside the same value as the match it belongs to, produced by the same pass, and dies with it at the end of the read.

**By construction.** A match and its ordinal produced by one pass cannot disagree; today the two come from two separate traversals of a projection that arriving output can change between them, so a rank taken from a different walk than the match is representable.

**Cheaper fallback.** Leave the ranks recomputed but short-circuit `searchDistance` when both candidates lie in the closed prefix, where `contentRank` is already O(1). That helps only the case that is already cheap.

**Measurement.** `Instrument.searchDistanceWork.measure { _ = terminal.searchStatus }` on a terminal whose active match sits in the live suffix -- the instrument exists for exactly this and is already used at `TerminalSearchTests` line ~754. The number that must move is the recorded unit count, toward zero for the navigation case. Wall clock: `just terminal-occupancy-probe --json`, case `search: Enter, output arriving between presses`.

**Regression risk.** The snapshot's suffix element grows by one `Int` per match; suffix matches are bounded by the visible rows, so the added footprint is a few words per frame and transient. None identified beyond that.

**Verification.** The existing distance-resolution tests (nearest-match selection with the position between two occurrences, and the equal-distance tie resolving toward the later match) must pass unchanged, plus a test that the selected index is identical whether the position lies in the closed prefix or in the live suffix.

**Risk.** Low. An anchor that is not a match start still falls back to the walk, so the fast path is additive and the slow path is the code that exists today.

### Area: Serialization: IPC, tape, checkpoints (`WIRE`)

_Scope: Serialization cost: IPC payloads, pane-tape streaming, and recovery checkpoints_

**Auditor's read on the area.** The layering here is genuinely good -- the checkpoint's expensive half is already deferred off the main actor behind `CheckpointCapture.encoder`, the dump path builds records on a utility queue, and the checkpoint scheduling policy is a clean pure state machine. The cost sits at the seams instead: every payload crosses two or three JSON representations before it reaches the socket, and the line framer walks the whole IPC byte stream one byte at a time. I did not audit the terminal engine's flight recorder itself, the audit-log writer, the tailnet/TLS transport, `RecoveryStore`'s file IO and session lock, or the CLI's rendering side beyond confirming which framer the client uses.

<a id="wire-1"></a>

#### WIRE-1. Frame IPC lines by scanning for the newline, not by appending one byte at a time

`perf-hot-path` &middot; impact 4, confidence 5 &middot; effort small

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/IpcLineFramer.swift`, `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift`, `lib/DanTermClient/Sources/DanTermClient/DanTermClientSession.swift`

**Problem.** `IpcLineFramer.append` is a per-byte loop over the received `Data`, with a `Data.append(byte)` call per non-newline byte. It runs on every byte that crosses the IPC socket in both directions: the app's read loop feeds it 4 KB at a time, and every client (`danterm` CLI, the iOS `PaneReplica`) feeds it every reply and every tape record it receives. A `pane tape dump` or a followed mirror stream carries megabytes, so the cost is per byte of the whole stream. `Data.append` is a non-inlinable cross-module call with a uniqueness and bounds check per byte, and each emitted `.line(buffer)` copies the accumulated buffer again.

**Evidence.** IpcLineFramer#append: `for byte in data { ... if byte == 0x0A { events.append(.line(buffer)); buffer.removeAll(keepingCapacity: true); continue } ... buffer.append(byte) }`. IpcConnection#startReading feeds it every read: `let data = Data(buffer.prefix(Int(count))); for event in framer.append(data)`. DanTermClientSession#nextLine does the same on the receive side: `for event in framer.append(chunk)`.

**Ideal fix.** Represent the framer's state as a buffer plus the region not yet scanned, and advance it with a whole-slice search for 0x0A (`data.withUnsafeBytes` + `memchr`, or `firstIndex(of: 0x0A)` on the slice). A line wholly contained in one chunk is emitted as a slice of that chunk with no accumulation at all; only a line that spans chunks touches the carry buffer, and it is appended as one contiguous slice. The oversize check becomes an arithmetic comparison against the pending length instead of a per-byte test.

**By construction.** The intermediate accumulation stops being representable for the common case: a line that arrives whole inside one read has no separate buffered copy at all, so there is no state that can disagree with the input, and the oversize bound is checked once per line rather than once per byte.

**Cheaper fallback.** Keep the byte loop but hoist it into `data.withUnsafeBytes` over a raw pointer and accumulate into a `[UInt8]` with `reserveCapacity`, which removes the per-byte `Data` call without changing the structure. Strictly worse: it keeps the byte-at-a-time shape that the slice search deletes.

**Measurement.** No calibrated instrument on the ladder contains this path -- every workload in `agent-docs/terminal-performance.md` drives the terminal through a PTY or headlessly, and none attaches an IPC client. Deciding it needs a new harness: a fixed corpus fed through `IpcLineFramer.append` in one process, reporting bytes per second, plus `just benchmark-loop scrollback-stream` with a `danterm pane tape follow` attached and a Time Profiler sample of the client process, where `IpcLineFramer.append` self time must fall. State plainly that this is currently unmeasurable by an existing command.

**Regression risk.** None identified. A slice-based scan does strictly less work for every input shape, including a stream of single-byte reads, where it degenerates to the same one comparison per byte without the append.

**Verification.** `IpcLineFramerTests` already pins the behavioral contract -- lines split across chunk boundaries, empty lines, the oversize refusal and the resynchronization after it. Add a case that a line spanning three chunks frames identically to the same bytes delivered in one chunk, which is the invariant the slice path could break.

**Risk.** Low. One self-contained public method with existing behavioral tests; the `.line(Data)` event type does not change.

<a id="wire-2"></a>

#### WIRE-2. Carry a tape record as its typed event, not as a JSONValue decoded from its own encoding

`data-modeling` &middot; impact 5, confidence 5 &middot; effort large

**Files.** `app/SwiftTerminalSessionView.swift`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift`, `lib/DanTermProtocol/Sources/DanTermProtocol/JSONValue.swift`, `lib/DanTermProtocol/Sources/DanTermProtocol/Envelope.swift`

**Problem.** Every recorded terminal event is JSON-encoded, immediately JSON-decoded back into a `JSONValue` tree, carried through the stream policy as that tree, and then JSON-encoded a third time by `encodeIpcLine`. For a `.feed` event the base64 of the PTY bytes is materialized as a String by the engine's encoder, escaped into JSON bytes, parsed back out into a second String, and escaped again into the wire line -- four materializations and three JSON passes per event. This runs once per recorded event, and a recorded event is roughly one PTY read chunk, so it scales with the pane's output while any tape dump, follow, or iOS replica stream is open. `JSONValue.init(from:)` makes it worse: it probes `try? decode(Bool)`, then Double, then String, then array, so every string and object node in the tree is reached by constructing and discarding Foundation decoding errors.

**Evidence.** app/SwiftTerminalSessionView.swift#paneTapeFollowEventJSON is the whole function: `let data = try JSONEncoder().encode(event); return try JSONDecoder().decode(JSONValue.self, from: data)`. The source it re-encodes is NeutralTerminalRecordingEvent#encode(to:): `case .feed(let bytes): try values.encode("feed", forKey: .type); try values.encode(Data(bytes).base64EncodedString(), forKey: .base64)`. The third pass is Envelope.swift#encodeIpcLine: `var line = try encoder.encode(value)`.

**Ideal fix.** Make the record an `Encodable` value that holds the typed event, not a `JSONValue`. `PaneTapeEvent` already carries the typed facts hoisted out of the event (sequence, timings, byte span); let it carry the `NeutralTerminalRecordingEvent`-shaped payload as an `Encodable` associated value too, and let `makePaneTapeEventRecord` build a record struct whose `encode(to:)` writes the event through the engine's own conformance. Then a record is encoded exactly once, at the moment it becomes wire bytes. The layering constraint that pushed `JSONValue` here -- DanTermSupport must not import the engine -- is satisfied by generics or a small protocol the engine's event conforms to, not by a lossy round trip through a dictionary tree.

**By construction.** A tape record stops being able to hold a JSON tree that disagrees with the typed event it was built from, because there is only one encoding of the event and it happens once. The `try` on the record construction path also disappears: an event can no longer fail to become a record.

**Cheaper fallback.** Keep `JSONValue` as the record type but delete the decode half: have the engine build the `JSONValue` for an event directly in `paneTapeFollowEventJSON`, mirroring `NeutralTerminalRecordingEvent.encode(to:)` by hand. That removes one full encode and one full decode per event but creates exactly the duplicate-representation drift the ideal removes -- two hand-written spellings of the same event that a test must now pin against each other.

**Measurement.** No calibrated workload reaches this code -- the ladder never opens a tape stream. The diagnostic that would decide it: `just benchmark-loop scrollback-stream`, attach `danterm --socket <harness socket> pane tape follow` to the streaming pane, and take a Time Profiler sample of the app; `JSONEncoder`/`JSONDecoder`/`base64EncodedString` frames under `paneTapeFollowEventJSON` must disappear from the utility-queue thread's self time. Report it as unmeasurable by any frozen instrument today.

**Regression risk.** None identified for throughput. The wire bytes must stay identical, which is the real risk and is a correctness one, not a performance one.

**Verification.** A golden-bytes test: for a fixed set of recorded events (feed with non-ASCII bytes, write, resize with `pinned`, input, paste, mouse, viewport, checkpoint), the encoded notification line must be byte-identical before and after. `PaneTapeInspectTests` and the CLI's record reader already decode this shape, so a round-trip through `PaneTapeRecordReader` covers the consumer side.

**Risk.** Medium-high. It moves a type across the core/support/app boundary that `scripts/core-purity-lint.sh` and the DanTermSupport-never-imports-engine rule both constrain, and the wire format must not shift by a byte.

<a id="wire-3"></a>

#### WIRE-3. Encode a delivered tape batch as one notification off the main actor, not one per record

`perf-occupancy` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeRecords.swift`, `app/AppRuntime.swift`

**Problem.** `IpcConnection.writeLine` runs `encodeIpcLine` on the calling thread, before it hands the bytes to the serial write queue. For a followed pane tape the calling thread is the main actor: `deliverPaneTapeFollowBatch` is a method on the `@MainActor` `AppRuntime` and calls `writePaneTapeRecords`, which loops over the batch calling `connection.writeNotification` once per record. So every record in every delivered batch is JSON-encoded on the main thread, each with a freshly allocated `JSONEncoder`, each wrapped in its own envelope that restates `subscriptionId.uuidString`, and each issuing its own `Darwin.write` syscall. The dump path deliberately avoids this -- its comment says every record is encoded on the utility queue -- so the follow path, the one that runs continuously while a replica mirrors a pane, is the one paying on the main thread.

**Evidence.** IpcConnection#writeLine: `guard let line = try? encodeIpcLine(value) else { ... }` sits above `writeQueue.async { [self, line] in ... }`. PaneTapeRecords.swift#writePaneTapeRecords: `for (index, record) in records.enumerated() { connection.writeNotification(method: Methods.paneTapeEvent, params: .object(["subscription": .string(subscriptionId.uuidString), "record": record]), ...) }`. AppRuntime.swift#deliverPaneTapeFollowBatch calls it directly from main-actor code, unlike AppRuntime.swift#streamFinitePaneTape which calls it inside `DispatchQueue.global(qos: .utility).async`.

**Ideal fix.** Two independent moves, both structural. First, encode inside `writeQueue.async` rather than before it -- the queue is serial, so ordering is unchanged, and the main thread hands over a value instead of bytes. Second, make the batch the wire unit it already is in the model: `PaneTapeBatch` is delivered atomically, so let one `pane.tape.event` notification carry `records: [...]`, which makes the subscription id, the envelope, and the syscall cost per delivery instead of per event.

**By construction.** A batch stops being splittable on the wire: a reader can no longer observe a partial batch, and there is no longer a place where the number of envelopes and the number of events can diverge. It also removes the possibility of a caller accidentally paying encode cost on whichever thread it happens to be on -- there is only one thread where encoding can occur.

**Cheaper fallback.** Do only the first move (encode on the write queue). It removes the main-thread occupancy but leaves the per-record envelope and syscall, so the wire still charges an envelope for every event.

**Measurement.** No frozen rule covers it. The honest instrument is `just benchmark-loop scrollback-stream` with `danterm --socket <harness socket> pane tape follow` attached, sampled with a Time Profiler trace: `encodeIpcLine` and `JSONEncoder` frames must vanish from the **main** thread's self time, and the syscall count per batch must drop from one-per-record to one. There is no calibrated workload that turns this into a verdict, and the batching change also alters the wire format, so no baseline arm can even parse the candidate's stream.

**Regression risk.** Batching increases peak line size, which pushes closer to `IpcLineFramer.maxLineBytes`; a batch of large feed events could now exceed a bound each record individually cleared. The fix must split a batch that would overflow -- the sync record path already does exactly this chunking, so the rule exists. Moving the encode onto the write queue also defers encode failures past the point where `writeLine` returns, so a caller that reads a synchronous failure must be checked.

**Verification.** The existing follow tests must still see every record in wire order across a pane close and a mid-stream failure. Add a test that a batch whose combined size exceeds the framer bound is delivered as multiple lines, and one that a record enqueued after a terminator still arrives after it -- the ordering guarantee `writePaneTapeRecords` exists to hold.

**Risk.** Medium. Ordering between the start reply, batches, and the terminator is the whole contract of this path, and the encode move changes when a write can fail.

<a id="wire-4"></a>

#### WIRE-4. Detect persisted-state divergence without re-projecting the whole model on every message

`perf-occupancy` &middot; impact 4, confidence 4 &middot; effort medium

**Files.** `app/AppRuntime.swift`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`, `lib/DanTermCore/Sources/DanTermCore/Model.swift`, `lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift`

**Problem.** `dispatchInFrame` calls `scheduleLightCheckpointIfNeeded()` for every dispatched `Msg`, and when no checkpoint window is armed that call builds a complete `AppModelSnapshot` of the whole model and deep-compares it to the baseline. `toSnapshot` walks every group, tab, split node, pane and todo, and materializes `rawValue.uuidString` -- a 36-character String allocation -- for each of them, because the snapshot types store ids as `String`. The comment on `scheduleCoalescedReconcile` records that title, cwd, progress, alert-badge and shell command-event messages "arrive at high frequency", so this is a whole-model projection per high-frequency message on the main actor, whose only purpose is to answer one boolean. The cost scales with the number of entities, not with the change.

**Evidence.** AppRuntime.swift#scheduleLightCheckpointIfNeeded: `guard lightCheckpointTimer == nil, schedulingLifecycle.isActive, currentLightCheckpointProjection() != lightCheckpointBaseline else { return }`, where AppRuntime.swift#currentLightCheckpointProjection is `LightCheckpointProjection(snapshot: toSnapshot(model))`. Persistence.swift#toSnapshot allocates per entity: `TabSnapshot(id: tab.id.rawValue.uuidString, ..., focusedPaneId: tab.paneTree.focusedPaneId.rawValue.uuidString, ...)`. Model.swift declares the storage that forces it: `struct PaneSnapshot: Codable, Equatable, Sendable { let id: String? ... }`.

**Ideal fix.** Hold typed ids in the snapshot types (`PaneId`, `TabId`, ...) and let their `Codable` conformance spell them as UUID strings only at encode time. Projection then copies values the model already holds, comparison compares 16-byte UUIDs instead of Strings, and the string form is materialized once per actual write instead of once per message. This also deletes the reverse parse on the graft path -- `graftScrollbackIntoNode` currently does `UUID(uuidString: idStr)` per pane per enriched checkpoint -- and the whole class of "snapshot id that is not a UUID".

**By construction.** An id in a snapshot that is not a well-formed UUID stops being representable, so `UUID(uuidString:)` and its nil branch disappear from the graft and validate paths, and a checkpoint can no longer round-trip an id into a pane that does not match it.

**Cheaper fallback.** Keep the String ids and gate the projection behind a persisted-revision counter the model bumps when a persisted field changes. That is a hand-maintained side signal of exactly the kind this repo treats as the fallback rather than the fix: a missed bump silently stops checkpointing, and nothing downstream can tell.

**Measurement.** `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30`, reading main-thread self time under `toSnapshot` / `uuidString`. Be honest about what this can conclude: `scrollback-stream` is ~96% PTY drain and generates few model messages, so it may well contain none of this cost, and its verdict is not the instrument here -- the profile is. There is no calibrated workload that produces high-frequency model messages, so no command on the ladder can turn this into a `faster`.

**Regression risk.** Typed ids in the snapshot must encode to the same strings, so the on-disk checkpoint format is unchanged; if any custom `Codable` is written wrong, the format silently shifts. Comparison cost per entity falls, so no workload should get heavier.

**Verification.** A round-trip test on a populated model: `toInitFile` -> encode -> `loadValidatedInitFile` reproduces the same model and pane snapshots, with the encoded JSON byte-identical to the pre-change encoding for a fixed fixture. Plus the existing checkpoint scheduling tests, which assert that an unchanged model schedules no write and a changed one schedules exactly one.

**Risk.** Medium. It touches the persisted format's Swift types, and the format is what a recovery reads on the next launch; the payoff is that the encoding stays identical while the change-detection path stops building strings.

<a id="wire-5"></a>

#### WIRE-5. Let the engine cut the checkpoint tail once, instead of re-walking the projected text to trim it

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`, `lib/DanTermCore/Sources/DanTermCore/CheckpointCapture.swift`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`

**Problem.** The bounded tail is decided twice over the same text. `primaryHistoryTailText` projects a candidate suffix and then walks it grapheme by grapheme in `tailCoversBudget` to check the budget, doubling the row window and re-walking on a miss. The String that survives is then handed to `truncateScrollback`, which walks it again four more times: `trimmingCharacters` copies the whole thing, a reversed `trimmed.indices` scan counts newlines by grapheme cluster, `String(trimmed[cutIndex!...]) + "\n"` copies again, and `result.count` is a full grapheme count over up to 400,000 characters before `suffix` copies once more. That is five or more full grapheme-segmenting passes plus three copies per live pane, per enriched checkpoint, on the checkpoint queue.

**Evidence.** Persistence.swift#truncateScrollback: `let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)` ... `for i in trimmed.indices.reversed() { if trimmed[i] == "\n" { ... } }` ... `var result = cutIndex != nil ? String(trimmed[cutIndex!...]) + "\n" : trimmed + "\n"` ... `if result.count > keeping.maxChars { let tail = result.suffix(keeping.maxChars) ... }`. The producer already walked the same text in Terminal.swift#primaryHistoryTailText via `tailCoversBudget`: `for character in text[first...last] { characters += 1; if character == "\n" { lineBreaks += 1 } }`. CheckpointCapture.swift#resolveScrollback runs the pair per pane: `guard let rawText = read(retention), let scrollback = truncateScrollback(rawText, keeping: retention)`.

**Ideal fix.** Make the bounded tail one operation with one owner. The engine walks rows and already knows where hard line breaks are, so let it produce exactly the text a checkpoint stores -- trimmed, line-capped and char-capped -- and return that. `truncateScrollback` and `tailCoversBudget` both disappear, along with the retry loop that exists only because the cut lives downstream of the projection. `ScrollbackRetention` stays the single value that expresses the budget, but it is now applied once, where the row structure is still in hand.

**By construction.** A read that stops short of what the cut keeps stops being representable -- the read is the cut. The comment on `ScrollbackRetention` says the pairing between the two halves is what must not drift; making it one operation removes the pairing rather than documenting it.

**Cheaper fallback.** Keep the split but stop measuring in graphemes: count over `text.utf8` and slice on UTF-8 offsets, which removes the segmentation cost from every pass while leaving the double decision in place. It preserves the current shape, including the retry loop and the two spellings of "what a truncation would keep".

**Measurement.** No instrument on the ladder sees this: `just terminal-memory-probe` measures grid census, not projection cost, and no calibrated workload takes a checkpoint. The diagnostic is `just benchmark-trace scrollback-stream template="Time Profiler" seconds=30` with the checkpoint queue in view -- `truncateScrollback`, `tailCoversBudget` and `_StringGuts.getCharacter` self time on the `danterm.checkpoint.io` thread must fall to near zero. Say plainly that no existing command can decide it, only describe it.

**Regression risk.** Moving the cut into the engine means the projection loop carries the budget, so a bug there could make it stop early on a pane whose history is mostly blank rows -- the exact case the current doubling retry handles. The retry exists for a reason and the replacement must handle soft wrap, trailing blank rows, and the leading trim in one pass.

**Verification.** The behavioral contract is already stated: the result is a suffix of `primaryHistoryText`, keeps at most `maxLines` lines and `maxChars` characters after trimming, and is nil for whitespace-only input. Pin those against the current implementation's output for a fixture history containing soft-wrapped rows, trailing blank rows, multi-scalar graphemes, and a history shorter than the budget -- the outputs must be byte-identical.

**Risk.** Medium. It moves policy into `TerminalCore`, which the design doc governs, and a wrong cut silently stores less scrollback than a pane is owed -- a failure no test notices unless it asserts the exact suffix.

<a id="wire-6"></a>

#### WIRE-6. Chunk and base64 the sync payload from slices, without copying the bytes three times first

`perf-memory` &middot; impact 3, confidence 5 &middot; effort small

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeStreamState.swift`

**Problem.** A reconstructible sync serializes the pane's whole state -- bounded only by `historyBudgetBytes`, which an exact consumer like `pane.snapshot` leaves nil, meaning every retained row. Those bytes then get copied three times before they are on the wire: `Array(synchronization.bytes[range])` materializes each chunk, `Data(bytes)` copies it again, `base64EncodedString()` produces a String about 1.33x the chunk, and `encodeIpcLine` escapes that String into a fourth buffer. All chunks are built eagerly into an array of `JSONValue` before any is written, so at peak roughly 5x the payload is resident, on a path whose whole reason for existing is that the payload is large. The chunk bound is 4 MB, so a multi-megabyte sync holds several of these at once.

**Evidence.** PaneTapeStreamState.swift#makePaneTapeSynchronizationRecords: `let chunks = ... stride(from: 0, to: synchronization.bytes.count, by: maximumPayloadBytes).map { start in Array(synchronization.bytes[start..<min(start + maximumPayloadBytes, synchronization.bytes.count)]) }` followed by `"base64": .string(Data(bytes).base64EncodedString())`. The payload's declared type is the source of the copies: `struct PaneTapeStateSynchronization { let bytes: [UInt8] ... }`.

**Ideal fix.** Carry the payload as `Data` from the serializer down, and base64 each chunk directly from a slice: `Data`'s slicing shares storage, and `base64EncodedData` on the slice removes both the `Array` and the `Data` copy. Produce the records lazily so only the chunk currently being encoded is resident, which fits the write path that already consumes them one at a time.

**By construction.** The chunk list stops being a second copy of the payload that can outlive the payload itself. There is one buffer of bytes, and a record names a range of it rather than owning a duplicate.

**Cheaper fallback.** Keep `[UInt8]` but drop the eager `Array(...)` by base64-ing from the `ArraySlice` through a `Data(buffer:)` view. It removes one copy and leaves the eager materialization of every chunk in place.

**Measurement.** `just benchmark-memory` is a leak detector and explicitly cannot answer "did my change shrink this" (`research/15/F6`), and `just terminal-memory-probe` measures grid census, not IPC buffers -- so no existing instrument decides this. The number that would: peak RSS across a single `danterm pane snapshot` of a pane with a full retained history, sampled by an external `footprint` poll around the request. State it as unmeasurable by any command in the guide.

**Regression risk.** None identified for speed. Lazy chunk production means the payload buffer must stay alive until the last record is encoded; if the records are handed to the write queue and the source is released, the slices must still own their storage, which `Data` guarantees but an unsafe-buffer variant would not.

**Verification.** The emitted records must be identical: same chunk count, same `part`/`parts`, same base64 per chunk, `initial` and `droppedHistoryRows` only on the first, `cursor` only on the last -- including the empty-payload case, which currently yields exactly one record with an empty base64. Pin that with a payload spanning three chunk boundaries and one of exactly `maximumPayloadBytes`.

**Risk.** Low. One private function with a fully determined output; the chunk boundary arithmetic is the only thing that can go wrong and a test names it.

### Area: iOS client data flow (`MOBILE`)

_Scope: iOS client data flow and render cost (ios/DanTermMobileKit, ios/DanTermMobileApp)_

**Auditor's read on the area.** The pure kit (policies, scroll driver, status, claim control) is genuinely tight and well factored; the costly work all sits at the two seams where a tape record meets UIKit -- TerminalSurfaceView.apply and MobileSessionController's redraw path -- and every one of them is per record, i.e. per PTY chunk the Mac sends. I deliberately did not cover the connect/reconnect policies, checkpoint store file IO, input mapping, or anything under lib/ except to establish what the iOS call sites cost (the double JSON parse in DanTermClientSession.readFrame is real but belongs to another auditor). Note up front: there is no iOS instrument in this repo at all -- the benchmark ladder builds the macOS app and scripts/run-test-suite.sh only runs `swift test` on ios/DanTermMobileKit -- so none of these findings can be decided by an existing command, and each says what would have to be built.

<a id="mobile-1"></a>

#### MOBILE-1. Resolve cell metrics where the display scale changes, not on every applied tape record

`perf-hot-path` &middot; impact 5, confidence 5 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileObserveSurface.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileContentBox.swift`

**Problem.** Every applied tape record rebuilds the CoreText font world from scratch. `TerminalSurfaceView.apply` calls `ensureSurfaces` unconditionally, and `ensureSurfaces` constructs `MobileObserveSurface` before its idempotence check; that initializer builds `TerminalRenderMetrics(displayScale:fontSize:)` and, whenever the pane's grid is wider than the phone can draw natively (the normal case), a second fitted one. The same record also reaches `surfaceDidLayout` -> `surfaceView.nativeGrid` -> `MobileContentBox.nativeGrid`, which builds a third. Each `TerminalRenderMetrics.init` creates a CTFont, builds a `TerminalFontSet` of five `TerminalFace`s (regular, bold, italic, bold-italic, packaged symbols), and each face runs `CTFontGetGlyphsForCharacters` plus `CTFontGetBoundingRectsForGlyphs` over the printable-ASCII table, after which `measuredInkEnvelope` unions four of them. So one tape record costs roughly three font sets, fifteen face constructions, and fifteen ASCII glyph-table measurements on the main actor -- for values that are a pure function of (displayScale, fontSize) and cannot change between two records.

**Evidence.** TerminalSurfaceView.apply: `guard replica.state == .exact, let terminal = replica.terminal else { return }` / `ensureSurfaces(columns: terminal.geometry.columns, rows: terminal.geometry.rows.count)`. ensureSurfaces: `guard let box = contentBox, let fitted = MobileObserveSurface(columns: columns, rows: rows, contentBox: box, fontSize: Self.fontSize) else { return }` / `if geometry?.columns == columns, geometry?.rows == rows, surface == fitted { return }` -- the construction precedes the equality guard. MobileObserveSurface.init: `let native = TerminalRenderMetrics(displayScale: displayScale, fontSize: fontSize)` then `else if let fitted = TerminalRenderMetrics(displayScale: scale, fontSize: fontSize)`. MobileContentBox.nativeGrid: `guard let metrics = TerminalRenderMetrics(displayScale: displayScale, fontSize: fontSize) else { return nil }`. TerminalRenderMetrics.init builds `TerminalFontSet(baseName:baseSize:symbolsResource:symbolsSize:)` and `Self.measuredInkEnvelope(...)`; TerminalFace.init runs `CTFontGetGlyphsForCharacters` and `CTFontGetBoundingRectsForGlyphs` over `asciiGlyphTableRange`.

**Ideal fix.** Make the resolved cell metrics a value the view holds and passes down, produced only where its inputs actually move. `MobileContentBox` already is the one reading of the drawable region; give it (or a sibling `MobileCellMetrics`) the resolved `TerminalRenderMetrics` as a stored member, constructed in `layoutSubviews`/`safeAreaInsetsDidChange` when bounds, insets, or displayScale change, and have `MobileObserveSurface.init` and `nativeGrid` take metrics as a parameter instead of deriving them. Then move `ensureSurfaces` off the per-record path entirely: the only inputs that can change the fitted surface are a layout pass and a grid change, and a grid change arrives as a typed `.resize` transition on the record stream, so the surface fit belongs on those two edges rather than after every apply.

**By construction.** With metrics carried by the content box, no code path can construct a font set from a record-shaped event: there is no initializer left that takes only a font size, so "rebuild the fonts because output arrived" stops being expressible.

**Cheaper fallback.** Hoist the idempotence check above the construction -- keep the last (columns, rows, contentBox) tuple and return before building `MobileObserveSurface` when it is unchanged. Cheaper diff, but it is a hand-maintained memo of a derivation rather than moving the derivation to its inputs, and it leaves `nativeGrid`'s font set being rebuilt per record.

**Measurement.** No existing instrument can see this -- the benchmark ladder builds the macOS app and there is no iOS benchmark recipe. What would decide it: an Instruments Time Profiler capture on a device running the mobile app while an observed pane floods (a `yes` or large `cat` in the claimed pane), reading the main-thread self-time share of `TerminalFace.init` / `CTFontGetBoundingRectsForGlyphs` / `TerminalRenderMetrics.init`; that share must go to zero, and the frames-per-second the surface publishes under the same flood must rise. A cheaper decisive proxy is a new test in ios/DanTermMobileKit that counts `TerminalRenderMetrics` constructions over N applied records: it must be O(1), not O(N).

**Regression risk.** None identified for steady state. The risk is correctness-shaped, not speed-shaped: if the stored metrics are not refreshed on a scale change (rotation onto an external display, a trait-collection change), the surface would draw at stale metrics. Rotation is the workload that would show it.

**Verification.** Existing SurfacePlacementTests/ContentBoxTests plus a new behavioral test: apply a record stream containing a `.resize` to a replica-backed surface and assert the fitted grid and drawn frame equal what the current code produces, and that a display-scale change produces new metrics. All assertions are on observable geometry, not on how many times anything was constructed.

**Risk.** Touching the one value that keeps the claimed grid and the drawn pixels in agreement; MobileContentBox's doc comment says both readings must come from one value, so the refactor must keep that property.

<a id="mobile-2"></a>

#### MOBILE-2. Feed the drained damage into the frame stores instead of re-rendering the whole grid every tick

`structural` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/MobilePresentationPolicy.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift`

**Problem.** `PaneReplica.drainPresentation()` returns `(terminal, damage)` and the display tick throws the damage away: it plans with the free function `planFrame(for:presentation:)`, which passes `damage: .full`, and rasterizes with `renderFull`. So every published frame on the phone replans every row and repaints every pixel of the grid, whatever moved -- once per display-link tick for as long as output keeps arriving. The information needed to do better is already computed by the engine and already returned by the replica; it is discarded one line later. `TerminalRenderExecution` already ships `TerminalFrameSwapchain`, which owns exactly this triple-buffer discipline, accumulates per-buffer stale damage, and calls `store.apply(plan:damage:)` with `renderFull` only as its fallback. `MobilePresentationPolicy` reimplements the buffer rotation without the damage, so the phone -- the device with the least CPU and a battery -- is the one client doing full-frame work.

**Evidence.** TerminalSurfaceView.displayTick: `guard let frame = replica.drainPresentation() else { ... }` then `let plan = planFrame(for: frame.terminal, presentation: RenderPresentation(...))` and `stores[surfaceId].renderFull(plan)` -- `frame.damage` is never read. MobilePresentationPolicy's whole damage model is `private var hasDamage = false` with `public mutating func noteDamage() { hasDamage = true }`. Compare TerminalFrameSwapchain.render: `let incremental = buffer.isCurrent && buffer.store.apply(plan: plan, damage: buffer.staleDamage)` / `if incremental == false { buffer.store.renderFull(plan) }`.

**Ideal fix.** Delete the parallel implementation: have `TerminalSurfaceView` own a `TerminalFrameSwapchain` over its three stores and publish `(plan, damage)` into it, so per-buffer stale-damage composition and the incremental/full decision live in the one place that already gets them right. Where the phone genuinely needs its own policy (it publishes on a display link rather than on a draw callback), change `MobilePresentationPolicy`'s `hasDamage: Bool` to an accumulated `TerminalDamage` and thread it through `didRender`, so the type can no longer represent "something changed" without saying what.

**By construction.** Once the policy carries `TerminalDamage` instead of a Bool, "we know something changed but not what" stops being a representable state, and a full repaint becomes an explicit `.full` value rather than the silent default.

**Cheaper fallback.** Keep the policy as is but pass the drained damage straight to `stores[surfaceId].apply(plan:damage:)`, falling back to `renderFull` on refusal. This is wrong for a rotating buffer -- a store that missed several publishes needs the union of the damage since it was last current, which is precisely what the swapchain's per-buffer `staleDamage` exists for -- so it must union damage per store rather than trusting the latest value.

**Measurement.** No existing instrument reaches iOS. `just benchmark-headless-draw` measures exactly this operation (`drawRenderFrame` on an already-clipped plan) but only for macOS TerminalCore arms, so it can bound the win in principle and cannot decide the iOS change. What would decide it: a device Time Profiler capture under an `incremental-mixed`-shaped stimulus (a TUI touching a few rows of a settled screen in the observed pane), reading main-thread self time in `drawRenderFrame` per published frame; that number must fall while the published-frame count holds. The workload shape matters -- on a full-screen content flood, damage is every row and the correct outcome is no change at all.

**Regression risk.** `TerminalFrameBackingStore.apply` does erase-span and ink-reach work that `renderFull` skips, so on frames whose damage really is the whole grid the incremental path can cost more before refusing; the swapchain already guards this with `damage.isFull` and `damagedRowCount == plan.rows`, and any hand-rolled version must too. A full-screen flood in the observed pane is the workload that would show a regression.

**Verification.** Pixel-equality: apply a recorded record stream twice, once forcing `renderFull` on every frame and once through the damage path, and assert the surfaces' bytes are identical at each publish. That is a behavioral assertion on the drawn result and is insensitive to how the buffers are rotated.

**Risk.** The store's incremental path is the subtlest code in the render layer (translation stale strips, ink-reach ledger); adopting it on iOS means the phone inherits any bug there, which today only the Mac exercises.

<a id="mobile-3"></a>

#### MOBILE-3. Decode each tape event once into a typed value instead of re-encoding and re-decoding it per record

`data-modeling` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift`

**Problem.** `PaneTapeEventRecord.event` is left as an untyped `JSONValue`, so every consumer re-parses it in its own way, once per record -- i.e. once per PTY chunk the Mac forwards. `PaneReplica.applyEvent` allocates a fresh `JSONEncoder`, serializes the already-parsed JSON tree back to `Data` (base64-re-encoding the whole feed payload), allocates a fresh `JSONDecoder`, and parses it again into `NeutralTerminalRecordingEvent` -- whose own decoder additionally builds a `Set<String>` of every key for validation. That is a third and fourth full traversal of bytes that were already parsed on the reader thread, and it runs on the main actor. Separately, `MobileSessionModel.pinnedStatement` reaches into the same `JSONValue` with string subscripts to answer "is this a resize, and what does it say about pinnedness" -- a question the typed event answers directly.

**Evidence.** PaneReplica.applyEvent: `let data = try JSONEncoder().encode(record.event)` / `guard let event = try? JSONDecoder().decode(NeutralTerminalRecordingEvent.self, from: data) else { throw PaneReplicaError.invalidEvent }`. MobileSessionModel.pinnedStatement: `guard event.event["type"]?.asString == "resize" else { return nil }` / `if case .bool(let pinned)? = event.event["pinned"] { return pinned }`. NeutralTerminalRecordingEvent.init(from:) opens with `let keys = Set(dynamicValues.allKeys.map(\.stringValue))`.

**Ideal fix.** Decode once at the edge where a record enters the phone's model and carry the typed value from there. `MobileSessionModel.receive` already calls `decodePaneTapeRecord`; have it produce a mobile-side record whose event case holds a decoded `NeutralTerminalRecordingEvent` (the kit already links `TerminalCoreRecording`), and let both `pinnedStatement` and `PaneReplica.applyEvent` switch on that value. The `.applyRecord` effect then carries a typed record, and no JSON tree survives past the decode point. Backwards compatibility is not a constraint here, so the record type itself can change shape.

**By construction.** A record whose event is typed cannot be parsed a second time -- there is no JSON left to parse -- so "two consumers disagree about what this event said" and "the same bytes were walked three times" both stop being representable.

**Cheaper fallback.** If the typed record cannot cross the effect boundary yet, at minimum hold one `JSONEncoder`/`JSONDecoder` pair for the replica's lifetime instead of constructing both per record. That removes two allocations per record and none of the two redundant traversals, so it is strictly the lesser fix and should be recorded as such.

**Measurement.** No existing instrument sees this path. What would decide it: a benchmark-shaped test in ios/DanTermMobileKit that applies N recorded `.event` records (feed payloads of a realistic chunk size) into a `PaneReplica` and reports elapsed time per record, with the record count emitted beside the aggregate so a zero cannot be confused with an unmeasured run. Wall time there is diagnostic only and must not become a pass/fail threshold; the deciding number is the same stimulus profiled on device, where `JSONEncoder`/`JSONDecoder` frames must vanish from the main thread.

**Regression risk.** None identified: the change removes work and adds no store. The one thing to watch is that the current round trip also acts as a validator -- `PaneReplicaError.invalidEvent` is thrown when the re-decode fails -- so the typed decode must keep raising the same refusal rather than silently accepting a malformed event.

**Verification.** PaneReplicaTests already pin the exactness and gap-detection semantics per event kind, including refusal of a malformed event; those tests must pass unchanged, since they assert replica state and cursor advance rather than how the event was decoded.

**Risk.** The typed record has to cross the DanTermMobileKit effect boundary, which today deliberately keeps DanTermClient's record type engine-free; the mobile-side record must be a new type rather than a change to the shared reader, or the client library gains an engine dependency it does not want.

<a id="mobile-4"></a>

#### MOBILE-4. Signal replica state and surface geometry only when they change, not once per applied record

`perf-occupancy` &middot; impact 4, confidence 4 &middot; effort small

**Files.** `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/ConnectionStatusPillView.swift`

**Problem.** `TerminalSurfaceView.apply` fires `didChangeReplicaState?(replica.state)` after every record, whether or not the state moved -- it is named as a change notification but behaves as a value notification. The controller's handler then does two things per record: it dispatches `.replicaStateChanged`, which in the model returns `[.redraw]` for the steady `.exact` case, and it calls `surfaceDidLayout()`. So each record composes a fresh `MobileSessionProjection` (including `MobileStatus.line`'s `parts.joined(separator: " - ")` string build), writes `statusLabel.text` and `titleLabel.text` -- UIKit does not compare, so an identical string still invalidates intrinsic content size and schedules layout -- scans the pane list for the selected pane's title, and drives `scrollChrome.refresh()`, which writes `frame`, `contentSize`, and `contentOffset` on a UIScrollView and re-enters `scrollViewDidScroll`. All of that is per PTY chunk, on the main actor, for a screen whose pixels are published on the display link and not by any of it.

**Evidence.** TerminalSurfaceView.apply: `try replica.apply(record)` / `didChangeReplicaState?(replica.state)` -- unguarded. MobileSessionController.start: `surfaceView.didChangeReplicaState = { [weak self] state in guard let self else { return }; dispatch(.replicaStateChanged(state)); surfaceDidLayout() }`. MobileSessionModel: `case .replicaStateChanged(let state): status.noteStream(state)` ... `case .exact: resumePolicy.replicaBecameExact(); return [.redraw]`. ConnectionStatusPillView.show: `statusLabel.text = status` (unguarded, while the neighbouring `titleLabel.isHidden` write is explicitly guarded with the comment "Written only on a change").

**Ideal fix.** Make the callback mean what it is named: hold the previously reported state in the surface view and call `didChangeReplicaState` only on a transition. Then split the two reasons `surfaceDidLayout` runs -- a layout pass changes the offered grid, an applied record does not -- so a record no longer reports surface facts at all; `MobileSessionModel.handle(.surfaceChanged)` already guards `facts != surface`, so the geometry half self-corrects once the surface stops volunteering unchanged facts. The scroll chrome's reconciliation is the one part that legitimately follows the engine's viewport, so drive `scrollChrome.refresh()` from the display tick that publishes a frame rather than from record application, which is also the moment the drawn window actually moved.

**By construction.** A callback that only fires on a transition makes "the UI was rebuilt because output arrived" unrepresentable; the redraw path can then only be entered by an actual session change.

**Cheaper fallback.** Guard the label writes in `ConnectionStatusPillView.show` and make `MobileSessionModel` return no `.redraw` when the projection is unchanged. That suppresses the UIKit half while leaving the per-record projection composition and scroll-chrome writes in place, and it puts the change detection in the wrong layer.

**Measurement.** No existing instrument sees this. What would decide it: a device Time Profiler capture during a sustained flood in the observed pane, reading main-thread time in `MobileStatus.line`, `UILabel.setText`, and `UIScrollView` layout, each of which must fall to the rate of real state changes rather than the rate of records. A cheaper structural check that is decisive on its own: count `.redraw` effects produced by a fixed record stream in a MobileSessionModelTests scenario -- it must be a small constant, not one per record.

**Regression risk.** A missed transition would leave the status line or the scroll indicator stale, which is a correctness regression rather than a speed one; the workload that shows it is a gap or stream end arriving between two ordinary records. Nothing here can make the steady state slower.

**Verification.** MobileSessionModelTests covering the state-change sequence (awaitingSynchronization -> exact -> gap -> exact) must still produce a redraw on each real transition, and MobileScrollTests must still reconcile the chrome after a remote viewport record. Both assert observable outputs of the pure model, so they survive the callback change.

**Risk.** The scroll chrome's reconciliation currently rides the record path, so moving it to the display tick changes when the indicator catches up with a remote viewport record; MobileScrollDriver's idle-reconciliation rules must be re-read before the move.

<a id="mobile-5"></a>

#### MOBILE-5. Own the replica off the main actor and hand the main actor frames instead of records

`structural` &middot; impact 4, confidence 3 &middot; effort large

**Files.** `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileConnectionRunner.swift`, `/Users/dan/Code/danterm/ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift`

**Problem.** Every frame the reader thread pulls off the socket is hopped to the main queue individually (`deliveryQueue` targets `.main`), and everything downstream of it runs on the main actor: `decodePaneTapeRecord`'s JSON walk, the model's event drain, the replica's decode, `Terminal.feed` (parsing and grid mutation for the entire remote stream), damage accumulation, and the geometry and redraw work the other findings describe. The phone therefore parses the Mac's whole output on the thread that also runs touch handling, scrolling physics, keyboard animation, and the display link. Nothing forces this: `PaneReplica` is a `Sendable` value over a pure engine, and the only main-actor consumer is the display tick, which needs a plan and a damage set -- not a record.

**Evidence.** MobileConnectionRunner.init: `self.deliveryQueue = DispatchQueue(label: "com.danneu.danterm.mobile-connection-delivery", target: deliveryQueue)` with `deliveryQueue: DispatchQueue = .main` and the comment "The main queue is the default so UIKit can consume events without a second asynchronous hop"; `enqueue` performs one `deliveryQueue.async` per frame. MobileSessionController: `@MainActor final class MobileSessionController`, `case .applyRecord(let record): try surfaceView.apply(record)`. TerminalSurfaceView is `@MainActor` and owns `private var replica = PaneReplica()`.

**Ideal fix.** Give the replica its own actor (or keep it on the reader thread behind the existing serialized delivery queue) and let it consume records where they arrive. The main actor then receives only what it must: replica-state transitions, and at display-link cadence a published `(RenderFramePlan, TerminalDamage)` pair -- which is also the shape finding 2 wants. Local scroll and input stay ordered by going through the same actor, and `checkpointSource()` stops copying a live main-actor value.

**By construction.** With the replica behind its own actor, a record cannot reach the main actor at all, so "the phone parses the remote stream on the UI thread" stops being expressible; the main-actor surface can only be handed a plan.

**Cheaper fallback.** Keep the replica on the main actor but batch: drain all records available in one main-queue hop instead of one hop per record, so the queue drain amortizes and the intervening UIKit work happens once per batch rather than once per record. That reduces hop and redraw overhead without moving `Terminal.feed` off the main thread, which is the dominant term under a flood.

**Measurement.** No existing instrument sees this, and the ladder's own warning applies in spirit: moving work off the critical path onto another core reads as neutral to any CPU-total metric, so process CPU is the wrong number here. What would decide it: a device Time Profiler capture under a sustained flood, reading main-thread on-CPU share (which must fall) together with a scroll-gesture responsiveness measure taken during the same flood -- hitch or frame-drop count while dragging the scroll chrome. If neither can be captured, this finding is honestly unmeasurable today and should be treated as an occupancy argument, not a benchmarked win.

**Regression risk.** Ordering is the risk: local viewport scrolls, claim renewals, and checkpoint snapshots currently interleave with record application in one serialized main-actor drain, and an actor hop can reorder them, which would show up as a viewport that jumps or a claim renewed against a stale grid. Throughput could also fall slightly if the hand-off per published frame is more expensive than the per-record hop it replaces, which a low-output interactive session would show.

**Verification.** The kit's existing pure tests (MobileSessionModelTests, PaneReplicaTests, MobileScrollTests) still pin the ordering semantics because the model stays pure and synchronous; add a behavioral test that a local scroll issued between two records lands at the same viewport row as it does today, which is the invariant the hop threatens.

**Risk.** Largest change of the five, and the one whose failure mode is a subtle ordering bug rather than a visible break; worth doing only after findings 1, 2, and 4 remove the per-record work that makes the main actor hot in the first place.

### Area: Unicode tables and lookups (`UNI`)

_Scope: Generated Unicode property tables and the lookups over them (UnicodeProperties.generated.swift, CanonicalCaseless.generated.swift/.swift, GraphemeBreak.swift, TerminalScalars.swift, scripts/generate-terminal-unicode-tables.py)_

**Auditor's read on the area.** The packed two-stage trie is already the right shape -- `GeneratedPackedUnicodeTables.record(for:)` is two dependent loads for any scalar, with no linear or binary search anywhere on the width/grapheme path, and no table is built at startup from a search structure. What ASCII costs there is worth stating plainly: nothing, on the dominant path. `TerminalInputStream.nextAction` emits `.printASCIIRun` and `Terminal.printBulkASCII` stamps the whole run through `writeNarrowCells` without consulting the table at all, so a printable-ASCII byte pays zero table lookups; only ASCII that `printBulkASCII` declines (pending wrap, insert mode, an open prepend cluster, a wide/spacer cell in the way, a content-identity wrap) falls into `Terminal.print` and pays the same two loads a supplementary-plane scalar pays. Adding a Latin-1 direct-index fast path in front of `record(for:)` would therefore be a cache-shaped answer to a problem the run granularity already solved, and I am not proposing one. The findings below are where the *representation* is still doing avoidable work: a record vocabulary of 29 values stored in 16 bits, a bulk-print predicate expressed as a byte range instead of the table property it actually is, UAX #29 pair rules expressed as array-literal set membership, and canonical-caseless tables whose "this scalar is unaffected" answer costs a binary search and a heap allocation. I did not look at UTF8Decoder, EscapeAbsorber, sprite classification, or the render-side consumers of `TerminalScalars` -- other auditors own those.

<a id="uni-1"></a>

#### UNI-1. Store the packed scalar record as a palette index over 29 decoded entries, not a 16-bit bitfield

`data-modeling` &middot; impact 4, confidence 5 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift`, `scripts/generate-terminal-unicode-tables.py`

**Problem.** `GeneratedPackedUnicodeTables.stageTwo` holds 31,488 `UInt16` entries (62,976 bytes) and `stageOne` holds 4,352 `UInt16` entries (8,704 bytes), 71,680 bytes total. I reconstructed the full 0x110000-entry record array from the committed tables: the whole table contains exactly **29 distinct record values**, and the largest stage-one block index is **122**. So stage one is a `UInt16` array whose values all fit a byte, and stage two is a `UInt16` array drawing on a 29-value vocabulary. On top of the size, every call to `terminalUnicodeClassification` -- once per non-ASCII printed scalar, and once per ASCII character `printBulkASCII` declines -- re-derives the four fields from bits (`record & 0b11`, three shifted mask tests, `record >> 5`) and runs two failable `rawValue` initializers guarded by `preconditionFailure`, because the bitfield can represent a width of 3 and a grapheme class of 31 that no generated entry ever holds.

**Evidence.** `scripts/generate-terminal-unicode-tables.py#packed_two_stage_tables`: `block_size = 1 << 8` (hardcoded, never searched) and `if len(block_indexes) > 0x10000: raise RuntimeError("packed Unicode table exceeds UInt16 stage-one indexes")` -- the generator guards a 65,536-block ceiling while actually emitting 123 blocks. `UnicodeProperties.generated.swift#GeneratedPackedUnicodeTables`: `static let stageOne: [UInt16]`, `static let stageTwo: [UInt16]`, and `static func record(for value: UInt32) -> UInt16 { let block = Int(stageOne[Int(value >> 8)]); return stageTwo[(block << 8) | Int(value & 0xFF)] }`. `UnicodeProperties.generated.swift#terminalUnicodeClassification`: `guard let width = TerminalCellWidth(rawValue: UInt8(record & 0b11)) else { preconditionFailure("Generated cell width is invalid") }` and `guard let result = GraphemeBreakClass(rawValue: UInt8(record >> 5)) else { preconditionFailure("Generated grapheme class is invalid") }`. Reconstructed counts: 29 distinct stage-two values, max value 545, max stage-one value 122.

**Ideal fix.** Have the generator emit the record vocabulary as what it is: a `static let palette: [TerminalUnicodeClassification]` of 29 fully-formed entries, `stageTwo` as `[UInt8]` palette indices, and `stageOne` as `[UInt8]` block indices. `record(for:)` becomes `palette[Int(stageTwo[(block << 8) | Int(value & 0xFF)])]` -- a load of an already-decoded value. Also let the generator search the block shift instead of fixing it at 8; I computed the packed sizes across shifts 5-11 on the committed data, and shift 7 with a palette is the minimum at 32,186 bytes (8,704 + 23,424 + 58) against 35,898 at shift 8 and 71,680 today.

**By construction.** A cell width of 3 and a grapheme-break class of 31 stop being representable, so the two `preconditionFailure` arms in the hottest lookup in the engine cease to exist rather than being merely unreached, and the four bit-mask extractions per scalar disappear with them. The bit layout also stops being a contract restated in two places (the generator's `records = [1 | (grapheme_classes[value] << 5) ...]` and the Swift decoder's masks) and becomes a single generated palette literal.

**Cheaper fallback.** If the extra palette indirection is unwanted, take the free half: `stageOne` as `[UInt8]` (max value 122) and keep stage two `UInt16`. That alone is 67,328 bytes and needs no change to the decode.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed` -- `feedDurationNanoseconds` is the number that must move, and per the A/A table a difference under 0.9 points is not a difference. Be honest about what that instrument can see: the `unicode-wrapping` corpus is one of four streams in the workload and its own non-ASCII share is roughly 13 scalars per ~145-character line, so the per-scalar decode saving is diluted and `equivalent` is a plausible honest outcome. The size half is directly measurable and not on the ladder at all: `size -m` on the built `TerminalCore` object, or `nm -S` on the two table symbols, must show ~71,680 bytes of `__const`/`__data` fall to ~32-36 KB. `just terminal-memory-probe` cannot see it -- it reports `Terminal.memoryCensus`, which measures grid state, not static module data.

**Regression risk.** The palette adds a third dependent load to a chain that is currently two. The palette is 29 entries, so it occupies a couple of cache lines and stays resident under any sustained feed, but a workload that touches the table sparsely between long gaps could pay a miss the bitfield form does not. That risk is the reason `terminal-feed` must be run rather than reasoned about, and it is the argument for the fallback if the run comes back `slower`. No mirror, cache, or hand-maintained side table is introduced -- the palette is generated output, regenerated by the same script from the same pinned data files.

**Verification.** `UnicodeWidthTests` and `GraphemeBreakTests` already check the table against the committed `reference_grapheme_properties` and `GraphemeBreakTest.txt` ranges for every scalar, and `TerminalASCIIRunTests` checks that every scalar in 0x20...0x7E is narrow and `.other`. Those are exhaustive over the codespace and structure-insensitive: they assert what the lookup returns, not how it is packed, so a correct repacking keeps them green and an incorrect one fails on a named scalar.

**Risk.** Regenerating the file requires the pinned Unicode data files; the header records their sha256 so a regeneration from different inputs is detectable. Low.

<a id="uni-2"></a>

#### UNI-2. Derive the bulk-print run predicate from the scalar record instead of from a printable-ASCII byte range

`perf-hot-path` &middot; impact 4, confidence 4 &middot; effort large

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`, `lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift`

**Problem.** The run granularity that makes plain text cheap is keyed on a byte property -- `byte >= 0x20 && byte <= 0x7E` -- rather than on the grid property it stands for. So a scalar the generated table classifies as identical to ASCII 'A' still arrives as a separate `.print(scalar)` action and pays, per cell: one table lookup and decode, the whole `appendToOpenClusterIfJoined` attempt (two `indices.contains` bounds checks, two cell-kind reads, a `graphemeBreak` call, a `scalars.first` read), `invalidateInspection`, `currentStyleId()`, a one-cell `writeNarrowCells`, and `rememberOpenCluster()` reading the cell back and copying its `TerminalScalars`. I checked the committed table directly: U+2500 (box drawing), U+2588 (block element), U+2801 (braille), U+0410 (Cyrillic), U+03B1 (Greek) and U+00E9 all carry record value `1` -- byte-identical to the record for `A` -- and 921,871 scalars in the codespace carry that exact record. Those are precisely the character sets a real TUI paints, so on a full-screen btop or ncurses frame essentially every cell takes the per-character path that ASCII was explicitly lifted out of.

**Evidence.** `TerminalInputStream.swift#isPrintableASCII`: `byte >= 0x20 && byte <= 0x7E`, and `TerminalInputStream.swift#nextAction`: `if absorber.isGround, decoder.isIdle, Self.isPrintableASCII(byte) { let start = index; repeat { index += 1 } while index < bytes.count && Self.isPrintableASCII(bytes[index]); return .printASCIIRun(start..<index) }` -- every other scalar falls through to `default: return .print(scalar)`. `Terminal.swift#printBulkASCII` states the precondition it is really relying on: "every scalar in 0x20...0x7E is narrow and grapheme-break-`.other` in the generated table, so no character of a run can be wide or be joined by the next one; and Prepend is the only class an `.other` scalar does not break from". That is a statement about records, not about bytes.

**Ideal fix.** Let the generated record carry the predicate. With the palette from finding 1, a `isBulkPrintable` field on the 29 palette entries costs zero extra table bytes and is derived by the generator from the same width and class data (`width == .narrow && class == .other && !isExtendedPictographic && !isEmojiModifier && !isEmojiVariationBase`). Then `nextAction` extends the run across decoded scalars carrying that flag rather than across bytes in 0x20...0x7E, and `printBulkASCII` keeps its existing cut rules unchanged. `writeNarrowCells` already takes a `scalar: (Int) -> Unicode.Scalar` supplier, so the write side needs no new shape -- only a supplier that walks decoded scalars in order rather than indexing bytes.

**By construction.** The duplicated statement of "which characters can be stamped in bulk" collapses. Today it exists three times -- as a byte range in `isPrintableASCII`, as a prose invariant in `printBulkASCII`'s doc comment, and as an assertion in `TerminalASCIIRunTests` that re-reads the table to confirm the range still holds. After the lift the table is the only statement, and a future Unicode revision that moved a character out of the bulk-safe set would change the run, not silently invalidate a comment.

**Cheaper fallback.** Keep the byte-range parser run as-is and add a second, narrower run only for the two-byte and three-byte UTF-8 ranges that are wholly bulk-printable (Latin-1 supplement through Greek/Cyrillic, and U+2500-U+259F). That recovers box drawing and blocks without touching the decoder's structure, but it re-introduces exactly the hardcoded range list this finding is about, so it is a worse representation and should be named as such if chosen.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed`, watching `feedDurationNanoseconds`. State the limitation up front rather than after the run: the `unicode-wrapping` corpus is Spanish written without accents, CJK (wide -- excluded by the predicate), combining marks and emoji (excluded), so it contains almost no narrow non-ASCII *runs* and terminal-feed will most likely read `equivalent`. The workload that contains this cost is `synchronized-frames` (95 captured btop frames, ~95% drain, box drawing and braille throughout) -- and per `research/23/D4` it carries no frozen rule and issues no verdict. So this win is largely **unmeasurable by the calibrated ladder**; the honest instruments are a descriptive `synchronized-frames` collection and `just benchmark-trace synchronized-frames template="Time Profiler"` showing the share of `Terminal.print`/`appendToOpenClusterIfJoined` fall. If the change is wanted as a decision, a new terminal-feed corpus of box-drawing frames is the prerequisite, not an optional extra.

**Regression risk.** The parser gets a per-scalar table load inside its run loop where it currently has a byte comparison, so a stream of scalars that are *not* bulk-printable pays a lookup the byte test did not. Since those scalars go on to `Terminal.print`, which does the same lookup, the fix is to carry the already-decoded classification into the action rather than look it up twice -- if that carry is not done, mixed emoji/CJK text gets slower and `terminal-feed` on `unicode-wrapping` is exactly the arm that would show it. No cache or mirror.

**Verification.** `TerminalASCIIRunTests` already pins the contract that a run must be indistinguishable from one `.print` per character, and `TerminalInputStream`'s token tests state the stream that way. Extending the run must keep those green, plus new cases feeding a box-drawing row, a Cyrillic row, and a row that mixes bulk-printable scalars with a combining mark and with a wide scalar, asserting the resulting grid equals the grid produced by feeding the same bytes one at a time. Chunk-invariance (feed the same bytes split at every offset, expect the same grid) is the structure-insensitive form of that test and it is what catches a run that crosses a boundary it should have cut.

**Risk.** Highest-effort item here and it touches the decoder/reducer seam, which is where chunk-invariance lives. Medium-high; the chunk-split test above is the thing that makes it safe.

<a id="uni-3"></a>

#### UNI-3. Generate the UAX #29 pair verdicts as a class table instead of array-literal set membership

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/GraphemeBreak.swift`, `scripts/generate-terminal-unicode-tables.py`

**Problem.** `GraphemeBreakState.shouldBreak` runs once per non-ASCII printed scalar (from `Terminal.appendToOpenClusterIfJoined`) and once per ASCII character `printBulkASCII` declines. It decides the Hangul rules by building four `Array` literals and calling `contains` on each -- an O(n) scan over a freshly constructed array, at a point in the cascade every scalar passes through, for rules that fire only on Hangul. `GraphemeBreakClass` has 19 cases, so each of those sets is a 19-bit value; representing them as arrays turns a single mask-and-test into an allocation-shaped construct that depends on the optimizer's willingness to stack-promote and unroll it. The whole cascade is ~15 sequential branches plus a `normalize` switch, evaluated per scalar, to answer a question whose inputs are two 19-valued enums.

**Evidence.** `GraphemeBreak.swift#shouldBreak`: `if previous == .l && [.l, .v, .lv, .lvt].contains(current) { return false }`, `if [.lv, .v].contains(previous) && [.v, .t].contains(current) { return false }`, `if [.lvt, .t].contains(previous) && current == .t { return false }`. These sit above the far more common GB9/GB9a/GB11 paths, so ordinary combining-mark and emoji text pays all three before reaching the rule that decides it.

**Ideal fix.** Have the generator emit a 19x19 pair table of three-state verdicts -- `break`, `noBreak`, `consultState` -- keyed by (previous, current), 361 bytes. `shouldBreak` becomes one load and a switch, with the stateful machinery (GB9c indic, GB11 pictographic, GB12/13 regional indicator) reached only for the pairs the table marks `consultState`. All of GB3-GB9b, which is where ordinary text lands, is answered by that single load. As a strictly smaller version of the same idea, the class sets become `UInt32` bitmask constants tested with `mask & (1 << rawValue)`, which is by construction allocation-free.

**By construction.** A set of grapheme classes stops being an `Array` that must be built, scanned, and hopefully optimized away, and becomes a value whose membership test cannot allocate. With the full pair table, the rule text also stops being a hand-transcribed cascade whose order is load-bearing -- the ordering constraint that makes `if previous.isControl || current.isControl` have to sit above the Hangul rules disappears into a generated table.

**Cheaper fallback.** Replace only the four array literals with `UInt32` bitmask constants and leave the cascade's shape alone. That removes the array construction with a two-line change and no new generated artifact, but it leaves the branch chain and the duplicated rule statement in place.

**Measurement.** `just benchmark-quick baseline=HEAD workload=terminal-feed` -- `feedDurationNanoseconds`, distrust anything under 0.9 points. Unlike finding 2, the workload genuinely contains this cost: `unicode-wrapping` puts a combining mark (`café` as e + U+0301) and a four-scalar emoji ZWJ sequence on every one of its 9,000 lines, and every one of those scalars traverses `shouldBreak`. If the win is real this is the cell that should show it. `just benchmark-feed-sample` is the diagnostic to run first, since it isolates `Terminal.feed` headlessly and will say whether `shouldBreak` appears at all before a paired run is spent on it.

**Regression risk.** A 361-byte pair table is one to six cache lines and is touched on the same path as the scalar trie, so it competes with it for L1 -- negligible against the 70 KB the trie itself occupies today, and smaller still after finding 1. The real risk is behavioral, not performance: the cascade's rule ordering encodes GB precedence, and a table generated from a wrong precedence reading is wrong on pairs no ordinary text produces. That is what makes the exhaustive test below non-negotiable rather than nice to have.

**Verification.** `GraphemeBreakTests` already replays the committed `GraphemeBreakTest.txt` corpus (its sha256 is pinned in the generated header), which is the exhaustive conformance suite for exactly these rules and is entirely structure-insensitive -- it feeds scalar sequences and asserts boundary positions. A pair table that gets any precedence wrong fails it on a named case. No new test shape is needed; the existing corpus is the proof.

**Risk.** Medium. The rules are subtle and stateful, but the conformance corpus is exhaustive and already wired up.

<a id="uni-4"></a>

#### UNI-4. Let the canonical-caseless tables answer "this scalar is unaffected" without a binary search or an allocation

`perf-hot-path` &middot; impact 3, confidence 4 &middot; effort medium

**Files.** `lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.swift`, `lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.generated.swift`, `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift`

**Problem.** Every non-ASCII grapheme the search scan touches goes through `canonicalCaselessKey`, which runs `canonicalDecomposition` twice with a `flatMap(fullCaseFold)` between them. For a scalar that has neither a canonical decomposition nor a case fold -- the overwhelming majority, and every CJK ideograph, box-drawing character and braille pattern -- that costs three `exactIndex` binary searches (~11 dependent, cache-scattered probes each over the 8,324-byte `decompositionScalars` and the 6,340-byte `foldScalars`) purely to return "absent", plus a fresh single-element heap array from `fullCaseFold` per scalar, plus the `result` array, the `.map` array, and the second pass's copies. `canonicallyOrder` adds a fourth binary search per scalar through `canonicalCombiningClass` over 403 ranges whenever a decomposition produced more than one scalar. This is the only place in my area where a search still stands where a table would answer, and it is per-cell over the scanned region, per search keystroke.

**Evidence.** `CanonicalCaseless.swift#exactIndex`: `while lower < upper { let middle = lower + (upper - lower) / 2; if sortedValues[middle] < value { lower = middle + 1 } else { upper = middle } }` over `GeneratedCanonicalCaselessTables.decompositionScalars` (2,081 `UInt32`) and `foldScalars` (1,585 `UInt32`). `CanonicalCaseless.swift#fullCaseFold`: `guard let index = exactIndex(...) else { return [scalar] }` -- the unmapped case, which is the common one, allocates an array to hold one scalar. `CanonicalCaseless.swift#canonicalCombiningClass` is a third hand-written binary search over three parallel arrays (`combiningClassLowerBounds`, `combiningClassUpperBounds`, `combiningClassValues`, 403 entries each). `TerminalSearch.swift#searchGraphemeKey` reaches all of it: `let key = canonicalCaselessKey(for: scalars)`, guarded only by an ASCII fast path (`scalar.value < 0x80`).

**Ideal fix.** Two changes, both representational. First, give the scalar record two more states -- `hasCanonicalDecomposition`, `hasCaseFold` -- either as fields on the palette from finding 1 or as a small parallel two-stage trie generated by the same script; then "unaffected" is answered by the same constant-time trie the width path already uses, and the binary searches run only for the scalars that actually have mappings. Second, make `fullCaseFold` return `TerminalScalars` instead of `[Unicode.Scalar]`: fold outputs are one to three scalars, `TerminalScalars` already exists in this module precisely to keep the one-scalar case off the heap, and the identity case then allocates nothing at all.

**By construction.** "This scalar is unchanged by NFD and by full case folding" stops being a conclusion reached by failing three searches and becomes a property read from the table -- and returning `TerminalScalars` makes the identity fold structurally incapable of touching the heap, rather than merely usually cheap.

**Cheaper fallback.** Emit the minimum mapped scalar for each table (`0xC0` for decomposition, `0x41` for folding) and early-return below it. That is a single comparison and it covers all of ASCII and most of Latin-1, but it is a threshold that must be kept in step with regenerated data by hand, which is a weaker guarantee than a generated bit.

**Measurement.** No instrument on the ladder can see this, and I want to say that plainly rather than name a workload that would report `equivalent` by construction: none of the six calibrated workloads runs a search, and `terminal-feed` never calls `canonicalCaselessKey` at all. `Instrument.searchDistanceWork` and `Instrument.searchIndexMaintenance` count content units inspected, not work per unit, so they will not move either. Deciding this needs an instrument that does not exist -- a headless search microbenchmark over a CJK-heavy retained scrollback, paired the way `benchmark-headless-draw` is paired. Until that exists, the claimable part is the allocation count, which is countable by reading the code: one array per scalar from `fullCaseFold` plus four per grapheme from the two decomposition passes, all of which the ideal fix removes for unmapped scalars.

**Regression risk.** Two extra bits on the record widen nothing if they ride the palette (finding 1), and widen the record's bit budget from 10 to 12 -- still inside a `UInt16` -- if they do not. A separate parallel trie would add a second table to keep in cache on the search path only, which is not the feed path, so it cannot regress `terminal-feed`. Changing `fullCaseFold`'s return type touches only two call sites, both in this file. None identified beyond that; I looked for a feed-path caller of these functions and there is none.

**Verification.** `CanonicalCaselessTests` already checks `canonicalDecomposition` and `fullCaseFold` against the committed reference derived from `UnicodeData.txt` and `CaseFolding.txt`, and `TerminalSearchTests` checks match results through `canonicalCaselessKey` end to end. Both assert returned values, not internal shape, so a correct short-circuit keeps them green. The specific case worth adding is a scalar that folds to itself but *does* decompose, and one that decomposes to itself but *does* fold, so a single conflated "unaffected" bit cannot pass.

**Risk.** Low. The change is confined to two files plus a generator field, and the conformance tests are already exhaustive over the mapped scalars.

