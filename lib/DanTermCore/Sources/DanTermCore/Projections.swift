// Pure view projections + structural diff/op helpers: the AppKit-free counterpart
// to Reconcile.swift. Each `desiredX(in:) -> Equatable` projection pairs with a
// `reconcileX` pass and a `ReconcilerCaches` field in Reconcile.swift; the diff
// helpers (`applyDiff`, `computeSidebarRowOps`, `computeContainerOps`, and the
// rename/cache/strand guards) turn two projections into the minimal patch a pass
// applies. This is the home the reconciler ADR and Reconcile.swift's "add a pass"
// template point at, and the unit-test boundary for the reconcile layer: derive view
// state from `AppModel` here (purely), apply it to Cocoa there. Keep it
// `import Foundation` only -- no AppKit -- which is what keeps the projection layer
// testable without Cocoa or GhosttyKit. Cross-layer model helpers these call back into
// (queries, alert counts, container shapes) stay in ModelOperations.swift; this earns
// its own file as the named pure peer of Reconcile.swift.
import Foundation

// MARK: - Theme Browser

/// Pure value describing the model-derived content shown in the theme browser.
struct ThemeBrowserProjection: Equatable {
    var currentThemeName: String?
}

/// Project the focused pane's user-set theme for the selected tab. This reads
/// `pane.theme`, not `effectiveTheme`, so remote theme overrides do not move
/// the browser checkmark.
func desiredThemeBrowser(in model: AppModel) -> ThemeBrowserProjection {
    ThemeBrowserProjection(
        currentThemeName: selectedTab(in: model).flatMap { model.pane($0.focusedPaneId)?.theme }
    )
}

// MARK: - Preferences Panel

/// Pure value describing the visible preferences panel state.
struct PreferencesPanelProjection: Equatable {
    var selectedAlertClearMode: AlertClearMode
    var remoteThemeText: String
    var ghosttyThemeText: String
    var fontSizeText: String
    var ghosttyThemeDirtyLabel: String?
    var fontSizeDirtyLabel: String?
    var alertClearModeDirtyLabel: String?
    var remoteThemeDirtyLabel: String?
    var saveEnabled: Bool
}

/// Project the preferences panel from the model. nil means no draft is open, so
/// the runtime has no preferences UI to update and clears the reconcile cache.
func desiredPreferencesPanel(in model: AppModel) -> PreferencesPanelProjection? {
    guard let draft = model.preferencesDraft else { return nil }

    let committed = model.config
    let ghostty = model.committedGhosttyPrefs
    let ghosttyThemeDirty = draft.theme != ghostty?.theme
    let fontSizeDirty = draft.fontSize != ghostty?.fontSize
    let alertDirty = draft.alertClearMode != committed.alertClearMode
    let remoteThemeDirty = resolveRemoteTheme(draft.remoteTheme) != committed.remoteTheme

    let alertDisplayValue = committed.alertClearMode == .focus ? "Focus" : "Manual"
    return PreferencesPanelProjection(
        selectedAlertClearMode: draft.alertClearMode,
        remoteThemeText: draft.remoteTheme,
        ghosttyThemeText: draft.theme ?? "",
        fontSizeText: draft.fontSize ?? "",
        ghosttyThemeDirtyLabel: ghosttyThemeDirty ? "Prev: \(ghostty?.theme ?? "(default)")" : nil,
        fontSizeDirtyLabel: fontSizeDirty ? "Prev: \(ghostty?.fontSize ?? "(default)")" : nil,
        alertClearModeDirtyLabel: alertDirty ? "Prev: \(alertDisplayValue)" : nil,
        remoteThemeDirtyLabel: remoteThemeDirty ? "Prev: \(committed.remoteTheme)" : nil,
        saveEnabled: ghosttyThemeDirty || fontSizeDirty || alertDirty || remoteThemeDirty
    )
}

// MARK: - Pane Toolbar

func paneToolbarText(for paneId: PaneId, in model: AppModel) -> (title: String, cwd: String?) {
  guard let pane = model.pane(paneId) else {
    return (title: "Terminal", cwd: nil)
  }
  return (title: pane.title, cwd: pane.cwd)
}

// MARK: - TODO Popover Projections

struct PaneTodoPopoverProjection: Equatable {
  let paneId: PaneId
  let rows: [TodoItem]
  let hasCompleted: Bool
}

func desiredPaneTodoPopover(paneId: PaneId, in model: AppModel) -> PaneTodoPopoverProjection? {
  guard let pane = model.pane(paneId) else { return nil }
  return PaneTodoPopoverProjection(
    paneId: paneId,
    rows: pane.todos,
    hasCompleted: pane.todos.contains(where: \.isDone)
  )
}

struct TabTodoPopoverProjection: Equatable {
  let tabId: TabId
  let rows: [TabTodoRow]
  let paneOrder: [PaneId]
  let tabHasCompleted: Bool
}

func desiredTabTodoPopover(tabId: TabId, in model: AppModel) -> TabTodoPopoverProjection? {
  guard let tab = tabById(tabId, in: model) else { return nil }
  return TabTodoPopoverProjection(
    tabId: tabId,
    rows: buildTabTodoRows(model: model, tabId: tabId),
    paneOrder: allPaneIds(tab.rootNode),
    tabHasCompleted: tab.todos.contains(where: \.isDone)
  )
}

// MARK: - Alerts Popover

struct AlertRowProjection: Equatable {
  let id: AlertId
  let kind: AlertKind
  let title: String
  let body: String
  let createdAt: Date
  let isUnread: Bool
}

struct AlertsPopoverProjection: Equatable {
  let rows: [AlertRowProjection]
  let showAll: Bool
  let markAllVisible: Bool
  let emptyText: String?
}

/// Project the alert feed rows and controls for an open alerts popover.
func desiredAlertsPopover(in model: AppModel) -> AlertsPopoverProjection {
  let tab: AlertTab = model.showAllAlerts ? .history : .unread
  let displayed = filteredAlerts(model.alerts, tab: tab)
  return AlertsPopoverProjection(
    rows: displayed.map {
      AlertRowProjection(
        id: $0.id,
        kind: $0.kind,
        title: $0.title,
        body: $0.body,
        createdAt: $0.createdAt,
        isUnread: $0.isUnread
      )
    },
    showAll: model.showAllAlerts,
    markAllVisible: model.alerts.contains(where: \.isUnread),
    emptyText: displayed.isEmpty ? alertsEmptyText(tab: tab) : nil
  )
}

// MARK: - View Reconciler (pure projections + diff)
//
// These projections intentionally prefer local model reads over a shared
// precomputed reconcile input. Focus borders, pane toolbar, and pane config walk
// `model.allPanes` during each reconcile sweep; alert-derived renders rescan
// `model.alerts` per pane, which is O(panes x alerts). That is accepted because
// rapidly-firing title/cwd/progress updates are coalesced to about 75ms by
// `AppRuntime.reconcileCoalesceInterval` / `Msg.coalescesReconcile`, while
// inline reconciles are human-paced (tab/pane creation, focus, sidebar ops).
// `model.alerts` is hard-capped at 100, pane/tab counts are expected to stay
// human-scale, and reconcile never runs per render frame or typed keystroke. See
// `Projection Scan Cost` in `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// Return whether a pane should show the green focus border in the current content view.
func isFocusedAndVisible(_ paneId: PaneId, in model: AppModel) -> Bool {
  guard let tab = selectedTab(in: model),
    tab.focusedPaneId == paneId
  else {
    return false
  }
  if case .leaf = tab.rootNode { return false }
  return true
}

/// Per-pane focus-border state the reconciler diffs and pushes to a TerminalView.
/// `focused` drives the green focus border, `bell` the red unread-alert border --
/// exactly the two values the old `.refreshPaneBorder` executor computed before
/// calling `TerminalView.setFocusBorder`. Equatable so the diff can skip unchanged panes.
struct BorderState: Equatable {
  let focused: Bool
  let bell: Bool
}

/// Focus-border projection: one `BorderState` per live pane. Keyed over every pane
/// (`allPanes`) so a pane leaving the model drops its key and the reconciler's
/// `applyDiff` prunes the cache. `isFocusedAndVisible` already encodes the
/// single-pane-tab rule (a lone leaf draws no green border); `bell` is independent,
/// so a single-pane tab can still show the red unread-alert border.
func desiredFocusBorders(in model: AppModel) -> [PaneId: BorderState] {
  var result: [PaneId: BorderState] = [:]
  for pane in model.allPanes {
    result[pane.id] = BorderState(
      focused: isFocusedAndVisible(pane.id, in: model),
      bell: paneHasUnreadAlert(pane.id, alerts: model.alerts)
    )
  }
  return result
}

/// Pane-toolbar render the reconciler diffs and pushes to a PaneWrapperView's
/// toolbar. Carries exactly the eight values the old imperative `refreshPaneToolbar`
/// read from the model before calling `PaneWrapperView.updateToolbar`. Equatable so
/// the diff skips panes whose toolbar inputs are unchanged.
struct PaneToolbarRender: Equatable {
  let title: String
  let cwd: String?
  let progress: ProgressState?
  let isRemote: Bool
  let remoteSession: RemoteSession?
  let unreadAlertCount: Int
  let totalTodoCount: Int
  let uncompletedTodoCount: Int
}

/// Pane-toolbar projection: one `PaneToolbarRender` per live pane. Keyed over every
/// pane (`allPanes`) so a key leaves only when its pane is gone -- at which point the
/// container pass has already torn down the host wrapper -- so `reconcilePaneChrome`
/// diffs this with the default no-op `remove`.
func desiredPaneToolbar(in model: AppModel) -> [PaneId: PaneToolbarRender] {
  var result: [PaneId: PaneToolbarRender] = [:]
  for pane in model.allPanes {
    let (title, cwd) = paneToolbarText(for: pane.id, in: model)
    result[pane.id] = PaneToolbarRender(
      title: title,
      cwd: cwd,
      progress: pane.progress,
      isRemote: pane.isRemote,
      remoteSession: pane.remoteSession,
      unreadAlertCount: model.alerts.count { $0.paneId == pane.id && $0.isUnread },
      totalTodoCount: pane.todos.count,
      uncompletedTodoCount: pane.todos.count { !$0.isDone }
    )
  }
  return result
}

/// Per-pane search-overlay render the reconciler diffs and pushes to a
/// PaneWrapperView's search overlay -- the needle plus the match counts the overlay
/// displays, all from `model.searchState`. Equatable so the diff skips unchanged
/// overlays.
struct SearchOverlayRender: Equatable {
  let needle: String
  let total: Int?
  let selected: Int?
}

/// Search-overlay projection: one `SearchOverlayRender` per pane *with active search*
/// (keyed iff `model.searchState[paneId] != nil`). The key disappears the instant
/// search ends, so `reconcilePaneChrome` diffs this with a non-default `remove` that
/// tears the overlay down (disappear-but-host-survives) while the pane's wrapper lives on.
func desiredSearchOverlays(in model: AppModel) -> [PaneId: SearchOverlayRender] {
  var result: [PaneId: SearchOverlayRender] = [:]
  for (paneId, search) in model.searchState {
    result[paneId] = SearchOverlayRender(needle: search.needle, total: search.total, selected: search.selected)
  }
  return result
}

/// Per-pane Ghostty config render the reconciler diffs and pushes to the surface.
/// The theme is keyed iff a pane has a non-nil effective theme; generation changes
/// when the app's base Ghostty config reloads, forcing themed panes to re-layer.
struct PaneConfigKey: Equatable {
  let theme: String
  let generation: Int
}

/// Pane-config projection: one key per live themed pane. Unthemed panes are absent,
/// so removing a theme makes the key disappear and the reconciler reloads base config
/// while the surface host survives.
func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {
  var result: [PaneId: PaneConfigKey] = [:]
  for pane in model.allPanes {
    if let theme = effectiveTheme(for: pane) {
      result[pane.id] = PaneConfigKey(theme: theme, generation: model.ghosttyConfigGeneration)
    }
  }
  return result
}

/// Generic diff/apply/prune backing every keyed reconcile pass. Applies `apply`
/// only for keys whose desired value differs from the cached one (unchanged keys
/// are skipped), invokes `remove` once for each key that left `desired` (the
/// disappear-but-host-survives teardown -- e.g. an ended search overlay), and
/// prunes the cache to exactly the desired key set. The cache holds the last
/// *applied* value, so a pass can't drift it across `send()`s.
func applyDiff<K: Hashable, V: Equatable>(
  _ desired: [K: V], _ cache: inout [K: V],
  apply: (K, V) -> Void, remove: (K) -> Void = { _ in }
) {
  for (k, v) in desired where cache[k] != v { apply(k, v); cache[k] = v }
  for k in cache.keys where desired[k] == nil { remove(k) }   // teardown disappeared keys
  cache = cache.filter { desired[$0.key] != nil }
}

// MARK: - Window Chrome Projection (reconcileWindowChrome)
//
// Unread-alert scans intentionally stay local projection work; see
// `Projection Scan Cost` in `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// The window's title-bar string: the selected tab's display title, plus
/// " — <subtitle>" when a distinct subtitle (cwd) is present. Pure so the
/// window-chrome projection can derive it and so it is test-visible; the
/// reconcile executor only assigns the result. Moved here from Update.swift
/// when the title stopped being a `.setWindowTitle` command (Stage 6).
func windowTitle(for tab: TabModel) -> String {
  if let subtitle = tab.subtitle, subtitle != tab.displayTitle {
    return "\(tab.displayTitle) — \(subtitle)"
  }
  return tab.displayTitle
}

/// Everything the window chrome shows, in one Equatable value the reconciler
/// diffs against its cache. Three channels, all on hosts that persist across
/// container rebuilds (window, chromeView, dock tile): the window title and the
/// chrome content title (which differ when a subtitle is present), the unread
/// dock/toolbar-bell badge count, and the tab-todo button's rollup counts.
struct WindowChromeProjection: Equatable {
  let windowTitle: String       // window?.title (display title + optional " — subtitle")
  let contentTitle: String      // chromeView content title (bare display title)
  let unreadCount: Int          // dock + toolbar bell badge
  let tabTodoTotal: Int         // tab-todo button total
  let tabTodoUncompleted: Int   // tab-todo button uncompleted
}

/// Window-chrome projection. Derives from the *selected* tab (empty titles +
/// a (0,0) rollup when there is none), the global unread-alert count, and the
/// selected tab's todo rollup. Pure: same `(AppModel)` -> same projection.
func desiredWindowChrome(in model: AppModel) -> WindowChromeProjection {
  let tab = selectedTab(in: model)
  let rollup = tab.map { tabTodoRollup($0.id, in: model) } ?? (total: 0, uncompleted: 0)
  return WindowChromeProjection(
    windowTitle: tab.map { windowTitle(for: $0) } ?? "",
    contentTitle: tab?.displayTitle ?? "",
    unreadCount: totalUnreadAlertCount(model: model),
    tabTodoTotal: rollup.total,
    tabTodoUncompleted: rollup.uncompleted
  )
}

// MARK: - Sidebar Projection + Row-Op Diff (reconcileSidebar)
//
// The sidebar's per-tab and per-group alert scans intentionally stay local; see
// `Projection Scan Cost` in `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// One sidebar tab row's rendered attributes -- everything `configureTabCell` draws.
/// `id` keys the row; the remaining fields are compared to decide a `reloadTab` op.
/// Selection is *not* here: NSOutlineView owns selectedRowIndexes and the reconciler
/// reapplies it via `resolveReloadSelection`, so a selection change is never a row op.
struct SidebarTabProjection: Equatable {
  let id: TabId
  // Non-id fields are `var` so the row-op model-apply test can transform a working
  // copy of the old projection in place (and the executor can mirror it). They never
  // change identity, only rendered content.
  var displayTitle: String
  var subtitle: String?
  var unreadAlertCount: Int
  var jumpKey: Character?   // model.jumpMode?.keyMap[tab.id]
  var color: TabColor?
}

/// One sidebar group row. `isCollapsed` drives the structural `setGroupCollapsed`
/// op (expand/collapse + caret); the reload-attrs (name/bell/tabCount/isFirst -- the
/// rest of what `configureGroupCell` draws) drive a `reloadGroup` op. `tabs` is the
/// ordered child list this group owns.
struct SidebarGroupProjection: Equatable {
  let id: GroupId
  var isCollapsed: Bool
  var name: String
  var unreadAlertCount: Int
  var tabCount: Int
  var isFirst: Bool        // first group draws no top separator
  var tabs: [SidebarTabProjection]
}

/// The full sidebar outline as a pure value: ordered groups -> ordered tabs, every
/// rendered attribute, collapse state, and the per-tab jump badge -- but NOT selection.
/// `isSingleGroupMode` (one group) hides group rows and promotes tabs to roots; a flip
/// of this flag restructures the whole outline, so `computeSidebarRowOps` rebuilds.
struct SidebarProjection: Equatable {
  var isSingleGroupMode: Bool
  var groups: [SidebarGroupProjection]
}

/// Project the sidebar outline from the model. Selection is excluded by design
/// (view-owned). The jump badge comes from `model.jumpMode?.keyMap[tab.id]`.
func desiredSidebar(in model: AppModel) -> SidebarProjection {
  let firstGroupId = model.groups.first?.id
  let groups = model.groups.map { group in
    SidebarGroupProjection(
      id: group.id,
      isCollapsed: group.isCollapsed,
      name: group.name,
      unreadAlertCount: groupUnreadAlertCount(for: group, alerts: model.alerts),
      tabCount: group.tabs.count,
      isFirst: group.id == firstGroupId,
      tabs: group.tabs.map { tab in
        SidebarTabProjection(
          id: tab.id,
          displayTitle: tab.displayTitle,
          subtitle: tab.subtitle,
          unreadAlertCount: unreadAlertCount(for: tab, alerts: model.alerts),
          jumpKey: model.jumpMode?.keyMap[tab.id],
          color: tab.color
        )
      }
    )
  }
  return SidebarProjection(isSingleGroupMode: model.groups.count == 1, groups: groups)
}

/// A single ordered NSOutlineView mutation. The list `computeSidebarRowOps` returns is
/// a *sequential* script: each index is relative to the running (intermediate) state,
/// so applying the ops one at a time -- as both the executor and the model-apply test
/// do -- transforms old into new. Reorders are decomposed into remove+insert (no move
/// op), which keeps the executor off NSOutlineView's crash-prone `moveItem` index
/// semantics and lets a moved edited row's cell be destroyed and rebuilt cleanly.
/// `insert`/`reload` ops carry the entity id; the executor and test source that row's
/// content from the *new* projection / live model. `remove` ops carry only an index.
enum SidebarRowOp: Equatable {
  case reloadAll                                                   // wholesale rebuild
  case insertGroup(id: GroupId, index: Int)
  case removeGroup(index: Int)
  case reloadGroup(id: GroupId)                                    // name/bell/tabCount/isFirst
  case setGroupCollapsed(id: GroupId, collapsed: Bool)
  case insertTab(id: TabId, groupId: GroupId, index: Int)
  case removeTab(groupId: GroupId, index: Int)
  case reloadTab(id: TabId)
}

/// Transform `old` id-list into `new` via a sequential remove/insert script (indices
/// relative to the running state). A reorder surfaces as a remove+insert pair, not a
/// move. Shared by the group-level and tab-level diffs.
private func sidebarSequenceOps<Id: Hashable>(
  old: [Id], new: [Id],
  insert: (Id, Int) -> SidebarRowOp,
  remove: (Int) -> SidebarRowOp
) -> [SidebarRowOp] {
  var ops: [SidebarRowOp] = []
  var work = old
  let newSet = Set(new)
  // 1. Remove ids absent from new, descending so the not-yet-processed indices stay valid.
  var i = work.count - 1
  while i >= 0 {
    if !newSet.contains(work[i]) {
      ops.append(remove(i))
      work.remove(at: i)
    }
    i -= 1
  }
  // 2. work now holds old's surviving ids (a subset of new). Walk new; wherever the
  //    running list disagrees with new[j], either pull new[j] down from its current
  //    spot (a reorder, k > j) or insert it (a new id) -- so the running prefix matches.
  var j = 0
  while j < new.count {
    if j < work.count, work[j] == new[j] { j += 1; continue }
    if let k = work.firstIndex(of: new[j]) {
      ops.append(remove(k)); work.remove(at: k)
    }
    ops.append(insert(new[j], j)); work.insert(new[j], at: j)
    j += 1
  }
  return ops
}

/// Diff two sidebar projections into a minimal ordered op list. A nil `old` (first
/// run) or a single<->multi group-mode flip rebuilds wholesale (`reloadAll`); otherwise
/// it diffs groups, then each surviving group's tabs, then reload + collapse ops. Pure
/// and unit-tested via model-apply (apply the ops to a copy of `old` -> equals `new`),
/// which catches NSOutlineView-invalid index ordering an exact-sequence assert would bless.
func computeSidebarRowOps(old: SidebarProjection?, new: SidebarProjection) -> [SidebarRowOp] {
  guard let old = old, old.isSingleGroupMode == new.isSingleGroupMode else {
    return [.reloadAll]
  }

  var ops: [SidebarRowOp] = []

  // Level 1: group rows (roots in multi-group mode). A removed group takes its tabs
  // with it; an inserted group brings its tabs (built from `new`/model), so neither
  // needs per-tab ops.
  ops += sidebarSequenceOps(
    old: old.groups.map(\.id), new: new.groups.map(\.id),
    insert: { id, idx in .insertGroup(id: id, index: idx) },
    remove: { idx in .removeGroup(index: idx) })

  let oldGroupById = Dictionary(uniqueKeysWithValues: old.groups.map { ($0.id, $0) })

  // Level 2: tabs within each surviving group.
  for newGroup in new.groups {
    guard let oldGroup = oldGroupById[newGroup.id] else { continue }  // inserted group: handled above
    ops += sidebarSequenceOps(
      old: oldGroup.tabs.map(\.id), new: newGroup.tabs.map(\.id),
      insert: { id, idx in .insertTab(id: id, groupId: newGroup.id, index: idx) },
      remove: { idx in .removeTab(groupId: newGroup.id, index: idx) })
  }

  // Group reload-attrs (everything configureGroupCell draws except collapse, which the
  // setGroupCollapsed op drives, and the tab list).
  for newGroup in new.groups {
    guard let oldGroup = oldGroupById[newGroup.id] else { continue }
    if (oldGroup.name, oldGroup.unreadAlertCount, oldGroup.tabCount, oldGroup.isFirst)
       != (newGroup.name, newGroup.unreadAlertCount, newGroup.tabCount, newGroup.isFirst) {
      ops.append(.reloadGroup(id: newGroup.id))
    }
  }

  // Tab reload-attrs: same id, different rendered content.
  let oldTabById = Dictionary(
    uniqueKeysWithValues: old.groups.flatMap(\.tabs).map { ($0.id, $0) })
  for newTab in new.groups.flatMap(\.tabs) {
    if let oldTab = oldTabById[newTab.id], oldTab != newTab {
      ops.append(.reloadTab(id: newTab.id))
    }
  }

  // Collapse (structural expand/collapse). Skipped in single-group mode -- the lone
  // group has no caret. A newly inserted group defaults to expanded, so emit a collapse
  // op if it should start collapsed.
  if !new.isSingleGroupMode {
    for newGroup in new.groups {
      if let oldGroup = oldGroupById[newGroup.id] {
        if oldGroup.isCollapsed != newGroup.isCollapsed {
          ops.append(.setGroupCollapsed(id: newGroup.id, collapsed: newGroup.isCollapsed))
        }
      } else if newGroup.isCollapsed {
        ops.append(.setGroupCollapsed(id: newGroup.id, collapsed: true))
      }
    }
  }

  return ops
}

/// The narrow rename guard (Risk: "Rename guard must stay narrow"). While a sidebar row
/// is inline-edited, a `reload` of *that* row is suppressed -- its title/attrs are owned
/// by the live field editor -- but every structural op still applies: a tab being
/// renamed can be closed or moved by another `send()`. `clearRename` tells the executor
/// to end the now-orphaned edit (and clear the sidecar) when the edited row is removed
/// (absent from `new`), moved (a re-insert op carries its id), or caught in a reloadAll
/// rebuild. Factored pure so the rename-guard-scope test is structure-insensitive.
func guardSidebarRenameOps(
  ops: [SidebarRowOp],
  renameTarget: RenameTarget?,
  new: SidebarProjection
) -> (ops: [SidebarRowOp], clearRename: Bool) {
  guard let renameTarget = renameTarget else { return (ops, false) }

  let targetPresent: Bool = {
    switch renameTarget {
    case .tab(let id): return new.groups.contains { $0.tabs.contains { $0.id == id } }
    case .group(let id): return new.groups.contains { $0.id == id }
    }
  }()

  var out: [SidebarRowOp] = []
  var clearRename = !targetPresent   // the edited row was removed/closed -> end the edit
  for op in ops {
    switch op {
    case .reloadTab(let id) where renameTarget == .tab(id):
      continue   // suppress: field editor owns this row
    case .reloadGroup(let id) where renameTarget == .group(id):
      continue   // suppress
    case .insertTab(let id, _, _) where renameTarget == .tab(id):
      out.append(op); clearRename = true   // edited row moved (remove+insert) -> end edit
    case .insertGroup(let id, _) where renameTarget == .group(id):
      out.append(op); clearRename = true
    case .reloadAll:
      out.append(op); clearRename = true   // wholesale rebuild recreates every cell
    default:
      out.append(op)
    }
  }
  return (out, clearRename)
}

/// Advance the reconcileSidebar cache to `new` after applying ops -- but if a row's
/// reload was suppressed because it is the live-editing row (`suppressedRenameTarget`
/// non-nil after the guard ran), retain that row's *prior* projection so the deferred
/// attribute update re-fires the next time the row diffs (once the edit ends and the
/// guard stops suppressing). Without this the cache would claim the suppressed attrs
/// were applied and silently drift (a cancelled rename would strand a stale badge).
/// The suppressed row never has a structural op (those clear the rename target), so
/// retaining its old attrs in `new`'s structure is safe.
func advanceSidebarCache(
  old: SidebarProjection?,
  new: SidebarProjection,
  suppressedRenameTarget: RenameTarget?
) -> SidebarProjection {
  guard let target = suppressedRenameTarget, let old = old else { return new }
  var merged = new
  switch target {
  case .tab(let id):
    guard let oldTab = old.groups.flatMap(\.tabs).first(where: { $0.id == id }) else { return new }
    for gi in merged.groups.indices {
      if let ti = merged.groups[gi].tabs.firstIndex(where: { $0.id == id }) {
        merged.groups[gi].tabs[ti] = oldTab
        return merged
      }
    }
  case .group(let id):
    guard let oldGroup = old.groups.first(where: { $0.id == id }),
          let gi = merged.groups.firstIndex(where: { $0.id == id }) else { return new }
    // Retain only the reload-attrs (collapse + tab list are structural, already applied).
    merged.groups[gi].name = oldGroup.name
    merged.groups[gi].unreadAlertCount = oldGroup.unreadAlertCount
    merged.groups[gi].tabCount = oldGroup.tabCount
    merged.groups[gi].isFirst = oldGroup.isFirst
  }
  return merged
}

// MARK: - View Reconciler: Containers (Stage 8)
//
// The content area renders one SplitContainerView per tab (eager: every tab's
// container is mounted; the selected tab's is visible, the rest hidden). A
// container is rebuilt only when its *shape* drifts -- structure + leaf ids +
// zoom -- NOT on a split-ratio change or any leaf PaneModel payload edit
// (title/cwd/progress/theme/todo), which now live in the tree. Excluding the
// payload is what keeps a metadata edit from rebuilding a container (and clearing
// anchored UI); excluding ratios keeps a divider drag a content-diff no-op.

/// Container-shape projection: one shape per tab in the model -- a *total* projection
/// of every group's every tab (eager mounting has no "mounted set" side-input).
func desiredContainerShapes(in model: AppModel) -> [TabId: ContainerShape] {
  var result: [TabId: ContainerShape] = [:]
  for group in model.groups {
    for tab in group.tabs {
      result[tab.id] = containerShape(of: tab)
    }
  }
  return result
}

/// A single container mutation the thin `reconcileContainers` executor applies.
/// `remove` detaches a gone tab's container; `rebuild` recreates a new/drifted tab's
/// container; `setVisible` toggles isHidden. Emitted remove -> rebuild -> setVisible
/// so a rebuilt container exists before its visibility op runs. Equatable for the
/// model-apply test.
enum ContainerOp: Equatable {
  case remove(tabId: TabId)
  case rebuild(tabId: TabId)
  case setVisible(tabId: TabId, visible: Bool)
}

/// Diff old vs new container shapes into ops: `.remove` for tabs gone from `new`,
/// `.rebuild` for a tab absent in `old` (new tab) or whose shape drifted, and
/// `.setVisible` for *every* tab in `new` (selected visible, rest hidden -- eager).
/// Ordered remove -> rebuild -> setVisible. Pure; unit-tested via model-apply
/// (apply the ops to a presence/visibility map -> equals new's keys + visibility),
/// which catches a dropped-hide regression an exact-sequence assert would bless.
func computeContainerOps(
  old: [TabId: ContainerShape],
  new: [TabId: ContainerShape],
  selectedTabId: TabId?
) -> [ContainerOp] {
  var ops: [ContainerOp] = []
  for tabId in old.keys where new[tabId] == nil {
    ops.append(.remove(tabId: tabId))
  }
  for (tabId, shape) in new where old[tabId] != shape {
    ops.append(.rebuild(tabId: tabId))
  }
  for tabId in new.keys {
    ops.append(.setVisible(tabId: tabId, visible: tabId == selectedTabId))
  }
  return ops
}

/// Does this container-op script strand the previously-visible tab -- i.e. is the
/// visible container removed, rebuilt, or hidden? This is the "view swap" condition.
/// A pane TODO popover anchored to that container's wrapper button is physically
/// orphaned when it holds; a tab popover is closed on view swap by policy.
func containerOpsStrandVisible(ops: [ContainerOp], previouslyVisibleTabId: TabId?) -> Bool {
  guard let visible = previouslyVisibleTabId else { return false }
  return ops.contains { op in
    switch op {
    case .remove(let tabId), .rebuild(let tabId):
      return tabId == visible
    case .setVisible(let tabId, let visibleFlag):
      return tabId == visible && !visibleFlag
    }
  }
}

/// Leaf pane ids of a container shape (backs `chromeInvalidation`).
func leafPaneIds(of shape: ContainerShape) -> [PaneId] {
  func walk(_ node: ContainerShapeNode) -> [PaneId] {
    switch node {
    case .leaf(let id): return [id]
    case .split(_, _, let first, let second): return walk(first) + walk(second)
    }
  }
  return walk(shape.tree)
}

/// Panes whose host PaneWrapperView a container op destroys, so `reconcileContainers`
/// must clear their paneToolbar/searchOverlay cache entries *before*
/// `reconcilePaneChrome` runs -- otherwise the value-unchanged chrome diff would skip
/// the fresh wrapper and leave it blank. Only `.rebuild` contributes (its panes
/// survive on a fresh wrapper): a `.remove`'s panes are gone from the model, so
/// reconcilePaneChrome's keyed-over-all-panes diff prunes their cache entries itself;
/// `.setVisible` keeps the same wrapper. (The signature takes only `newShapes`, which
/// cannot resolve a removed tab's leaves anyway -- by design, since they need no
/// invalidation.)
func chromeInvalidation(ops: [ContainerOp], newShapes: [TabId: ContainerShape]) -> Set<PaneId> {
  var result: Set<PaneId> = []
  for op in ops {
    if case .rebuild(let tabId) = op, let shape = newShapes[tabId] {
      result.formUnion(leafPaneIds(of: shape))
    }
  }
  return result
}

/// Surfaces to tear down: live surfaces whose pane no longer exists in the model.
/// With tree-owns-panes, "desired surfaces" is exactly `model.allPaneIds`, so a pure
/// set difference selects the dead ones. `reconcileSurfaceExistence` runs this over
/// `Set(surfaces.keys)` and tears down each selected pane. Surface *creation* stays a
/// command (it forks a PTY), so the reconciler only ever destroys.
func surfacesToTearDown(liveSurfaceIds: Set<PaneId>, model: AppModel) -> Set<PaneId> {
  liveSurfaceIds.subtracting(Set(model.allPaneIds))
}

// MARK: - MRU Switcher + Quit Confirmation Projections

// One row in the MRU switcher overlay. Pure data, moved here from SwitcherPanel
// (an AppKit file) so desiredSwitcher and its tests can build it without Cocoa;
// the view layer reads it back to render a row.
struct SwitcherRow: Equatable {
  let tabId: TabId
  let name: String
  let color: TabColor?
  let alertCount: Int
}

// The whole MRU switcher overlay as a value: the ordered rows plus the highlighted
// cursor index. A nil projection (see desiredSwitcher) means no cycle is active and
// reconcileSwitcher orders the panel out.
struct SwitcherProjection: Equatable {
  let rows: [SwitcherRow]
  let cursorIndex: Int
}

/// Project the MRU switcher overlay from the model. Returns nil when no cycle is
/// active (mruCycle == nil) or every frozen tab has been removed mid-cycle
/// (resolveLiveCycle == nil) -- reconcileSwitcher turns that nil into an orderOut.
/// Otherwise builds one row per live tab in the resolved (frozen) order. Pure:
/// mirrors SwitcherPanel.render's old body minus the view calls (resolveLiveCycle /
/// tabById / unreadAlertCount are all pure).
func desiredSwitcher(in model: AppModel) -> SwitcherProjection? {
  guard
    let cycle = model.mruCycle,
    let resolved = resolveLiveCycle(cycle, in: model)
  else { return nil }

  let rows = resolved.liveOrder.compactMap { tabId -> SwitcherRow? in
    guard let tab = tabById(tabId, in: model) else { return nil }
    return SwitcherRow(
      tabId: tabId,
      name: tab.displayTitle,
      color: tab.color,
      alertCount: unreadAlertCount(for: tab, alerts: model.alerts)
    )
  }
  return SwitcherProjection(rows: rows, cursorIndex: resolved.cursorIndex)
}

// The quit confirmation panel as pure data: non-nil only for the non-modal
// terminate confirmation. Close-tab confirmation is a separate NSAlert path.
struct QuitConfirmationProjection: Equatable {
  let paneCount: Int
}

/// Project the non-modal quit confirmation panel from the model. Returns nil for
/// no pending confirmation and for `.closeTab`, because close-tab confirmation is
/// driven by modal NSAlert commands instead.
func desiredQuitConfirmation(in model: AppModel) -> QuitConfirmationProjection? {
  guard model.pendingConfirmation == .terminate else { return nil }
  return QuitConfirmationProjection(paneCount: model.allPaneIds.count)
}
