# Tree-owns-panes model + full view reconciler

## Stage map

| Implemented? | Stage          | Part   | Section                                                                                      |
| ------------ | -------------- | ------ | -------------------------------------------------------------------------------------------- |
| Yes          | 1              | Part 1 | 1a -- Tree-owns-panes (live model, wire format unchanged)                                    |
| Yes          | 2              | Part 1 | 1a -- One leaf-embedded snapshot format (v2)                                                 |
|              | _(checkpoint)_ | --     | Part 1 -> Part 2 go/no-go                                                                    |
| Yes          | 3              | Part 2 | `reconcileFocusBorders`                                                                      |
|              | 4              | Part 2 | `reconcilePaneChrome` (toolbars + search overlay)                                            |
|              | 5              | Part 2 | `reconcileSidebar` + Part 1b (`ViewLocalState`/`RenameTarget`)                               |
|              | 6              | Part 2 | `reconcileWindowChrome`                                                                      |
|              | 7              | Part 2 | `reconcileSwitcher`                                                                          |
|              | 8              | Part 2 | `reconcileSurfaceExistence` + `reconcileContainers` + Part 1c (keyed surface reconciliation) |
|              | 9              | Part 2 | Rename `Effect` -> `Command`                                                                 |

This plan does two things, in order. First it restructures the model so a pane
exists iff a tree leaf owns it (Part 1) -- pane content moves into the leaf and
the parallel `panes` dict is deleted, so the dual-write drift bugs become
structurally impossible. Then it migrates the view to a reconciler (Part 2):
`update()` returns only commands, and a `reconcile()` pass derives the
AppKit/surface tree from the model after every `send()`, replacing ~91
hand-emitted view-sync effects. The model restructure goes first as the
foundation, so the worst bug classes die at the model layer before the view
migration starts. Stages land sequentially (see Delivery sequence).

## Context

Two long-standing sources of fragility, attacked in order:

1. **Dual-stored panes.** Pane data lives twice: in the flat
   `AppModel.panes: [PaneId: PaneModel]` dict (`app/Model.swift:179`) _and_ in
   each tab's split tree, whose leaves reference panes by id
   (`SplitNodeModel.leaf(PaneId)`, `app/Model.swift:89`). Every
   tree-mutating handler must hand-mirror the dict, and restore spends ~50 lines
   policing the `Set(model.panes.keys) == Set(allLeaves)` invariant
   (`validateAndBuildDetailed`, `app/Model.swift:388-454`). This dual-write
   discipline is what produced the `surfaceCreationFailed` sibling-leak and the
   `movePaneToTab` "content lives in a global dict referenced from a new tree
   position" footgun.

2. **Hand-emitted view sync.** ~91 projection effects scattered across
   `update()` plus a second imperative path inside `send()`
   (`app/AppRuntime.swift:224-228`, `:242-284`). Each emit site is a discipline
   obligation; the same class of "forgot to emit X" bug recurs.

The fix is two governing principles:

- **Single source of truth at the leaf.** A pane exists iff a tree leaf owns it.
  Pane _content_ moves into the leaf; the `panes` dict is deleted; the
  drift invariant becomes structurally impossible.
- **View is a projection of the model.** `update()` returns only commands
  (true side effects); a `reconcile()` pass derives the AppKit/surface tree from
  the model after every `send()`.

This stays pure AppKit + the existing Elm core (no SwiftUI). The model stays a
value type and fully unit-testable.

---

# Part 1 -- Model restructure (the foundation)

## 1a. Tree-owns-panes

### Leaf owns the pane

- `SplitNodeModel.leaf(PaneId)` -> `SplitNodeModel.leaf(PaneModel)`
  (`app/Model.swift:89`). `PaneModel.id` is already a `let`
  (`Model.swift:76`), so identity travels with the payload. The enum stays
  `Equatable` automatically (`PaneModel` is `Equatable`).
- Delete `AppModel.panes` (`Model.swift:179`). The memberwise init loses its
  `panes:` label -- **two** production callers update: the restore builder
  (`Model.swift:485`) and `AppRuntime.init` (`AppRuntime.swift:63-66`), whose
  empty-launch model becomes `AppModel(groups: [GroupModel(id: GroupId(), name:
"General")])` (no `panes:` -- no tabs/leaves exist yet). Test helpers update in
  lockstep (see Tests).
- `focusedPaneId` **stays a bare `PaneId` on `TabModel`** (`Model.swift:112`).
  It is a per-tab pointer, not pane content -- the one place a `PaneId`
  reference legitimately remains.

### Access API + call-site rewrite

Add to `AppModel`:

```swift
func pane(_ id: PaneId) -> PaneModel?                       // walk groups -> tabs -> leaves
var allPanes: [PaneModel]                                   // flatMap leaves
var allPaneIds: [PaneId]                                    // replaces panes.keys / .count
mutating func updatePane(_ id: PaneId, _ body: (inout PaneModel) -> Void)  // walk to leaf, mutate, rebuild spine
```

`pane(_:)`/`updatePane` are O(tree size); lookups are per-`Msg`, never on a
render frame (Metal drives rendering through the ghostty surface, off the Elm
loop), and the model already does whole-tree walks on every
relevant `Msg` (`tabForPane`, `effectiveSurfaceVisibility`, `reconcileMru`).
**No _stored_ index** (`[PaneId: PaneModel]` or `[PaneId: TabId]`) -- that would
reintroduce the drift this refactor removes. Per-call transient maps inside a
single handler (e.g. the existing `paneToTabIdMap`, `Update.swift:2577`) are
fine and stay.

`updatePane` follows the spine-rebuild pattern `setRatio` already uses
(`ModelOperations.swift:322`); stop walking once the (unique) pane is found.

**Every `model.panes[...]` site is rewritten** -- there is no zero-churn shim.
A subscript on `AppModel` would be `model[id]`, not `model.panes[id]`, so it
does not preserve existing syntax; deleting `AppModel.panes` makes all ~98 app
sites and ~265 test sites fail to compile until rewritten. **Readers are not
confined to the `Update`/`AppRuntime`/`ModelOperations` handlers** -- view files
read `runtime.model.panes[id]?.{theme,cwd,title,todos}` directly and must be
rewritten too: `ThemeBrowserView.swift:146` (theme), `PaneWrapperView.swift:336`/
`:372` (cwd), `TabTodoPopoverView.swift:396`/`:552`/`:895` (todos/title),
`TodoPopoverView.swift:66` (todos). The mechanical patterns:

| Today                                               | Becomes                                                                                                                                                                                              |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model.panes[id]` (read)                            | `model.pane(id)`                                                                                                                                                                                     |
| `model.panes[id]?.field = x` / `.todos.append(...)` | `model.updatePane(id) { $0.field = x }`                                                                                                                                                              |
| `model.panes.removeValue(forKey: id)`               | **delete the line** (leaf removal covers it)                                                                                                                                                         |
| `model.panes[id] = newPane` (insert)                | build the leaf via the tree op (`splitLeaf`/`createTab`)                                                                                                                                             |
| `for (id, p) in model.panes`                        | iterate `model.allPanes`; for mutate-all that also emits effects, two passes (collect target ids, then `updatePane` + append effect each) -- e.g. the remote-theme loops (`Update.swift:615`/`:709`) |
| `model.panes.keys` / `.count`                       | `model.allPaneIds` / `model.allPaneIds.count`                                                                                                                                                        |
| `Set(model.panes.keys)` (diff idiom)                | `Set(model.allPaneIds)` (`Update.swift:1603-1606` paneSplit new-id diff)                                                                                                                             |

An optional read-only `subscript(_ id: PaneId) -> PaneModel?` (get = `pane(id)`)
may be added as `model[id]` sugar -- it is a pure function of the tree, so no
drift -- but it still requires touching every call site and does not preserve
`.panes[...]`. Treat the migration volume (~98 app + ~265 test) as real.

### Tree-helper signature changes (the move-correctness win)

These helpers can no longer reconstruct a leaf from an id alone -- they must
thread the `PaneModel` payload:

- `removeLeaf(_:paneId:)` -> returns `(newTree: SplitNodeModel?, nextFocus:
PaneId?, removed: PaneModel?)` (`ModelOperations.swift:128`). Close paths
  discard `removed`; move paths re-insert it.
- `splitLeaf(...)` takes `newPane: PaneModel` (not `newPaneId`) and builds
  `.leaf(newPane)`; the original leaf is preserved as the existing node
  (`ModelOperations.swift:98`).
- `insertAtLeaf(...)` takes a `PaneModel` to insert (`ModelOperations.swift:209`).
- `swapLeaves`/`swapLeavesInner` swap the whole leaf nodes (their `PaneModel`
  payloads), not ids (`ModelOperations.swift:167`). `moveLeaf` = `removeLeaf`
  (capturing `removed`) then `insertAtLeaf(removed)` (`ModelOperations.swift:192`).
- `allPaneIds`, `firstLeafId`, `lastLeafId`, `nearestLeaf` change
  `case .leaf(let id)` -> `case .leaf(let pane)` then use `pane.id`
  (one-line each).

### Snapshot: step 1 keeps the wire format; step 2 swaps to one leaf-embedded format

The live-model restructure is **decoupled from the wire format**:

- **Step 1 (with the model change): wire format UNCHANGED, no version bump.**
  The flat `panes` array stays as a pure encode/decode join, produced from and
  consumed back into leaves -- never a live store, so no drift.
  - Decode (`validateAndBuildDetailed`, `Model.swift:314-488`): attach the
    built `PaneModel` to each leaf _during_ the tree walk
    (`parseSplitNode`) instead of building the dict at step 5
    (`:462-474`). Keep every existing check (missing-pane `:398-401`,
    orphan `:448-454`, duplicate-in-two-trees `:403-406`, id uniqueness) -- the
    flat array is still the input. The `autoPaneIds`/`autoPaneCursor` omitted-id
    logic (`Model.swift:317-343`, `:524-528`) is unchanged. Keep deriving restore
    chrome from the _snapshot_ form (`deriveTabChromeFromSnapshot`, launch-cwd
    aware, `ModelOperations.swift:413`), **not** `deriveTabChrome(from: PaneModel)`
    (pane-cwd), to preserve restore titles.
  - Encode (`toSnapshot`, `ModelOperations.swift:947`): iterate leaves and read
    each leaf's `PaneModel` directly (drop the `model.panes[paneId]` lookup at
    `:956`); still emit the flat `panes` array.
  - `enrichSnapshot` (`AppRuntime.swift:965`) and `mergeCheckpoints`
    (`ModelOperations.swift:1059`) are **untouched** -- they still join
    scrollback by the populated flat array.

  This delivers the entire drift-bug elimination with zero snapshot-migration
  risk and zero checkpoint-pipeline change.

- **Step 2: one leaf-embedded snapshot format (v2); the public/persisted split is dropped.**
  We are dropping external backwards-compat for persistence. There is **one**
  snapshot type hierarchy, leaf-embedded, serving `ls`, export, import, _and_ the
  checkpoint/recovery files alike -- no separate persisted types, no flat `panes`
  array, no version-dispatch fork.
  - **One leaf-embedded hierarchy.** `SplitNodeSnapshot.leaf(paneId: String?)` ->
    `SplitNodeSnapshot.leaf(PaneSnapshot)` (`Model.swift:286`); the leaf carries
    its full `PaneSnapshot` (which already has `scrollback`, `Model.swift:340`).
    Delete the flat `panes` array from `AppModelSnapshot` (`Model.swift:265`) so it
    is `{ groups, selectedTabId }`. `AppInitFile` keeps its `{ version, model }`
    shape, but `model` now embeds panes in the tree. There is **no**
    `PersistedInitFile`/`PersistedModelSnapshot`/`PersistedSplitNode` parallel
    hierarchy -- that split existed only to keep the public DTO flat, and we are
    dropping that constraint.
  - **One encode path.** `toSnapshot` (`ModelOperations.swift:999`) emits the
    embedded shape: drop the flat `paneSnapshots` accumulator (`:1000-1028`,
    `:1053`); `toSplitNodeSnapshot` (`:1058`) builds the `PaneSnapshot` from each
    leaf's `PaneModel` inline (with `scrollback: nil`) instead of emitting
    `.leaf(paneId:)`. This single encoder serves the IPC `ls` response
    (`Update.swift:1544`), `.exportState` (`Update.swift:755`), import, _and_ the
    checkpoints. **Scrollback enrichment collapses to one pure helper**
    `graftScrollback(onto: AppModelSnapshot, scrollbackByPaneId: [PaneId: String])
-> AppModelSnapshot` that walks the embedded tree and sets each leaf's
    `PaneSnapshot.scrollback` from the map. The live-surface read stays impure as a
    shared `scrollbackByPaneId() -> [PaneId: String]` step (today's `enrichSnapshot`
    inner loop, `AppRuntime.swift:966-974`; NOT in the pure target). Both
    `performEnrichedCheckpoint` (`AppRuntime.swift:990`) and `.exportState` call
    `graftScrollback(onto: toSnapshot(model), scrollbackByPaneId: scrollbackByPaneId())`.
    **Delete `enrichSnapshot`** (`AppRuntime.swift:965`); there is no
    `graftScrollbackFlat` and no two-graft split.
  - **Decoder simplifies.** `validateAndBuildDetailed` (`Model.swift:360`) walks
    the embedded tree, building each leaf's `PaneModel` and collecting the
    `(model, paneSnapshots: [PaneId: PaneSnapshot])` pair from the leaves rather
    than from a flat array. The orphan (`:512-518`), missing-pane (`:462-466`), and
    duplicate-across-trees (`:467-470`) checks **die** -- structurally impossible
    once a pane exists iff a leaf embeds it. **Keep leaf-id uniqueness:** one
    walk-wide check rejects any pane id that appears on two leaves (subsuming the
    old per-tab `:456-459`, cross-tree `:467-470`, and flat `:376-379` duplicate
    checks), and keep the global cross-domain id-collision guard (`allIds`,
    `:402`/`:419`/`:436`/`:596`) -- `surfaces`/`searchState`/`lastNotificationTime`/
    `updatePane` are all id-keyed, so a corrupt or hand-edited dup id would
    reintroduce exactly the drift this refactor removes. **Delete
    `autoPaneIds`/`autoPaneCursor`** (`:363-381`, `:559-584`): they only
    positionally paired id-less flat `panes` entries with id-less leaves; with the
    pane embedded in the leaf, an id-less leaf just mints a fresh `PaneId` inline
    during the walk (the omitted-id hand-authoring affordance survives; the pre-pass
    - cursor threading does not). Restore chrome still derives from the snapshot
      form (`deriveTabChromeFromSnapshot`, `:482`), now read from the focused leaf's
      embedded `PaneSnapshot`.
  - **Version 2; reject v1 (no version dispatch).** Bump the written version to `2`
    (`toInitFile` `ModelOperations.swift:996`, `performEnrichedCheckpoint`
    `AppRuntime.swift:992`). `loadValidatedInitFile` (`ModelOperations.swift:869`)
    decodes the one `AppInitFile` and guards `version == 2` (`:877`), rejecting v1
    (and v3+) as `unsupportedVersion` -- there is no version-dispatch fork in the
    loader. The `SnapshotTests.swift:61-85` unsupported-version test inverts to
    assert v2 succeeds, v1 and v3 reject.
  - **Session migration: reject-v1 (chosen).** Breaking the format means the
    existing light/enriched checkpoint files won't decode on the first post-upgrade
    launch, so the current open session is lost on that one restart (a rejected
    checkpoint falls through to a fresh session). This is accepted as the
    zero-migration, baggage-free end state -- no v1 loader, no transition window.
    (Alternative, **not** chosen: a load-only one-shot v1 importer -- the single
    place that reads the old flat file, converts to embedded in memory, deleted a
    release later -- if losing the live session across the upgrade ever proves
    unacceptable.)
  - **`mergeCheckpoints` on the validated pair (single format).** Keep the
    merge-on-normalized-pair shape: `mergeCheckpoints` (`ModelOperations.swift:1109`,
    today reads the flat `.panes`) takes the two `ValidatedAppRestore`s' `[PaneId:
PaneSnapshot]` maps and grafts `enriched.paneSnapshots[id]?.scrollback` into
    `light.paneSnapshots` by id, light authoritative for structure/model. This skips
    re-validation (light is already validated) and never tree-walks. `main.swift:93`
    passes the validated pair (not `.snapshot`), and the recovery carrier
    `delegate.lastSessionSnapshot` (`AppDelegate.swift:23`, consumed `:141`) holds
    the merged _validated_ result so the crash-recovery structure is never
    decoded/validated twice. **No mixed-version handling** -- under reject-v1 the
    merge only ever sees v2+v2. (The explicit `--init` `initSnapshot` path is
    unaffected in flow -- it still validates its snapshot -- but a hand-authored
    `--init` file must now be the v2 embedded shape.)

### Side-tables stay keyed by PaneId

`searchState` (`Model.swift:183`), `lastNotificationTime` (`:182`), and all
runtime side-tables (`surfaces`, `surfaceVisibility`, `replayFiles`,
`searchDebounceTimers`, `tokenStore`) stay `[PaneId: ...]`. They are per-pane
_runtime/ephemeral_ state, never persisted, never the orphan-bug source; a stale
entry self-prunes harmlessly. Their cleanup calls (`removePaneSearchState`,
`lastNotificationTime.removeValue`) stay in the destruction handlers -- they do
_not_ fold into `removeLeaf` (a pure tree function with no side-table access).

### The 8 dual-write handlers collapse

Each loses its `model.panes.removeValue` / `model.panes[id] =` line, and the
move handlers stop relying on a global dict:

- `createTab` (`Update.swift:44`): build `PaneModel`, put it in the leaf
  directly (`.leaf(pane)`); the dict write (`:53`) vanishes.
- `splitPane` (`:173`): `splitLeaf(newPane:)` embeds the pane; dict write
  (`:194`) vanishes; `cwd`/`theme` reads (`:184-185`) -> `model.pane(...)`.
- `closePane` (`:222`): `removeLeaf` drops the pane atomically; `removeValue`
  (`:240`) vanishes; side-table cleanup stays.
- `surfaceCreationFailed` (`:864`): tab removal drops every leaf-owned sibling
  pane; the per-pane `removeValue` (`:878`) vanishes. **The non-tree fallback
  (`:903-907`) becomes a near no-op** -- a pane in no tree cannot exist, so it
  reduces to side-table cleanup. Can no longer leave a half-removed pane.
- `movePaneToTab` (`:297`) / `movePaneToNewTab` (`:368`): `removeLeaf` returns
  the `removed` `PaneModel`; insert _that_ into the target leaf
  (`.leaf(removed)`); derive chrome from `removed`. The pane physically moves
  between trees in one operation -- the scary global-dict indirection is gone.
- `closeTabBody` (`:2618`): tab removal drops the subtree; per-pane `removeValue`
  (`:2640`) vanishes; the `allPaneIds` loop stays (to destroy surfaces / prune
  id-keyed side-tables).
- `deleteGroup` (`:1052`): closing a whole group with `moveTabs == false` loops
  every tab's `allPaneIds`; the per-pane `removeValue` (`:1072`) vanishes (subtree
  removal drops all leaf-owned panes atomically); the `allPaneIds` loop stays
  (destroy surfaces / prune id-keyed side-tables). Its `.destroySurface` (`:1068`)
  is one of the four deleted in stage 8.

## 1b. Domain / UIState split

Formalize ephemeral view state into a typed sidecar the reconciler reads as a
second input and never clobbers (its consumer arrives with the sidebar pass):

```swift
struct ViewLocalState {
    var sidebarRenameTarget: RenameTarget?      // tab/group being inline-renamed
}
```

**`RenameTarget` moves into the shared layer and the sidecar becomes the
authority on which row is editing.** Today `RenameTarget` is a `private enum`
(`SidebarView.swift:1425`, cases `.tab(TabId)`/`.group(GroupId)` -- no AppKit
type) stored as an `objc` associated object on the field editor's text field,
set in `beginRenaming` (`SidebarView.swift:463`) and cleared in all three
finish paths (`finishInlineRename` `:1316`, `doCommandBy` `:1365`,
`textShouldEndEditing` `:1417`). A reconciler in `AppRuntime` can read neither a
`private` type nor a per-text-field associated object, so the rename guard as
first sketched could not compile or know which row is live. The wiring:

- Hoist `RenameTarget` out of `SidebarView` into the model/projection layer
  (`Model.swift`; it is pure data, importable by `ModelOperations.swift`).
- `ViewLocalState` is stored on `AppRuntime` next to `model` and passed to every
  projection as the second input (`(AppModel, ViewLocalState)`).
- Make the sidecar authoritative: `beginRenaming` sets
  `runtime.viewLocalState.sidebarRenameTarget`; **every** finish path clears it
  (the associated-object dance may stay as the field editor's own bookkeeping,
  but the sidecar is what the reconciler reads). This update happens
  synchronously, before any `send()` the rename paths dispatch, so a row never
  reconciles mid-edit.
- The `reconcileSidebar` executor guards the rename target **narrowly**: it
  suppresses only a `reload` (title/attribute) op for that exact row -- matching
  today's in-place `skipTitle` behavior (`SidebarView.swift:406`), which skips the
  title write but still updates badge/subtitle/color. Structural ops
  (`insert`/`remove`/`move`) for the rename-target row **still apply** -- a tab
  being edited can be moved or closed by another `send()`, and skipping that would
  strand a row or leave stale edit state. When the rename target is absent from
  the new projection (its tab/group was removed), the executor **clears
  `sidebarRenameTarget`** (ending the now-orphaned edit) and applies the removal.
  All of this lands together in stage 5, where `sidebarRenameTarget` is introduced.

The sidecar holds only view state with no natural AppKit owner -- today just the
inline-rename target. **The theme browser is deliberately NOT in the sidecar:**
it already owns its filter (`searchField` + `filteredNames`) and captures/
restores its own focus (`captureFocusTarget()`/`restoreFocus(_:)`,
`ThemeBrowserView.swift`), so mirroring `themeBrowserFilter`/`themeBrowserFocus`
into the model would be dead weight no reconcile pass reads.

**Sidebar multi-selection is deliberately NOT in the sidecar.** `NSOutlineView`
owns `selectedRowIndexes` (`SidebarView.swift:286`); a model/sidecar copy would
reintroduce drift and need a selection `Msg` on every shift/cmd-click. The
reconciler reads live selection and normalizes it through the existing pure rule
`resolveReloadSelection(priorSelectedTabIds:liveTabIds:selectedTabId:)`
(`ModelOperations.swift:1430`, already tested) -- capturing prior selected ids
at pass entry (before the row diff, as `reload(model:)` does at
`SidebarView.swift:284-290`), then reapplying after.

## 1c. Keyed surface reconciliation

`surfaces: [PaneId: TerminalView]` (`AppRuntime.swift:21`) is already keyed by
id. Surface _destruction_ becomes a projection: `reconcileSurfaceExistence`
tears down surfaces for panes no longer in `model.allPaneIds` (Part 2). Surface
_creation_ stays a command (it forks a PTY and has `.surfaceCreationFailed`
feedback) -- and because the reconciler only destroys, the restore-race a
create-capable reconciler would have does not exist. With tree-owns-panes,
"desired surfaces" is simply `model.allPaneIds` -- no dict to cross-check.

---

# Part 2 -- View reconciler (builds on Part 1)

After Part 1, `update()` returns only **commands** (transient imperatives /
external side effects): PTY **creation** (destruction is a projection -- see
below), focus moves, **per-pane theme application**, notifications, IPC,
checkpoint, config writes, modal confirmations, TODO popovers. Everything the view _shows_ becomes a
**projection** derived by `reconcile()`. Rename `Effect` -> `Command` (last; see
Delivery sequence) so the compiler enforces that no projection emission survives.

### The reconcile pass

Replace the `syncSurfaceVisibility()` call in `send()`
(`AppRuntime.swift:220`) with ordered sub-passes (existence -> content ->
focus/chrome; occlusion last because it reads `surfaces`):

```swift
private func reconcile() {
    reconcileSurfaceExistence()  // destroy surfaces for panes gone from model.allPaneIds
    reconcileContainers()        // desired = ALL tabs' shapes (eager); selected visible, rest mounted+hidden
    reconcileFocusBorders()      // (focused, bell) per pane, diffed
    reconcilePaneChrome()        // pane toolbars + search overlays, diffed
    reconcileSidebar()           // granular NSOutlineView row diff
    reconcileWindowChrome()      // window title, dock/toolbar badges, tab-todo button
    reconcileSwitcher()          // single-optional MRU projection; nil (no mruCycle) -> orderOut
    syncSurfaceVisibility()      // existing occlusion pass; stays last
}
```

Each pass follows the `syncSurfaceVisibility()` template
(`AppRuntime.swift:335`): compute desired from the model, diff against a
per-pass cache, apply only the delta, self-prune dead keys.

**Per-pane theme application stays a command, NOT a projection.**
`applyPaneTheme`/`reapplyAllPaneThemes` (`AppRuntime.swift:1106`/`:1113`) re-apply
config to every themed pane on a _config reload_ (`reloadGhosttyConfig`, the
Ghostty config-change callback `GhosttyApp.swift:346`, prefs
`PreferencesPanel.swift:382`) **even when the theme name is unchanged** -- the
resolved theme changed, not the name. A name-keyed projection diff would skip
that reapply and leave stale themes, so theme application is an external side
effect (depends on the loaded Ghostty config, not model state) and remains a
command. Only the focus _border_ reconciles.

**The `panes.keys == allLeaves` DEBUG assertion the old plan added is gone** --
tree-owns-panes makes it structurally impossible to violate. `desiredSurfaceIds`
collapses to `model.allPaneIds`. Per-pane cleanup in `update()` keeps the
side-table removals but drops `model.panes.removeValue` (leaf removal covers it).

### Command phases: focus runs after reconcile

```swift
let commands = update(&model, msg)
for c in commands where !c.isPostReconcile { perform(c) }  // PTY, createSurface, focusSurface, applyPaneTheme, ...
reconcile()
for c in commands where c.isPostReconcile { perform(c) }   // makeFirstResponder, focusSearchField
```

`isPostReconcile` is true for **exactly** `makeFirstResponder` and
`focusSearchField` -- they target views the reconciler creates (a pane's
`TerminalView`, the search field). Implement it as an **exhaustive switch with no
`default`** so adding a command without classifying it fails to compile.
`focusSurface` stays **pre-reconcile**: it calls `ghostty_surface_set_focus` on
an existing surface, and deferring it is actively wrong -- a foreground
`createTab` create-failure (`AppRuntime.swift:397-398`) re-enters `send` and
re-focuses the fallback; a deferred `focusSurface(old,false)` would then defocus
it. (`makeFirstResponder`/`focusSearchField` no-op in that failure path: their
target pane was removed, so `surfaces[id]` is nil.)

### Apply granularity per view

Both **ordered** passes (containers, sidebar) split into a **pure** op-list
computation (an `Equatable` `[Op]` derived from old vs new projection) and a
**thin impure executor** that applies the ops to AppKit. That converts the
riskiest, AppKit-bound logic in Part 2 into structure-insensitive unit tests
(the simple keyed passes already get this for free via `applyDiff`).

- **Content (`SplitContainerView`) -- coarse, EAGER.** `computeContainerOps(old:
[TabId: ContainerShape], new:, selectedTabId:) -> [ContainerOp]` (pure) emits
  remove/rebuild/visibility ops; the thin executor applies them. **`new` (the
  desired set) is ALL model tabs' container shapes -- a total function of the
  model, no "mounted set" side-input.** The selected tab's container is visible;
  every other tab's container is mounted with `isHidden = true`. (Decision: go
  eager. There is no lazy/visited-set variant, no "scope to only the
  mounted-or-selected tabs" (the superseded prior-review fix), and no "visibility
  op on an unmounted container is a no-op" special case --
  every tab's container always exists, so threading runtime visit-history into a
  pure projection is avoided.) A container rebuilds only when its `ContainerShape`
  drifts. **`ContainerShape` = split ids/directions + leaf `PaneId`s + zoom only**
  -- it excludes split ratios (so `splitRatioChanged` is a content-diff no-op)
  **and** the leaf `PaneModel` payload (which now lives in the tree, so a
  title/cwd/progress/theme/todo edit must NOT trigger a container rebuild that
  would clear anchored UI). The expensive ghostty surface persists in `surfaces`;
  hidden-but-parented surfaces are occluded by `syncSurfaceVisibility()` (runs
  last), so eager mounting adds no post-first-reconcile render churn.
  **Rebuild/remove invalidates host-local chrome caches.** A `rebuild` (or
  `remove`) op recreates the tab's `PaneWrapperView`s
  (`SplitContainerView.rebuild()` removes all subviews), so the toolbar and
  search overlay -- subviews of the _wrapper_ -- are gone, while the focus border
  rides the persisted `TerminalView` and survives. Therefore the container
  executor, for every leaf pane in a removed-or-rebuilt container, **clears
  `caches.paneToolbar`/`caches.searchOverlay` for that pane id** before
  `reconcilePaneChrome` runs (the next pass). Without this, the value-unchanged
  chrome diff would skip the fresh wrapper, leaving it with no toolbar content or
  a dropped active-search overlay. `focusBorders` is _not_ invalidated (its host
  persists). This mirrors today's `refreshPaneToolbars`/search-rehydrate that runs
  immediately after a container build (`AppRuntime.swift:1535`,`:1543`).
- **Sidebar (`NSOutlineView`) -- fine.**
  `computeSidebarRowOps(old: SidebarProjection, new: SidebarProjection) ->
[SidebarRowOp]` (pure) diffs rows/order/per-row attributes/collapse/jump badge
  into minimal `insert`/`remove`/`move`/`reload` ops; the thin executor issues the
  matching `insertItems`/`removeItems`/`moveItem`/`reloadItem` (inconsistent batch
  ops crash `NSOutlineView` hard, so this is the highest-value pass to keep pure).
  Selection handled view-owned (Part 1b). The executor suppresses only a `reload`
  op for the live-editing row (the narrow `sidebarRenameTarget` guard -- Part 1b);
  `insert`/`remove`/`move` for that row still apply, and a vanished rename target
  clears the sidecar.

### Diff caches (consolidated)

Bundle all per-pass caches into one struct so teardown resets them by re-init
(a newly-added cache field resets for free -- the structural form of the
restore-cache fix):

```swift
struct ReconcilerCaches {
    var surfaceVisibility: [PaneId: Bool] = [:]
    var focusBorders: [PaneId: BorderState] = [:]
    var paneToolbar: [PaneId: PaneToolbarRender] = [:]
    var searchOverlay: [PaneId: SearchOverlayRender] = [:]   // key present iff search active
    var containerShape: [TabId: ContainerShape] = [:]
    var sidebar: SidebarProjection? = nil
    var windowChrome: WindowChromeProjection? = nil
    var switcher: SwitcherProjection? = nil                  // nil == no MRU cycle == panel hidden
}
```

(No theme cache -- theme application is a command, not a diffed projection.)
The `paneToolbar`/`searchOverlay`/`switcher` caches back `reconcilePaneChrome`
and `reconcileSwitcher`; without them those passes could not diff and would
re-apply (or fail to hide) on every `send()`. Cache-lifetime rule: any cache
whose host view is _recreated_ by an earlier pass must be invalidated for the
affected keys before its own pass runs -- `reconcileContainers` clears
`paneToolbar`/`searchOverlay` for panes in rebuilt/removed containers (see
Content above); `focusBorders` needs no such invalidation (its `TerminalView`
host persists).

### Projections compute pure, apply impure

Every projection is a pure function in `ModelOperations.swift` (which cannot
import AppKit), taking only `(AppModel, ViewLocalState)` and returning an
`Equatable` value; only the `reconcile*` pass touches AppKit. A small generic
bakes in diff + cache-update + self-prune so a pass can't drift its cache:

```swift
func applyDiff<K: Hashable, V: Equatable>(
    _ desired: [K: V], _ cache: inout [K: V],
    apply: (K, V) -> Void, remove: (K) -> Void = { _ in }
) {
    for (k, v) in desired where cache[k] != v { apply(k, v); cache[k] = v }
    for k in cache.keys where desired[k] == nil { remove(k) }   // teardown disappeared keys
    cache = cache.filter { desired[$0.key] != nil }
}
```

**A key leaving `desired` is a removal, not just a cache prune.** The original
sketch pruned the cache silently, so a projection that _disappears_ (a search
overlay after `.endSearch` `Update.swift:1250`, while its pane lives on) would
never be torn down -- the overlay would linger. The `remove` callback fixes
this. Two keying disciplines, both correct under it:

- **Key absence == disappear-but-host-survives** (search overlay): the desired
  dict holds a key only while the overlay should show; on `.endSearch` the key
  leaves and `remove` calls `hideSearchOverlay()` (a no-op if the pane's
  container was already torn down by an earlier pass -- `findPaneWrapper` returns
  nil). `reconcilePaneChrome` passes this `remove`.
- **Key absence == host destroyed** (focus borders, pane toolbar): the desired
  dict is keyed over all live panes, so a key leaves only when its pane is gone,
  and `reconcileContainers` (an earlier pass) already removed the host view. These
  keep the default no-op `remove`; the prune just keeps the cache clean.

The **switcher is a single panel, not a keyed set**, so it does not use
`applyDiff` at all -- `reconcileSwitcher` diffs one `SwitcherProjection?` against
`caches.switcher` (the `windowChrome` template): a `nil` projection (no
`model.mruCycle`) issues `switcherPanel.orderOut`, a non-nil one renders +
`orderFront`. The `nil` transition is what hides the panel on MRU end (today's
explicit `.hideSwitcherOverlay` `AppRuntime.swift:816`).

Pure projection helpers to add next to `effectiveSurfaceVisibility`
(`ModelOperations.swift:61`): `desiredSurfaceIds` (= `allPaneIds`), container
shape equality (**structure + leaf ids + zoom; excludes ratios and `PaneModel`
payload**), the sidebar projection (rows + attributes + jump badge from
`model.jumpMode?.keyMap[tab.id]`; **selection excluded**), the per-pane
focus-border state (`(focused, bell)` from `isFocusedAndVisible` +
`paneHasUnreadAlert` -- note single-pane tabs draw no border,
`ModelOperations.swift:900`), the search-overlay _render_ projection
(`[PaneId: SearchOverlayRender]` -- needle + total/selected, keyed only for panes
with active search, so an ended search drops the key and triggers the `remove`
teardown), the switcher render projection (a _single_ `SwitcherProjection?` --
rows + `cursorIndex` from `model.mruCycle`, mirroring `SwitcherPanel.render`;
`nil` when no cycle is active), `desiredPaneToolbar(model:pane:)` (title/cwd via
`paneToolbarText`, progress, isRemote/remoteSession, unread-alert count,
total/uncompleted todo counts -- the fields `refreshPaneToolbar` reads at
`AppRuntime.swift:1380-1390`), and window-title/badge derivations.

Plus two **pure op-list** functions backing the ordered passes:
`computeSidebarRowOps(old:new:) -> [SidebarRowOp]` and
`computeContainerOps(old:new:selectedTabId:) -> [ContainerOp]` (both over
`Equatable` op enums) -- the diff-to-ops logic the thin executors consume, kept
out of AppKit so it is unit-testable.

### Focus, popovers, restore (carried from the reviewed plan)

- **First responder stays a command.** `focusDirection` (`Update.swift:525`)
  emits `.makeFirstResponder` (AppKit's `becomeFirstResponder` then fires
  `paneBecameFirstResponder` which mutates the model). Only `refreshPaneBorder`
  emissions are stripped -- borders reconcile. `finalizeTabSelection` (folded
  into `reconcileContainers`) establishes mount-time focus **only for the visible
  (selected) container, never per-built-container** -- with eager mounting that
  scoping is the required focus-cascade guard (otherwise every hidden tab's mount
  would fight for first responder). Already guarded against stealing from
  search/theme-browser (`AppRuntime.swift:1527`).
- **TODO popovers stay commands** (anchored to view geometry,
  `AppRuntime.swift:754`). `model.todoPopover` stays pure state for guards +
  close callbacks, never read by the reconciler to present. Add a pure
  `clearTodoPopoverForViewSwap(&model)` placed by a **mechanical rule**: wherever
  the migration removes a `.showSelectedTab` emission (all 8 sites) or a
  visible-tab `.rebuildTabContainer`, drop the helper in its place -- 1:1 parity
  with today's `prepareForViewSwap` clearing. The reconciler still dismisses a
  _stranded_ AppKit popover when its anchor container is torn down/rebuilt.
- **Restore** (`commitRestoreSession`, `AppRuntime.swift:1275`) sets
  `surfaces`+`model` then calls `reconcile()`. `tearDownCurrentSession`
  (`:1245`, runs as commit's first line `:1276`) resets the whole
  `ReconcilerCaches` (extending the existing `surfaceVisibility.removeAll()` at
  `:1267`) so the first post-restore reconcile is a clean build, not a
  stale-cache diff. Only the surface-existence pass is a no-op (staged surfaces
  match); the container pass **builds every tab's container eagerly** (selected
  visible, rest mounted+hidden), and the sidebar/chrome passes build from scratch
  (replacing the old `showSelectedTab()` + manual refreshes at `:1286-1293`). This
  is consistent with `stageValidatedRestore` (`AppRuntime.swift:1198-1224`), which
  already forks a PTY + ghostty surface for every pane in every tab -- eager
  container mounting adds only the (negligible) AppKit view-tree allocation on top
  of the N surfaces already created.
- **Delete `send()`'s imperative view-sync**: the unread-badge diff
  (`AppRuntime.swift:224-228`) moves to `reconcileWindowChrome`; the msg-keyed
  `refreshPaneToolbar`/`refreshTabTodoButton` switch (`:242-284`) moves to
  `reconcilePaneChrome`/`reconcileWindowChrome`. Leaving them would run stale
  refreshes alongside the reconciler.

---

# Delivery sequence

Land one cohesive stage at a time (an agent implements each in order); the app
stays shippable throughout. The `Effect`->`Command` rename is the only
globally-coupled action and goes last.

**Per-stage invariant:** each reconcile-pass stage deletes the projection
emission sites AND the corresponding `Effect` case(s) + their `perform` arm(s)
**in the same stage** (as stage 3 does). Deleting the case is what makes a
_missed_ emission a compile error within that stage; otherwise the stale
`perform` arm still runs alongside the new reconcile pass (double-sync) -- the
exact silent-miss class this plan exists to kill, which the pure tests
(commands-only on a handful of handlers, not global) cannot catch. With every
projection case gone by the end of stage 8, stage 9 degrades to a pure rename of
the surviving command enum.

1. **Tree-owns-panes, live model (wire format unchanged).** `leaf(PaneModel)`,
   delete `panes`, add `pane`/`updatePane`/`allPaneIds`, tree-helper signature
   changes, rewrite ~98 app call sites + the 8 handlers, `toSnapshot`/decode
   read-from/attach-to leaves (still v1). No view-_architecture_ change, but the
   view files reading `model.panes` (ThemeBrowser/PaneWrapper/TabTodoPopover/
   TodoPopover, listed above) are rewritten to `model.pane(...)` to compile.
   **Banks the entire drift-bug elimination.**
2. **One leaf-embedded snapshot format (v2).** `SplitNodeSnapshot.leaf(PaneSnapshot)`,
   delete the flat `panes` array from `AppModelSnapshot`, bump the written version
   to `2`. The single `toSnapshot` encoder emits the embedded shape for `ls`,
   `.exportState`, import, and checkpoints alike; one pure `graftScrollback(onto:
AppModelSnapshot, scrollbackByPaneId:)` over the embedded tree (fed by the shared
   impure `scrollbackByPaneId()` read) enriches both export and the enriched
   checkpoint -- no `graftScrollbackFlat`, no separate persisted types. The decoder
   drops the orphan/missing/cross-tree-dup checks (structurally impossible) but
   **keeps leaf-id uniqueness**, and deletes `autoPaneIds`/`autoPaneCursor` (an
   id-less leaf mints a fresh id inline). `loadValidatedInitFile` guards
   `version == 2` and **rejects v1** (no dispatch fork; the current open session is
   lost on the one post-upgrade launch -- accepted, see Session migration).
   **`mergeCheckpoints` merges on the normalized `paneSnapshots` pair, not the
   tree** (grafts enriched scrollback into light's map by id), and `main.swift`
   passes the validated pair. Add the embedded round-trip + embedded-shape
   `ls`/export contract + duplicate-leaf-id-rejected + v2-accepted/v1-rejected +
   single-format `mergeCheckpoints` graft tests, and **update
   `integrations/danterm/SKILL.md`** for the new `ls`/export shape in the same change.

> **Checkpoint: Part 1 -> Part 2 is an explicit go/no-go, not a foregone
> continuation.** Stages 1-2 carry most of the value at materially lower risk:
> they delete the dual-write drift bug class _structurally_ and ship a stable,
> bisectable resting point. Part 2 (stages 3-9) trades "forgot to emit X" bugs for
> "host-local cache coherence across rebuilds" bugs (the `paneToolbar`/
> `searchOverlay` invalidation dance). Re-evaluate here: if Part 2's
> cache-coherence surface proves thornier than budgeted, stopping after Part 1 is
> clean and valuable. Each Part 2 stage remains independently shippable, so the
> decision can also be staged.

3. `reconcileFocusBorders` -- delete the `.refreshPaneBorder` emissions (3 sites)
   AND the `refreshPaneBorder` `Effect` case + its `perform` arm
   (`AppRuntime.swift:472`); the pass keeps calling the same
   `TerminalView.setFocusBorder` executor (`:641`). No command-phase change.
4. `reconcilePaneChrome` (toolbars + search overlay) -- delete those emissions
   AND their `Effect` cases (`refreshPaneToolbar`, `showSearchOverlay`/
   `hideSearchOverlay`) + `perform` arms, plus the `send()` toolbar/todo switch
   (`:242-284`). Add the `paneToolbar`/`searchOverlay` caches; the search-overlay
   diff passes a `remove` closure (`hideSearchOverlay()`) so an ended search tears
   the overlay down (replacing the deleted explicit `.hideSearchOverlay`).
   **Introduces the command-phase split**, flagging `focusSearchField`
   post-reconcile; `makeFirstResponder` stays pre-reconcile (containers still
   effect-built). `applyPaneTheme` stays a command (untouched here).
5. `reconcileSidebar` (the NSOutlineView granular diff) -- delete all 34 sidebar
   emission sites (`reloadSidebar` x18, `updateSidebarTabRow` x10,
   `updateSidebarGroupRow` x5, `setSidebarSelection` x1) AND the four `Effect`
   cases + `perform` arms; add `ViewLocalState.sidebarRenameTarget` (Part 1b) --
   hoist `RenameTarget` out of `SidebarView` into the model layer, store
   `ViewLocalState` on `AppRuntime`, and set/clear it from `beginRenaming` + every
   rename-finish path _before_ wiring the row guard; selection view-owned. Lands
   the pure `computeSidebarRowOps` + thin executor (see Apply granularity). The
   trickiest code, landing isolated.
6. `reconcileWindowChrome` -- delete `setWindowTitle`/badge emissions AND their
   `Effect` cases + `perform` arms, plus the `send()` badge block (`:224-228`).
7. `reconcileSwitcher` -- delete the `showSwitcherOverlay`/`hideSwitcherOverlay`
   emissions AND their `Effect` cases + `perform` arms. Add the single-optional
   `switcher` cache; a `nil` projection (`mruCycle == nil`) issues `orderOut`
   (replacing the deleted explicit `.hideSwitcherOverlay`), non-nil renders +
   `orderFront`.
8. `reconcileSurfaceExistence` + `reconcileContainers` (coupled teardown core,
   Part 1c): fold `showSelectedTab`/`ensureTabContainer`/`rebuildTabContainer`/
   `removeTabContainer`/`finalizeTabSelection` + the `prepareForViewSwap`
   popover-dismiss into the passes (landing the pure `computeContainerOps` + thin
   executor -- see Apply granularity). **Eager: `computeContainerOps`'s desired set
   is all model tabs (selected visible, rest mounted+hidden); `finalizeTabSelection`
   mount-time focus applies only to the visible container.** **Delete the four
   `.destroySurface`
   emissions** (`Update.swift:232`/`:874`/`:1068`/`:2636`) AND the `destroySurface`/
   `showSelectedTab`/`ensureTabContainer`/`rebuildTabContainer`/`removeTabContainer`
   `Effect` cases + `perform` arms -- `reconcileSurfaceExistence` now owns the
   teardown (`tokenStore.remove`, `cleanupReplayFile`, cancel
   `searchDebounceTimers`, `closeSurface`) for every pane absent from
   `model.allPaneIds`; the container executor invalidates
   `caches.paneToolbar`/`caches.searchOverlay` for panes in rebuilt/removed
   containers (so the now-fresh wrappers re-receive chrome from
   `reconcilePaneChrome`); add `clearTodoPopoverForViewSwap` placements; reset
   `ReconcilerCaches` in `tearDownCurrentSession`; point `commitRestoreSession` at
   `reconcile()`. **Extends the command-phase split**: `makeFirstResponder`
   post-reconcile now that `reconcileContainers` mounts the `TerminalView`.
   **Migrate the `surfaceCreationFailed` destroy-effect test** (stage-1 form) to
   the pure surface-existence teardown-selection test, since `.destroySurface` is
   deleted here. After this stage no projection `Effect` case remains.
9. **Rename `Effect` -> `Command`, last.** A pure rename of the surviving command
   enum (every projection case already gone by stage 8); banks the "no projection
   emission survives" guarantee.

---

# Tests

`tests/test.sh` excludes GhosttyKit/AppKit, so view-tree mechanics are manual;
model and projection logic are pure and ARE tested.

### Part 1 (model)

- **Test helpers** `makeModel`/`makeVisibilityModel`/`makeMruModel`
  (`TestHarness.swift:79`, `ModelOperationsTests.swift:54`, `:1659`) drop the
  `panes:` arg (panes already live in the leaves). High-leverage -- they feed
  dozens of tests.
- **Call-site rewrites** (no shim): `model.panes[id]` -> `model.pane(id)`;
  `model.panes[id]?.field = x` -> `model.updatePane`; `Set(model.panes.keys)` ->
  `Set(model.allPaneIds)`; whole-dict equality
  (`UpdateLifecycleTests.swift:197-222`) -> compare `model.allPanes`. The
  orphan-injection test (`UpdateIpcTests.swift:349-364`, which injects a
  pane-in-no-tree) -- **its premise dies**; rewrite to "split on an unknown
  `PaneId` -> null reply", the clean demonstration that the drift hole is closed.
- **New behavioral tests:**
  - v1 snapshot decodes into leaf-owned panes; each pane reachable via
    `model.pane(id)` with correct title/cwd/theme/todos; `allPaneIds` == leaves.
  - `updatePane(B)` changes B's leaf only (A/C and split ids/ratios byte-identical).
  - after `closePane`, `model.pane(closedId) == nil` and `Set(model.allPaneIds)`
    == set of leaves (the old invariant, now asserted as structural).
  - `movePaneToTab` carries distinctive title/todos to the target leaf (not
    lost, not duplicated) and the source no longer has it.
  - `swapLeaves` with two panes carrying distinct content (cwd/theme/todos):
    each pane's full `PaneModel` payload lands at the other's position (the
    node/payload-swap correctness check). Existing tests
    (`ModelOperationsTests.swift:473-545` and the `.movePane`/`.swap` tests
    `UpdatePaneTests.swift:452-490`) assert ids/structure on default-content
    panes only.
  - **`insertAtLeaf` payload threading via `.movePane(intent: .splitRight)`** on a
    pane with distinct cwd/theme/todos: the full `PaneModel` payload lands at the
    new split position and the source position no longer holds it. This is the
    _only_ path through `insertAtLeaf` (`.movePane` split intent -> `moveLeaf` ->
    `insertAtLeaf`, `Update.swift:285`); `movePaneToTab` does a manual
    `removeLeaf` + wrap (`Update.swift:306-321`) and `swapLeaves` uses
    `swapLeavesInner`, so neither covers it. `insertAtLeaf` today rebuilds leaves
    from bare ids (`.leaf(sourceId)`/`.leaf(targetId)`,
    `ModelOperations.swift:219-220`) -- exactly the line that must thread the
    `removed` `PaneModel`; a regression rebuilding a fresh default
    `.leaf(PaneModel(id: sourceId))` would pass every existing (default-content)
    `.movePane` test while silently dropping cwd/theme/todos. This test is the net
    for the plan's stated "Tree-helper carry-through" risk.
  - **`surfaceCreationFailed` for a failed pane in a SPLIT tab** removes the whole
    containing tab, drops every sibling pane from `model.pane`/`allPaneIds`, and
    cleans the id-keyed side tables -- plus the unknown-pane case is a safe no-op
    (empty effects, model unchanged). **Stages 1-7** additionally assert it emits a
    `.destroySurface` per sibling pane (the sibling-leak regression this refactor
    closes). **Stage 8 deletes `.destroySurface`** (teardown moves to
    `reconcileSurfaceExistence`), so this assertion _migrates in stage 8_: drop the
    destroy-effect expectation (now empty for the structural part) and instead
    assert, via the pure surface-existence diff (Part 2 tests), that every sibling
    pane is selected for teardown once it is absent from `model.allPaneIds`.
  - _(step 2)_ embedded-format native round-trip (an `AppInitFile` v2 with panes
    nested in `rootNode` leaves decodes to leaf-owned panes and re-encodes
    identically); **`ls`/export JSON has the embedded shape** -- panes in the tree
    leaves, no top-level `panes` array (pins the new CLI contract that SKILL.md
    documents); v2 accepted / v1 and v3 rejected (invert `SnapshotTests.swift:61-85`);
    **a file with two leaves sharing a pane id is rejected** (leaf-id uniqueness,
    the lone surviving duplicate check); **an id-less leaf decodes with a
    freshly-minted pane id** (the omitted-id affordance survives the
    `autoPaneIds`/`autoPaneCursor` deletion); **restore chrome derives from the
    focused leaf's embedded `PaneSnapshot`** -- a v2 file whose focused pane has a
    distinctive `launch.cwd` (plus a different `cwd`, proving launch-cwd wins)
    decodes to a tab whose title/subtitle match `deriveTabChromeFromSnapshot(focusedPs)`,
    and a non-focused sibling's cwd does not leak into the tab title; the derived
    chrome is recomputed at decode (not stored in the snapshot), so the round-trip
    test cannot catch a mis-relocated read -- this is its net; **single-format
    `mergeCheckpoints` on the
    normalized pair** -- grafting enriched `paneSnapshots` scrollback into light's
    map by id, light authoritative for structure (replacing `CheckpointTests`'
    hand-built flat arrays `:261-355`); the pure `graftScrollback(onto:
AppModelSnapshot, scrollbackByPaneId:)` helper embeds scrollback into the
    embedded leaves. The shared `scrollbackByPaneId()` live-surface read is impure
    (not in the pure target) -- its end-to-end path is manual QA step 11.

### Part 2 (reconciler)

- **Delete** projection-emission assertions in `tests/Update*Tests.swift`
  (`splitPane emits .rebuildTabContainer`, sidebar-effect, `.refreshPaneBorder`/
  `.setWindowTitle`/`.updateSidebarTabRow`); replace with commands-only
  assertions (still asserting `makeFirstResponder`/`focusSurface`, `applyPaneTheme`,
  and TODO-popover commands on the relevant handlers).
- **Preserve** model-state assertions (`surfaceTitle`/`syncFocusedPaneChrome` set
  `TabModel.title`/`.subtitle`; `renameTab` sets `customTitle`; focus handlers
  leave/set `focusedPaneId`; per-pane cleanup clears `model.todoPopover`).
- **Add**: `Command.isPostReconcile` classification (makeFirstResponder/
  focusSearchField true; focusSurface false; representative sample of others
  false); the generic `applyDiff` (an `apply` closure recording invoked keys --
  assert only changed keys apply, unchanged keys skip, and a key present in the
  cache but absent from `desired` invokes the `remove` closure exactly once and
  is then pruned from the cache -- the disappearance path); the two op-list computations
  (`computeSidebarRowOps`, `computeContainerOps`) as **model-apply** tests, NOT
  exact-sequence `expectEqual` assertions -- apply the emitted ops in order to a
  plain in-memory model of the old projection (the sidebar is a small nested
  group->tab array; the container side is a `[TabId]` presence/visibility map) and
  assert the result equals the new projection. The sidebar case covers
  insert/remove/move/reload and combinations; the container case covers
  remove/rebuild **and the visibility-only selected-tab switch** -- old selected=A
  with B mounted+hidden at an identical `ContainerShape`, new selected=B, asserting
  the applied ops leave A hidden / B visible, plus a no-op when the selected tab is
  unchanged (the common eager path, whose net was otherwise only in manual QA --
  this catches a dropped-hide regression that leaves two containers visible). This is structure-insensitive (a valid but differently-ordered
  diff still passes) and is the form that actually catches `NSOutlineView`-invalid
  index ordering, which an exact-sequence assertion would instead bless;
  `clearTodoPopoverForViewSwap` one-per-kind (select tab, foreground
  createTab, cross-tab move, visible structural rebuild); pure projection tests
  in `ModelOperationsTests.swift` for each helper:
  - **container shape**: same leaves+splits with different ratios compare equal
    (ratio carveout); a leaf `PaneModel` metadata edit (title/cwd/progress/todo)
    compares **equal** (payload excluded); a structural change (add/remove/move
    leaf, change direction, zoom toggle) compares **unequal**.
  - sidebar (incl. jump badge, _excluding_ selection -- `resolveReloadSelection`
    keeps its existing tests); focus-border (incl. single-pane-no-border);
    pane-toolbar render projection; window title/badges.
  - **search-overlay disappearance**: with search active the projection has the
    pane's key; after `.endSearch` the projection drops it (so the `applyDiff`
    `remove` -> `hideSearchOverlay()` fires). Pure: assert key present then absent.
  - **switcher disappearance**: with `model.mruCycle` set the projection is
    non-nil; after the cycle ends (`mruCycle == nil`) it is `nil` (so the diff
    issues `orderOut`). Pure: assert non-nil then nil.
  - **surface-existence teardown selection** (the stage-8 target of the migrated
    `surfaceCreationFailed` assertion): pure `surfacesToTearDown(liveSurfaceIds:,
model:) = liveSurfaceIds - Set(model.allPaneIds)`. A model missing a pane
    whose surface is still live selects exactly that pane (and its split siblings
    after a `surfaceCreationFailed` tab removal); surviving panes are never
    selected.
  - **chrome-cache invalidation on rebuild** (the container/paneChrome coupling):
    pure `chromeInvalidation(ops:, newShapes:) -> Set<PaneId>` returns every leaf
    pane in a `remove`/`rebuild` container op and nothing for a visibility-only op.
    Combined with the `applyDiff` test (a key absent from the cache re-applies),
    this proves a rebuilt wrapper re-receives its (value-unchanged) toolbar/search
    chrome instead of being skipped.
  - **sidebar rename-guard scope**: apply a `reload` op for the rename-target row
    while editing -> suppressed (title/attrs not clobbered); apply a `remove`/
    `move` op for the rename-target row -> **applied** (row removed/moved) and
    `sidebarRenameTarget` cleared; a `reload` for a _different_ row -> applied.
    All behavioral and structure-insensitive.

---

# Verification

- `just test` -- pure model + projection tests green.
- `just build` -- compiles (the only check that the reconciler, trimmed
  `perform`, and `Effect`->`Command` rename typecheck).
- After step 2: `danterm ls` and `.exportState` emit the embedded shape (panes
  nested in tree leaves, no top-level `panes` array); **`integrations/danterm/SKILL.md`
  MUST be updated in the same change** (per the repo's CLI-doc rule).
- Manual QA from `just build-run`, full tab/pane checklist (tab switch with
  active search, scrollback survives switch, focus borders, zoom across switch,
  navigateToPane clears zoom, cross-tab pane drag, extract to new tab, delete
  group, snapshot restore, 20-tab rapid switch, Cmd-Tab, close selected/
  non-selected tab, theme browser z-order, Retina scale change, todo popover
  during rebuild, snapshot import over active session) PLUS:
  1. Inline-rename a tab; trigger an unrelated `send()` (bell elsewhere) -- the
     field editor survives (sidecar guard).
  2. Multi-select tabs, then an unrelated `send()` -- selection survives (not
     collapsed to the focused tab); reorder/drag between groups -- minimal row
     ops, no flicker.
  3. Collapse a group, switch tabs, add a tab -- collapse preserved.
  4. Bell + todo badges update on the right rows without a full reload.
  5. Theme browser: type a filter, switch tabs, return -- filter + focus
     preserved (the theme browser owns this view-local state itself, as today --
     not the sidecar). Change the app theme/config and confirm every themed pane
     re-applies (theme stays a command -- name-unchanged reloads still apply).
  6. Rapid clicks between panes -- first responder never fights the click.
  7. Cmd-F opens search AND the cursor lands in the field on the first press
     (post-reconcile focus); type a needle -- match count updates live; press
     Escape (`.endSearch`) -- the overlay disappears (the `applyDiff` `remove`
     teardown), the pane stays.
  8. Tab jump mode -- per-tab badges appear; press a key / Escape clears them;
     badges never linger after an unrelated `send()`.
  9. Hold Cmd-Tab through a 20-tab MRU cycle -- overlay updates each step, no lag;
     release Cmd (`mruCycle == nil`) -- the switcher panel disappears (single-
     optional projection -> `orderOut`).
  10. Drag a split divider continuously -- smooth (`splitRatioChanged` is a
      content-diff no-op). If 9/10 regress, gate unaffected passes behind a
      dirty-flag.
  11. **Restore with scrollback** (after step 2) -- enriched checkpoint restores
      scrollback into every pane.
  12. With an active search overlay in a pane, force a container rebuild of its
      tab (split/unsplit a sibling, toggle zoom) -- the toolbar and the active
      search overlay re-appear on the rebuilt wrapper (chrome-cache invalidation),
      not blank.
  13. Inline-rename a tab, then from another path (menu, IPC, drag) move or close
      _that_ tab -- the row moves/closes and the edit ends cleanly (no stranded
      field editor, no stale row; `sidebarRenameTarget` cleared).
  14. Restore a many-tab session (eager mounting) -- every tab's container is
      mounted but only the selected one is visible; hidden tabs stay occluded (no
      render churn / no CPU on background tabs after the first reconcile), and
      first responder lands only in the selected tab.

---

# Risks

- **Test-migration volume.** ~265 `model.panes[...]` references in tests + ~98 in
  app code (the latter incl. four view files that read `model.panes` directly),
  all rewritten (no shim preserves `.panes[...]`). Budgeted up front; the
  helper-trio rewrite (`makeModel`/`makeVisibilityModel`/`makeMruModel`) is the
  high-leverage first move.
- **Tree-helper carry-through.** `removeLeaf`/`splitLeaf`/`insertAtLeaf`/
  `swapLeaves` must thread `PaneModel` payloads, not rebuild leaves from ids;
  this is the move-handler correctness win, not optional.
- **Format break is intentional (step 2).** The single leaf-embedded v2 format
  changes the `ls`/export JSON shape (SKILL.md updated in the same change) and is
  rejected by older builds; under reject-v1 the current open session is lost on the
  one post-upgrade launch (a load-only one-shot v1 importer is the documented escape
  hatch if that ever matters). The embedded-shape contract test pins the new
  `ls`/export shape.
- **Eager container mounting (decided).** `computeContainerOps`'s desired set is
  all model tabs (a total projection), so every tab's container is mounted
  (selected visible, rest `isHidden`) -- no lazy/visited-set side-input. The cost
  is bounded: `stageValidatedRestore` already forks a PTY + ghostty surface per
  pane per tab, so eager adds only AppKit view-tree allocation, negligible next to
  N surfaces; and it preserves the `perf(tabs): reuse content containers across
switches` steady state (it only drops the near-worthless lazy initial build).
  Hidden surfaces stay occluded via `syncSurfaceVisibility()` (last pass,
  `occlusion=false` for non-visible), so no render churn after the first
  reconcile. Issue #31's scrollback-read leak is about reading, not surface count
  -- eager doesn't touch it. The "20-tab rapid switch" + "snapshot restore" QA
  items are the empirical gate.
- **Container shape excludes payload.** With panes in the tree, `ContainerShape`
  must derive from structure + leaf ids + zoom only -- naive `rootNode` equality
  would rebuild containers on every pane metadata edit. The projection test pins
  this.
- **Host-local cache coherence across rebuilds.** A diffed cache holds the last
  _applied_ value, but a rebuilt host view loses what was applied. `reconcile`
  ordering (containers before chrome) plus the executor's
  `paneToolbar`/`searchOverlay` invalidation for rebuilt/removed containers
  re-applies chrome onto fresh wrappers; the focus border survives on the
  persisted `TerminalView`. The chrome-invalidation test is the net -- a silent
  skip here would leave a rebuilt pane chrome-less.
- **Rename guard must stay narrow.** Suppressing _all_ ops for the editing row
  would strand a row if another `send()` moves/closes that tab mid-edit. The guard
  suppresses only same-row `reload`s; structural ops apply and clear
  `sidebarRenameTarget` when the target disappears. The edited-target-removal
  op-application test is the net.
- **Theme application is a command.** Config reload reapplies all themed panes
  regardless of name change; a projection diff would skip it. Kept as a command.
- **Scrollback join (step 2).** One pure `graftScrollback(onto: AppModelSnapshot,
scrollbackByPaneId:)` walks the embedded tree and sets each leaf's scrollback;
  both export and the enriched checkpoint call it, fed by the one impure
  `scrollbackByPaneId()` live-surface read (manual QA step 11). The pure graft test
  is the net. Step 1 sidesteps this entirely by keeping the flat array.
- **Blast radius, contained by sequencing.** One stage at a time, shippable and
  bisectable; the NSOutlineView diff lands isolated (stage 5); the rename last.
- **Ordered-pass op-lists are tested; executors are thin.** The two riskiest
  AppKit passes (sidebar row diff, container teardown/visibility) compute pure
  `Equatable` op-lists (`computeSidebarRowOps`/`computeContainerOps`) under unit
  test; only the trivial executors that apply ops to `NSOutlineView`/the container
  view tree are manual-QA-only.
- **Command-phase ordering.** `makeFirstResponder`/`focusSearchField`
  post-reconcile, `focusSurface` pre-reconcile; `isPostReconcile` is exactly
  those two (exhaustive switch + test). QA 6/7 and foreground create-tab failure
  are the net.

---

# Implementation Notes

Per-stage notes from each stage's implementor, added as work lands. Each stage
appends its own `### Stage N` subsection (what shipped, deviations from the
plan, and handoffs for later stages).

### Stage 1 -- Tree-owns-panes, live model (wire format unchanged)

Landed. `just test` 961/961 (953 prior + 8 new), `just build` clean.

**What shipped (the live-model half of 1a + snapshot step 1 only):**

- `SplitNodeModel.leaf(PaneModel)`; `AppModel.panes` deleted; added
  `pane(_:)` / `allPanes` / `allPaneIds` / `updatePane(_:_:)` (extension in
  `Model.swift`). No stored index -- `updatePane` is a spine rebuild via the new
  free helper `updatePaneInNode`; `pane`/`allPanes` walk the tree
  (`paneInNode`/`panesInNode` in `ModelOperations.swift`). `allPaneIds` is
  `allPanes.map(\.id)` (avoids a name clash with the free `allPaneIds(_:)`).
- Tree helpers thread the `PaneModel`: `removeLeaf` returns
  `(tree, focus, removed: PaneModel?)`; `splitLeaf`/`insertAtLeaf` take a
  `PaneModel`; `swapLeaves`/`swapLeavesInner` swap whole leaf payloads;
  `moveLeaf` = `removeLeaf` (capture `removed`) + `insertAtLeaf(removed)`.
- The 8 dual-write handlers no longer touch a dict; the move handlers carry
  `removed` into the target leaf.
- Snapshot **step 1 only**: `parseSplitNode` attaches the built `PaneModel` to
  each leaf (decode); `toSnapshot` reads each leaf's `PaneModel` (encode). Every
  existing check + the `autoPaneIds` logic kept; restore chrome still from
  `deriveTabChromeFromSnapshot`. Wire stays **v1, flat `panes` array,
  byte-compatible**.
- New `tests/TreeOwnsPanesTests.swift` (registered in `TestHarness`) holds the
  Part-1 behavioral tests. The `swapLeaves` and `insertAtLeaf`-via-`.movePane`
  payload tests were confirmed to go red against a naive bare-id leaf rebuild
  before the threaded impl was restored -- the "Tree-helper carry-through" net.

**Deviations / judgment calls:**

- **Orphan-injection test rewrite.** The plan said rewrite to "split on an
  unknown PaneId -> null reply." But an unknown pane no longer _resolves_
  (`resolveTargetPane` throws), so IPC returns an invalid-params error
  (`-32602`), not a null `pane` reply -- the null path required a pane that
  resolved but was orphaned from the tree, now structurally impossible. The
  explicit-unknown-pane error case was already covered by an adjacent test, so
  the orphan test now uses the _context_ path and asserts rejection + unchanged
  `allPaneIds`.
- **The `.leaf(...)` migration was a separate, larger sweep than the
  `model.panes` count implied** (~108 test + ~30 app sites). Constructions
  became `.leaf(PaneModel(id: id))`; the 22 `case .leaf(let X)` pattern-matches
  bind a `PaneModel` and use `X.id`.
- **Optional `model[id]` subscript skipped** -- dead weight once every site uses
  `model.pane(id)`.
- **Two synthetic zoom display nodes** in `AppRuntime` (`.leaf(focusedPaneId)`)
  use `model.pane(id) ?? PaneModel(id: id)`; the consumer only reads `.id`.

**Handoffs for later stages:**

- _Stage 2 (1a step 2): DONE -- see the Stage 2 notes below._ The codec is now
  leaf-embedded v2: `SplitNodeSnapshot.leaf(PaneSnapshot)`, and `AppModelSnapshot`
  has no flat `panes` array. `loadValidatedInitFile` now requires `version == 2`
  (rejects v1/v3+). `enrichSnapshot` is **deleted**, replaced by the pure
  `graftScrollback(onto:scrollbackByPaneId:)` + the impure
  `AppRuntime.scrollbackByPaneId()`. `mergeCheckpoints` now merges on the
  validated `ValidatedAppRestore` pair (grafts enriched scrollback into light's
  `paneSnapshots` map by id), not the flat array.
- _Stage 5 (1b):_ `RenameTarget` is still a `private enum` in `SidebarView`; no
  `ViewLocalState` exists yet.
- _Stage 8 (1c):_ `.destroySurface` is still emitted in 4 handlers (closePane /
  surfaceCreationFailed / deleteGroup / closeTabBody); the
  `surfaceCreationFailed` split-tab test asserts one per sibling and must migrate
  when teardown moves to `reconcileSurfaceExistence`.
- `Effect` not renamed (Stage 9). Side-tables (`searchState`,
  `lastNotificationTime`, runtime `surfaces`, etc.) remain `[PaneId: ...]` with
  cleanup in the destruction handlers, not folded into `removeLeaf`.

### Stage 2 -- One leaf-embedded snapshot format (v2)

Landed. `just test` 964/964 (961 prior + 3 new step-2 tests; the migration kept
the prior count by reshaping in place), `just build` clean.

**What shipped (1a step 2 -- the wire-format swap only; Part 2 untouched):**

- `SplitNodeSnapshot.leaf(paneId: String?)` -> `leaf(PaneSnapshot)`; a leaf
  encodes/decodes its pane under a `pane` key. `AppModelSnapshot` lost its flat
  `panes` array (now `{ groups, selectedTabId }`); `AppInitFile` keeps
  `{ version, model }`. No `PersistedInitFile`/`PersistedModelSnapshot`/
  `PersistedSplitNode` parallel hierarchy (the discarded design).
  `PaneSnapshot.scrollback` is now a `var`.
- Decoder (`validateAndBuildDetailed` + `parseSplitNode`): walks the embedded
  tree, building each leaf's `PaneModel` from its embedded `PaneSnapshot` and
  collecting the returned `[PaneId: PaneSnapshot]` map from the leaves. The
  orphan / missing-pane / cross-tree-dup checks are gone (structurally
  impossible); one walk-wide `seenPaneIds` check keeps leaf-id uniqueness, and
  the global `allIds` cross-domain guard stays. `autoPaneIds`/`autoPaneCursor`
  deleted -- an id-less leaf mints a fresh `PaneId` inline. Restore chrome
  derives from the focused leaf's embedded `PaneSnapshot`
  (`deriveTabChromeFromSnapshot`), recomputed at decode.
- Encoder: `toSnapshot`/`toSplitNodeSnapshot` emit the embedded shape via a new
  private `toPaneSnapshot(_:)` (scrollback nil); the flat-array accumulator +
  cross-tab dedup are gone. This one encoder serves `ls` (`Update` IPC),
  `.exportState`, import, and the checkpoints.
- Scrollback: `enrichSnapshot` **deleted**. New pure
  `graftScrollback(onto:scrollbackByPaneId:)` in `ModelOperations` walks the
  embedded tree and sets each matching leaf's scrollback; the impure
  `AppRuntime.scrollbackByPaneId()` reads live surfaces. Both
  `performEnrichedCheckpoint` and the `.exportState` perform-arm now
  `graftScrollback(onto: <snapshot>, scrollbackByPaneId: scrollbackByPaneId())`.
- Version: `appInitFileVersion = 2` constant; `toInitFile(_:)` plus a new
  `toInitFile(snapshot:)` overload centralize the written version (used by the
  checkpoint + export paths). `loadValidatedInitFile` guards
  `version == appInitFileVersion`, rejecting v1 and v3+ with no dispatch fork.
- `mergeCheckpoints(light:enriched:)` now takes/returns `ValidatedAppRestore` and
  grafts `enriched.paneSnapshots[id].scrollback` into light's map by id (light
  authoritative; no re-validation, no tree walk). `main.swift` passes the
  validated pair; `delegate.lastSessionSnapshot` is now `ValidatedAppRestore?`;
  added `AppRuntime.bootstrapFromValidatedRestore(_:)` so the recovered structure
  is validated exactly once (in `main`). `bootstrapFromSnapshot` (the `--init`
  path) validates then delegates to it.
- `integrations/danterm/SKILL.md` updated in the same change: the `ls` recipe
  recurses the tree (`.. | objects | select(.type=="leaf") | .pane`), and the
  shape prose + stdout table now say `{groups, selectedTabId}` with each pane
  embedded at its `rootNode` leaf under `.pane`.

**Deviations / judgment calls:**

- **`pane` is optional on decode.** A bare `{ "type": "leaf" }` decodes to an
  empty `PaneSnapshot` then mints an id -- preserving the exact v1 omitted-leaf
  authoring affordance, not just the omitted-id one. Encode always writes `pane`.
- **`scrollback` made `var`** (was `let`) so graft/merge set it in place instead
  of rebuilding the struct (which had risked silently dropping `todos`).
- **`toInitFile(snapshot:)` overload** so the enriched-checkpoint and export
  paths share the one version constant instead of repeating literal `2`s.
- **Session loss on first post-upgrade launch is via the version guard, not a
  decode failure.** A v1 checkpoint still decodes structurally under the new
  types (the unknown `panes` key is ignored; a missing `pane` defaults), but
  `loadValidatedInitFile`'s `version == 2` guard rejects it -> fresh session.
  Accepted (reject-v1); no one-shot importer.
- **TDD reds confirmed against broken impls:** the two marquee tests (written
  pre-impl) failed for the right reason (version 1; top-level `panes` present);
  the chrome-from-focused-leaf test was confirmed red ("Sibling != Editor")
  against a decoder that read `firstLeafId` instead of `focusedPaneId` -- it puts
  the focused pane in the _second_ leaf so a first-leaf regression fails it.

**Manual QA still owed (cannot be driven headless):**

- **Step 11 -- restore with scrollback.** The pure tests cover `graftScrollback`
  and the validated-pair merge, but the live-surface read (`scrollbackByPaneId()`)
  end-to-end -> enriched checkpoint -> restore-into-replay-files path is
  GUI-only. A human should run `just build-run`, open a few panes with
  scrollback, quit (writes the enriched checkpoint), relaunch, and confirm
  scrollback restores into every pane. (Also exercises the v1->v2 break: any
  pre-upgrade checkpoint is rejected once, yielding a fresh session.)

**Handoffs for later stages:**

- Part 2 (the reconciler, stages 3-9) is untouched; `Effect` is **not** renamed
  (still Stage 9). The Stage 5 (`RenameTarget`/`ViewLocalState`) and Stage 8
  (`.destroySurface` in 4 handlers; the `surfaceCreationFailed` split-tab test
  still asserts one `.destroySurface` per sibling) handoffs above remain valid.
- New pure helpers available to later work: `graftScrollback(onto:scrollbackByPaneId:)`
  and the test helpers `allPaneSnapshots`/`paneSnapshot(_:in:)` (TestHarness).
- No new index or stored pane state was introduced (the format swap is read/write
  only); the tree remains the single source of truth.

### Stage 3 -- `reconcileFocusBorders` (first reconcile pass + scaffolding)

Landed. `just test` 970/970 (964 prior + 6 new: 3 focus-border projection, 3
`applyDiff`), `just build` clean. This is the first reconcile pass; it stands up
the scaffolding stages 4-8 copy.

**What shipped:**

- **Reconciler scaffolding.** New `app/Reconcile.swift` (app-only, SPM-globbed)
  holds `struct ReconcilerCaches` (one field so far, `focusBorders: [PaneId:
BorderState]`) and `extension AppRuntime { func reconcile(); func
reconcileFocusBorders() }`. `reconcile()` runs `reconcileFocusBorders()` then
  `syncSurfaceVisibility()` (occlusion stays last). `send()` calls `reconcile()`
  where it used to call `syncSurfaceVisibility()` directly; **no command-phase
  split** (single-phase flow preserved -- `isPostReconcile` is Stage 4's).
- **Pure layer in `ModelOperations.swift`** (so the test build, whose `test.sh`
  source list includes `ModelOperations.swift` but not `AppRuntime.swift`/AppKit,
  can cover it): `struct BorderState: Equatable { focused; bell }`,
  `desiredFocusBorders(in:) -> [PaneId: BorderState]` (keyed over `allPanes`;
  `focused = isFocusedAndVisible`, which already encodes the single-pane-tab
  no-green-border rule; `bell = paneHasUnreadAlert`, independent so a single-pane
  tab still shows the red bell), and the generic `applyDiff` exactly as the plan
  specifies, **including the `remove`-on-disappear semantics** (a key absent from
  `desired` invokes `remove` once, then is pruned). `BorderState` reproduces the
  two values the old `.refreshPaneBorder` arm computed before
  `TerminalView.setFocusBorder`; the executor is unchanged, only the computation
  moved into the pure layer.
- **Focus borders migrated off effects.** Deleted the `Effect.refreshPaneBorder`
  case, its `perform` arm, and all 3 emission sites (`paneBecameFirstResponder`'s
  two emissions; `refreshPaneAlertChromeEffects`, now toolbar-only). Deleting the
  case is what forced the compiler to surface every site (app + test). The
  alert-cleared toolbar refresh and downstream chrome stay as commands.
- **Restore + teardown wired.** `tearDownCurrentSession` resets the caches by
  re-init (`caches = ReconcilerCaches()`) alongside the existing
  `surfaceVisibility.removeAll()`, so the first post-restore reconcile is a clean
  build. `commitRestoreSession` routes its post-restore sync through
  `reconcile()` instead of a bare `syncSurfaceVisibility()`.
- **Tests.** Focus-border projection tests in `ModelOperationsTests.swift` (incl.
  single-pane-no-border, bell-on-single-pane, focused-in-split, keyed-over-all-
  live-panes/non-selected-tab-no-border). New `tests/ReconcileTests.swift`
  (`reconcileTests()`, registered in `TestHarness`) holds the `applyDiff` tests:
  only-changed-keys-apply / unchanged-skip / disappeared-key-invokes-remove-once-
  then-prunes / default-no-op-remove-still-prunes. Deleted the `.refreshPaneBorder`
  emission assertions across `UpdateAlertTests` (16 calls + the
  `alertTestHasRefreshPaneBorder` helper), `UpdateGhosttyTests` (2), and
  `UpdatePaneTests` (4); the paired toolbar/model-state assertions (focus handlers
  set/leave `focusedPaneId`, alerts marked read) are preserved.

**Verified finding (the interim-stage cache-coherence subtlety):**
`focusBorders` is exempt from cross-pass invalidation because the border rides
the persisted `TerminalView`. **Confirmed for Stage 3** (where containers are
still effect-built): `TerminalView` is constructed _only_ in `makeTerminalView`;
`SplitContainerView` obtains views via `surfaceLookup: { surfaces[paneId] }`
(`AppRuntime.swift` ~1473) and re-parents the _same_ instance from the `surfaces`
dict on `rebuildTabContainer`. `setFocusBorder` writes `layer.borderWidth/Color`,
which travel with the view instance across re-parenting, so a rebuild does not
drop the border and the value-unchanged diff correctly skips re-applying. The
assumption holds; no invalidation needed.

**Deviations / judgment calls:**

- **`finalizeTabSelection`'s container-build border loop (`AppRuntime.swift`
  ~1524) was deliberately left in place.** It is not an `Effect` emission -- it is
  part of the still-effect-built container path Stage 8 folds into
  `reconcileContainers`. It coexists coherently with `reconcileFocusBorders`
  (identical `isFocusedAndVisible`/`paneHasUnreadAlert` computation, same persisted
  `TerminalView`), so it never diverges from the cache; removing it now would be
  Stage 8 overreach. Stage 8 deletes it when containers move to the reconciler.
- **`surfaceVisibility` stays a standalone cache**, not folded into
  `ReconcilerCaches` ("add only the field you use now"). Teardown resets both
  (`surfaceVisibility.removeAll()` + `caches = ReconcilerCaches()`). A later stage
  may fold it in; `syncSurfaceVisibility()` is otherwise untouched.
- **`AppDelegate.windowDidChangeOcclusionState` keeps calling
  `syncSurfaceVisibility()` directly** -- it is the occlusion callback, not the
  restore path, and borders do not depend on occlusion. Only `send()` and the
  restore commit route through `reconcile()`.
- **Pure-vs-AppKit file split** dictated by `test.sh`'s explicit source list:
  pure projection + `applyDiff` + `BorderState` in `ModelOperations.swift`
  (test-visible); impure passes + `ReconcilerCaches` in app-only
  `app/Reconcile.swift`. `reconcile()`/`reconcileFocusBorders()` are `internal`
  (not `private`) because they live in a cross-file extension that `send()` and
  `commitRestoreSession` call; `caches` is likewise `internal` so the extension
  can reach it.
- **`applyDiff` records `cache[k]=v` even when the `apply` closure no-ops** (e.g.
  `surfaces[k]` nil). Harmless in Stage 3: `createSurface` populates `surfaces`
  synchronously in the command phase before `reconcile()`, so every pane in
  `desired` has a live `TerminalView` at reconcile time, and `setFocusBorder`
  needs only the view (not the ghostty `.surface`). Matches how the existing
  visibility cache behaves.

**Manual QA still owed (cannot be driven headless):**

There is no headless test for actual border _drawing_ -- the executor
(`setFocusBorder`) is unchanged and the projection/diff are the pure nets. A human
should `just build-run` and confirm end-to-end: green focus border follows focus
moves across panes; **single-pane tab draws no green border**; red bell border
appears on background-bell panes and clears on ack; borders correct after tab
switch and zoom toggle; borders correct after snapshot restore (clean-build path).

**Handoffs for later stages:**

- **Where the scaffolding lives:** `reconcile()` + `reconcileFocusBorders()` +
  `ReconcilerCaches` in `app/Reconcile.swift`; `applyDiff` + projections +
  `BorderState` in `app/ModelOperations.swift` (pure, test-covered in
  `tests/ReconcileTests.swift` + `tests/ModelOperationsTests.swift`).
- **Template for adding a pass** (this stage is the exemplar): (1) pure projection
  in `ModelOperations.swift` returning an `Equatable` value; (2) add a cache field
  to `ReconcilerCaches` (resets for free via the `tearDownCurrentSession` re-init);
  (3) a `reconcileX()` in `Reconcile.swift` running the projection through
  `applyDiff` (pass a non-default `remove` for disappear-but-host-survives passes
  like the search overlay), inserted into `reconcile()` _before_
  `syncSurfaceVisibility()`; (4) delete the matching `Effect` case + its `perform`
  arm + every emission site **in the same stage** -- deleting the case makes a
  missed emission a compile error.
- **Stage 4 owns introducing the command-phase split** (`isPostReconcile`, the
  pre/post `perform` partition) that this stage deliberately left out. Stage 3
  kept the single-phase flow per the plan's "No command-phase change."
- **Cache invalidation:** `focusBorders` needs none (host persists, verified
  above). The first host-recreated cache (`paneToolbar`/`searchOverlay`, Stage 4)
  is where the container executor must clear affected keys before its pass --
  `applyDiff`'s "absent-from-cache re-applies" is the mechanism that re-pushes
  value-unchanged chrome onto a fresh wrapper.
- Stage 5 (`RenameTarget`/`ViewLocalState`), Stage 8 (`.destroySurface` still
  emitted in 4 handlers; the `surfaceCreationFailed` split-tab test still asserts
  one per sibling), and Stage 9 (`Effect` -> `Command` rename) handoffs above
  remain valid and untouched.
