// Pure view projections + structural diff/op helpers: the AppKit-free counterpart
// to Reconcile.swift. Each `desiredX(in:) -> Equatable` projection pairs with a
// `reconcileX` pass and a `ReconcilerCaches` field in Reconcile.swift; the diff
// helpers (`applyDiff`, `computeSidebarRowOps`, `computeContainerOps`, and the
// rename/cache/strand guards) turn two projections into the minimal patch a pass
// applies. This is the home the reconciler ADR and Reconcile.swift's "add a pass"
// template point at, and the unit-test boundary for the reconcile layer: derive view
// state from `AppModel` here (purely), apply it to Cocoa there. Keep it
// free of AppKit, which is what keeps the projection layer
// testable without Cocoa or the terminal engine. Cross-layer model helpers these call back into
// (queries, alert counts, container shapes) stay in ModelOperations.swift; this earns
// its own file as the named pure peer of Reconcile.swift. Pane-owned live
// lifecycles arrive as explicit immutable inputs; they never enter AppModel.
import Foundation
import DanTermProtocol

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
        currentThemeName: selectedTab(in: model).flatMap {
            $0.paneTree.focusedPane.theme
        }
    )
}

// MARK: - Preferences Panel

/// The font picker's one entry that is not a font: it stands for "no
/// `font.family` key", i.e. the built-in monospace face. It is a reserved
/// sentinel on the draft -- `resolveFontFamilyDraft` normalizes it back to nil --
/// which is what lets the combo box write its selected title straight into the
/// draft with no AppKit-side special case.
let systemMonospaceFontChoiceTitle = "System Monospace (Default)"

/// Pure value describing the visible preferences panel state.
struct PreferencesPanelProjection: Equatable {
    var selectedAlertClearMode: AlertClearMode
    var remoteThemeText: String
    var themeText: String
    var fontSizeText: String
    var fontFamilyText: String
    var copyOnSelect: Bool
    /// Every family the picker offers, system monospace first. Sourced from the
    /// catalog injected on open, never from an ambient CoreText query.
    var fontFamilyChoices: [String]
    /// Inline, non-modal report that the committed family is not installed.
    /// Non-nil only while the field still holds the name it describes.
    var fontFamilyWarning: String?
    /// Reports explicit config names absent from the bundled catalog. Both
    /// render paths recover to the built-in dark theme.
    var themeWarning: String?
    var remoteThemeWarning: String?
    var themeDirtyLabel: String?
    var fontSizeDirtyLabel: String?
    var fontFamilyDirtyLabel: String?
    var alertClearModeDirtyLabel: String?
    var copyOnSelectDirtyLabel: String?
    var remoteThemeDirtyLabel: String?
    var saveEnabled: Bool
}

/// Project the preferences panel from the model. nil means no draft is open, so
/// the runtime has no preferences UI to update and clears the reconcile cache.
func desiredPreferencesPanel(in model: AppModel) -> PreferencesPanelProjection? {
    guard let draft = model.preferencesDraft else { return nil }

    let committed = model.config
    // The draft holds what the user typed, so the committed size is rendered to
    // text to compare with it: "13" and 13.0 are the same setting, and normalizing
    // the other direction would have to guess at half-typed input.
    let committedFontSizeText = committed.fontSize.map(configFontSizeText)
    let themeDirty = draft.theme != committed.defaultTheme
    let fontSizeDirty = draft.fontSize != committedFontSizeText
    let fontFamilyDirty = resolveFontFamilyDraft(draft.fontFamily) != committed.fontFamily
    let alertDirty = draft.alertClearMode != committed.alertClearMode
    let copyOnSelectDirty = draft.copyOnSelect != committed.copyOnSelect
    let remoteThemeDirty = resolveRemoteTheme(draft.remoteTheme) != committed.remoteTheme

    let alertDisplayValue = committed.alertClearMode == .focus ? "Focus" : "Manual"
    // Warn only while the field still holds the unresolved name: once the user
    // edits it, the warning would be describing text no longer on screen, and the
    // new name has not been resolved against the installed families yet.
    let unresolvedFamily = committed.fontFamily.flatMap {
        model.resolvedFontFamily == nil && resolveFontFamilyDraft(draft.fontFamily) == $0 ? $0 : nil
    }
    let availableThemeNames = Set(model.availableThemeNames)
    let unresolvedTheme = committed.defaultTheme.flatMap {
        draft.theme == $0 && !availableThemeNames.contains($0) ? $0 : nil
    }
    let unresolvedRemoteTheme: String? = {
        let name = committed.remoteTheme
        return resolveRemoteTheme(draft.remoteTheme) == name && !availableThemeNames.contains(name)
            ? name
            : nil
    }()
    return PreferencesPanelProjection(
        selectedAlertClearMode: draft.alertClearMode,
        remoteThemeText: draft.remoteTheme,
        themeText: draft.theme ?? "",
        fontSizeText: draft.fontSize ?? "",
        // Raw draft text, like the other fields: normalizing here would rewrite
        // the field under the user mid-edit. Absent means the sentinel choice, so
        // the picker always displays a selected entry.
        fontFamilyText: draft.fontFamily ?? systemMonospaceFontChoiceTitle,
        copyOnSelect: draft.copyOnSelect,
        fontFamilyChoices: [systemMonospaceFontChoiceTitle] + model.installedFontFamilies,
        fontFamilyWarning: unresolvedFamily.map {
            "Font \"\($0)\" is not installed -- using the system monospace font."
        },
        themeWarning: unresolvedTheme.map {
            "Theme \"\($0)\" is not available -- using the built-in dark theme."
        },
        remoteThemeWarning: unresolvedRemoteTheme.map {
            "Theme \"\($0)\" is not available -- using the built-in dark theme."
        },
        themeDirtyLabel: themeDirty ? "Prev: \(committed.defaultTheme ?? "(default)")" : nil,
        fontSizeDirtyLabel: fontSizeDirty ? "Prev: \(committedFontSizeText ?? "(default)")" : nil,
        fontFamilyDirtyLabel: fontFamilyDirty
            ? "Prev: \(committed.fontFamily ?? systemMonospaceFontChoiceTitle)" : nil,
        alertClearModeDirtyLabel: alertDirty ? "Prev: \(alertDisplayValue)" : nil,
        copyOnSelectDirtyLabel: copyOnSelectDirty
            ? "Prev: \(committed.copyOnSelect ? "On" : "Off")" : nil,
        remoteThemeDirtyLabel: remoteThemeDirty ? "Prev: \(committed.remoteTheme)" : nil,
        saveEnabled: themeDirty || fontSizeDirty || fontFamilyDirty
            || alertDirty || copyOnSelectDirty || remoteThemeDirty
    )
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

/// Carries the complete content and owner for the one projected TODO popover.
enum TodoPopoverProjection: Equatable {
  case pane(PaneTodoPopoverProjection)
  case tab(TabTodoPopoverProjection)
}

/// Projects TODO popover existence and content from its single model slot.
func desiredTodoPopover(in model: AppModel) -> TodoPopoverProjection? {
  switch model.todoPopover {
  case .pane(let paneId):
    return desiredPaneTodoPopover(paneId: paneId, in: model).map(TodoPopoverProjection.pane)
  case .tab(let tabId):
    return desiredTabTodoPopover(tabId: tabId, in: model).map(TodoPopoverProjection.tab)
  case nil:
    return nil
  }
}

func desiredTabTodoPopover(tabId: TabId, in model: AppModel) -> TabTodoPopoverProjection? {
  guard let tab = tabById(tabId, in: model) else { return nil }
  return TabTodoPopoverProjection(
    tabId: tabId,
    rows: buildTabTodoRows(model: model, tabId: tabId),
    paneOrder: allPaneIds(tab.paneTree.root),
    tabHasCompleted: tab.todos.contains(where: \.isDone)
  )
}

// MARK: - Alerts Popover

struct AlertRowProjection: Equatable {
  let id: AlertId
  let kind: AlertKind
  let title: DisplayLine
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
func desiredAlertsPopover(in model: AppModel) -> AlertsPopoverProjection? {
  guard model.alertsPopoverOpen else { return nil }
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
// Focus borders, pane toolbar, and pane config still walk `model.allPanes`
// during each reconcile sweep. Alert-derived renders read an UnreadAlertTally
// computed once in `reconcile()` and threaded through the hot-path calls; the
// no-arg projection wrappers recompute it only for tests and cold callers. Rapid
// title/cwd/progress, background alert-badge, and command-event updates coalesce
// to about 75 ms, keeping inline reconciles at human pace. See `Projection Scan
// Cost` in `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// The pane-owned AppKit control that should receive the next key event.
enum PaneFocusTarget: Equatable {
  case terminal(PaneId)
  case searchField(PaneId)

  var paneId: PaneId {
    switch self {
    case .terminal(let paneId), .searchField(let paneId): return paneId
    }
  }
}

/// Project the selected tab's model-declared pane focus target.
func desiredPaneFocus(in model: AppModel) -> PaneFocusTarget? {
  guard let paneId = selectedTab(in: model)?.paneTree.focusedPaneId else { return nil }
  if model.searchState[paneId]?.focusOwner == .field {
    return .searchField(paneId)
  }
  return .terminal(paneId)
}

/// Whether `paneId` draws the green focus border for an already-resolved selected tab.
/// Centralizes the focused-pane and lone-leaf rule so loops and convenience callers
/// share one predicate body.
func isFocusedAndVisible(_ paneId: PaneId, in tab: TabModel?) -> Bool {
  guard let tab, tab.paneTree.focusedPaneId == paneId else {
    return false
  }
  if case .leaf = tab.paneTree.root { return false }
  return true
}

/// Return whether a pane should show the green focus border in the current content view.
func isFocusedAndVisible(_ paneId: PaneId, in model: AppModel) -> Bool {
  isFocusedAndVisible(paneId, in: selectedTab(in: model))
}

/// Per-pane focus-border state the reconciler diffs and pushes to a pane wrapper.
/// `focused` drives the green focus ring, `bell` the red unread-alert ring --
/// exactly the two values the old `.refreshPaneBorder` executor computed.
/// Equatable so the diff can skip unchanged panes.
struct BorderState: Equatable {
  let focused: Bool
  let bell: Bool
}

/// Convenience wrapper for tests and cold callers; hot-path callers pass the
/// precomputed unread-alert tally to avoid rescanning alerts.
func desiredFocusBorders(in model: AppModel) -> [PaneId: BorderState] {
  desiredFocusBorders(in: model, tally: unreadAlertTally(for: model))
}

/// Focus-border projection: one `BorderState` per live pane. Keyed over every pane
/// (`allPanes`) so a pane leaving the model drops its key and the reconciler's
/// `applyDiff` prunes the cache. `isFocusedAndVisible` already encodes the
/// single-pane-tab rule (a lone leaf draws no green border); `bell` is independent,
/// so a single-pane tab can still show the red unread-alert border.
func desiredFocusBorders(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: BorderState] {
  let selected = selectedTab(in: model)
  var result: [PaneId: BorderState] = [:]
  for pane in model.allPanes {
    result[pane.id] = BorderState(
      focused: isFocusedAndVisible(pane.id, in: selected),
      bell: (tally.byPane[pane.id] ?? 0) > 0
    )
  }
  return result
}

/// Pane-toolbar render the reconciler diffs and pushes to a PaneWrapperView's
/// toolbar. Live lifecycle fields come only from the pane owner's immutable
/// snapshot. Equatable lets the diff skip panes whose inputs are unchanged.
///
/// Every string here is already composed. The view receives no raw model value
/// and no domain object, so no untrusted terminal-reported text -- a title, a
/// cwd, a remote user and host -- is assembled inside AppKit.
struct PaneToolbarRender: Equatable {
  /// The running command while one is live, otherwise the title and cwd.
  let label: DisplayLine
  let progress: ProgressState?
  /// Whether the pane is on a remote host at all. Independent of `remoteLabel`,
  /// which is nil until the remote declares who it is.
  let isRemote: Bool
  /// The remote pill's text, nil when there is no pill to show.
  let remoteLabel: DisplayLine?
  /// The agent pill's text, nil when there is no pill to show -- which includes
  /// every agent whose chip already names it.
  let agentLabel: DisplayLine?
  /// The chip's tooltip, which names the attached agent and its full session id.
  /// Nil when no agent is attached.
  let chipTooltip: DisplayLine?
  let chipKind: ChipKind
  let unreadAlertCount: Int
  let totalTodoCount: Int
  let uncompletedTodoCount: Int
  let isZoomed: Bool
  let hasSplits: Bool
}

/// Convenience wrapper for tests and cold callers; hot-path callers pass the
/// precomputed unread-alert tally to avoid rescanning alerts.
/// Convenience wrapper for callers that do not already hold the alert tally
/// computed by reconcile.
func desiredPaneToolbar(
  in model: AppModel
) -> [PaneId: PaneToolbarRender] {
  desiredPaneToolbar(
    in: model,
    tally: unreadAlertTally(for: model)
  )
}

/// Pane-toolbar projection: one `PaneToolbarRender` per live pane. Keyed over every
/// pane (`allPanes`) so a key leaves only when its pane is gone -- at which point the
/// container pass has already torn down the host wrapper -- so `reconcilePaneChrome`
/// diffs this with the default no-op `remove`.
func desiredPaneToolbar(
  in model: AppModel,
  tally: UnreadAlertTally
) -> [PaneId: PaneToolbarRender] {
  var result: [PaneId: PaneToolbarRender] = [:]
  for group in model.groups {
    for tab in group.tabs {
      let hasSplits: Bool
      if case .split = tab.paneTree.root { hasSplits = true } else { hasSplits = false }
      for pane in panesInNode(tab.paneTree.root) {
        let session = pane.session
        let remoteSession: RemoteSession?
        if case .remote(let identity) = session?.connection ?? .local {
          remoteSession = identity
        } else {
          remoteSession = nil
        }
        let agentSession: AgentSession?
        if case .attached(let attachedSession, _) = session?.agent ?? .none {
          agentSession = attachedSession
        } else {
          agentSession = nil
        }
        let command: String?
        if case .running(let text) = session?.command ?? .idle {
          command = text
        } else {
          command = nil
        }
        let chipKind = ChipKind(agent: session?.agent ?? .none)
        result[pane.id] = PaneToolbarRender(
          label: DisplayLine(paneCommandChromeText(
            title: session?.title ?? "Terminal",
            cwd: session?.cwd,
            command: command
          )),
          progress: session?.progress,
          isRemote: remoteSession != nil || (session?.connection ?? .local) != .local,
          remoteLabel: remoteSession.map { DisplayLine($0.displayString) },
          // `.agent` is the mark for an agent DanTerm cannot name, so the pill
          // has to supply the name the chip is missing. Every other kind either
          // names the agent itself or means there is no agent.
          agentLabel: chipKind == .agent ? agentSession.map { DisplayLine($0.toolbarLabel) } : nil,
          chipTooltip: agentSession.map { DisplayLine("\($0.kind) session \($0.sessionId)") },
          chipKind: chipKind,
          unreadAlertCount: tally.byPane[pane.id] ?? 0,
          totalTodoCount: pane.todos.count,
          uncompletedTodoCount: pane.todos.count { !$0.isDone },
          isZoomed: tab.paneTree.isZoomed && tab.paneTree.focusedPaneId == pane.id,
          hasSplits: hasSplits
        )
      }
    }
  }
  return result
}

/// Per-pane search-overlay render the reconciler diffs and pushes to a
/// PaneWrapperView's search overlay -- the needle plus the match counts the overlay
/// displays, all from `model.searchState`. Equatable so the diff skips unchanged
/// overlays.
struct SearchOverlayRender: Equatable {
  let needle: String
  let status: SearchMatchStatus?
}

/// Search-overlay projection: one `SearchOverlayRender` per pane *with active search*
/// (keyed iff `model.searchState[paneId] != nil`). The key disappears the instant
/// search ends, so `reconcilePaneChrome` diffs this with a non-default `remove` that
/// tears the overlay down (disappear-but-host-survives) while the pane's wrapper lives on.
func desiredSearchOverlays(in model: AppModel) -> [PaneId: SearchOverlayRender] {
  var result: [PaneId: SearchOverlayRender] = [:]
  for (paneId, search) in model.searchState {
    result[paneId] = SearchOverlayRender(needle: search.needle, status: search.status)
  }
  return result
}

/// Per-pane terminal config render the reconciler diffs and pushes to the session.
/// Every live pane is keyed because the JSON defaults always resolve both values.
struct PaneConfigKey: Equatable {
  let theme: String
  let fontSize: Double
  /// The verified-installed family, or nil for the system monospace font. The raw
  /// name from config never reaches rendering; only a canonical resolved family may.
  let fontFamily: String?
  /// Whether the pane arms copy-on-select. Carried in the key so a reload retargets
  /// already-mounted panes through the same diff as theme and font.
  let copyOnSelect: Bool

  init(
    theme: String,
    fontSize: Double = DanTermConfig.default.resolvedFontSize,
    fontFamily: String? = nil,
    copyOnSelect: Bool = DanTermConfig.default.copyOnSelect
  ) {
    self.theme = theme
    self.fontSize = fontSize
    self.fontFamily = fontFamily
    self.copyOnSelect = copyOnSelect
  }
}

/// Projects the resolved theme, per-pane effective font size, resolved font
/// family, and copy-on-select onto every live pane.
func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {
  var result: [PaneId: PaneConfigKey] = [:]
  for pane in model.allPanes {
    result[pane.id] = PaneConfigKey(
      theme: effectiveTheme(
        for: pane,
        config: model.config
      ),
      fontSize: effectiveFontSize(for: pane, config: model.config),
      fontFamily: model.resolvedFontFamily,
      copyOnSelect: model.config.copyOnSelect
    )
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
// Window chrome reads the precomputed unread-alert tally's total count; see
// `Projection Scan Cost` in `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// The window's title-bar string: the selected tab's display title, plus
/// " — <subtitle>" when a distinct subtitle (cwd) is present. Pure so the
/// window-chrome projection can derive it and so it is test-visible; the
/// reconcile executor only assigns the result. Moved here from Update.swift
/// when the title stopped being a `.setWindowTitle` command (Stage 6).
func windowTitle(for tab: TabModel) -> String {
  let displayTitle = tabDisplayTitle(tab)
  if let subtitle = tabSubtitle(tab), subtitle != displayTitle {
    return "\(displayTitle) — \(subtitle)"
  }
  return displayTitle
}

/// Everything the window chrome shows, in one Equatable value the reconciler
/// diffs against its cache. Three channels, all on hosts that persist across
/// container rebuilds (window, chromeView, dock tile): the window title and the
/// chrome content title (which differ when a subtitle is present), the unread
/// dock/toolbar-bell badge count, and the tab-todo button's rollup counts.
struct WindowChromeProjection: Equatable {
  let windowTitle: DisplayLine  // window?.title (display title + optional " — subtitle")
  let contentTitle: DisplayLine // chromeView content title (bare display title)
  let unreadCount: Int          // dock + toolbar bell badge
  let tabTodoTotal: Int         // tab-todo button total
  let tabTodoUncompleted: Int   // tab-todo button uncompleted
}

/// Convenience wrapper for tests and cold callers; hot-path callers pass the
/// precomputed unread-alert tally to avoid rescanning alerts.
func desiredWindowChrome(in model: AppModel) -> WindowChromeProjection {
  desiredWindowChrome(in: model, tally: unreadAlertTally(for: model))
}

/// Window-chrome projection. Derives from the *selected* tab (empty titles +
/// a (0,0) rollup when there is none), the global unread-alert count, and the
/// selected tab's todo rollup. Pure: same `(AppModel)` -> same projection.
func desiredWindowChrome(in model: AppModel, tally: UnreadAlertTally) -> WindowChromeProjection {
  let tab = selectedTab(in: model)
  let rollup = tab.map { tabTodoRollup($0.id, in: model) } ?? (total: 0, uncompleted: 0)
  return WindowChromeProjection(
    windowTitle: DisplayLine(tab.map { windowTitle(for: $0) } ?? ""),
    contentTitle: DisplayLine(tab.map { tabDisplayTitle($0) } ?? ""),
    unreadCount: tally.total,
    tabTodoTotal: rollup.total,
    tabTodoUncompleted: rollup.uncompleted
  )
}

// MARK: - Sidebar Projection + Row-Op Diff (reconcileSidebar)
//
// Sidebar rows read the precomputed unread-alert tally's per-tab and per-group
// rollups; see `Projection Scan Cost` in
// `docs/design/2026-05-27-model-driven-view-reconciliation.md`.

/// One sidebar tab row's rendered attributes -- everything `configureTabCell` draws.
/// `id` keys the row; the remaining fields are compared to decide a `reloadTab` op.
/// Selection is *not* here: NSOutlineView owns selectedRowIndexes and the reconciler
/// reapplies it via `resolveReloadSelection`, so a selection change is never a row op.
struct SidebarTabProjection: Equatable {
  let id: TabId
  // Non-id fields are `var` so the row-op model-apply test can transform a working
  // copy of the old projection in place (and the executor can mirror it). They never
  // change identity, only rendered content.
  var displayTitle: DisplayLine
  var subtitle: DisplayLine?
  var unreadAlertCount: Int
  var jumpKey: Character?   // model.jumpMode?.keyMap[tab.id]
  var color: TabColor?
  var hasCustomTitle: Bool = false
  // The row speaks for the focused pane, like displayTitle and subtitle do.
  var chipKind: ChipKind = .terminal
  // The second line's pane enumeration, empty for a single-pane tab. Carried in
  // the projection so a split, a close, a focus move, or a state change inside
  // the tab reloads the row. Only `unreadAlertCount` overlaps at all, and it
  // moves for a tab-wide total rather than for the pane that changed, so
  // without this field an agent going idle would never repaint the strip.
  var paneChips: [TabPaneChip] = []
}

/// One sidebar group row. `isCollapsed` drives the structural `setGroupCollapsed`
/// op (expand/collapse + caret); the reload-attrs (name/bell/tabCount/isFirst -- the
/// rest of what `configureGroupCell` draws) drive a `reloadGroup` op. `tabs` is the
/// ordered child list this group owns.
struct SidebarGroupProjection: Equatable {
  let id: GroupId
  var isCollapsed: Bool
  var name: DisplayLine
  var unreadAlertCount: Int
  var tabCount: Int
  var isFirst: Bool        // first group draws no top separator
  var tabs: [SidebarTabProjection]
}

/// The full sidebar outline as a pure value: ordered groups -> ordered tabs, every
/// rendered attribute, collapse state, and sidebar interaction facts.
/// `isSingleGroupMode` (one group) hides group rows and promotes tabs to roots; a flip
/// of this flag restructures the whole outline, so `computeSidebarRowOps` rebuilds.
struct SidebarProjection: Equatable {
  var isSingleGroupMode: Bool
  var selectedTabId: TabId?
  var singleGroupDropTargetId: GroupId?
  var canDeleteGroups: Bool = false
  var renameTarget: RenameTarget?
  var groups: [SidebarGroupProjection]

  /// The row payload `SidebarItemStore` mounts for an inserted or reloaded group.
  /// Linear over a list that is one entry per group row on screen.
  func group(_ id: GroupId) -> SidebarGroupProjection? {
    groups.first { $0.id == id }
  }

  /// The row payload `SidebarItemStore` mounts for an inserted or reloaded tab.
  func tab(_ id: TabId) -> SidebarTabProjection? {
    for group in groups {
      if let tab = group.tabs.first(where: { $0.id == id }) { return tab }
    }
    return nil
  }
}

/// Convenience wrapper for tests and cold callers; hot-path callers pass the
/// precomputed unread-alert tally to avoid rescanning alerts.
func desiredSidebar(in model: AppModel) -> SidebarProjection {
  desiredSidebar(in: model, tally: unreadAlertTally(for: model))
}

/// Project the sidebar outline and the facts its interaction handlers need.
/// NSOutlineView still owns the multi-selection; `selectedTabId` identifies its
/// focused row. The jump badge comes from `model.jumpMode?.keyMap[tab.id]`.
func desiredSidebar(in model: AppModel, tally: UnreadAlertTally) -> SidebarProjection {
  let firstGroupId = model.groups.first?.id
  let groups = model.groups.map { group in
    SidebarGroupProjection(
      id: group.id,
      isCollapsed: group.isCollapsed,
      name: DisplayLine(group.name),
      unreadAlertCount: tally.byGroup[group.id] ?? 0,
      tabCount: group.tabs.count,
      isFirst: group.id == firstGroupId,
      tabs: group.tabs.map { tab in
        SidebarTabProjection(
          id: tab.id,
          displayTitle: DisplayLine(tabDisplayTitle(tab)),
          subtitle: tabSubtitle(tab).map { DisplayLine($0) },
          unreadAlertCount: tally.byTab[tab.id] ?? 0,
          jumpKey: model.jumpMode?.keyMap[tab.id],
          color: tab.color,
          hasCustomTitle: tab.customTitle != nil,
          chipKind: tabChipKind(tab),
          paneChips: tabPaneChips(tab, unreadByPane: tally.byPane)
        )
      }
    )
  }
  return SidebarProjection(
    isSingleGroupMode: model.groups.count == 1,
    selectedTabId: model.selectedTabId,
    singleGroupDropTargetId: model.groups.count == 1 ? model.groups[0].id : nil,
    canDeleteGroups: model.groups.count > 1,
    renameTarget: model.sidebarRenameTarget,
    groups: groups)
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
/// to end the now-orphaned view-owned edit when the edited row is removed
/// (absent from `new`), moved (a re-insert op carries its id), hidden by its group
/// collapsing (collapseItem tears the cell down with no field-editor delegate callback,
/// which would strand `isEditable = true` into the reuse pool), or caught in a reloadAll
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

  // The group whose collapse would hide the edited tab's row. A group rename is
  // unaffected: collapsing a group hides its children but keeps the group row visible.
  let editedTabGroupId: GroupId? = {
    guard case .tab(let id) = renameTarget else { return nil }
    return new.groups.first { $0.tabs.contains { $0.id == id } }?.id
  }()

  var out: [SidebarRowOp] = []
  var clearRename = !targetPresent   // the edited row was removed/closed -> end the edit
  for op in ops {
    switch op {
    case .reloadTab(let id) where renameTarget == .tab(id):
      continue   // suppress: field editor owns this row
    case .reloadGroup(let id) where renameTarget == .group(id):
      continue   // suppress
    case .setGroupCollapsed(let id, true) where id == editedTabGroupId:
      out.append(op); clearRename = true   // collapse hides the edited row -> end edit
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
/// non-nil after the guard ran), or a visible row reload could not fetch its cell,
/// retain that row's *prior* projection so the deferred attribute update re-fires the
/// next time the row diffs. Without this the cache would claim unapplied attrs were
/// painted and silently drift.
func advanceSidebarCache(
  old: SidebarProjection?,
  new: SidebarProjection,
  suppressedRenameTarget: RenameTarget?,
  unappliedTabIds: Set<TabId> = [],
  unappliedGroupIds: Set<GroupId> = []
) -> SidebarProjection {
  guard let old = old else { return new }
  var merged = new

  func retainTabProjection(_ id: TabId) {
    guard let oldTab = old.groups.flatMap(\.tabs).first(where: { $0.id == id }) else { return }
    for gi in merged.groups.indices {
      if let ti = merged.groups[gi].tabs.firstIndex(where: { $0.id == id }) {
        merged.groups[gi].tabs[ti] = oldTab
        return
      }
    }
  }

  func retainGroupReloadAttrs(_ id: GroupId) {
    guard let oldGroup = old.groups.first(where: { $0.id == id }),
          let gi = merged.groups.firstIndex(where: { $0.id == id }) else { return }
    // Retain only the reload-attrs (collapse + tab list are structural, already applied).
    merged.groups[gi].name = oldGroup.name
    merged.groups[gi].unreadAlertCount = oldGroup.unreadAlertCount
    merged.groups[gi].tabCount = oldGroup.tabCount
    merged.groups[gi].isFirst = oldGroup.isFirst
  }

  if let target = suppressedRenameTarget {
    switch target {
    case .tab(let id):
      retainTabProjection(id)
    case .group(let id):
      retainGroupReloadAttrs(id)
    }
  }

  for id in unappliedTabIds {
    retainTabProjection(id)
  }
  for id in unappliedGroupIds {
    retainGroupReloadAttrs(id)
  }

  return merged
}

// MARK: - View Reconciler: Containers (Stage 8)
//
// The content area renders one SplitContainerView per tab (eager: every tab's
// container is mounted; the selected tab's is visible, the rest hidden).
// Structural and ratio-only changes update the flat container directly, while
// leaf PaneModel payload edits stay excluded.

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
/// New tabs receive one full build; surviving tabs receive direct tree, layout,
/// and zoom updates; `setVisible` toggles `isHidden`.
enum ContainerOp: Equatable {
  case remove(tabId: TabId)
  case build(tabId: TabId)
  case setTree(tabId: TabId)
  case setLayout(tabId: TabId)
  case setZoomedPane(tabId: TabId, paneId: PaneId?)
  case setVisible(tabId: TabId, visible: Bool)
}

/// Diff old vs new container shapes into ops: `.remove` for tabs gone from `new`,
/// `.build` for a tab absent in `old`, direct tree updates for surviving structural
/// changes, ratio-only layout updates, zoom presentation updates, and `.setVisible`
/// for every tab in `new`.
/// Ordered remove -> build/tree/layout/zoom -> setVisible. Pure; unit-tested via model-apply
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
  for (tabId, shape) in new {
    guard let oldShape = old[tabId] else {
      ops.append(.build(tabId: tabId))
      continue
    }
    if oldShape.tree != shape.tree {
      ops.append(.setTree(tabId: tabId))
    } else if oldShape.layout != shape.layout {
      ops.append(.setLayout(tabId: tabId))
    }
    if oldShape.zoomedLeaf != shape.zoomedLeaf {
      ops.append(.setZoomedPane(tabId: tabId, paneId: shape.zoomedLeaf))
    }
  }
  for tabId in new.keys {
    ops.append(.setVisible(tabId: tabId, visible: tabId == selectedTabId))
  }
  return ops
}

/// Does this container-op script strand the previously-visible tab -- i.e. is the
/// visible container removed or hidden? This is the "view swap" condition.
/// A pane TODO popover anchored to that container's wrapper button is physically
/// orphaned when it holds; a tab popover is closed on view swap by policy.
func containerOpsStrandVisible(ops: [ContainerOp], previouslyVisibleTabId: TabId?) -> Bool {
  guard let visible = previouslyVisibleTabId else { return false }
  return ops.contains { op in
    switch op {
    case .remove(let tabId), .build(let tabId):
      return tabId == visible
    case .setTree, .setLayout, .setZoomedPane:
      return false
    case .setVisible(let tabId, let visibleFlag):
      return tabId == visible && !visibleFlag
    }
  }
}

/// Reports whether a surviving visible tab's tree or zoom presentation changed.
func containerOpsEditVisibleTree(
  ops: [ContainerOp],
  previouslyVisibleTabId: TabId?
) -> Bool {
  guard let visible = previouslyVisibleTabId else { return false }
  return ops.contains { op in
    switch op {
    case .setTree(let tabId), .setZoomedPane(let tabId, _):
      return tabId == visible
    case .remove, .build, .setLayout, .setVisible:
      return false
    }
  }
}

/// Sessions to tear down: live sessions whose pane no longer exists in the model.
/// With tree-owns-panes, "desired sessions" is exactly `model.allPaneIds`, so a pure
/// set difference selects the dead ones. `reconcileSessionExistence` runs this over
/// the runtime's live pane records and tears down each selected pane. Session
/// *creation* stays a command (it forks a PTY), so the reconciler only ever destroys.
func sessionsToTearDown(liveSessionIds: Set<PaneId>, model: AppModel) -> Set<PaneId> {
  liveSessionIds.subtracting(Set(model.allPaneIds))
}

// MARK: - MRU Switcher + Quit Confirmation Projections

// One row in the MRU switcher overlay. Pure data, moved here from SwitcherPanel
// (an AppKit file) so desiredSwitcher and its tests can build it without Cocoa;
// the view layer reads it back to render a row.
struct SwitcherRow: Equatable {
  let tabId: TabId
  let name: DisplayLine
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
/// Convenience wrapper for tests and cold callers; hot-path callers pass the
/// precomputed unread-alert tally to avoid rescanning alerts.
func desiredSwitcher(in model: AppModel) -> SwitcherProjection? {
  desiredSwitcher(in: model, tally: unreadAlertTally(for: model))
}

/// Project the MRU switcher overlay from the model. Returns nil when no cycle is
/// active (mruCycle == nil) or every frozen tab has been removed mid-cycle
/// (resolveLiveCycle == nil) -- reconcileSwitcher turns that nil into an orderOut.
/// Otherwise builds one row per live tab in the resolved (frozen) order. Pure:
/// mirrors SwitcherPanel.render's old body minus the view calls.
func desiredSwitcher(in model: AppModel, tally: UnreadAlertTally) -> SwitcherProjection? {
  guard
    let cycle = model.mruCycle,
    let resolved = resolveLiveCycle(cycle, in: model)
  else { return nil }

  let rows = resolved.liveOrder.compactMap { tabId -> SwitcherRow? in
    guard let tab = tabById(tabId, in: model) else { return nil }
    return SwitcherRow(
      tabId: tabId,
      name: DisplayLine(tabDisplayTitle(tab)),
      color: tab.color,
      alertCount: tally.byTab[tabId] ?? 0
    )
  }
  return SwitcherProjection(rows: rows, cursorIndex: resolved.cursorIndex)
}

/// Carries all copy and identity needed to render and answer one confirmation.
struct ConfirmationProjection: Equatable {
  let id: ConfirmationId
  let title: DisplayLine
  let informativeText: String
  /// Every running command the confirmed action would end, in pane order. The
  /// panel presents as many as fit and scrolls the rest; nothing here is
  /// shortened, so the copy affordance can hand over the whole list.
  let commands: [DisplayLine]
  let confirmTitle: DisplayLine
  let secondaryTitle: DisplayLine?
}

/// Projects the single pending transaction into the shared non-modal panel.
func desiredConfirmation(in model: AppModel) -> ConfirmationProjection? {
  guard let pending = model.pendingConfirmation else { return nil }
  switch pending.subject {
  case .app:
    let paneCount = model.allPaneIds.count
    let sessions = paneCount == 1 ? "1 terminal session" : "\(paneCount) terminal sessions"
    return ConfirmationProjection(
      id: pending.id,
      title: "Quit DanTerm?",
      informativeText: "This will close \(sessions).",
      // Quit has no frozen impact on purpose: its copy is a live rollup that
      // follows the model while the panel is open, so the command list is read
      // from the live panes the same way the session count is.
      commands: model.allPanes.compactMap(\.runningCommand).map { DisplayLine($0) },
      confirmTitle: "Quit",
      secondaryTitle: nil
    )
  case .pane:
    guard let impact = pending.impact else { return nil }
    let copy = closeConfirmationCopy(
      subject: pending.subject,
      impact: impact,
      quitAuthorized: pending.quitAuthorized
    )
    return ConfirmationProjection(
      id: pending.id,
      title: "Close pane?",
      informativeText: copy.informativeText,
      commands: copy.commands,
      confirmTitle: "Close Pane",
      secondaryTitle: nil
    )
  case .tab(let tabId):
    guard tabById(tabId, in: model) != nil,
          let tabTitle = pending.tabTitle,
          let impact = pending.impact
    else { return nil }
    let copy = closeConfirmationCopy(
      subject: pending.subject,
      impact: impact,
      quitAuthorized: pending.quitAuthorized
    )
    return ConfirmationProjection(
      id: pending.id,
      title: DisplayLine("Close tab \"\(tabTitle.text)\"?"),
      informativeText: copy.informativeText,
      commands: copy.commands,
      confirmTitle: "Close Tab",
      secondaryTitle: nil
    )
  case .tabs(let tabIds):
    guard let impact = pending.impact else { return nil }
    let copy = closeConfirmationCopy(
      subject: pending.subject,
      impact: impact,
      quitAuthorized: pending.quitAuthorized
    )
    let tabCount = tabIds.count
    return ConfirmationProjection(
      id: pending.id,
      title: DisplayLine(pending.quitAuthorized
        ? "Close \(tabCount) tabs and quit DanTerm?"
        : "Close \(tabCount) tabs?"),
      informativeText: copy.informativeText,
      commands: copy.commands,
      confirmTitle: DisplayLine("Close \(tabCount) Tabs"),
      secondaryTitle: nil
    )
  case .deleteGroup(let groupId):
    guard let frozen = pending.deleteGroup,
          let group = model.groups.first(where: { $0.id == groupId }),
          let destination = model.groups.first(where: {
            $0.id == frozen.destinationGroupId
          })
    else { return nil }
    return ConfirmationProjection(
      id: pending.id,
      title: DisplayLine("Delete group \"\(group.name)\"?"),
      informativeText: "This group has \(frozen.tabIds.count) tab(s).",
      commands: [],
      confirmTitle: DisplayLine("Move to \(destination.name)"),
      secondaryTitle: "Close Tabs"
    )
  }
}
