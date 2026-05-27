# Plan: Resolve `findPaneWrapper` via a `TerminalView` back-pointer (not a parallel index)

## Context

`AppRuntime.findPaneWrapper(for:in:)` (`app/AppRuntime.swift:1281`) resolves a `PaneId`
to its `PaneWrapperView` by recursively walking the NSView subtree under `contentArea`.
It is called for every pane whose toolbar or search-overlay render changes during
`reconcilePaneChrome` (`app/Reconcile.swift:182,196,199`) -- a path that fires on
title/cwd/progress/alert/todo changes across all live panes -- plus four more sites:
search-field focus (`app/AppRuntime.swift:612`), TODO popover anchoring (`:665`), the
pane-drag frame provider (`:964`), and mount-time search focus (`:1369`).

This is a `PaneId`-keyed lookup implemented as a tree scan, even though a fully
lifecycle-managed `PaneId` index already exists: `surfaces: [PaneId: TerminalView]`
(`app/AppRuntime.swift:25`), maintained by `reconcileSurfaceExistence` / `tearDownSurface`.

The original review proposed adding a *second* `[PaneId: PaneWrapperView]` index with
manual population on build and manual pruning on rebuild/removal. That duplicates
`surfaces` and reintroduces exactly the host-recreated-cache drift hazard the reconciler
already engineers around (see the `ReconcilerCaches` comments + `chromeInvalidation`,
`app/Reconcile.swift:25-36`, `104-112`). Manual pruning across every rebuild site is fragile.

**Pivot:** ride the existing `surfaces` index. Give `TerminalView` a weak back-pointer to
its wrapper, set in `PaneWrapperView.init` and cleared in its `deinit`. No new dictionary,
no manual pruning, self-healing across rebuilds. Net effect: ~3 small edits plus a
one-line method body, and a strictly smaller, more honest API.

## Approach

### 1. Add a weak back-pointer to `TerminalView` (`app/TerminalView.swift`)

Alongside the existing `weak var runtime` / `weak var scrollDelegate` (lines 22, 27), add:

```swift
// Back-pointer to the wrapper currently hosting this terminal, set by PaneWrapperView.init
// and cleared in its deinit. Lets AppRuntime.findPaneWrapper resolve PaneId -> wrapper via the
// existing `surfaces` index instead of a recursive view-tree scan. Weak: the wrapper owns us.
weak var paneWrapper: PaneWrapperView?
```

### 2. Set / clear the pointer in `PaneWrapperView` (`app/PaneWrapperView.swift`)

- Immediately after `super.init(frame: .zero)` (line 78): `terminalView.paneWrapper = self`.
- Add a `deinit` that clears it only when still pointing at self:

```swift
deinit {
    // Only clear if we are still the current wrapper. A rebuild constructs the new wrapper
    // (which re-points the back-pointer) before the old one deallocates, so the `===` guard
    // stops a late deinit from clobbering the live pointer.
    if terminalView.paneWrapper === self { terminalView.paneWrapper = nil }
}
```

Why both halves:
- `init` makes the newest wrapper win immediately. Every container rebuild constructs a
  fresh wrapper (`SplitContainerView.buildView`, `app/SplitContainerView.swift:79`) that
  overwrites the pointer, so for any *displayed* pane the back-pointer always references the
  live wrapper -- equivalent to the old scan.
- `deinit` + `===` guard restores exact parity for a *zoomed-away* pane (live in the model
  but with no mounted wrapper, because `buildAndInsertContainer` builds only the focused leaf
  when zoomed, `app/AppRuntime.swift:1296-1303`): the removed wrapper nils the pointer on
  dealloc, so the lookup returns nil just as the recursive scan did.

### 3. Reduce `findPaneWrapper` to the index lookup (`app/AppRuntime.swift:1281-1290`)

Replace the recursive method with:

```swift
// Resolve a pane's live wrapper via the `surfaces` PaneId index + the wrapper back-pointer,
// replacing a recursive contentArea subtree scan. A pane belongs to exactly one tab, so it has
// at most one mounted wrapper; the back-pointer references that wrapper (or nil when the pane is
// zoomed away / not mounted). `internal` (not private) so Reconcile.swift can reach it.
func findPaneWrapper(for paneId: PaneId) -> PaneWrapperView? {
    surfaces[paneId]?.paneWrapper
}
```

Drop the now-unused `in view:` parameter and update all 7 call sites to `findPaneWrapper(for:)`:
`app/AppRuntime.swift:612,665,964,1369` and `app/Reconcile.swift:182,196,199`. Dropping the
parameter is deliberate: it makes the lookup honestly global-by-PaneId rather than implying
caller-controlled subtree scoping. The one scoped caller (`app/AppRuntime.swift:1369`,
`in: container`) targets `tab.focusedPaneId`, which is always mounted in that tab's container,
so the global lookup is equivalent.

## Correctness basis (verified against the code, not assumed)

- **Displayed (selected-tab) panes:** equivalent to the old scan -- each rebuild's fresh wrapper
  `init` overwrites the back-pointer, so it always references the live wrapper.
- **Background-tab (mounted-but-hidden) panes:** under eager mounting, `reconcileContainers`
  builds every tab's container -- selected visible, the rest hidden -- so a background tab's pane
  has a live, mounted wrapper that is simply not displayed. The old scan was global over
  `contentArea` (a hidden container is still a subview, so the recursion resolved background-tab
  panes), and `surfaces[paneId]?.paneWrapper` is equivalently global, so a hidden mounted pane
  resolves to its wrapper identically. A tab switch is a `setVisible` op
  (`app/Reconcile.swift:144-148`) that only toggles `isHidden` and never rebuilds wrappers, so the
  pointer set at build time stays valid across switches.
- **Zoomed-away panes:** `desiredPaneToolbar` is keyed over all live panes
  (`app/ModelOperations.swift`, `for pane in model.allPanes`), so chrome updates still fire for
  a pane with no mounted wrapper. Old scan returned nil; back-pointer returns nil too once the
  removed wrapper deallocates (the `deinit` clear). The brief pre-dealloc window can update a
  detached, offscreen wrapper -- harmless wasted work, never visible, never the wrong *visible*
  wrapper.
- **Unzoom / movePane:** the rebuilt tab's new-shape leaves are cache-invalidated
  (`chromeInvalidation`, `app/ModelOperations.swift:1554`) before `reconcilePaneChrome`, which
  re-pushes chrome onto the fresh wrappers. `applyDiff` advances the cache even when an executor
  no-ops (`cache[k] = v` runs regardless), so no stuck state. (`app/Reconcile.swift:104-112`.)
- **Lifecycle:** nothing but the view tree retains a `PaneWrapperView` -- `PaneDragCoordinator`,
  the TODO popover adapter, `SearchOverlayView`, and `TerminalView` hold only weak / `PaneId` /
  closure refs -- so a removed wrapper deallocates within a frame and the `deinit` fires promptly.

## Out of scope

`SplitContainerView.findPaneSplitViewIn` (`app/SplitContainerView.swift:61`) is the same
recursive-scan-by-id shape but keyed on `SplitId`, runs only during `rebuild()`/`applyRatios`
on the freshly built local subtree (cold path), and has no existing index to ride. Not worth
unifying now.

## Verification

This is a view-layer change with no pure-unit-testable seam: the test target links neither
Cocoa nor GhosttyKit (`test.sh`, `tests/TestHarness.swift`), and `TerminalView.init` requires a
live `ghostty_surface_new` (`app/TerminalView.swift`), so a `PaneWrapperView` / `TerminalView`
cannot be constructed in the pure suite. No existing test instantiates AppKit views
(`tests/ReconcileTests.swift` explicitly marks reconcile passes "manual-QA-only"). Verify by
compile + runtime:

1. **Compile gate:** `just build` -- the signature change must propagate cleanly to all 7 call
   sites.
2. **Runtime (`just build-run`)**, exercising each path that depends on `findPaneWrapper`:
   - Multi-split tab: run commands that change titles/cwd in different panes; each pane's
     toolbar label updates on the correct pane.
   - Background-tab update: with tab A visible, run a title-changing command in tab B's pane,
     then switch to B; the toolbar shows the update (confirms the back-pointer resolves a hidden,
     mounted pane, and that a tab switch does not rebuild or re-push).
   - Cmd-F search on the focused pane: overlay appears, search field takes focus, match count
     updates, Esc hides it (covers `:612`, `:196`, `:199`, `:1369`).
   - Zoom a pane then unzoom: toolbar (and an active search overlay) reappear on the rebuilt
     pane.
   - Open a pane's TODO popover from the toolbar: it anchors on the correct pane (covers `:665`).
   - Drag a pane by its toolbar handle across panes/tabs: drop targeting highlights the correct
     panes and the move lands (covers `:964`); the moved pane's toolbar still updates afterward.
3. **`just test`** to confirm the pure suite still passes (unchanged, but guards against
   accidental breakage).
