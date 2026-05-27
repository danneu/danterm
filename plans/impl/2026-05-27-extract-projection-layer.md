# Refactor: extract the projection layer (and two cohesive clusters) out of ModelOperations.swift

## Context

`app/ModelOperations.swift` has grown to **~2487 lines** (and climbing under
active commits -- it was ~2266 when this plan was first drafted, now ~2487, all
the growth in new reconcile projections) and become a grab-bag.
Its top comment ("Pure model helpers for split trees, snapshots, title-channel
events, and UI text") and the `AGENTS.md` file map ("Pure helpers: split tree
ops, query helpers, bell counts") have both drifted from reality. The file now
holds 28 MARK sections spanning split-tree ops, query helpers, the tab-todo
popover model, restore/export/recovery/IO, the entire view-projection + diff
layer (now including theme-browser, TODO-popover, alerts-popover, and
quit-confirmation projections), reconcile scheduling, and MRU/jump/event-protocol
helpers, and more.

The most important drift is architectural: `app/Reconcile.swift` (the **impure**
half of the reconcile subsystem -- `import Cocoa`, AppKit passes) documents at
its header and in its "add a pass" template that *"Pure projections live in
ModelOperations.swift (AppKit-free, unit tested)."* So the projection layer is
already a named, first-class architectural concern -- the pure counterpart to
Reconcile.swift -- but it has no home of its own; it's buried in the grab-bag,
and Reconcile.swift points at the wrong file.

**Goal:** give the pure projection layer its own named peer file
(`Projections.swift`), pull the two other large self-contained clusters into
their own files, and leave `ModelOperations.swift` as a lean core that matches
a corrected doc. Pure motion of code: no behavior changes.

This is low-risk by construction: `app/` is a **single Swift module**
(`.executableTarget` named DanTerm, `path: "app"`), so moving `internal` free
functions / structs / enums between `.swift` files needs **zero import changes
and zero access-level changes**. The moved code is AppKit-free and the move is
pure motion -- identical code, same module -- so `just build` is what actually
guarantees correctness (it catches stranded `private` helpers and import
mistakes), while the existing behavioral tests over these clusters guard against
an accidental edit slipping in during the move.

## Scope (decided)

**In:** create three new files and shrink `ModelOperations.swift`:

| New file | Source MARK block(s) | ~lines |
|---|---|---|
| `app/Projections.swift` | the full pure view-projection + diff layer: Theme Browser, TODO Popover Projections, Preferences-panel + Pane-Toolbar-text projection slices, Alerts-popover projection slice, View Reconciler, Window Chrome, Sidebar Projection + Row-Op Diff, View Reconciler: Containers (projection/diff symbols only -- the `containerShape` helpers stay), plus the Switcher + Quit-confirmation projection slices | ~780 |
| `app/TabTodo.swift` | tab-todo popover **row model** (rows/drag/reorder); **not** the `*PopoverProjection` types -- see boundary rule | ~300 |
| `app/Persistence.swift` | Restore + Export + Recovery + Session Lock + Scrollback Truncation | ~350 |

(Sizes are approximate and drift with the file; the ~780 for `Projections.swift`
is up from an earlier ~560 estimate because the projection layer has since
gained the theme-browser, TODO-popover, alerts-popover, and quit-confirmation
passes. Navigate by section/symbol name when implementing, not these numbers.)

Result: `ModelOperations.swift` drops to ~1080 lines of split-tree ops, AppModel
queries, termination helpers, a small shared-pure-helpers section, the
alerts-*panel* helpers, the reconcile-scheduling classifier, MRU mutation,
switcher/jump classifiers, event protocol, and tab color -- which genuinely
matches its (corrected) name.

**Out (deliberately):**
- Splitting `update()` (Update.swift, 2571 lines) into per-domain files. It's
  lateral churn that clarifies no layer boundary, forces arbitrary homes for
  cross-domain cases (`movePaneToTab`, `deleteGroup`), and creates
  dual-maintenance (dispatcher route + handler per new `Msg`). The monolith's
  single exhaustive `switch` + single `defer { reconcileMru }` chokepoint are
  genuine merits. If its size ever bites, extract individual giant case-bodies
  into named free functions -- don't file-split.
- Further splitting the small cohesive clusters (MRU mutation, switcher/jump
  classifiers, event protocol; ~100 lines each). They belong with the core;
  splitting them trades "one big file" for "which of N files is this in?".
- Fixing the root cause of the test-script churn. The two hand-maintained
  `swiftc` source lists in `test.sh` / `test-ui.sh` are a standing hazard that
  *every* future `app/` file-split trips over. A follow-up could derive the
  AppKit-free test sources by glob, or move them into a real SwiftPM test target.
  Out of scope here -- this plan just adds the 3 files to both lists.

## The boundary rule

Move a symbol to `Projections.swift` iff its job is to **derive view state from
the model, or diff two such derivations**:

- the `desiredX(in:) -> <Equatable>` projection functions. The full current set
  (each has a matching `reconcileX` pass + `ReconcilerCaches` field in
  `Reconcile.swift`, so all of them move): `desiredFocusBorders`,
  `desiredPaneConfig`, `desiredContainerShapes`, `desiredPaneToolbar`,
  `desiredSearchOverlays`, `desiredSidebar`, `desiredWindowChrome`,
  `desiredSwitcher`, `desiredQuitConfirmation`, `desiredPreferencesPanel`,
  `desiredAlertsPopover`, `desiredPaneTodoPopover`, `desiredTabTodoPopover`,
  `desiredThemeBrowser`,
- their projection structs / Op enums (`BorderState`, `PaneConfigKey`,
  `PaneToolbarRender`, `SearchOverlayRender`, `WindowChromeProjection`,
  `SidebarProjection` + `SidebarTabProjection` + `SidebarGroupProjection`,
  `PreferencesPanelProjection`,
  `SwitcherProjection` + `SwitcherRow`, `QuitConfirmationProjection`,
  `AlertsPopoverProjection` + `AlertRowProjection`, `PaneTodoPopoverProjection`,
  `TabTodoPopoverProjection`, `ThemeBrowserProjection`, `SidebarRowOp`,
  `ContainerOp`),
- the diff helpers (`applyDiff`, `computeSidebarRowOps`, `guardSidebarRenameOps`,
  `advanceSidebarCache`, `computeContainerOps`, `containerOpsStrandVisible`,
  `leafPaneIds`, `chromeInvalidation`, `surfacesToTearDown` -- but **not**
  `containerShape(of:)` / `containerShapeNode`, which are now cross-layer and stay;
  see below),
- and a pure feeder **only if every one of its callers is a projection function
  above** (grep to confirm before moving). Confirmed projection-only, so they
  move: `windowTitle` (sole caller `desiredWindowChrome`), `paneToolbarText`
  (sole caller `desiredPaneToolbar`), `isFocusedAndVisible` (sole caller
  `desiredFocusBorders`).

A feeder with **any** caller outside the projection cluster is a cross-layer
helper and **stays** in `ModelOperations.swift` -- moving it would just rebuild a
smaller grab-bag inside `Projections.swift`. Confirmed cross-layer (each has a
non-projection caller in Update / AppRuntime / a view): `resolveRemoteTheme`
(`Update.swift:670`), `effectiveTheme` (`AppRuntime.swift:1044`),
`formatToolbarLabel` (`PaneWrapperView.swift:251`), `shouldForceSidebarRowEmphasis`
(`SidebarView.swift:480`), the alert-count family `unreadAlertCount` /
`groupUnreadAlertCount` / `totalUnreadAlertCount` (`SidebarView.swift:989`/`666`;
kept together for cohesion), `paneHasUnreadAlert` (`Update.swift:922`),
`isDraftDirty` (no projection caller), `tabTodoRollup` (a count query consumed
by `update()`, termination, and the window-chrome projection), and -- the entry
the strand-key refactor in commit `e7d4576` newly made cross-layer -- the
container-*shape* helpers `containerShape(of:)` / `containerShapeNode` plus their
`ContainerShape` / `ContainerShapeNode` types. `containerShape(of:)` is now called
both by the projection `desiredContainerShapes` (a mover) **and** by the staying
model helpers `todoPopoverStrandKey` / `reconcileTodoPopover` (:2155/:2168), and
`ContainerShape` is a stored field of the staying `TodoPopoverStrandKey` struct
(:2149) -- so by this very rule the shape helpers + types stay. (They came in
*after* this plan's first draft, which is why an earlier draft wrongly moved the
whole Containers section.) Keeping them here preserves the one-way dependency
`Projections.swift -> ModelOperations.swift`: `desiredContainerShapes` calls
`containerShape(of:)` across files, which is fine, whereas moving the shape helper
would force the lean core (`reconcileTodoPopover`) to depend back on
`Projections.swift` for basic shape derivation -- exactly the entanglement this
refactor removes. Gather these under a new
`// MARK: - Shared Pure Helpers` in `ModelOperations.swift` so the projection
boundary stays legible. Projection functions in `Projections.swift` call back
into them freely (same module).

Everything that **mutates** the model or answers a general model query also stays
-- `removePaneSearchState`, the view-swap popover **strand cluster**
(`TodoPopoverStrandKey` / `todoPopoverStrandKey` / `reconcileTodoPopover`, in the
`MRU Tab Switcher` MARK at :2149 -- this replaced the old
`clearTodoPopoverForViewSwap`; it captures/clears `model.todoPopover` and is the
staying caller that pins the container-shape helpers above), `reconcileMru` +
`moveToFront` + `resolveLiveCycle`, the switcher/jump input classifiers, the
**reconcile-scheduling classifier** (`reconcileDecision` + the `ReconcileDecision`
enum, currently in the `DanTerm Event Protocol` section): it's pure but it is
*scheduling* logic, not a projection, so it stays (and the ADR edit below keeps
"reconcile scheduling" attributed to `ModelOperations.swift`). The alerts-*panel*
helpers `AlertTab` / `filteredAlerts` / `alertsEmptyText` also stay -- they back
the alerts side panel, not a reconcile pass. **Note the split inside the `Alert
Helpers` MARK:** the alerts-*popover* **projection** (`AlertRowProjection` +
`AlertsPopoverProjection` + `desiredAlertsPopover`) is a real reconcile pass
(`reconcileAlertsPopover`, cache `caches.alertsPopover`) and **moves** to
`Projections.swift`; only the panel helpers and `paneHasUnreadAlert` stay. And
tab color stays.

## What moves where (by MARK section in ModelOperations.swift)

*Line numbers here are approximate and drift under active commits -- navigate by
MARK-section name and symbol name (both stable), not absolute line numbers.*

**-> `Projections.swift`** (AppKit-free; `import Foundation` only). Whole MARK
sections that are pure projection/diff move intact: `Theme Browser` (:18,
`ThemeBrowserProjection` + `desiredThemeBrowser`), `TODO Popover Projections`
(:619, the four `desired{Pane,Tab}TodoPopover` + `{Pane,Tab}TodoPopoverProjection`
symbols), `View Reconciler` (:1162, includes `PaneConfigKey` + `desiredPaneConfig`),
`Window Chrome Projection` (:1297, includes its `windowTitle` feeder),
`Sidebar Projection + Row-Op Diff` (:1339; the private `sidebarSequenceOps`, sole
caller `computeSidebarRowOps`, goes with it). The remaining sections are **mixed**
-- move only the projection symbols, leaving their cross-layer neighbors behind:
from `View Reconciler: Containers` (:1607) move `desiredContainerShapes`,
`computeContainerOps`, `ContainerOp`, `containerOpsStrandVisible`, `leafPaneIds`,
and `chromeInvalidation`, but **leave behind** `containerShape(of:)` /
`containerShapeNode` and the `ContainerShape` / `ContainerShapeNode` types -- now
cross-layer shared helpers pinned by the staying `reconcileTodoPopover` (see the
boundary rule); `desiredContainerShapes` calls `containerShape(of:)` across files;
`PreferencesPanelProjection` + `desiredPreferencesPanel` (from `Preferences Panel`
:34; `isDraftDirty` stays), `paneToolbarText` (from `Pane Toolbar` :83;
`formatToolbarLabel` stays), the alerts-*popover* projection trio `AlertRowProjection`
+ `AlertsPopoverProjection` + `desiredAlertsPopover` (from `Alert Helpers` :1092;
the panel helpers `AlertTab` / `filteredAlerts` / `alertsEmptyText` /
`paneHasUnreadAlert` stay), and from `MRU Tab Switcher` (:2144) take the switcher
projection types (`SwitcherRow` / `SwitcherProjection` / `desiredSwitcher`) **and**
the quit-confirmation projection (`QuitConfirmationProjection` + `desiredQuitConfirmation`,
which sits at the tail of that section). Also move the projection-only feeder
`isFocusedAndVisible` (:1152, physically under `Alert Helpers`). **Do not** move the
cross-layer feeders interleaved in these ranges -- the alert-count family, the
alerts-panel helpers above, the reconcile-scheduling classifier (`reconcileDecision`),
and the `Pane Theme` section (:4, `resolveRemoteTheme` / `effectiveTheme`, distinct
from the adjacent `Theme Browser` projection section) all stay (see the boundary rule).

**-> `TabTodo.swift`** (pure): the popover **row-model** symbols only -- the
row/drag/reorder `TabTodo*` enums (`TabTodoRow`, `TabTodoEditTarget`,
`TabTodoDropOperation`, `TabTodoReorderStep`), `tabTodoItemCount`,
`buildTabTodoRows`, the `resolveTabTodo*` helpers (`resolveTabTodoEditTarget`,
`newlyAddedTabTodoTarget`, the two `resolveTabTodoDropTarget` overloads,
`resolveTabTodoBucketStep`, `resolveTabTodoReorderStep`), and the private
`tabTodoDestination` / `tabTodoCount` (the `Tab Todo Popover` MARK body, now
~:653-977).

**Name-glob trap (do not mis-file):** the projection types
`TabTodoPopoverProjection` and `PaneTodoPopoverProjection` and their
`desired{Tab,Pane}TodoPopover` functions live in the *separate* `TODO Popover
Projections` MARK (:619, immediately above), **not** in `Tab Todo Popover`. Even
though `TabTodoPopoverProjection` matches the `TabTodo*` name pattern, it is a
reconcile projection (cached as `caches.tabTodoPopover` in `Reconcile.swift`) and
goes to **`Projections.swift`**, not here. After the split, `desiredTabTodoPopover`
(in `Projections.swift`) calls `buildTabTodoRows` (in `TabTodo.swift`) -- its only
non-test caller -- and the `resolveTabTodo*` helpers (in `TabTodo.swift`) take a
`TabTodoPopoverProjection` parameter (defined in `Projections.swift`). Both are
clean cross-file references within the single module; no import or access-level
change. (This is the deliberate feeder-rule exception: `buildTabTodoRows` feeds
only the projection, but it is the heart of the row model and is tested as such,
so it stays with the row model in `TabTodo.swift`.)

**Not** `tabTodoRollup` (~:607): it's a cross-layer count query (callers in
`update()`, termination, and the window-chrome projection), so by the boundary
rule it stays in `ModelOperations.swift` under `Shared Pure Helpers` -- and it
already physically lives in the `Termination Helpers` section, not the popover
block. **Not** the close-tab confirmation helpers either: `closeTabConfirmationResponse`
/ `closeTabsConfirmationResponse` / `closeTabsConfirmationCopy` (now ~:978-1019)
sit under the `Tab Todo Popover` MARK by accident but are termination helpers
(called from `AppRuntime` and `UpdateLifecycleTests`) -- they stay in
`ModelOperations.swift`. Move them up adjacent to the other `Termination Helpers`
(:546) while you're in there, so the section is contiguous.

**-> `Persistence.swift`** (`import Foundation`; pure serialization + thin
FileManager I/O): `Restore` (:1020), `Export` (:1782), `Recovery Paths` (:1915),
`Session Lock I/O` (:1967), `Scrollback Truncation` (:1997). Private helpers
`toPaneSnapshot` / `toSplitNodeSnapshot` / `graftScrollbackIntoNode` move with them.

**Stay in `ModelOperations.swift`:** `Pane Theme` (:4, `resolveRemoteTheme` /
`effectiveTheme` -- distinct from the `Theme Browser` projection section, which
moves), `Sidebar Row Emphasis` (:109, `shouldForceSidebarRowEmphasis`),
`SplitNodeModel Operations` (:120) and its private helpers (`swapLeavesInner`,
`insertAtLeaf`, `enterSubtree`, `buildPath`), `AppModel Query Helpers` (:462),
`Termination Helpers` (:546, now also holding the relocated close-tab confirmation
trio and `tabTodoRollup`), `Search Cleanup` (:102), `Alert Helpers` (:1092)
**minus** `isFocusedAndVisible` **and minus the alerts-popover projection trio**
(`AlertRowProjection` / `AlertsPopoverProjection` / `desiredAlertsPopover`) -- the
panel helpers `AlertTab` / `filteredAlerts` / `alertsEmptyText` /
`paneHasUnreadAlert` stay, a new `Shared Pure Helpers` MARK (the cross-layer
feeders named in the boundary rule, now including the container-shape helpers
`containerShape(of:)` / `containerShapeNode` + the `ContainerShape` /
`ContainerShapeNode` types), `Delete Group` (:1758), `DanTerm Event Protocol`
(:2033, including the reconcile-scheduling classifier `reconcileDecision` /
`ReconcileDecision`), the MRU **mutation** part of `MRU Tab Switcher` (:2144, i.e.
everything before the `SwitcherProjection` / quit-confirmation projection tail that
moves -- this includes the view-swap popover strand cluster `TodoPopoverStrandKey`
/ `todoPopoverStrandKey` / `reconcileTodoPopover` at :2149), `Switcher Event
Classifier` (:2299), `Tab Jump Mode` (:2322), `Sidebar Pure Helpers` (:2416), and
`Tab Color` (:2456).

## Doc + comment edits (must accompany the move)

1. **`app/Reconcile.swift`** -- repoint both references from `ModelOperations.swift`
   to `Projections.swift`: the header (line 4: *"Pure projections live in
   ModelOperations.swift..."*) and template step 1 (line 9: *"a pure projection
   in ModelOperations.swift..."*).
2. **`AGENTS.md`** file map (line 29) -- correct the `ModelOperations.swift`
   description and add the three new files, e.g.:
   ```
   ├── ModelOperations.swift   # Pure model ops: split-tree ops, AppModel queries, MRU/jump/event-protocol, tab color
   ├── Projections.swift        # Pure view projections + diff (AppKit-free peer to Reconcile.swift)
   ├── TabTodo.swift            # Pure tab-todo popover model: rows, drag/drop, reorder
   ├── Persistence.swift        # Model <-> disk: snapshot/export, restore, checkpoints, session-lock, scrollback trunc
   ```
   Also update the `Reconcile.swift` map line if it references projections.
3. **`docs/design/2026-05-27-model-driven-view-reconciliation.md`** (the reconciler
   ADR) -- it currently names `ModelOperations.swift` as the projection home in
   three places, which this refactor falsifies. Update all three:
   - the intended-pass-shape bullet (line 18: *"pure projections and structural
     diff/op helpers live in `ModelOperations.swift`..."*) -> name `Projections.swift`;
   - the new-pass template bullet (line 46: *"put pure projections and structural
     diff/op helpers in `ModelOperations.swift`..."*) -> name `Projections.swift`;
   - the References list (line 171: *"`app/ModelOperations.swift`: pure projections,
     diff/op helpers, reconcile scheduling"*) -> split into two: `app/Projections.swift`
     for pure projections + diff/op helpers, and `app/ModelOperations.swift` for
     shared model helpers + reconcile scheduling (`reconcileDecision`).
   Keep the AppKit-free + unit-tested framing; only the *file name* of the
   projection home changes.
4. **File header comments** (AGENTS.md's named *File header comments* rule, which
   replaced the old generic "every file needs a top comment"): give each new file
   (`Projections.swift`, `TabTodo.swift`, `Persistence.swift`) a **line-1 `//` block**
   above the imports -- **not** `///`. The rule is explicit: a file header uses `//`
   because it describes the file, not a declaration. **Do not** model the headers on
   the neighbor popover files (`TodoPopoverView.swift`, `TabTodoPopoverView.swift`,
   `AlertsPopoverView.swift`) -- they open with `///` and are now non-conforming, so
   they are the wrong template. Per the rule's content bullets, each header should
   convey what the file contains, its intent, **what belongs in it and why it exists
   separately from `ModelOperations.swift`**, and why it earns its own file -- not
   just a one-line label. E.g. `Projections.swift` should say it is the AppKit-free
   pure counterpart to `Reconcile.swift` (every `desiredX` + its diff helpers, the
   unit-test boundary for the reconcile layer), explicitly the home the ADR and
   `Reconcile.swift` template point at. Then rewrite `ModelOperations.swift`'s top
   comment (already a `//` block; currently mentions "snapshots ... and UI text",
   both of which leave) to describe the narrowed core.

## Implementation notes

- **Single module = mechanical move.** Cut symbols and paste into the new file;
  no `import` edits in callers (Reconcile.swift, AppRuntime.swift, view files,
  tests all keep compiling). Default `internal` visibility is module-wide.
- **Pure motion vs. the "Doc comments on declarations" rule -- no `///` backfill.**
  AGENTS.md now requires a `///` doc comment on every *new* type / top-level
  function. This refactor introduces **no new declarations** -- every relocated
  symbol moves verbatim and carries its existing comments (`///` or `//`) unchanged.
  The per-declaration rule is therefore satisfied trivially, and the **only** comments
  this change authors are the four file headers (the 3 new files + the rewritten
  `ModelOperations.swift` header; doc-edit items 3-4). **Do not** backfill `///` onto
  relocated symbols that lack one today: that would forfeit the "identical code, no
  net logic lines, pure motion" guarantee this plan's verification rests on (the
  `git diff --stat` motion check + the behavioral tests). Note for the `review-impl`
  pass: relocated symbols appear as "added" lines in the new files but are **motion,
  not new declarations**, so the per-declaration `///` rule does not govern them.
- **Private-helper rule (the one real gotcha):** a `private` symbol must land in
  the same file as its sole caller. The three private clusters above
  (`sidebarSequenceOps`; `toPaneSnapshot`/`toSplitNodeSnapshot`/
  `graftScrollbackIntoNode`; `tabTodoDestination`/`tabTodoCount`) move with their
  movers. The split-tree private helpers stay (their callers stay). The compiler
  fails immediately if any private symbol is stranded, so this is self-correcting.
- **AppKit-free invariant:** `ModelOperations.swift` imports only `Foundation`
  today. Keep all three new files `import Foundation` only -- do **not** add
  `import Cocoa`. This is what keeps them unit-testable (the reason Reconcile.swift
  is the separate impure half).
- **Two test scripts hand-list sources -- they MUST gain the 3 new files (the
  one real blocker).** `just test` -> `test.sh` and `just test-ui` -> `test-ui.sh`
  do not use SwiftPM's `path: "app"` glob; each invokes `xcrun swiftc` with an
  explicit list of `app/*.swift` files (`test.sh:23-40`, `test-ui.sh:23-30`, both
  naming `ModelOperations.swift`). After the move, files in the compiled set
  reference the relocated symbols -- e.g. `Update.swift:706`/`:1462`/`:2192` call
  `toSnapshot` (Export block -> `Persistence.swift`), `tests/ModelOperationsTests.swift`
  calls `buildTabTodoRows` (-> `TabTodo.swift`), and `PaneToolbarTests` /
  `CustomTitleTests` call `paneToolbarText` / `windowTitle` (-> `Projections.swift`)
  -- one mover per new file, so without the additions the test compile dies with
  "cannot find X in scope." **Fix: add `app/Projections.swift`, `app/TabTodo.swift`,
  `app/Persistence.swift` to the source list in BOTH scripts.** The
  `tests/*.swift` / `tests-ui/*.swift` *contents* need no edits -- in a single
  module the symbols resolve once their defining files are in the compile. (`just
  build` is exempt: the `DanTerm` target globs `path: "app"`, so it picks up new
  files automatically; only the bespoke `swiftc` test scripts carry per-file lists.)

## Critical files

- New: `app/Projections.swift`, `app/TabTodo.swift`, `app/Persistence.swift`
- Modified: `app/ModelOperations.swift` (shrinks ~2487 -> ~1080), `app/Reconcile.swift`
  (2 comment edits), `AGENTS.md` (file map),
  `docs/design/2026-05-27-model-driven-view-reconciliation.md` (3 projection-home
  references: lines 18, 46, 171), and **`test.sh` + `test-ui.sh`** (add the 3 new
  files to their hand-maintained `swiftc` source lists)
- Unchanged: `Package.swift` (the `DanTerm` target globs `path: "app"`, so
  `just build` picks up new files automatically), the *contents* of `tests/*.swift`
  and `tests-ui/*.swift`, all callers in `app/`

## Verification

1. `just test` (after adding the 3 files to `test.sh` + `test-ui.sh` -- see
   Implementation notes; the scripts won't compile otherwise). Existing behavioral
   tests cover the projection, tab-todo, and persistence clusters broadly
   (ModelOperations / Reconcile / Update* / PaneToolbar / CustomTitle / Export /
   Snapshot tests); they must pass unchanged. Coverage is per-cluster, not
   per-symbol -- e.g. `tabTodoItemCount` (~:768, moving to `TabTodo.swift`) still
   has no caller or test today, a pre-existing dead helper left as-is (removing it
   is out of scope here).
2. `just test-ui` -- run it explicitly: `just test` does **not** (it's a separate
   justfile target -> `test-ui.sh`), and `just build` goes through `Package.swift`,
   so the `test-ui.sh` source-list edit is otherwise exercised by nothing. The
   implementer is on macOS with a display, so this runs. If for some reason it
   can't, verify the `test-ui.sh` edit by inspection -- diff its source-list change
   against `test.sh`'s -- rather than silently trusting it.
3. `just build` -- the real guardrail for pure code motion: confirms the whole
   app compiles, catching any stranded `private` helper or accidental
   `import Cocoa`.
4. `git diff --stat` sanity check: the diff should be ~pure motion -- large
   deletions from `ModelOperations.swift`, matching additions in the three new
   files, plus the small doc/comment edits. No net logic lines added.
5. Optional spot-check: `grep -rn "import Cocoa\|import AppKit" app/Projections.swift
   app/TabTodo.swift app/Persistence.swift` returns nothing.

## Implementation notes (added during impl)

- `effectiveTheme` stale citation: the boundary rule cited `AppRuntime.swift:1044` as
  `effectiveTheme`'s cross-layer caller, but no such caller exists anymore -- its only
  non-test caller is the *moving* projection `desiredPaneConfig`. Kept it in the
  `Pane Theme` section anyway, per the plan's explicit "stay" decision: it is paired
  with the genuinely cross-layer `resolveRemoteTheme` (`Update.swift:631`), and
  splitting a cohesive two-function section to chase one projection-only feeder would
  be worse. Placement is compile-irrelevant (internal symbol, single module).
- `Shared Pure Helpers` composition: the boundary rule and the "Stay in" list were
  slightly inconsistent about the section's contents. Resolved by placing there exactly
  the cross-layer feeders whose original MARK section is *fully vacated* by the
  projection move -- `formatToolbarLabel` (Pane Toolbar), `isDraftDirty` (Preferences
  Panel), the alert-count family (View Reconciler), and the container-shape
  helpers/types (View Reconciler: Containers) -- while leaving the explicitly-named
  surviving sections (Pane Theme, Sidebar Row Emphasis, Alert Helpers panel, Termination
  Helpers) intact with their own cross-layer feeders. This matches the "Stay in" list
  omitting "Pane Toolbar"/"Preferences Panel" as standalone sections.
- Assembled by byte-exact line-slicing of the original (not retyping), gated on a
  code-line invariant asserting every non-comment, non-blank source line is preserved
  exactly once across the four files -- the machine check behind the "identical code,
  pure motion" guarantee, complementing `just build`.

## Follow Up

- Pre-existing `just test-ui` compile break (NOT caused by this refactor; the relevant
  files are byte-identical to HEAD): `tests-ui/SidebarSelectionCacheTests.swift:203`
  (the `makeTab` helper) calls `TabModel(id:title:focusedPaneId:rootNode:)`, but
  `TabModel.title` is a computed read-only property (`app/Model.swift:126`), not an
  init parameter -- so the UI-test target fails to compile before any test runs. Fix:
  set `customTitle:` (or drop the argument) in the helper. This blocked full
  `just test-ui` validation here; the `test-ui.sh` source-list edit was instead verified
  by inspection (it matches `test.sh`'s), and the three new files compiled cleanly in
  the UI-test set (no "cannot find in scope" errors).
