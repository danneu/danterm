// Pure model helpers for split trees, snapshots, title-channel events, and UI text.
import Foundation

// MARK: - Pane Theme

/// Normalize a raw remote theme string: trim whitespace, default empty to the config default.
func resolveRemoteTheme(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? DanTermConfig.default.remoteTheme : trimmed
}

/// Returns the theme that should be applied to a pane's Ghostty surface.
/// Remote override takes priority over user-set theme.
func effectiveTheme(for pane: PaneModel) -> String? {
  pane.remoteThemeOverride ?? pane.theme
}

// MARK: - Preferences Panel

/// Whether the preferences draft has any changes compared to the committed config.
func isDraftDirty(_ draft: PreferencesDraft, vs config: DanTermConfig, ghostty: GhosttyPrefs?) -> Bool {
    draft.alertClearMode != config.alertClearMode
        || resolveRemoteTheme(draft.remoteTheme) != config.remoteTheme
        || draft.theme != ghostty?.theme
        || draft.fontSize != ghostty?.fontSize
}

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

func formatToolbarLabel(title: String, cwd: String?) -> String {
  guard let cwd else { return title }
  let shortCwd = abbreviateHome(cwd)
  if title == cwd {
    return shortCwd
  } else {
    return "\(title) \u{2013} \(shortCwd)"
  }
}

// MARK: - Search Cleanup

/// Remove search state for a pane being destroyed. Called from all pane-destruction paths.
func removePaneSearchState(_ paneId: PaneId, from model: inout AppModel) {
    model.searchState.removeValue(forKey: paneId)
}

// MARK: - Sidebar Row Emphasis

/// Decides whether a sidebar tab row should draw with AppKit's emphasized
/// (accent-colored) selection regardless of first-responder state. Returns
/// true only when the row is a tab whose id matches the model's focused
/// tab; group rows pass `nil` for `rowTabId` and never qualify.
func shouldForceSidebarRowEmphasis(rowTabId: TabId?, focusedTabId: TabId?) -> Bool {
    guard let rowTabId, let focusedTabId else { return false }
    return rowTabId == focusedTabId
}

// MARK: - SplitNodeModel Operations

func allPaneIds(_ node: SplitNodeModel) -> [PaneId] {
  switch node {
  case .leaf(let pane):
    return [pane.id]
  case .split(_, _, let first, let second, _):
    return allPaneIds(first) + allPaneIds(second)
  }
}

/// All PaneModels in a node, in left-to-right tree order.
func panesInNode(_ node: SplitNodeModel) -> [PaneModel] {
  switch node {
  case .leaf(let pane):
    return [pane]
  case .split(_, _, let first, let second, _):
    return panesInNode(first) + panesInNode(second)
  }
}

/// Find the pane with the given id within a node. Backs `AppModel.pane(_:)`.
func paneInNode(_ node: SplitNodeModel, id: PaneId) -> PaneModel? {
  switch node {
  case .leaf(let pane):
    return pane.id == id ? pane : nil
  case .split(_, _, let first, let second, _):
    return paneInNode(first, id: id) ?? paneInNode(second, id: id)
  }
}

/// Rebuild a node with `body` applied to the leaf owning `id`, rebuilding only
/// the spine down to that leaf (the `setRatio` pattern). Returns nil if `id` is
/// not in this subtree, letting the caller try a sibling. Stops at the first
/// match -- pane ids are unique, so `body` runs at most once.
func updatePaneInNode(_ node: SplitNodeModel, id: PaneId, _ body: (inout PaneModel) -> Void) -> SplitNodeModel? {
  switch node {
  case .leaf(var pane):
    guard pane.id == id else { return nil }
    body(&pane)
    return .leaf(pane)
  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = updatePaneInNode(first, id: id, body) {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = updatePaneInNode(second, id: id, body) {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

/// Compute the model-derived renderer visibility for every pane in every tab.
func effectiveSurfaceVisibility(in model: AppModel, windowVisible: Bool) -> [PaneId: Bool] {
  var result: [PaneId: Bool] = [:]
  let selectedTabId = model.selectedTabId

  for group in model.groups {
    for tab in group.tabs {
      let tabIsSelected = tab.id == selectedTabId
      for paneId in allPaneIds(tab.rootNode) {
        let visible = windowVisible
          && tabIsSelected
          && !(tab.isZoomed && paneId != tab.focusedPaneId)
        result[paneId] = visible
      }
    }
  }

  return result
}

func firstLeafId(_ node: SplitNodeModel) -> PaneId {
  switch node {
  case .leaf(let pane):
    return pane.id
  case .split(_, _, let first, _, _):
    return firstLeafId(first)
  }
}

func lastLeafId(_ node: SplitNodeModel) -> PaneId {
  switch node {
  case .leaf(let pane):
    return pane.id
  case .split(_, _, _, let second, _):
    return lastLeafId(second)
  }
}

func splitLeaf(
  _ node: SplitNodeModel, paneId: PaneId, direction: SplitNodeModel.Direction, newPane: PaneModel
) -> SplitNodeModel? {
  switch node {
  case .leaf(let pane):
    if pane.id == paneId {
      return .split(
        id: SplitId(),
        direction: direction,
        first: .leaf(pane),
        second: .leaf(newPane),
        ratio: 0.5
      )
    }
    return nil

  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = splitLeaf(first, paneId: paneId, direction: direction, newPane: newPane) {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = splitLeaf(second, paneId: paneId, direction: direction, newPane: newPane)
    {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

/// Remove a leaf from the tree. Returns (newTree, nextFocusPaneId, removed).
/// newTree is nil if the removed leaf was the only node (root leaf). `removed`
/// is the PaneModel that lived at that leaf, or nil if `paneId` wasn't found:
/// close paths discard it, move paths re-insert it so cwd/theme/todos travel
/// with the pane to its new position.
func removeLeaf(_ node: SplitNodeModel, paneId: PaneId) -> (SplitNodeModel?, PaneId?, PaneModel?) {
  switch node {
  case .leaf(let pane):
    if pane.id == paneId {
      return (nil, nil, pane)
    }
    return (node, nil, nil)

  case .split(let splitId, let dir, let first, let second, let ratio):
    // Check if either direct child is the target leaf
    if case .leaf(let firstPane) = first, firstPane.id == paneId {
      return (second, firstLeafId(second), firstPane)
    }
    if case .leaf(let secondPane) = second, secondPane.id == paneId {
      return (first, lastLeafId(first), secondPane)
    }

    // Recurse into children
    let (newFirst, focusFromFirst, removedFromFirst) = removeLeaf(first, paneId: paneId)
    if let newFirst = newFirst, newFirst != first {
      return (
        .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio),
        focusFromFirst,
        removedFromFirst
      )
    }

    let (newSecond, focusFromSecond, removedFromSecond) = removeLeaf(second, paneId: paneId)
    if let newSecond = newSecond, newSecond != second {
      return (
        .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio),
        focusFromSecond,
        removedFromSecond
      )
    }

    return (node, nil, nil)
  }
}

/// Swap two leaves' whole PaneModel payloads throughout the tree -- the pane at
/// `a`'s position lands at `b`'s position and vice versa, carrying their full
/// content (cwd/theme/todos). Returns nil if either ID is missing.
func swapLeaves(_ node: SplitNodeModel, _ a: PaneId, _ b: PaneId) -> SplitNodeModel? {
  guard a != b else { return nil }
  guard let paneA = paneInNode(node, id: a), let paneB = paneInNode(node, id: b) else { return nil }
  return swapLeavesInner(node, a: a, b: b, paneA: paneA, paneB: paneB)
}

private func swapLeavesInner(
  _ node: SplitNodeModel, a: PaneId, b: PaneId, paneA: PaneModel, paneB: PaneModel
) -> SplitNodeModel {
  switch node {
  case .leaf(let pane):
    if pane.id == a { return .leaf(paneB) }
    if pane.id == b { return .leaf(paneA) }
    return node
  case .split(let splitId, let dir, let first, let second, let ratio):
    return .split(
      id: splitId, direction: dir,
      first: swapLeavesInner(first, a: a, b: b, paneA: paneA, paneB: paneB),
      second: swapLeavesInner(second, a: a, b: b, paneA: paneA, paneB: paneB),
      ratio: ratio
    )
  }
}

/// Remove source from tree and split-insert it at target's position.
/// Returns nil if source == target, either is missing, or source is the root leaf.
func moveLeaf(
  _ node: SplitNodeModel,
  source: PaneId,
  target: PaneId,
  direction: SplitNodeModel.Direction,
  insertFirst: Bool
) -> SplitNodeModel? {
  guard source != target else { return nil }
  let ids = Set(allPaneIds(node))
  guard ids.contains(source), ids.contains(target) else { return nil }
  // Capture the removed pane's full payload and re-insert THAT, so cwd/theme/
  // todos move with the pane instead of being rebuilt as a fresh default leaf.
  let (stripped, _, removed) = removeLeaf(node, paneId: source)
  guard let stripped = stripped, let removed = removed else { return nil }
  return insertAtLeaf(
    stripped, at: target, inserting: removed, direction: direction, insertFirst: insertFirst)
}

/// Replace a target leaf with a split containing both the moved `source` pane
/// (its full payload, threaded from `removeLeaf`) and the original target leaf.
private func insertAtLeaf(
  _ node: SplitNodeModel,
  at targetId: PaneId,
  inserting source: PaneModel,
  direction: SplitNodeModel.Direction,
  insertFirst: Bool
) -> SplitNodeModel? {
  switch node {
  case .leaf(let pane):
    if pane.id == targetId {
      let first: SplitNodeModel = insertFirst ? .leaf(source) : .leaf(pane)
      let second: SplitNodeModel = insertFirst ? .leaf(pane) : .leaf(source)
      return .split(id: SplitId(), direction: direction, first: first, second: second, ratio: 0.5)
    }
    return nil
  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = insertAtLeaf(
      first, at: targetId, inserting: source, direction: direction, insertFirst: insertFirst)
    {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = insertAtLeaf(
      second, at: targetId, inserting: source, direction: direction, insertFirst: insertFirst)
    {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

func nearestLeaf(
  _ node: SplitNodeModel, from paneId: PaneId, direction: SplitNodeModel.Direction,
  side: SplitNodeModel.Side
) -> PaneId? {
  // Build path from root to paneId
  var path: [(SplitNodeModel, Bool)] = []  // (splitNode, isInFirstChild)
  if !buildPath(node, target: paneId, path: &path) { return nil }

  // Walk up the path looking for a split with matching direction where we can cross
  for i in stride(from: path.count - 1, through: 0, by: -1) {
    let (splitNode, isInFirst) = path[i]
    guard case .split(_, let dir, let first, let second, _) = splitNode else { continue }

    if dir == direction {
      switch side {
      case .second:
        if isInFirst {
          let hints = Array(path[(i + 1)...])
          return enterSubtree(second, navigating: direction, side: side, hints: hints)
        }
      case .first:
        if !isInFirst {
          let hints = Array(path[(i + 1)...])
          return enterSubtree(first, navigating: direction, side: side, hints: hints)
        }
      }
    }
  }

  return nil
}

/// Pick the best leaf when entering a sibling subtree.
/// For splits in the navigation direction, pick the near edge.
/// For perpendicular splits, preserve the source pane's position using path hints.
private func enterSubtree(
  _ node: SplitNodeModel, navigating direction: SplitNodeModel.Direction, side: SplitNodeModel.Side,
  hints: [(SplitNodeModel, Bool)]
) -> PaneId {
  switch node {
  case .leaf(let pane):
    return pane.id
  case .split(_, let dir, let first, let second, _):
    if dir == direction {
      // Same direction as navigation: pick the near edge
      switch side {
      case .first:
        return enterSubtree(second, navigating: direction, side: side, hints: hints)
      case .second:
        return enterSubtree(first, navigating: direction, side: side, hints: hints)
      }
    } else {
      // Perpendicular split: use hint from source pane's position if available
      let hint = hints.first(where: {
        if case .split(_, let hDir, _, _, _) = $0.0 { return hDir == dir }
        return false
      })
      let goFirst = hint?.1 ?? true
      return enterSubtree(goFirst ? first : second, navigating: direction, side: side, hints: hints)
    }
  }
}

private func buildPath(_ node: SplitNodeModel, target: PaneId, path: inout [(SplitNodeModel, Bool)])
  -> Bool
{
  switch node {
  case .leaf(let pane):
    return pane.id == target

  case .split(_, _, let first, let second, _):
    path.append((node, true))
    if buildPath(first, target: target, path: &path) { return true }
    path.removeLast()

    path.append((node, false))
    if buildPath(second, target: target, path: &path) { return true }
    path.removeLast()

    return false
  }
}

func setRatio(_ node: SplitNodeModel, splitId: SplitId, ratio: CGFloat) -> SplitNodeModel {
  switch node {
  case .leaf:
    return node
  case .split(let id, let dir, let first, let second, let currentRatio):
    if id == splitId {
      return .split(id: id, direction: dir, first: first, second: second, ratio: ratio)
    }
    return .split(
      id: id, direction: dir,
      first: setRatio(first, splitId: splitId, ratio: ratio),
      second: setRatio(second, splitId: splitId, ratio: ratio),
      ratio: currentRatio
    )
  }
}

// MARK: - AppModel Query Helpers

// Canonical primitive for index-based tab lookups.
func tabLocation(_ tabId: TabId, in model: AppModel) -> (groupIdx: Int, tabIdx: Int)? {
  for gi in model.groups.indices {
    if let ti = model.groups[gi].tabs.firstIndex(where: { $0.id == tabId }) {
      return (gi, ti)
    }
  }
  return nil
}

func tabById(_ tabId: TabId, in model: AppModel) -> TabModel? {
  guard let (gi, ti) = tabLocation(tabId, in: model) else { return nil }
  return model.groups[gi].tabs[ti]
}

func selectedTab(in model: AppModel) -> TabModel? {
  guard let id = model.selectedTabId else { return nil }
  return tabById(id, in: model)
}

func tabForPane(_ paneId: PaneId, in model: AppModel) -> TabModel? {
  for group in model.groups {
    for tab in group.tabs {
      if allPaneIds(tab.rootNode).contains(paneId) { return tab }
    }
  }
  return nil
}

func groupForTab(_ tabId: TabId, in model: AppModel) -> GroupModel? {
  return model.groups.first(where: { $0.tabs.contains(where: { $0.id == tabId }) })
}

func focusedPane(in model: AppModel) -> PaneModel? {
  guard let tab = selectedTab(in: model) else { return nil }
  return model.pane(tab.focusedPaneId)
}

func currentCwd(in model: AppModel) -> String? {
  if let pane = focusedPane(in: model), let cwd = pane.cwd { return cwd }
  // Fall back to most recent tab with a known cwd
  let allTabs = model.groups.flatMap(\.tabs)
  for tab in allTabs.reversed() {
    if let cwd = model.pane(tab.focusedPaneId)?.cwd { return cwd }
  }
  return nil
}

func paneIdsForTab(_ tabId: TabId, in model: AppModel) -> [PaneId] {
  for group in model.groups {
    if let tab = group.tabs.first(where: { $0.id == tabId }) {
      return allPaneIds(tab.rootNode)
    }
  }
  return []
}

func abbreviateHome(_ path: String) -> String {
  let home = NSHomeDirectory()
  guard path.hasPrefix(home) else { return path }
  return "~" + path.dropFirst(home.count)
}

/// Derive tab chrome (title/subtitle) from the focused pane.
func deriveTabChrome(from pane: PaneModel) -> (title: String, subtitle: String?) {
  let title = abbreviateHome(pane.title)
  let subtitle = pane.cwd.map { abbreviateHome($0) }
  return (title, subtitle)
}

/// Derive initial tab chrome from a pane snapshot at import time.
/// Uses resolveLaunch semantics so launch.cwd is preferred over pane.cwd.
func deriveTabChromeFromSnapshot(_ ps: PaneSnapshot) -> (title: String, subtitle: String?) {
  let title = abbreviateHome(ps.title ?? "Terminal")
  let (resolvedCwd, _) = resolveLaunch(ps)
  let subtitle = resolvedCwd.map { abbreviateHome($0) }
  return (title, subtitle)
}

func adjacentTabId(direction: TabDirection, in model: AppModel) -> TabId? {
  let allTabs = model.groups.flatMap(\.tabs)
  guard let idx = allTabs.firstIndex(where: { $0.id == model.selectedTabId }) else { return nil }
  let count = allTabs.count
  let newIdx: Int
  switch direction {
  case .next: newIdx = (idx + 1) % count
  case .prev: newIdx = (idx - 1 + count) % count
  }
  return allTabs[newIdx].id
}

// MARK: - Termination Helpers

func totalTabCount(_ model: AppModel) -> Int {
  model.groups.flatMap(\.tabs).count
}

func wouldQuitFromClose(_ model: AppModel) -> Bool {
  totalTabCount(model) == 1
}

// Single chokepoint for asking the user before quitting. Returns no commands
// when any confirmation sheet is already in flight.
func emitTerminateConfirmation(_ model: inout AppModel) -> [Command] {
  guard model.pendingConfirmation == nil else { return [] }
  model.pendingConfirmation = .terminate
  return [.showTerminateConfirmation(paneCount: model.allPaneIds.count)]
}

// Single chokepoint for asking before closing a multi-pane tab. It guards the
// same slot as quit confirmation so close-tab and quit sheets cannot stack.
// `uncompletedTodoCount` is the full tab + pane rollup (see `tabTodoRollup`).
func emitCloseTabConfirmation(
  _ model: inout AppModel, tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool,
  uncompletedTodoCount: Int
) -> [Command] {
  guard model.pendingConfirmation == nil else { return [] }
  model.pendingConfirmation = .closeTab
  return [.showCloseTabConfirmation(
    tabId: tabId,
    tabTitle: tabTitle,
    paneCount: paneCount,
    isLastTab: isLastTab,
    uncompletedTodoCount: uncompletedTodoCount
  )]
}

// Single chokepoint for asking before closing a tab batch. It uses the same
// pending-confirmation slot as single-tab close and quit confirmations.
func emitCloseTabsConfirmation(_ model: inout AppModel, ids: [TabId]) -> [Command] {
  guard model.pendingConfirmation == nil else { return [] }
  model.pendingConfirmation = .closeTab

  var totalPaneCount = 0
  var totalUncompletedTodos = 0
  for id in ids {
    guard let tab = tabById(id, in: model) else { continue }
    totalPaneCount += allPaneIds(tab.rootNode).count
    totalUncompletedTodos += tabTodoRollup(id, in: model).uncompleted
  }

  return [.showCloseTabsConfirmation(
    tabIds: ids,
    tabCount: ids.count,
    totalPaneCount: totalPaneCount,
    totalUncompletedTodos: totalUncompletedTodos,
    isQuit: ids.count == totalTabCount(model)
  )]
}

/// Total + uncompleted count for a tab's own to-dos plus every pane's
/// to-dos inside that tab. Pure: same input -> same output.
func tabTodoRollup(_ tabId: TabId, in model: AppModel) -> (total: Int, uncompleted: Int) {
  guard let tab = tabById(tabId, in: model) else { return (0, 0) }
  var total = tab.todos.count
  var uncompleted = tab.todos.count { !$0.isDone }
  for paneId in allPaneIds(tab.rootNode) {
    guard let todos = model.pane(paneId)?.todos else { continue }
    total += todos.count
    uncompleted += todos.count { !$0.isDone }
  }
  return (total, uncompleted)
}

// MARK: - Tab Todo Popover

enum TabTodoRow: Equatable {
  case tabSectionHeader
  case tabItem(TodoItem)
  case tabEmptyPlaceholder
  case paneSectionHeader(paneId: PaneId, title: String)
  case paneItem(paneId: PaneId, item: TodoItem)
  case paneEmptyPlaceholder(paneId: PaneId)
}

enum TabTodoEditTarget: Equatable {
  case tab(todoId: UUID)
  case pane(paneId: PaneId, todoId: UUID)
}

enum TabTodoDropOperation: Equatable {
  case on
  case above
}

enum TabTodoReorderStep: Equatable {
  case reorderInSection(toIndex: Int)
  case moveToBucket(destination: TodoDestination, atIndex: Int)
}

extension TabTodoRow {
  var isHeader: Bool {
    switch self {
    case .tabSectionHeader, .paneSectionHeader:
      return true
    case .tabItem, .tabEmptyPlaceholder, .paneItem, .paneEmptyPlaceholder:
      return false
    }
  }

  var isSelectable: Bool {
    switch self {
    case .tabItem, .paneItem:
      return true
    case .tabSectionHeader, .tabEmptyPlaceholder, .paneSectionHeader, .paneEmptyPlaceholder:
      return false
    }
  }

  var editTarget: TabTodoEditTarget? {
    switch self {
    case .tabItem(let item):
      return .tab(todoId: item.id)
    case .paneItem(let paneId, let item):
      return .pane(paneId: paneId, todoId: item.id)
    case .tabSectionHeader, .tabEmptyPlaceholder, .paneSectionHeader, .paneEmptyPlaceholder:
      return nil
    }
  }

  var itemText: String? {
    switch self {
    case .tabItem(let item), .paneItem(_, let item):
      return item.text
    case .tabSectionHeader, .tabEmptyPlaceholder, .paneSectionHeader, .paneEmptyPlaceholder:
      return nil
    }
  }

  var sectionIdentifier: AnyHashable? {
    switch self {
    case .tabSectionHeader, .tabItem, .tabEmptyPlaceholder:
      return AnyHashable("tab")
    case .paneSectionHeader(let paneId, _), .paneItem(let paneId, _), .paneEmptyPlaceholder(let paneId):
      return AnyHashable(paneId)
    }
  }
}

func tabTodoItemCount(_ tabId: TabId, in model: AppModel) -> Int {
  guard let tab = tabById(tabId, in: model) else { return 0 }
  var total = tab.todos.count
  for paneId in allPaneIds(tab.rootNode) {
    total += model.pane(paneId)?.todos.count ?? 0
  }
  return total
}

func buildTabTodoRows(model: AppModel, tabId: TabId) -> [TabTodoRow] {
  guard let tab = tabById(tabId, in: model) else { return [] }
  var rows: [TabTodoRow] = [.tabSectionHeader]
  if tab.todos.isEmpty {
    rows.append(.tabEmptyPlaceholder)
  } else {
    for item in tab.todos {
      rows.append(.tabItem(item))
    }
  }
  for paneId in allPaneIds(tab.rootNode) {
    guard let pane = model.pane(paneId) else { continue }
    rows.append(.paneSectionHeader(paneId: paneId, title: pane.title))
    if pane.todos.isEmpty {
      rows.append(.paneEmptyPlaceholder(paneId: paneId))
    } else {
      for item in pane.todos {
        rows.append(.paneItem(paneId: paneId, item: item))
      }
    }
  }
  return rows
}

func resolveTabTodoDropTarget(
  rows: [TabTodoRow],
  model: AppModel,
  tabId: TabId,
  proposedRow: Int,
  dropOperation: TabTodoDropOperation
) -> (destination: TodoDestination, atIndex: Int)? {
  switch dropOperation {
  case .on:
    guard rows.indices.contains(proposedRow) else { return nil }
    switch rows[proposedRow] {
    case .tabSectionHeader:
      guard let tab = tabById(tabId, in: model) else { return nil }
      return (.tab(tabId), tab.todos.count)
    case .paneSectionHeader(let paneId, _):
      guard let pane = model.pane(paneId) else { return nil }
      return (.pane(paneId), pane.todos.count)
    case .tabEmptyPlaceholder:
      return (.tab(tabId), 0)
    case .paneEmptyPlaceholder(let paneId):
      guard model.pane(paneId) != nil else { return nil }
      return (.pane(paneId), 0)
    case .tabItem, .paneItem:
      return nil
    }

  case .above:
    guard proposedRow >= 0, proposedRow <= rows.count else { return nil }
    if proposedRow == rows.count {
      guard let last = rows.last,
            let destination = tabTodoDestination(for: last, tabId: tabId),
            let count = tabTodoCount(for: destination, in: model) else { return nil }
      return (destination, count)
    }

    switch rows[proposedRow] {
    case .tabSectionHeader:
      return nil
    case .paneSectionHeader:
      guard proposedRow > 0,
            let destination = tabTodoDestination(for: rows[proposedRow - 1], tabId: tabId),
            let count = tabTodoCount(for: destination, in: model) else { return nil }
      return (destination, count)
    case .tabItem:
      let atIndex = rows[..<proposedRow].count { row in
        if case .tabItem = row { return true }
        return false
      }
      return (.tab(tabId), atIndex)
    case .tabEmptyPlaceholder:
      return (.tab(tabId), 0)
    case .paneItem(let paneId, _):
      guard model.pane(paneId) != nil else { return nil }
      let atIndex = rows[..<proposedRow].count { row in
        if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
        return false
      }
      return (.pane(paneId), atIndex)
    case .paneEmptyPlaceholder(let paneId):
      guard model.pane(paneId) != nil else { return nil }
      return (.pane(paneId), 0)
    }
  }
}

func resolveTabTodoBucketStep(
  current: TabTodoEditTarget,
  paneOrder: [PaneId],
  tabId: TabId,
  delta: Int
) -> TodoDestination? {
  guard delta != 0 else { return nil }
  let currentIndex: Int
  switch current {
  case .tab:
    currentIndex = 0
  case .pane(let paneId, _):
    guard let paneIndex = paneOrder.firstIndex(of: paneId) else { return nil }
    currentIndex = paneIndex + 1
  }

  let destinationIndex = currentIndex + delta
  guard destinationIndex >= 0, destinationIndex <= paneOrder.count else { return nil }
  if destinationIndex == 0 { return .tab(tabId) }
  return .pane(paneOrder[destinationIndex - 1])
}

// Resolves Shift-J/K as movement through the tab section and pane sections as
// one continuous list, leaving the caller to dispatch the matching Msg.
func resolveTabTodoReorderStep(
  current: TabTodoEditTarget,
  paneOrder: [PaneId],
  tabId: TabId,
  currentIndex: Int,
  currentSectionCount: Int,
  destinationSectionCount: (TodoDestination) -> Int,
  delta: Int
) -> TabTodoReorderStep? {
  guard delta == 1 || delta == -1,
        currentIndex >= 0,
        currentIndex < currentSectionCount else { return nil }

  if delta > 0 {
    if currentIndex + 1 < currentSectionCount {
      return .reorderInSection(toIndex: currentIndex + 1)
    }
    guard let destination = resolveTabTodoBucketStep(
      current: current,
      paneOrder: paneOrder,
      tabId: tabId,
      delta: delta
    ) else { return nil }
    return .moveToBucket(destination: destination, atIndex: 0)
  }

  if currentIndex > 0 {
    return .reorderInSection(toIndex: currentIndex - 1)
  }
  guard let destination = resolveTabTodoBucketStep(
    current: current,
    paneOrder: paneOrder,
    tabId: tabId,
    delta: delta
  ) else { return nil }
  return .moveToBucket(destination: destination, atIndex: destinationSectionCount(destination))
}

private func tabTodoDestination(for row: TabTodoRow, tabId: TabId) -> TodoDestination? {
  switch row {
  case .tabSectionHeader, .tabItem, .tabEmptyPlaceholder:
    return .tab(tabId)
  case .paneSectionHeader(let paneId, _), .paneItem(let paneId, _), .paneEmptyPlaceholder(let paneId):
    return .pane(paneId)
  }
}

private func tabTodoCount(for destination: TodoDestination, in model: AppModel) -> Int? {
  switch destination {
  case .tab(let tabId):
    return tabById(tabId, in: model)?.todos.count
  case .pane(let paneId):
    return model.pane(paneId)?.todos.count
  }
}

// Converts the AppKit close-tab alert response into an explicit Msg so both
// confirm and cancel paths can clear pending confirmation state.
func closeTabConfirmationResponse(isConfirm: Bool, tabId: TabId) -> Msg {
  isConfirm ? .confirmCloseTab(id: tabId) : .cancelCloseTab
}

// Converts the AppKit close-tabs alert response into an explicit Msg so both
// confirm and cancel paths can clear pending confirmation state.
func closeTabsConfirmationResponse(isConfirm: Bool, ids: [TabId]) -> Msg {
  isConfirm ? .confirmCloseTabs(ids: ids) : .cancelCloseTabs
}

/// Build the close-tabs confirmation copy. Mentions extra panes beyond one per
/// tab and unfinished tasks, matching the details the tab badges advertise.
func closeTabsConfirmationCopy(
  tabCount: Int,
  totalPaneCount: Int,
  totalUncompletedTodos: Int,
  isQuit: Bool
) -> String {
  var parts: [String] = []
  if totalPaneCount > tabCount {
    parts.append("\(totalPaneCount) terminal panes")
  }
  if totalUncompletedTodos > 0 {
    let label = totalUncompletedTodos == 1 ? "1 unfinished task" : "\(totalUncompletedTodos) unfinished tasks"
    parts.append(label)
  }

  let prefix: String
  if parts.isEmpty {
    prefix = "These tabs will be closed."
  } else if parts.count == 1 {
    prefix = "These tabs have \(parts[0])."
  } else {
    prefix = "These tabs have \(parts[0]) and \(parts[1])."
  }

  if isQuit {
    return prefix + " Closing them will quit DanTerm."
  }
  return prefix
}

// MARK: - Restore

struct ValidatedAppRestore {
  let snapshot: AppModelSnapshot
  let model: AppModel
  let paneSnapshots: [PaneId: PaneSnapshot]
}

enum AppInitFileLoadError: Error, Equatable {
  case decodeFailed
  case unsupportedVersion(Int)
  case invalidSnapshot
}

/// Decode a saved init file and validate that its snapshot can be rebuilt.
func loadValidatedInitFile(from data: Data) throws -> ValidatedAppRestore {
  let initFile: AppInitFile
  do {
    initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
  } catch {
    throw AppInitFileLoadError.decodeFailed
  }

  // Require the current leaf-embedded version. v1 (flat panes array) is rejected
  // outright -- no version-dispatch fork, no one-shot importer. A v1 checkpoint
  // on the first post-upgrade launch falls through to a fresh session.
  guard initFile.version == appInitFileVersion else {
    throw AppInitFileLoadError.unsupportedVersion(initFile.version)
  }

  guard let built = validateAndBuildDetailed(initFile.model) else {
    throw AppInitFileLoadError.invalidSnapshot
  }

  return ValidatedAppRestore(
    snapshot: initFile.model,
    model: built.model,
    paneSnapshots: built.paneSnapshots
  )
}

/// Parse the restore command behavior from CLI arguments.
/// Defaults to `.prefill` to avoid surprising command execution during restore.
func restoreCommandBehavior(from arguments: [String]) -> RestoreCommandBehavior {
  guard let idx = arguments.firstIndex(of: "--restore-commands"),
    idx + 1 < arguments.count
  else {
    return .prefill
  }

  switch arguments[idx + 1] {
  case RestoreCommandBehavior.execute.rawValue:
    return .execute
  case RestoreCommandBehavior.prefill.rawValue:
    return .prefill
  default:
    return .prefill
  }
}

/// Convert saved command metadata into live shell input for restore.
/// `.prefill` restores the draft command without executing it.
func restoreInitialInput(for command: String?, behavior: RestoreCommandBehavior) -> String? {
  guard let command, !command.isEmpty else { return nil }
  switch behavior {
  case .prefill:
    return command
  case .execute:
    return command.hasSuffix("\n") ? command : command + "\n"
  }
}

// MARK: - Alert Helpers

enum AlertTab: Int { case unread = 0, history = 1 }

func filteredAlerts(_ alerts: [AlertModel], tab: AlertTab) -> [AlertModel] {
    switch tab {
    case .unread: return alerts.filter(\.isUnread)
    case .history: return alerts
    }
}

func alertsEmptyText(tab: AlertTab) -> String {
    switch tab {
    case .unread: return "No unread alerts"
    case .history: return "No alerts"
    }
}

func paneHasUnreadAlert(_ paneId: PaneId, alerts: [AlertModel]) -> Bool {
  alerts.contains { $0.isUnread && $0.paneId == paneId }
}

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

// MARK: - View Reconciler (pure projections + diff)

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

func unreadAlertCount(for tab: TabModel, alerts: [AlertModel]) -> Int {
  let paneIds = Set(allPaneIds(tab.rootNode))
  return alerts.filter { $0.isUnread && paneIds.contains($0.paneId) }.count
}

func groupUnreadAlertCount(for group: GroupModel, alerts: [AlertModel]) -> Int {
  group.tabs.reduce(0) { $0 + unreadAlertCount(for: $1, alerts: alerts) }
}

func totalUnreadAlertCount(model: AppModel) -> Int {
  model.alerts.filter(\.isUnread).count
}

// MARK: - Window Chrome Projection (reconcileWindowChrome)

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

/// Structural fingerprint of a split tree: split ids + directions + leaf pane ids,
/// with ratios and the leaf PaneModel payload dropped. Equatable so two trees that
/// differ only in ratio or payload compare equal.
indirect enum ContainerShapeNode: Equatable {
  case leaf(PaneId)
  case split(id: SplitId, direction: SplitNodeModel.Direction, first: ContainerShapeNode, second: ContainerShapeNode)
}

/// What a tab's container is built from, reduced to the inputs that require a
/// rebuild: the tree's structural fingerprint plus the zoom state (a zoomed tab
/// renders only its focused leaf, so the zoom flag and the zoomed leaf id are part
/// of the shape). Ratios and pane payloads are excluded via `ContainerShapeNode`.
struct ContainerShape: Equatable {
  let tree: ContainerShapeNode
  let isZoomed: Bool
  // focusedPaneId while zoomed; nil otherwise -- so a focus change in an unzoomed
  // tab does NOT drift the shape (which is why a pane click never rebuilds).
  let zoomedLeaf: PaneId?
}

/// Reduce a split tree to its structural fingerprint (drops ratios + payload).
func containerShapeNode(_ node: SplitNodeModel) -> ContainerShapeNode {
  switch node {
  case .leaf(let pane):
    return .leaf(pane.id)
  case .split(let id, let dir, let first, let second, _):
    return .split(id: id, direction: dir, first: containerShapeNode(first), second: containerShapeNode(second))
  }
}

/// The container shape for one tab.
func containerShape(of tab: TabModel) -> ContainerShape {
  ContainerShape(
    tree: containerShapeNode(tab.rootNode),
    isZoomed: tab.isZoomed,
    zoomedLeaf: tab.isZoomed ? tab.focusedPaneId : nil
  )
}

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

/// Clear the open-TODO-popover model record on a view swap (tab switch or visible
/// container rebuild). The record drives guards + close callbacks but is never read
/// by the reconciler to *present* a popover; the matching AppKit dismiss lives in
/// `reconcileContainers`. Placed by a 1:1 rule wherever the migration removed a
/// `.showSelectedTab` emission or a visible-tab `.rebuildTabContainer`, preserving
/// today's `prepareForViewSwap` clearing.
func clearTodoPopoverForViewSwap(_ model: inout AppModel) {
  model.todoPopover = nil
}

// MARK: - Delete Group

// Determines whether deleting a group requires user confirmation.
enum DeleteGroupAction {
  case deleteImmediately(groupId: GroupId)
  case confirm(groupId: GroupId, name: String, tabCount: Int)
}

func adjacentGroupIndex(deletingAt idx: Int, count: Int) -> Int? {
  guard count > 1 else { return nil }
  return idx > 0 ? idx - 1 : 1
}

func deleteGroupAction(for groupId: GroupId, in model: AppModel) -> DeleteGroupAction? {
  guard let group = model.groups.first(where: { $0.id == groupId }),
    model.groups.count > 1
  else { return nil }
  if group.tabs.isEmpty {
    return .deleteImmediately(groupId: groupId)
  } else {
    return .confirm(groupId: groupId, name: group.name, tabCount: group.tabs.count)
  }
}

// MARK: - Export

func toInitFile(_ model: AppModel) -> AppInitFile {
  toInitFile(snapshot: toSnapshot(model))
}

/// Wrap an already-built snapshot (e.g. a scrollback-grafted one) in the current
/// init-file version. Single source of truth for the written version.
func toInitFile(snapshot: AppModelSnapshot) -> AppInitFile {
  AppInitFile(version: appInitFileVersion, model: snapshot)
}

func toSnapshot(_ model: AppModel) -> AppModelSnapshot {
  let groupSnapshots: [GroupSnapshot] = model.groups.map { group in
    let tabSnapshots: [TabSnapshot] = group.tabs.map { tab in
      let tabTodoSnapshots: [TodoSnapshot]? = tab.todos.isEmpty ? nil : tab.todos.map {
        TodoSnapshot(id: $0.id.uuidString, text: $0.text, isDone: $0.isDone)
      }
      var tabSnapshot = TabSnapshot(
        id: tab.id.rawValue.uuidString,
        customTitle: tab.customTitle,
        focusedPaneId: tab.focusedPaneId.rawValue.uuidString,
        rootNode: toSplitNodeSnapshot(tab.rootNode),
        color: tab.color
      )
      tabSnapshot.todos = tabTodoSnapshots
      return tabSnapshot
    }
    return GroupSnapshot(
      id: group.id.rawValue.uuidString,
      name: group.name,
      isCollapsed: group.isCollapsed,
      tabs: tabSnapshots
    )
  }

  return AppModelSnapshot(
    groups: groupSnapshots,
    selectedTabId: model.selectedTabId?.rawValue.uuidString
  )
}

/// Build the PaneSnapshot embedded in a leaf, reading the leaf's PaneModel
/// directly. Always emits `scrollback: nil`; scrollback is grafted separately
/// (graftScrollback) from a live-surface read so this stays pure.
private func toPaneSnapshot(_ pane: PaneModel) -> PaneSnapshot {
  let abbrevCwd = pane.cwd.map { abbreviateHome($0) }
  let launch: PaneLaunchSnapshot?
  if pane.lastCommand != nil || abbrevCwd != nil {
    launch = PaneLaunchSnapshot(command: pane.lastCommand, cwd: abbrevCwd)
  } else {
    launch = nil
  }
  let todoSnapshots: [TodoSnapshot]? = pane.todos.isEmpty ? nil : pane.todos.map {
    TodoSnapshot(id: $0.id.uuidString, text: $0.text, isDone: $0.isDone)
  }
  var snapshot = PaneSnapshot(
    id: pane.id.rawValue.uuidString,
    title: pane.title,
    cwd: abbrevCwd,
    launch: launch,
    scrollback: nil,
    theme: pane.theme
  )
  snapshot.todos = todoSnapshots
  return snapshot
}

private func toSplitNodeSnapshot(_ node: SplitNodeModel) -> SplitNodeSnapshot {
  switch node {
  case .leaf(let pane):
    return .leaf(toPaneSnapshot(pane))
  case .split(let id, let direction, let first, let second, let ratio):
    let dirStr: String
    switch direction {
    case .horizontal: dirStr = "horizontal"
    case .vertical: dirStr = "vertical"
    }
    return .split(
      id: id.rawValue.uuidString,
      direction: dirStr,
      first: toSplitNodeSnapshot(first),
      second: toSplitNodeSnapshot(second),
      ratio: Double(ratio)
    )
  }
}

/// Embed scrollback text into a snapshot's tree leaves, keyed by pane id. Pure:
/// the live-surface read is the separate impure `scrollbackByPaneId()` step in
/// AppRuntime. Used by both `.exportState` and the enriched checkpoint.
func graftScrollback(onto snapshot: AppModelSnapshot, scrollbackByPaneId: [PaneId: String]) -> AppModelSnapshot {
  AppModelSnapshot(
    groups: snapshot.groups.map { group in
      GroupSnapshot(
        id: group.id,
        name: group.name,
        isCollapsed: group.isCollapsed,
        tabs: group.tabs.map { tab in
          TabSnapshot(
            id: tab.id,
            customTitle: tab.customTitle,
            focusedPaneId: tab.focusedPaneId,
            rootNode: graftScrollbackIntoNode(tab.rootNode, scrollbackByPaneId),
            color: tab.color,
            todos: tab.todos
          )
        }
      )
    },
    selectedTabId: snapshot.selectedTabId
  )
}

private func graftScrollbackIntoNode(_ node: SplitNodeSnapshot, _ scrollbackByPaneId: [PaneId: String]) -> SplitNodeSnapshot {
  switch node {
  case .leaf(var ps):
    if let idStr = ps.id, let uuid = UUID(uuidString: idStr),
       let scrollback = scrollbackByPaneId[PaneId(rawValue: uuid)] {
      ps.scrollback = scrollback
    }
    return .leaf(ps)
  case .split(let id, let direction, let first, let second, let ratio):
    return .split(
      id: id,
      direction: direction,
      first: graftScrollbackIntoNode(first, scrollbackByPaneId),
      second: graftScrollbackIntoNode(second, scrollbackByPaneId),
      ratio: ratio
    )
  }
}

// MARK: - Recovery Paths
//
// Session persistence lives in
// ~/Library/Application Support/<bundle-id>/Recovery/:
//   last-light.json    — frequent structural checkpoint (no scrollback, 2s debounce)
//   last-enriched.json — periodic full checkpoint (structure + scrollback, 60s timer)
//   session.json       — lock file, written at launch and deleted on clean exit
//
// Namespacing by bundle ID isolates DanTerm.app (com.danneu.danterm) from
// DanTerm Dev.app (com.danneu.danterm-dev) so the dev build never restores
// from a prod session and vice versa. The bundleId parameter exists for
// tests; production code always takes the default.

func recoveryDirectoryURL(
    bundleId: String = Bundle.main.bundleIdentifier ?? "com.danneu.danterm"
) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleId, isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
}

func lightCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-light.json")
}

func enrichedCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-enriched.json")
}

/// Merge an enriched restore's scrollback into a light restore's pane map.
/// Both inputs are already validated, so this skips re-validation and never
/// tree-walks: it grafts `enriched.paneSnapshots[id].scrollback` into light's
/// [PaneId: PaneSnapshot] map by id. Light is authoritative for structure/model
/// (a pane only in enriched is ignored; a pane only in light keeps nil scrollback).
func mergeCheckpoints(light: ValidatedAppRestore, enriched: ValidatedAppRestore) -> ValidatedAppRestore {
    var mergedPaneSnapshots = light.paneSnapshots
    for (id, scrollback) in enriched.paneSnapshots.compactMapValues(\.scrollback) {
        guard var ps = mergedPaneSnapshots[id] else { continue }
        ps.scrollback = scrollback
        mergedPaneSnapshots[id] = ps
    }
    return ValidatedAppRestore(
        snapshot: light.snapshot,
        model: light.model,
        paneSnapshots: mergedPaneSnapshots
    )
}

func sessionLockURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("session.json")
}

// MARK: - Session Lock I/O
//
// All session lock serialization goes through these three helpers so the
// JSON encoder/decoder date strategy (.iso8601) is configured in one place.

/// Write a session lock file at launch. Its presence at next launch means the
/// previous exit was unclean — no PID liveness check needed.
func writeSessionLockFile() {
    let lock = SessionLock(pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(lock) else { return }
    let dir = recoveryDirectoryURL()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: sessionLockURL(), options: .atomic)
}

/// Read the session lock if it exists (non-nil = previous exit was unclean).
func readSessionLockFile() -> SessionLock? {
    guard let data = try? Data(contentsOf: sessionLockURL()) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionLock.self, from: data)
}

/// Delete the session lock on clean termination.
func deleteSessionLockFile() {
    try? FileManager.default.removeItem(at: sessionLockURL())
}

// MARK: - Scrollback Truncation

/// Truncate scrollback text to the last `maxLines` lines and `maxChars` characters.
/// Strips trailing whitespace-only lines. Returns nil for empty/whitespace-only input.
func truncateScrollback(_ text: String, maxLines: Int = 4000, maxChars: Int = 400_000) -> String? {
  // Strip trailing whitespace
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  // Keep the last maxLines lines via backward newline scan
  var newlineCount = 0
  var cutIndex: String.Index? = nil
  for i in trimmed.indices.reversed() {
    if trimmed[i] == "\n" {
      newlineCount += 1
      if newlineCount == maxLines {
        cutIndex = trimmed.index(after: i)
        break
      }
    }
  }
  var result = cutIndex != nil ? String(trimmed[cutIndex!...]) + "\n" : trimmed + "\n"

  // If still over maxChars, take last maxChars breaking at nearest newline
  if result.count > maxChars {
    let tail = result.suffix(maxChars)
    if let newlineIdx = tail.firstIndex(of: "\n") {
      result = String(tail[tail.index(after: newlineIdx)...])
    } else {
      result = String(tail)
    }
  }

  return result
}

// MARK: - DanTerm Event Protocol

enum DantermEvent: Equatable {
  case commandStarted(command: String)
  case commandEnded
  case remoteStart
  case remoteSession(value: RemoteSession)
}

/// Token store for pane-to-token mapping. Used by AppRuntime; extracted here for testability.
struct PaneTokenStore {
  private(set) var tokens: [PaneId: String] = [:]

  mutating func generate(for paneId: PaneId) -> String {
    let token = UUID().uuidString
    tokens[paneId] = token
    return token
  }

  mutating func remove(_ paneId: PaneId) {
    tokens.removeValue(forKey: paneId)
  }

  func token(for paneId: PaneId) -> String? {
    tokens[paneId]
  }
}

/// How send() should drive reconcile() for a translated message.
enum ReconcileDecision: Equatable {
  case reconcileNow
  case scheduleCoalesced
  case coalesceIntoPending
}

/// Classify reconcile scheduling separately from the DispatchSourceTimer glue.
func reconcileDecision(
  for msg: Msg,
  coalescedSweepPending: Bool,
  emitsPostReconcile: Bool
) -> ReconcileDecision {
  guard msg.coalescesReconcile, !emitsPostReconcile else { return .reconcileNow }
  return coalescedSweepPending ? .coalesceIntoPending : .scheduleCoalesced
}

/// Translate a Msg through the event protocol layer.
/// Returns nil when the message should be dropped (bad token, malformed event).
/// Normal (non-event) messages pass through unchanged.
func translateMsg(_ msg: Msg, tokenForPane: (PaneId) -> String?) -> Msg? {
  guard case .surfaceTitle(let paneId, let title) = msg,
    title.hasPrefix("__DANTERM_EVT__:")
  else {
    return msg
  }
  guard let token = tokenForPane(paneId),
    let event = parseDantermEvent(title, expectedToken: token)
  else {
    return nil
  }
  switch event {
  case .commandStarted(let command):
    return .commandStarted(paneId: paneId, command: command)
  case .commandEnded:
    return .commandEnded(paneId: paneId)
  case .remoteStart:
    return .remoteSessionStarted(paneId: paneId)
  case .remoteSession(let value):
    return .remoteSessionReported(paneId: paneId, session: value)
  }
}

func parseDantermEvent(_ raw: String, expectedToken: String) -> DantermEvent? {
  let prefix = "__DANTERM_EVT__:"
  guard raw.hasPrefix(prefix) else { return nil }
  let payload = String(raw.dropFirst(prefix.count))

  let parts = payload.split(separator: ":", maxSplits: 1)
  guard parts.count == 2, String(parts[0]) == expectedToken else { return nil }
  let event = String(parts[1])

  if event.hasPrefix("CMD_START:") {
    let b64 = String(event.dropFirst("CMD_START:".count))
    guard let data = Data(base64Encoded: b64),
      let cmd = String(data: data, encoding: .utf8),
      !cmd.isEmpty
    else { return nil }
    return .commandStarted(command: cmd)
  } else if event == "CMD_END" {
    return .commandEnded
  } else if event == "REMOTE_START" {
    return .remoteStart
  } else if event.hasPrefix("REMOTE_HOST:") {
    let payload = String(event.dropFirst("REMOTE_HOST:".count))
    let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let userB64 = String(parts[0])
    let hostB64 = String(parts[1])
    guard !userB64.isEmpty,
      !hostB64.isEmpty,
      let userData = Data(base64Encoded: userB64),
      let user = String(data: userData, encoding: .utf8),
      !user.isEmpty,
      let hostData = Data(base64Encoded: hostB64),
      let host = String(data: hostData, encoding: .utf8),
      !host.isEmpty
    else { return nil }
    return .remoteSession(value: RemoteSession(user: user, host: host))
  }
  return nil
}

// MARK: - MRU Tab Switcher

/// Move `value` to index 0 of the array, removing all other occurrences.
/// No-op if the value is not present.
func moveToFront<T: Equatable>(_ array: inout [T], _ value: T) {
  guard array.contains(value) else { return }
  array.removeAll { $0 == value }
  array.insert(value, at: 0)
}

/// Reconcile mruOrder against the live tab set.
/// Idempotent. Removes dead ids, deduplicates (first occurrence wins),
/// appends missing live tabs at the back, and (when not cycling) hoists
/// selectedTabId to index 0 so mruOrder[0] always equals the focused tab.
func reconcileMru(_ model: inout AppModel) {
  let liveTabs = Set(model.groups.flatMap(\.tabs).map(\.id))
  var seen = Set<TabId>()
  var rebuilt: [TabId] = []
  for tabId in model.mruOrder {
    guard liveTabs.contains(tabId), seen.insert(tabId).inserted else { continue }
    rebuilt.append(tabId)
  }
  for tab in model.groups.flatMap(\.tabs) where !seen.contains(tab.id) {
    rebuilt.append(tab.id)
    seen.insert(tab.id)
  }
  model.mruOrder = rebuilt
  if model.mruCycle == nil, let sel = model.selectedTabId {
    moveToFront(&model.mruOrder, sel)
  }
}

struct ResolvedCycle: Equatable {
  var liveOrder: [TabId]
  var cursorIndex: Int
}

/// Project frozenOrder through the current live tab set, with cursor remapping.
/// Cursor remap rules:
///   1. If the original cursor target is still live, point to its new index.
///   2. Otherwise, walk backward from the cursor through frozenOrder for the
///      nearest preceding live id (so the highlight does not skip forward).
///   3. If no preceding live id exists, fall back to liveOrder index 0.
/// Returns nil iff no tabs in frozenOrder remain live.
func resolveLiveCycle(_ cycle: MruCycleState, in model: AppModel) -> ResolvedCycle? {
  let liveTabs = Set(model.groups.flatMap(\.tabs).map(\.id))
  let live = cycle.frozenOrder.filter { liveTabs.contains($0) }
  guard !live.isEmpty else { return nil }

  let originalIdx = max(0, min(cycle.cursorIndex, cycle.frozenOrder.count - 1))
  let targetId = cycle.frozenOrder[originalIdx]
  if let liveIdx = live.firstIndex(of: targetId) {
    return ResolvedCycle(liveOrder: live, cursorIndex: liveIdx)
  }
  // Target was removed; walk backward through frozenOrder for the nearest
  // preceding live id.
  if originalIdx > 0 {
    for i in stride(from: originalIdx - 1, through: 0, by: -1) {
      if let liveIdx = live.firstIndex(of: cycle.frozenOrder[i]) {
        return ResolvedCycle(liveOrder: live, cursorIndex: liveIdx)
      }
    }
  }
  // No earlier live entry; fall back to live index 0.
  return ResolvedCycle(liveOrder: live, cursorIndex: 0)
}

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

// MARK: - Switcher Event Classifier

enum SwitcherInputKind: Equatable {
  case keyDown(keyCode: UInt16)
  case flagsChanged
}

struct SwitcherModifiers: OptionSet, Hashable {
  let rawValue: Int
  static let command = SwitcherModifiers(rawValue: 1 << 0)
  static let shift   = SwitcherModifiers(rawValue: 1 << 1)
  static let option  = SwitcherModifiers(rawValue: 1 << 2)
  static let control = SwitcherModifiers(rawValue: 1 << 3)
}

enum SwitcherAction: Equatable {
  case passthrough
  case stepOlder
  case stepNewer
  case cancel
  case commit
}

// MARK: - Tab Jump Mode

let jumpModeKeySequence: [Character] = Array("asdfghjkl;qwertyuiop[]zxcvbnm,./")

/// Assign one jump key to each visible tab row, capped by the fixed v1 key set.
func assignJumpKeys(visibleTabs: [TabId]) -> [TabId: Character] {
  var result: [TabId: Character] = [:]
  for (tabId, key) in zip(visibleTabs, jumpModeKeySequence) {
    result[tabId] = key
  }
  return result
}

enum JumpInputKind: Equatable {
  case keyDown(keyCode: UInt16, character: Character?)
  case flagsChanged
  case mouseDown
}

enum JumpAction: Equatable {
  case passthrough
  case activate
  case commit(char: Character)
  case cancel
}

private let kVK_ANSI_I: UInt16 = 0x22
private let kVK_ANSI_O: UInt16 = 0x1F
private let kVK_ANSI_F: UInt16 = 0x03
private let kVK_Escape: UInt16 = 0x35

/// Pure classifier for the local NSEvent monitor. Domain-native types only;
/// no AppKit. Maps (event kind, normalized modifiers, cycle-active state)
/// to the action AppRuntime should take. Any non-passthrough result must be
/// swallowed by the caller.
func classifySwitcherInput(
  kind: SwitcherInputKind,
  modifiers: SwitcherModifiers,
  cycleActive: Bool
) -> SwitcherAction {
  switch kind {
  case .keyDown(let keyCode):
    // Trigger combos require exactly cmd+shift; extra modifiers (option,
    // control) pass through so user chord bindings keep working.
    if modifiers == [.command, .shift] {
      switch keyCode {
      case kVK_ANSI_O: return .stepOlder  // primary direction (like cmd-tab)
      case kVK_ANSI_I: return .stepNewer  // reverse / undo direction
      default: return .passthrough
      }
    }
    if cycleActive && keyCode == kVK_Escape { return .cancel }
    return .passthrough

  case .flagsChanged:
    guard cycleActive else { return .passthrough }
    // Releasing EITHER required modifier commits.
    if !modifiers.contains(.command) || !modifiers.contains(.shift) {
      return .commit
    }
    return .passthrough
  }
}

/// Pure classifier for tab jump mode. Modifier-only changes intentionally
/// pass through while active so releasing cmd-shift after activation does not
/// cancel the mode before the target key arrives.
func classifyJumpInput(
  kind: JumpInputKind,
  modifiers: SwitcherModifiers,
  jumpActive: Bool
) -> JumpAction {
  guard jumpActive else {
    if case .keyDown(let keyCode, _) = kind,
       keyCode == kVK_ANSI_F,
       modifiers == [.command, .shift] {
      return .activate
    }
    return .passthrough
  }

  switch kind {
  case .flagsChanged:
    return .passthrough
  case .mouseDown:
    return .cancel
  case .keyDown(let keyCode, let character):
    if keyCode == kVK_Escape { return .cancel }
    if !modifiers.isEmpty { return .cancel }
    guard let character else { return .cancel }
    return .commit(char: character)
  }
}

// MARK: - Sidebar Pure Helpers

/// Decide which tab rows the sidebar should select after a reload.
/// Preserves the prior multi-selection iff its live subset still
/// contains the model's focused tab; otherwise collapses to just the
/// focused tab. Stale ids (closed tabs) are dropped via `liveTabIds`.
func resolveReloadSelection(
    priorSelectedTabIds: Set<TabId>,
    liveTabIds: Set<TabId>,
    selectedTabId: TabId?
) -> Set<TabId> {
    let livePrior = priorSelectedTabIds.intersection(liveTabIds)
    if let sel = selectedTabId,
       liveTabIds.contains(sel),
       livePrior.contains(sel) {
        return livePrior
    }
    if let sel = selectedTabId, liveTabIds.contains(sel) {
        return [sel]
    }
    return []
}

/// Finder/Mail rule for a sidebar context menu: if the right-clicked
/// row is part of the current selection, the menu targets the whole
/// selection; otherwise just the clicked row. Group rows (and any row
/// whose `tabIdAtRow` returns nil) are filtered out. Returned ids are
/// in row order (i.e. the user's visual top-to-bottom order).
func resolveContextTargets(
    clickedRow: Int,
    selectedRows: IndexSet,
    tabIdAtRow: (Int) -> TabId?
) -> [TabId] {
    guard clickedRow >= 0 else { return [] }
    let rows: [Int] = selectedRows.contains(clickedRow)
        ? selectedRows.sorted()
        : [clickedRow]
    return rows.compactMap { tabIdAtRow($0) }
}

// MARK: - Tab Color

// Resolves the TabColor to apply when a user-initiated color action targets
// `tabIds`. Single source of truth for the dispatcher's toggle-off policy,
// shared by AppDelegate (keyboard/menu) and SidebarView (right-click).
//
// Rule: re-applying a color that EVERY targeted tab already has clears them
// all (toggle-off). Otherwise, set every tab to `requested`. This unifies
// single- and multi-tab behavior:
//   - 1 tab matching requested      -> nil (clear)
//   - 1 tab differing from requested -> requested (set)
//   - N tabs all matching requested -> nil (clear all)
//   - N tabs mixed/none matching    -> requested (set all)
//
//   - count == 0:        returns nil (fail-closed; callers should guard).
//   - requested == nil:  returns nil (explicit clear path; no toggle).
//
// Tabs whose ids don't resolve in `model` count as not-matching, so a
// stale id never produces a spurious clear. Update.swift filters those
// ids out before applying.
func resolveColorForBatch(
    tabIds: [TabId],
    requested: TabColor?,
    in model: AppModel
) -> TabColor? {
    guard !tabIds.isEmpty else { return nil }
    guard let req = requested else { return nil }
    let allShareRequested = tabIds.allSatisfy { id in
        tabById(id, in: model)?.color == req
    }
    return allShareRequested ? nil : req
}
