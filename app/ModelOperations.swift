// Pure model helpers for split trees, snapshots, title-channel events, and UI text.
import Foundation

// MARK: - Pane Theme

/// Returns the theme that should be applied to a pane's Ghostty surface.
/// Remote override takes priority over user-set theme.
func effectiveTheme(for pane: PaneModel) -> String? {
  pane.remoteThemeOverride ?? pane.theme
}

// MARK: - Pane Toolbar

func paneToolbarText(for paneId: PaneId, in model: AppModel) -> (title: String, cwd: String?) {
  guard let pane = model.panes[paneId] else {
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
  case .leaf(let id):
    return [id]
  case .split(_, _, let first, let second, _):
    return allPaneIds(first) + allPaneIds(second)
  }
}

func firstLeafId(_ node: SplitNodeModel) -> PaneId {
  switch node {
  case .leaf(let id):
    return id
  case .split(_, _, let first, _, _):
    return firstLeafId(first)
  }
}

func lastLeafId(_ node: SplitNodeModel) -> PaneId {
  switch node {
  case .leaf(let id):
    return id
  case .split(_, _, _, let second, _):
    return lastLeafId(second)
  }
}

func splitLeaf(
  _ node: SplitNodeModel, paneId: PaneId, direction: SplitNodeModel.Direction, newPaneId: PaneId
) -> SplitNodeModel? {
  switch node {
  case .leaf(let id):
    if id == paneId {
      return .split(
        id: SplitId(),
        direction: direction,
        first: .leaf(id),
        second: .leaf(newPaneId),
        ratio: 0.5
      )
    }
    return nil

  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = splitLeaf(first, paneId: paneId, direction: direction, newPaneId: newPaneId) {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = splitLeaf(second, paneId: paneId, direction: direction, newPaneId: newPaneId)
    {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

/// Remove a leaf from the tree. Returns (newTree, nextFocusPaneId).
/// newTree is nil if the removed leaf was the only node (root leaf).
func removeLeaf(_ node: SplitNodeModel, paneId: PaneId) -> (SplitNodeModel?, PaneId?) {
  switch node {
  case .leaf(let id):
    if id == paneId {
      return (nil, nil)
    }
    return (node, nil)

  case .split(let splitId, let dir, let first, let second, let ratio):
    // Check if either direct child is the target leaf
    if case .leaf(let firstId) = first, firstId == paneId {
      return (second, firstLeafId(second))
    }
    if case .leaf(let secondId) = second, secondId == paneId {
      return (first, lastLeafId(first))
    }

    // Recurse into children
    let (newFirst, focusFromFirst) = removeLeaf(first, paneId: paneId)
    if let newFirst = newFirst, newFirst != first {
      return (
        .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio),
        focusFromFirst
      )
    }

    let (newSecond, focusFromSecond) = removeLeaf(second, paneId: paneId)
    if let newSecond = newSecond, newSecond != second {
      return (
        .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio),
        focusFromSecond
      )
    }

    return (node, nil)
  }
}

/// Swap two leaf IDs throughout the tree. Returns nil if either ID is missing.
func swapLeaves(_ node: SplitNodeModel, _ a: PaneId, _ b: PaneId) -> SplitNodeModel? {
  guard a != b else { return nil }
  let ids = Set(allPaneIds(node))
  guard ids.contains(a), ids.contains(b) else { return nil }
  return swapLeavesInner(node, a, b)
}

private func swapLeavesInner(_ node: SplitNodeModel, _ a: PaneId, _ b: PaneId) -> SplitNodeModel {
  switch node {
  case .leaf(let id):
    if id == a { return .leaf(b) }
    if id == b { return .leaf(a) }
    return node
  case .split(let splitId, let dir, let first, let second, let ratio):
    return .split(
      id: splitId, direction: dir,
      first: swapLeavesInner(first, a, b),
      second: swapLeavesInner(second, a, b),
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
  let (stripped, _) = removeLeaf(node, paneId: source)
  guard let stripped = stripped else { return nil }
  return insertAtLeaf(
    stripped, at: target, inserting: source, direction: direction, insertFirst: insertFirst)
}

/// Replace a target leaf with a split containing both source and target.
private func insertAtLeaf(
  _ node: SplitNodeModel,
  at targetId: PaneId,
  inserting sourceId: PaneId,
  direction: SplitNodeModel.Direction,
  insertFirst: Bool
) -> SplitNodeModel? {
  switch node {
  case .leaf(let id):
    if id == targetId {
      let first: SplitNodeModel = insertFirst ? .leaf(sourceId) : .leaf(targetId)
      let second: SplitNodeModel = insertFirst ? .leaf(targetId) : .leaf(sourceId)
      return .split(id: SplitId(), direction: direction, first: first, second: second, ratio: 0.5)
    }
    return nil
  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = insertAtLeaf(
      first, at: targetId, inserting: sourceId, direction: direction, insertFirst: insertFirst)
    {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = insertAtLeaf(
      second, at: targetId, inserting: sourceId, direction: direction, insertFirst: insertFirst)
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
  case .leaf(let id):
    return id
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
  case .leaf(let id):
    return id == target

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
  return model.panes[tab.focusedPaneId]
}

func currentCwd(in model: AppModel) -> String? {
  if let pane = focusedPane(in: model), let cwd = pane.cwd { return cwd }
  // Fall back to most recent tab with a known cwd
  let allTabs = model.groups.flatMap(\.tabs)
  for tab in allTabs.reversed() {
    if let cwd = model.panes[tab.focusedPaneId]?.cwd { return cwd }
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

// Single chokepoint for asking the user before quitting. Returns no effects
// when any confirmation sheet is already in flight.
func emitTerminateConfirmation(_ model: inout AppModel) -> [Effect] {
  guard model.pendingConfirmation == nil else { return [] }
  model.pendingConfirmation = .terminate
  return [.showTerminateConfirmation(paneCount: model.panes.count)]
}

// Single chokepoint for asking before closing a multi-pane tab. It guards the
// same slot as quit confirmation so close-tab and quit sheets cannot stack.
// `uncompletedTodoCount` is the full tab + pane rollup (see `tabTodoRollup`).
func emitCloseTabConfirmation(
  _ model: inout AppModel, tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool,
  uncompletedTodoCount: Int
) -> [Effect] {
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

/// Total + uncompleted count for a tab's own to-dos plus every pane's
/// to-dos inside that tab. Pure: same input -> same output.
func tabTodoRollup(_ tabId: TabId, in model: AppModel) -> (total: Int, uncompleted: Int) {
  guard let tab = tabById(tabId, in: model) else { return (0, 0) }
  var total = tab.todos.count
  var uncompleted = tab.todos.count { !$0.isDone }
  for paneId in allPaneIds(tab.rootNode) {
    guard let todos = model.panes[paneId]?.todos else { continue }
    total += todos.count
    uncompleted += todos.count { !$0.isDone }
  }
  return (total, uncompleted)
}

// MARK: - Tab Todo Popover

enum TabTodoRow: Equatable {
  case tabSectionHeader
  case tabItem(TodoItem)
  case paneSectionHeader(paneId: PaneId, title: String)
  case paneItem(paneId: PaneId, item: TodoItem)
}

enum TabTodoEditTarget: Equatable {
  case tab(todoId: UUID)
  case pane(paneId: PaneId, todoId: UUID)
}

enum TabTodoDropOperation: Equatable {
  case on
  case above
}

extension TabTodoRow {
  var isHeader: Bool {
    switch self {
    case .tabSectionHeader, .paneSectionHeader:
      return true
    case .tabItem, .paneItem:
      return false
    }
  }

  var isSelectable: Bool { !isHeader }

  var editTarget: TabTodoEditTarget? {
    switch self {
    case .tabItem(let item):
      return .tab(todoId: item.id)
    case .paneItem(let paneId, let item):
      return .pane(paneId: paneId, todoId: item.id)
    case .tabSectionHeader, .paneSectionHeader:
      return nil
    }
  }

  var itemText: String? {
    switch self {
    case .tabItem(let item), .paneItem(_, let item):
      return item.text
    case .tabSectionHeader, .paneSectionHeader:
      return nil
    }
  }

  var sectionIdentifier: AnyHashable? {
    switch self {
    case .tabSectionHeader, .tabItem:
      return AnyHashable("tab")
    case .paneSectionHeader(let paneId, _), .paneItem(let paneId, _):
      return AnyHashable(paneId)
    }
  }
}

func tabTodoItemCount(_ tabId: TabId, in model: AppModel) -> Int {
  guard let tab = tabById(tabId, in: model) else { return 0 }
  var total = tab.todos.count
  for paneId in allPaneIds(tab.rootNode) {
    total += model.panes[paneId]?.todos.count ?? 0
  }
  return total
}

func buildTabTodoRows(model: AppModel, tabId: TabId) -> [TabTodoRow] {
  guard let tab = tabById(tabId, in: model) else { return [] }
  var rows: [TabTodoRow] = [.tabSectionHeader]
  for item in tab.todos {
    rows.append(.tabItem(item))
  }
  for paneId in allPaneIds(tab.rootNode) {
    guard let pane = model.panes[paneId] else { continue }
    rows.append(.paneSectionHeader(paneId: paneId, title: pane.title))
    for item in pane.todos {
      rows.append(.paneItem(paneId: paneId, item: item))
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
      guard let pane = model.panes[paneId] else { return nil }
      return (.pane(paneId), pane.todos.count)
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
    case .paneItem(let paneId, _):
      guard model.panes[paneId] != nil else { return nil }
      let atIndex = rows[..<proposedRow].count { row in
        if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
        return false
      }
      return (.pane(paneId), atIndex)
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

private func tabTodoDestination(for row: TabTodoRow, tabId: TabId) -> TodoDestination? {
  switch row {
  case .tabSectionHeader, .tabItem:
    return .tab(tabId)
  case .paneSectionHeader(let paneId, _), .paneItem(let paneId, _):
    return .pane(paneId)
  }
}

private func tabTodoCount(for destination: TodoDestination, in model: AppModel) -> Int? {
  switch destination {
  case .tab(let tabId):
    return tabById(tabId, in: model)?.todos.count
  case .pane(let paneId):
    return model.panes[paneId]?.todos.count
  }
}

// Converts the AppKit close-tab alert response into an explicit Msg so both
// confirm and cancel paths can clear pending confirmation state.
func closeTabConfirmationResponse(isConfirm: Bool, tabId: TabId) -> Msg {
  isConfirm ? .confirmCloseTab(id: tabId) : .cancelCloseTab
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

  guard initFile.version == 1 else {
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
  AppInitFile(version: 1, model: toSnapshot(model))
}

func toSnapshot(_ model: AppModel) -> AppModelSnapshot {
  var paneSnapshots: [PaneSnapshot] = []
  var seenPaneIds = Set<PaneId>()

  let groupSnapshots: [GroupSnapshot] = model.groups.map { group in
    let tabSnapshots: [TabSnapshot] = group.tabs.map { tab in
      // Collect panes in tree traversal order
      for paneId in allPaneIds(tab.rootNode) {
        guard seenPaneIds.insert(paneId).inserted,
          let pane = model.panes[paneId]
        else { continue }
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
            id: paneId.rawValue.uuidString,
            title: pane.title,
            cwd: abbrevCwd,
            launch: launch,
            scrollback: nil,
            theme: pane.theme
        )
        snapshot.todos = todoSnapshots
        paneSnapshots.append(snapshot)
      }

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
    panes: paneSnapshots,
    selectedTabId: model.selectedTabId?.rawValue.uuidString
  )
}

private func toSplitNodeSnapshot(_ node: SplitNodeModel) -> SplitNodeSnapshot {
  switch node {
  case .leaf(let paneId):
    return .leaf(paneId: paneId.rawValue.uuidString)
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

/// Merge scrollback from an enriched snapshot into a light snapshot's structure.
/// Panes matched by ID. Light provides authoritative structure; enriched provides scrollback.
func mergeCheckpoints(light: AppModelSnapshot, enriched: AppModelSnapshot) -> AppModelSnapshot {
    var scrollbackById: [String: String] = [:]
    for pane in enriched.panes {
        guard let id = pane.id, let scrollback = pane.scrollback else { continue }
        scrollbackById[id] = scrollback
    }
    let mergedPanes: [PaneSnapshot] = light.panes.map { ps in
        guard let id = ps.id, let scrollback = scrollbackById[id] else { return ps }
        var merged = PaneSnapshot(id: ps.id, title: ps.title, cwd: ps.cwd,
                            launch: ps.launch, scrollback: scrollback, theme: ps.theme)
        merged.todos = ps.todos
        return merged
    }
    return AppModelSnapshot(groups: light.groups, panes: mergedPanes,
                            selectedTabId: light.selectedTabId)
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
