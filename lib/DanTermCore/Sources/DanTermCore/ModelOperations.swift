// Pure model core for DanTerm's Elm-style architecture: the split-tree operations
// (`allPaneIds`, `splitLeaf`, `removeLeaf`, `moveLeaf`, ...), AppModel query helpers,
// termination/close-tab helpers, the MRU/switcher/jump input classifiers, the
// reconcile-scheduling classifier (`reconcileDecision` -- scheduling, not a
// projection), the DanTerm event protocol, and a `Shared Pure Helpers` section of
// cross-layer feeders (container shapes, alert counts, ...) that the projection layer
// reads back. The pure *view projections* + their diff helpers now live in their own
// AppKit-free peer, Projections.swift (the counterpart to Reconcile.swift); snapshot /
// restore / recovery I/O lives in Persistence.swift; the tab-todo row model in
// TabTodo.swift. Keep this free of AppKit so the model core
// stays unit-testable without Cocoa or the terminal engine.
import Foundation
import DanTermProtocol

// MARK: - Pane Theme

/// Normalize a raw remote theme string: trim whitespace, default empty to the config default.
func resolveRemoteTheme(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? DanTermConfig.default.remoteTheme : trimmed
}

/// Normalizes a drafted font family to the value that belongs in the config
/// document: trimmed, with blank text -- or the picker's system-monospace entry,
/// which is a choice rather than a font name -- meaning "no `font.family` key"
/// rather than an empty family name. This is the whole of the core's font-family
/// validation: whether the name is installed is a CoreText question the core
/// never asks.
func resolveFontFamilyDraft(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false,
          trimmed != systemMonospaceFontChoiceTitle
    else { return nil }
    return trimmed
}

/// Formats optional numeric config values for the Preferences text-field boundary.
func configFontSizeText(_ size: Double) -> String {
    let text = String(size)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

/// Classifies drafted font-size text for both save and presentation. Blank text
/// removes the config key, valid text yields the bounded stored value, and
/// invalid text leaves the committed config unchanged.
func resolveFontSizeDraft(_ raw: String) -> (isValid: Bool, fontSize: Double?) {
    guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return (true, nil)
    }
    guard let parsed = Double(raw), parsed.isFinite, parsed > 0 else {
        return (false, nil)
    }
    return (true, DanTermConfig.boundedFontSize(parsed))
}

/// Resolves the live connection theme ahead of the pane's local theme choice.
func effectiveTheme(
  for pane: PaneModel,
  config: DanTermConfig = .default
) -> String {
  if case .remote = pane.session?.connection ?? .local {
    return config.remoteTheme
  }
  return pane.theme ?? config.resolvedDefaultTheme
}

/// Points one zoom step moves a pane. Whole points: a fractional step would
/// produce sizes too close to distinguish while still forcing a re-raster and a
/// PTY reflow, and would lose the exact return to the configured size.
let paneFontSizeStepPoints: Double = 1

/// How far a pane may be zoomed from the configured size. Bounded on every
/// ingress, not at projection, so repeated presses at a bound accumulate no
/// hidden state and one press in the other direction is always visible.
let paneFontSizeStepRange: ClosedRange<Int> = -4...24

/// Bound a step count arriving from an adjustment or a persisted snapshot.
func clampedPaneFontSizeSteps(_ steps: Int) -> Int {
  min(max(steps, paneFontSizeStepRange.lowerBound), paneFontSizeStepRange.upperBound)
}

/// The size a pane actually renders at. No clamp: both operands are already
/// bounded, and clamping here would silently eat steps the pane still holds.
func effectiveFontSize(for pane: PaneModel, config: DanTermConfig = .default) -> Double {
  config.resolvedFontSize + Double(pane.fontSizeSteps) * paneFontSizeStepPoints
}

/// Carry the live appearance settings onto a model rebuilt from a snapshot.
/// `config` and `resolvedFontFamily` are loaded from disk at launch and never
/// snapshotted, so a restored model arrives with them at their defaults. The
/// restore path applies this before it creates any session from the model, so a
/// zoomed pane is built at its real size instead of the default one and the
/// committed model does not revert the user's configuration.
func carryingLiveAppearance(
  _ model: AppModel, config: DanTermConfig, resolvedFontFamily: String?
) -> AppModel {
  var carried = model
  carried.config = config
  carried.resolvedFontFamily = resolvedFontFamily
  return carried
}

// MARK: - Pane alert cleanup

/// Remove all alerts for a pane being destroyed.
func removeAlertsForPane(_ paneId: PaneId, in model: inout AppModel) {
    model.alerts.removeAll { $0.paneId == paneId }
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
  var result: [PaneId] = []
  appendPaneIds(in: node, to: &result)
  return result
}

/// Appends pane IDs in left-to-right tree order without intermediate arrays.
private func appendPaneIds(in node: SplitNodeModel, to result: inout [PaneId]) {
  switch node {
  case .leaf(let pane):
    result.append(pane.id)
  case .split(_, _, let first, let second, _):
    appendPaneIds(in: first, to: &result)
    appendPaneIds(in: second, to: &result)
  }
}

/// Exposes the pane-id tree walk under a name that cannot collide with
/// `AppModel.allPaneIds` when core sources compile same-module into the app.
func paneIdsInNode(_ node: SplitNodeModel) -> [PaneId] {
  allPaneIds(node)
}

/// Reports whether a pane ID belongs to this tree without materializing its leaves.
func containsPane(_ node: SplitNodeModel, _ paneId: PaneId) -> Bool {
  switch node {
  case .leaf(let pane):
    return pane.id == paneId
  case .split(_, _, let first, let second, _):
    return containsPane(first, paneId) || containsPane(second, paneId)
  }
}

/// Reports whether the tree has exactly one pane from its root shape.
func isSinglePane(_ node: SplitNodeModel) -> Bool {
  if case .leaf = node { return true }
  return false
}

/// Visits each pane once in left-to-right tree order without materializing a collection.
func forEachPane(in node: SplitNodeModel, _ body: (PaneModel) throws -> Void) rethrows {
  switch node {
  case .leaf(let pane):
    try body(pane)
  case .split(_, _, let first, let second, _):
    try forEachPane(in: first, body)
    try forEachPane(in: second, body)
  }
}

/// Visits every pane in the whole model once, in tab then tree (left-to-right)
/// order, without materializing a pane array. The model-wide counterpart to the
/// node-level `forEachPane`, and the only whole-model pane traversal production
/// code has: projections that once flattened the trees into `[PaneModel]` call
/// this instead, so a per-sweep materialization cannot come back through a new
/// caller.
func forEachPane(in model: AppModel, _ body: (PaneModel) throws -> Void) rethrows {
  for group in model.groups {
    for tab in group.tabs {
      try forEachPane(in: tab.paneTree.root, body)
    }
  }
}

/// Whether `splitId` names an interior split node of this tree.
func containsSplit(_ node: SplitNodeModel, _ splitId: SplitId) -> Bool {
  switch node {
  case .leaf:
    return false
  case .split(let id, _, let first, let second, _):
    return id == splitId || containsSplit(first, splitId) || containsSplit(second, splitId)
  }
}

/// All PaneModels in a node, in left-to-right tree order.
func panesInNode(_ node: SplitNodeModel) -> [PaneModel] {
  var result: [PaneModel] = []
  forEachPane(in: node) { result.append($0) }
  return result
}

/// Finds the first leaf pane that satisfies `predicate`, in left-to-right order.
func paneInNode(
  _ node: SplitNodeModel,
  where predicate: (PaneModel) -> Bool
) -> PaneModel? {
  switch node {
  case .leaf(let pane):
    return predicate(pane) ? pane : nil
  case .split(_, _, let first, let second, _):
    return paneInNode(first, where: predicate) ?? paneInNode(second, where: predicate)
  }
}

/// Finds the pane with the given id within a node. Backs `AppModel.pane(_:)`.
func paneInNode(_ node: SplitNodeModel, id: PaneId) -> PaneModel? {
  paneInNode(node) { $0.id == id }
}

/// Rebuilds the path to the first leaf that satisfies `predicate` and returns
/// the value produced while mutating that leaf.
func updatePaneInNode<Result>(
  _ node: SplitNodeModel,
  where predicate: (PaneModel) -> Bool,
  _ body: (inout PaneModel) -> Result
) -> (node: SplitNodeModel, result: Result)? {
  switch node {
  case .leaf(var pane):
    guard predicate(pane) else { return nil }
    let result = body(&pane)
    return (.leaf(pane), result)
  case .split(let splitId, let dir, let first, let second, let ratio):
    if let mutation = updatePaneInNode(first, where: predicate, body) {
      return (
        .split(id: splitId, direction: dir, first: mutation.node, second: second, ratio: ratio),
        mutation.result
      )
    }
    if let mutation = updatePaneInNode(second, where: predicate, body) {
      return (
        .split(id: splitId, direction: dir, first: first, second: mutation.node, ratio: ratio),
        mutation.result
      )
    }
    return nil
  }
}

/// Rebuilds the path to the pane with `id` and applies `body` to that leaf.
func updatePaneInNode(
  _ node: SplitNodeModel,
  id: PaneId,
  _ body: (inout PaneModel) -> Void
) -> SplitNodeModel? {
  updatePaneInNode(node, where: { $0.id == id }, body)?.node
}

/// Compute the model-derived renderer visibility for every pane in every tab.
func effectivePaneVisibility(in model: AppModel, windowVisible: Bool) -> [PaneId: Bool] {
  var result: [PaneId: Bool] = [:]
  let selectedTabId = model.selectedTabId

  for group in model.groups {
    for tab in group.tabs {
      let tabIsSelected = tab.id == selectedTabId
      forEachPane(in: tab.paneTree.root) { pane in
        let paneId = pane.id
        let visible = windowVisible
          && tabIsSelected
          && !(tab.paneTree.isZoomed && tab.paneTree.zoomedPaneId != paneId)
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
  _ node: SplitNodeModel,
  paneId: PaneId,
  direction: SplitDirection,
  newPane: PaneModel,
  newSplitId: SplitId
) -> SplitNodeModel? {
  switch node {
  case .leaf(let pane):
    if pane.id == paneId {
      return .split(
        id: newSplitId,
        direction: direction,
        first: .leaf(pane),
        second: .leaf(newPane),
        ratio: 0.5
      )
    }
    return nil

  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = splitLeaf(
      first, paneId: paneId, direction: direction, newPane: newPane, newSplitId: newSplitId)
    {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = splitLeaf(
      second, paneId: paneId, direction: direction, newPane: newPane, newSplitId: newSplitId)
    {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

/// Keeps leaf removal states exhaustive so a surviving node always has a successor focus.
enum LeafRemovalOutcome {
  case notFound
  case emptied(PaneModel)
  case surviving(node: SplitNodeModel, successorFocus: PaneId, removed: PaneModel)
}

/// Removes a leaf while preserving its payload and reporting the sibling focus after collapse.
func removeLeaf(_ node: SplitNodeModel, paneId: PaneId) -> LeafRemovalOutcome {
  switch node {
  case .leaf(let pane):
    if pane.id == paneId {
      return .emptied(pane)
    }
    return .notFound

  case .split(let splitId, let dir, let first, let second, let ratio):
    // Check if either direct child is the target leaf
    if case .leaf(let firstPane) = first, firstPane.id == paneId {
      return .surviving(node: second, successorFocus: firstLeafId(second), removed: firstPane)
    }
    if case .leaf(let secondPane) = second, secondPane.id == paneId {
      return .surviving(node: first, successorFocus: lastLeafId(first), removed: secondPane)
    }

    // Recurse into children
    if case .surviving(let newFirst, let focusFromFirst, let removedFromFirst) =
      removeLeaf(first, paneId: paneId)
    {
      return .surviving(
        node: .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio),
        successorFocus: focusFromFirst,
        removed: removedFromFirst
      )
    }

    if case .surviving(let newSecond, let focusFromSecond, let removedFromSecond) =
      removeLeaf(second, paneId: paneId)
    {
      return .surviving(
        node: .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio),
        successorFocus: focusFromSecond,
        removed: removedFromSecond
      )
    }

    return .notFound
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
  direction: SplitDirection,
  insertFirst: Bool,
  newSplitId: SplitId
) -> SplitNodeModel? {
  guard source != target else { return nil }
  guard containsPane(node, source), containsPane(node, target) else { return nil }
  // Capture the removed pane's full payload and re-insert THAT, so cwd/theme/
  // todos move with the pane instead of being rebuilt as a fresh default leaf.
  guard case .surviving(let stripped, _, let removed) = removeLeaf(node, paneId: source) else {
    return nil
  }
  return insertAtLeaf(
    stripped, at: target, inserting: removed, direction: direction, insertFirst: insertFirst,
    newSplitId: newSplitId)
}

/// Replace a target leaf with a split containing both the moved `source` pane
/// (its full payload, threaded from `removeLeaf`) and the original target leaf.
private func insertAtLeaf(
  _ node: SplitNodeModel,
  at targetId: PaneId,
  inserting source: PaneModel,
  direction: SplitDirection,
  insertFirst: Bool,
  newSplitId: SplitId
) -> SplitNodeModel? {
  switch node {
  case .leaf(let pane):
    if pane.id == targetId {
      let first: SplitNodeModel = insertFirst ? .leaf(source) : .leaf(pane)
      let second: SplitNodeModel = insertFirst ? .leaf(pane) : .leaf(source)
      return .split(id: newSplitId, direction: direction, first: first, second: second, ratio: 0.5)
    }
    return nil
  case .split(let splitId, let dir, let first, let second, let ratio):
    if let newFirst = insertAtLeaf(
      first, at: targetId, inserting: source, direction: direction, insertFirst: insertFirst,
      newSplitId: newSplitId)
    {
      return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
    }
    if let newSecond = insertAtLeaf(
      second, at: targetId, inserting: source, direction: direction, insertFirst: insertFirst,
      newSplitId: newSplitId)
    {
      return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
    }
    return nil
  }
}

func nearestLeaf(
  _ node: SplitNodeModel, from paneId: PaneId, direction: SplitDirection,
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
  _ node: SplitNodeModel, navigating direction: SplitDirection, side: SplitNodeModel.Side,
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

func setRatio(_ node: SplitNodeModel, splitId: SplitId, ratio: SplitRatio) -> SplitNodeModel {
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

/// Live tab ids across all groups, built without materializing tab values.
func liveTabIds(in model: AppModel) -> Set<TabId> {
  var ids = Set<TabId>()
  for group in model.groups {
    for tab in group.tabs {
      ids.insert(tab.id)
    }
  }
  return ids
}

func selectedTab(in model: AppModel) -> TabModel? {
  guard let id = model.selectedTabId else { return nil }
  return tabById(id, in: model)
}

func tabForPane(_ paneId: PaneId, in model: AppModel) -> TabModel? {
  for group in model.groups {
    for tab in group.tabs {
      if containsPane(tab.paneTree.root, paneId) { return tab }
    }
  }
  return nil
}

/// The tab whose split tree contains `splitId`, or nil. Id-carrying split
/// messages resolve their own tab because hidden background containers stay mounted.
func tabForSplit(_ splitId: SplitId, in model: AppModel) -> TabModel? {
  for group in model.groups {
    for tab in group.tabs {
      if containsSplit(tab.paneTree.root, splitId) { return tab }
    }
  }
  return nil
}

func groupForTab(_ tabId: TabId, in model: AppModel) -> GroupModel? {
  return model.groups.first(where: { $0.tabs.contains(where: { $0.id == tabId }) })
}

func focusedPane(in model: AppModel) -> PaneModel? {
  guard let tab = selectedTab(in: model) else { return nil }
  return tab.paneTree.focusedPane
}

func currentCwd(in model: AppModel) -> String? {
  if let cwd = focusedPane(in: model)?.session?.cwd { return cwd }
  // Fall back to most recent tab with a known cwd
  let allTabs = model.groups.flatMap(\.tabs)
  for tab in allTabs.reversed() {
    if let cwd = tab.paneTree.focusedPane.session?.cwd { return cwd }
  }
  return nil
}

func paneIdsForTab(_ tabId: TabId, in model: AppModel) -> [PaneId] {
  for group in model.groups {
    if let tab = group.tabs.first(where: { $0.id == tabId }) {
      return allPaneIds(tab.paneTree.root)
    }
  }
  return []
}

/// Collapse a home-prefixed absolute path to `~/...` for display or for a saved
/// snapshot. `home` defaults to the real ambient home so SHOWN callers (tab/
/// toolbar chrome) need pass nothing; SAVED/SENT callers (the snapshot codec)
/// inject an explicit home so the output reproduces across machines. The prefix
/// test is boundary-aware (`== home` or `home + "/"`) so `/Users/dan` does not
/// mis-abbreviate `/Users/danielle/foo`.
func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {  // core-purity: ambient-seam
  guard path == home || path.hasPrefix(home + "/") else { return path }
  return "~" + path.dropFirst(home.count)
}

/// What a pane calls itself before the cwd is considered: the title a program
/// declared, else the label a restore recovered for it.
///
/// Separate from `paneResolvedTitle` because a surface that shows the cwd beside
/// the title (the pane toolbar) needs to know when the two would be the same
/// string, and only the absence of a claim tells it that.
func paneClaimedTitle(_ pane: PaneModel) -> String? {
  pane.session?.titleState.claimed
}

/// The one name a pane displays: its declared title, then its recovered label,
/// then its abbreviated cwd, then the placeholder for a pane no terminal has
/// spoken for.
///
/// The single resolution every display surface shares, so the cwd fallback
/// cannot drift between the tab row, the switcher, an alert, and the todo
/// popover. Deliberately not the pane roster's rule, which needs a
/// running-command fallback and unabbreviated paths for targeting.
func paneResolvedTitle(_ pane: PaneModel) -> String {
  if let claimed = paneClaimedTitle(pane) { return claimed }
  guard let cwd = pane.session?.cwd else { return placeholderPaneTitle }
  return abbreviateHome(cwd)
}

/// What a pane is called before any terminal has spoken for it.
let placeholderPaneTitle = "Terminal"

/// Derives tab chrome from the focused pane's current terminal session.
///
/// `PaneTree` guarantees that the focused pane belongs to this tab.
func tabChrome(_ tab: TabModel) -> (title: String, subtitle: String?) {
  let pane = tab.paneTree.focusedPane
  return (paneResolvedTitle(pane), pane.session?.cwd.map { abbreviateHome($0) })
}

/// Returns the terminal-derived title for one tab.
func tabTitle(_ tab: TabModel) -> String {
  tabChrome(tab).title
}

/// Applies a custom title over the terminal-derived title for one tab.
func tabDisplayTitle(_ tab: TabModel) -> String {
  tab.customTitle ?? tabTitle(tab)
}

/// Returns the focused session's working-directory subtitle for one tab.
func tabSubtitle(_ tab: TabModel) -> String? {
  tabChrome(tab).subtitle
}

/// Returns the chip for one tab's row, taken from the focused pane like the
/// rest of the row's chrome. An agent in an unfocused split does not show here.
func tabChipKind(_ tab: TabModel) -> ChipKind {
  ChipKind(agent: tab.paneTree.focusedPane.session?.agent ?? .none)
}

/// What a pane chip's agent mark says, if anything.
///
/// Only the agent's own state: whether a pane also has an unread alert is a
/// separate fact carried beside this one, because the two are independent and
/// a chip has a corner for each. Nothing here outranks the alert bit.
///
/// `quiet` covers an idle agent, an attached agent that has reported no
/// activity, and a plain shell alike. A turn that finished worth knowing about
/// has already rung a bell, and an unreported activity is a state the hooks
/// have not claimed: neither earns a mark, and the glyph already separates a
/// quiet agent pane from a shell.
enum PaneAgentMark: Equatable {
  case waiting
  case working
  case quiet
}

/// One entry of the chip row a tab shows for its panes. Carries the pane id so
/// a later iteration can make a chip clickable.
///
/// `hasAlert` and `agent` are separate and neither collapses into the other: a
/// pane can be both ringing and mid-turn, and the chip says so with two marks.
struct TabPaneChip: Equatable {
  let paneId: PaneId
  let kind: ChipKind
  let isFocused: Bool
  let hasAlert: Bool
  let agent: PaneAgentMark
}

/// The chips for a tab's panes, in the tree's left-to-right order, with the
/// tab's focused pane flagged so the row can draw the others greyscale.
/// `unreadByPane` is `UnreadAlertTally.byPane`, so the sidebar projection can
/// pass the count it has already rolled up instead of rescanning the alerts.
func tabPaneChips(_ tab: TabModel, unreadByPane: [PaneId: Int]) -> [TabPaneChip] {
  let panes = panesInNode(tab.paneTree.root)
  return panes.map { pane in
    let agent = pane.session?.agent ?? .none
    return TabPaneChip(
      paneId: pane.id,
      kind: ChipKind(agent: agent),
      isFocused: pane.id == tab.paneTree.focusedPaneId,
      hasAlert: (unreadByPane[pane.id] ?? 0) > 0,
      agent: paneAgentMark(agent: agent))
  }
}

/// Maps a pane's agent lifecycle onto the mark its chip draws for the agent.
func paneAgentMark(agent: AgentLifecycle) -> PaneAgentMark {
  guard case .attached(_, let activity) = agent else { return .quiet }
  switch activity?.reported {
  case .waiting: return .waiting
  case .working: return .working
  case .idle, nil: return .quiet
  }
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

// MARK: - Todo Operations

/// Adds one normalized todo through the shared reducer and IPC mutation path.
func appendTodo(_ model: inout AppModel, owner: TodoOwner, text: TodoText, id: TodoId) -> TodoItem? {
  guard model.todos(for: owner) != nil else { return nil }
  let item = TodoItem(id: id, text: text, isDone: false)
  model.updateTodos(for: owner) { $0.append(item) }
  return item
}

// MARK: - Termination Helpers

func totalTabCount(_ model: AppModel) -> Int {
  model.groups.flatMap(\.tabs).count
}

func wouldQuitFromClose(_ model: AppModel) -> Bool {
  totalTabCount(model) == 1
}

/// Computes the frozen close cost for one interactive close target.
func closeImpact(for target: CloseTarget, in model: AppModel) -> CloseImpact? {
  let panes: [PaneModel]
  let uncompletedTodoCount: Int

  switch target {
  case .pane(let paneId, _):
    guard let pane = model.pane(paneId) else { return nil }
    panes = [pane]
    uncompletedTodoCount = pane.todos.count { $0.isDone == false }
  case .otherPanes(let retainedPaneId):
    guard let tab = tabForPane(retainedPaneId, in: model) else { return nil }
    panes = panesInNode(tab.paneTree.root).filter { $0.id != retainedPaneId }
    uncompletedTodoCount = panes.reduce(into: 0) { count, pane in
      count += pane.todos.count { $0.isDone == false }
    }
  case .tab(let tabId, _, _):
    guard let tab = tabById(tabId, in: model) else { return nil }
    panes = panesInNode(tab.paneTree.root)
    uncompletedTodoCount = tabTodoRollup(tabId, in: model).uncompleted
  case .tabs(let tabIds, _):
    let tabs = tabIds.compactMap { tabById($0, in: model) }
    panes = tabs.flatMap { panesInNode($0.paneTree.root) }
    uncompletedTodoCount = tabs.reduce(into: 0) { total, tab in
      total += tabTodoRollup(tab.id, in: model).uncompleted
    }
  }

  return CloseImpact(
    panes: panes.map { CloseImpact.Pane(paneId: $0.id, runningCommand: $0.runningCommand) },
    uncompletedTodoCount: uncompletedTodoCount
  )
}

/// Replaces the confirmation transaction so the most recent request owns the panel.
func emitConfirmation(
  _ model: inout AppModel,
  target: CloseTarget,
  env: CoreEnv
) -> [Command] {
  guard let impact = closeImpact(for: target, in: model) else { return [] }
  model.pendingConfirmation = PendingConfirmation(
    id: ConfirmationId(rawValue: env.newId()),
    kind: .close(target: target, impact: impact)
  )
  return []
}

/// Replaces the confirmation transaction with a live quit request.
func emitQuitConfirmation(_ model: inout AppModel, env: CoreEnv) -> [Command] {
  model.pendingConfirmation = PendingConfirmation(
    id: ConfirmationId(rawValue: env.newId()),
    kind: .quit
  )
  return []
}

/// Total + uncompleted count for a tab's own to-dos plus every pane's
/// to-dos inside that tab. Pure: same input -> same output.
func tabTodoRollup(_ tabId: TabId, in model: AppModel) -> (total: Int, uncompleted: Int) {
  guard let tab = tabById(tabId, in: model) else { return (0, 0) }
  var total = tab.todos.count
  var uncompleted = tab.todos.count { !$0.isDone }
  forEachPane(in: tab.paneTree.root) { pane in
    total += pane.todos.count
    uncompleted += pane.todos.count { !$0.isDone }
  }
  return (total, uncompleted)
}

/// Builds alert body copy from the same impact value that opened the gate.
func closeConfirmationCopy(
  target: CloseTarget,
  impact: CloseImpact
) -> CloseConfirmationCopy {
  if case .otherPanes = target {
    let paneCount = impact.panes.count
    let paneLabel = paneCount == 1 ? "1 other pane" : "\(paneCount) other panes"
    let runningCommands = impact.panes.compactMap(\.runningCommand)
    var details: [String] = []
    if runningCommands.count == 1 {
      details.append("a running command")
    } else if runningCommands.count > 1 {
      details.append("\(runningCommands.count) running commands")
    }
    if impact.uncompletedTodoCount > 0 {
      details.append(impact.uncompletedTodoCount == 1
        ? "1 unfinished task"
        : "\(impact.uncompletedTodoCount) unfinished tasks")
    }
    let informativeText: String
    if details.isEmpty {
      informativeText = "\(paneLabel) will be closed."
    } else {
      let detailText = details.count == 1
        ? details[0]
        : details.dropLast().joined(separator: ", ") + " and " + details.last!
      let verb = paneCount == 1 ? "has" : "have"
      let pronoun = paneCount == 1 ? "It" : "They"
      informativeText = "\(paneLabel) \(verb) \(detailText). \(pronoun) will be closed."
    }
    return CloseConfirmationCopy(
      informativeText: informativeText,
      commands: runningCommands.map { DisplayLine($0) }
    )
  }

  var parts: [String] = []
  switch target {
  case .tab where impact.panes.count > 1:
    parts.append("\(impact.panes.count) terminal panes")
  case .tabs(let tabIds, _) where impact.panes.count > tabIds.count:
    parts.append("\(impact.panes.count) terminal panes")
  default:
    break
  }

  let runningCommands = impact.panes.compactMap(\.runningCommand)
  if runningCommands.count == 1 {
    parts.append("a running command")
  } else if runningCommands.count > 1 {
    parts.append("\(runningCommands.count) running commands")
  }

  if impact.uncompletedTodoCount > 0 {
    let label = impact.uncompletedTodoCount == 1
      ? "1 unfinished task"
      : "\(impact.uncompletedTodoCount) unfinished tasks"
    parts.append(label)
  }

  let noun: String
  let verb: String
  let fallback: String
  switch target {
  case .pane, .otherPanes:
    noun = "This pane"
    verb = "has"
    fallback = "This pane will be closed."
  case .tab:
    noun = "This tab"
    verb = "has"
    fallback = "This tab will be closed."
  case .tabs:
    noun = "These tabs"
    verb = "have"
    fallback = "These tabs will be closed."
  }

  let sentence: String
  if parts.isEmpty {
    sentence = fallback
  } else if parts.count == 1 {
    sentence = "\(noun) \(verb) \(parts[0])."
  } else {
    let head = parts.dropLast().joined(separator: ", ")
    sentence = "\(noun) \(verb) \(head) and \(parts.last!)."
  }

  let informativeText: String
  let quitAuthorized = switch target {
  case .pane(_, let quitAuthorized),
       .tab(_, _, let quitAuthorized),
       .tabs(_, let quitAuthorized):
    quitAuthorized
  case .otherPanes:
    false
  }
  if quitAuthorized {
    let pronoun = if case .tabs = target { "them" } else { "it" }
    informativeText = sentence + " Closing \(pronoun) will quit DanTerm."
  } else {
    informativeText = sentence
  }

  return CloseConfirmationCopy(
    informativeText: informativeText,
    commands: runningCommands.map { DisplayLine($0) }
  )
}

// MARK: - Shared Pure Helpers
//
// Pure feeders and the types they build, kept out of Projections.swift because the
// runtime consumes them too: reconcile calls `unreadAlertTally` itself and holds
// `ContainerShape` values across passes. The dependency runs one way --
// Projections.swift -> here (e.g. `desiredContainerShapes` calls
// `containerShape(of:)`), never the reverse.

// MARK: - Unread Alert Tally
//
// The one definition of "how many unread alerts". It exists so reconcile can
// compute alert counts once and thread them through every alert-consuming
// projection.

/// Precomputed unread-alert counts for one AppModel snapshot.
///
/// `total` counts every unread alert, including stale-pane alerts whose pane no
/// longer appears in any split tree. `byTab` and `byGroup` are tree-restricted:
/// they count only alerts on panes reachable from that tab's or group's pane
/// tree, and every live tab and group gets a key even when its count is zero.
struct UnreadAlertTally: Equatable {
  var byPane: [PaneId: Int]
  var byTab: [TabId: Int]
  var byGroup: [GroupId: Int]
  var total: Int
}

/// Build the unread-alert tally that reconcile threads through alert consumers.
func unreadAlertTally(for model: AppModel) -> UnreadAlertTally {
  var byPane: [PaneId: Int] = [:]
  var total = 0
  for alert in model.alerts where alert.isUnread {
    byPane[alert.paneId, default: 0] += 1
    total += 1
  }

  var byTab: [TabId: Int] = [:]
  var byGroup: [GroupId: Int] = [:]
  for group in model.groups {
    var groupCount = 0
    for tab in group.tabs {
      let tabCount = sumUnread(in: tab.paneTree.root, byPane: byPane)
      byTab[tab.id] = tabCount
      groupCount += tabCount
    }
    byGroup[group.id] = groupCount
  }

  return UnreadAlertTally(byPane: byPane, byTab: byTab, byGroup: byGroup, total: total)
}

/// Sum per-pane unread counts through a split tree without allocating a pane-id set.
private func sumUnread(in node: SplitNodeModel, byPane: [PaneId: Int]) -> Int {
  switch node {
  case .leaf(let pane):
    return byPane[pane.id] ?? 0
  case .split(_, _, let first, let second, _):
    return sumUnread(in: first, byPane: byPane) + sumUnread(in: second, byPane: byPane)
  }
}

/// Carries every pure pane-layout input while excluding unrelated pane payload.
indirect enum ContainerLayoutNode: Equatable {
  case leaf(PaneId)
  case split(
    id: SplitId,
    direction: SplitDirection,
    first: ContainerLayoutNode,
    second: ContainerLayoutNode,
    ratio: SplitRatio
  )
}

/// Everything a mounted container presents: layout, zoom, and visibility.
///
/// The structural fingerprint is not stored, because `sameContainerStructure`
/// reads it out of `layout` in place. That makes a shape whose structure
/// contradicts its own layout unrepresentable.
struct ContainerShape: Equatable {
  let layout: ContainerLayoutNode
  // focusedPaneId while zoomed; nil otherwise -- so a focus change in an unzoomed
  // tab does NOT drift the shape (which is why a pane click needs no tree update).
  // It also carries the zoom fact on its own: `PaneTree.zoomedPaneId` is nil iff
  // the tab is unzoomed.
  let zoomedLeaf: PaneId?
  // True for the selected tab's container. Held here rather than passed beside
  // the shapes so `computeContainerOps` diffs it like every other field: a
  // `.setVisible` that changes nothing becomes unrepresentable, and the
  // reconciler can read the last shown tab out of its own cache.
  let visible: Bool
}

/// Drops pane payload while retaining every input to the pane layout function.
func containerLayoutNode(_ node: SplitNodeModel) -> ContainerLayoutNode {
  switch node {
  case .leaf(let pane):
    return .leaf(pane.id)
  case .split(let id, let direction, let first, let second, let ratio):
    return .split(
      id: id,
      direction: direction,
      first: containerLayoutNode(first),
      second: containerLayoutNode(second),
      ratio: ratio
    )
  }
}

/// Compares two layout trees while skipping ratios, so a divider drag reads as
/// equal and every real tree edit reads as different.
///
/// Compares in place rather than deriving a ratio-free tree per call: building
/// one would heap-allocate a box per node on every diff, which is the cost this
/// comparison exists to avoid.
func sameContainerStructure(_ a: ContainerLayoutNode, _ b: ContainerLayoutNode) -> Bool {
  switch (a, b) {
  case (.leaf(let aId), .leaf(let bId)):
    return aId == bId
  case (.split(let aId, let aDir, let aFirst, let aSecond, _),
        .split(let bId, let bDir, let bFirst, let bSecond, _)):
    return aId == bId && aDir == bDir
      && sameContainerStructure(aFirst, bFirst)
      && sameContainerStructure(aSecond, bSecond)
  case (.leaf, .split), (.split, .leaf):
    return false
  }
}

/// The container shape for one tab. The caller supplies the selection answer,
/// so a shape is always a complete description of what its container presents.
func containerShape(of tab: TabModel, visible: Bool) -> ContainerShape {
  ContainerShape(
    layout: containerLayoutNode(tab.paneTree.root),
    zoomedLeaf: tab.paneTree.zoomedPaneId,
    visible: visible
  )
}

// MARK: - Delete Group

func adjacentGroupIndex(deletingAt idx: Int, count: Int) -> Int? {
  guard count > 1 else { return nil }
  return idx > 0 ? idx - 1 : 1
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
  coalescedSweepPending: Bool
) -> ReconcileDecision {
  guard msg.coalescesReconcile else { return .reconcileNow }
  return coalescedSweepPending ? .coalesceIntoPending : .scheduleCoalesced
}

// MARK: - MRU Tab Switcher

/// Reports whether the owner's button is present in the currently visible chrome.
func todoPopoverAnchorIsEligible(_ owner: TodoOwner, in model: AppModel) -> Bool {
  guard let selectedTabId = model.selectedTabId,
        let selectedTab = tabById(selectedTabId, in: model)
  else { return false }
  switch owner {
  case .pane(let paneId):
    guard containsPane(selectedTab.paneTree.root, paneId) else { return false }
    return selectedTab.paneTree.isZoomed == false
      || selectedTab.paneTree.focusedPaneId == paneId
  case .tab(let tabId):
    return tabId == selectedTabId
  }
}

/// Retracts an open TODO popover as soon as its model-derived anchor is ineligible.
func reconcileTodoPopover(_ model: inout AppModel) {
  guard let owner = model.todoPopover else { return }
  if todoPopoverAnchorIsEligible(owner, in: model) == false {
    model.todoPopover = nil
  }
}

/// Move `value` to index 0 of the array, removing all other occurrences.
/// No-op if the value is not present.
func moveToFront<T: Equatable>(_ array: inout [T], _ value: T) {
  guard array.contains(value) else { return }
  array.removeAll { $0 == value }
  array.insert(value, at: 0)
}

/// Reconcile selectedTabId and mruOrder against the live tab set, as one result.
///
/// Both derive from the same ordered live-tab snapshot, so the two cannot drift
/// apart: whichever tab the repair selects is the tab mruOrder leads with.
/// Idempotent. It drops dead ids from mruOrder, deduplicates (first occurrence
/// wins), appends missing live tabs at the back, repairs a selectedTabId that
/// names no live tab to the most recently used survivor (nil when none
/// survive), and (when not cycling) hoists selectedTabId to index 0 so
/// mruOrder[0] always equals the focused tab.
///
/// Owning the repair here is what lets a removal path stay silent about
/// selection. The exceptions are the paths that make a deliberate selection
/// move of their own -- the close family's predecessor-then-successor pick, and
/// movePaneToTab's jump to the target tab -- which leave a live selection
/// behind for this pass to accept unchanged.
func reconcileTabState(_ model: inout AppModel) {
  let liveTabs = liveTabIds(in: model)
  if tabStateIsCanonical(model, liveTabs: liveTabs) { return }

  var seen = Set<TabId>()
  var rebuilt: [TabId] = []
  rebuilt.reserveCapacity(liveTabs.count)
  for tabId in model.mruOrder where liveTabs.contains(tabId) && seen.insert(tabId).inserted {
    rebuilt.append(tabId)
  }
  for group in model.groups {
    for tab in group.tabs where seen.insert(tab.id).inserted {
      rebuilt.append(tab.id)
    }
  }
  model.mruOrder = rebuilt

  if selectionIsLive(model.selectedTabId, liveTabs: liveTabs) == false {
    // The surviving MRU prefix answers "most recently used"; live tabs with no
    // MRU history sit behind it in flattened order, which is the fallback.
    model.selectedTabId = rebuilt.first
  }
  if model.mruCycle == nil, let sel = model.selectedTabId {
    moveToFront(&model.mruOrder, sel)
  }
}

/// Where the selection sits: the selected tab together with the group holding
/// it. The expansion rule triggers on a change to this pair, not to the tab id
/// alone, so a tab moved under a stationary selection counts as a move.
struct SelectionSite: Equatable {
  let tabId: TabId
  let groupId: GroupId
}

/// The selection's current site, or nil when nothing is selected.
func selectionSite(in model: AppModel) -> SelectionSite? {
  guard let tabId = model.selectedTabId,
        let (groupIdx, _) = tabLocation(tabId, in: model)
  else { return nil }
  return SelectionSite(tabId: tabId, groupId: model.groups[groupIdx].id)
}

/// Expand the group holding the selected tab, so the selection always has a
/// visible sidebar row. Idempotent, and a no-op with no selection or an
/// already-expanded group -- update() is re-entrant, so a nested frame that
/// already expanded is simply seen again by the outer one.
func expandGroupHoldingSelection(_ model: inout AppModel) {
  guard let tabId = model.selectedTabId,
        let (groupIdx, _) = tabLocation(tabId, in: model),
        model.groups[groupIdx].isCollapsed
  else { return }
  model.groups[groupIdx].isCollapsed = false
}

/// True when selectedTabId names a live tab, or is nil because none exist.
private func selectionIsLive(_ selectedTabId: TabId?, liveTabs: Set<TabId>) -> Bool {
  guard let selectedTabId else { return liveTabs.isEmpty }
  return liveTabs.contains(selectedTabId)
}

/// True when selectedTabId and mruOrder already match reconcileTabState's output.
private func tabStateIsCanonical(_ model: AppModel, liveTabs: Set<TabId>) -> Bool {
  guard selectionIsLive(model.selectedTabId, liveTabs: liveTabs) else { return false }
  guard model.mruCycle != nil || model.mruOrder.first == model.selectedTabId else {
    return false
  }
  var seen = Set<TabId>()
  seen.reserveCapacity(liveTabs.count)
  for id in model.mruOrder {
    guard liveTabs.contains(id), seen.insert(id).inserted else { return false }
  }
  return seen.count == liveTabs.count
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
  let liveTabs = liveTabIds(in: model)
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
  case keyDown(chord: KeyChord?)
  case escape
  case flagsChanged(modifiers: DanTermProtocol.KeyModifiers)
}

enum SwitcherAction: Equatable {
  case passthrough
  case stepOlder
  case stepNewer
  case cancel
  case commit
}

/// Keeps a keyboard activation modal while menu and programmatic activation stay one-shot.
func mruActivationMessage(
  direction: MruDirection,
  initiatedByKeyEquivalent: Bool
) -> Msg {
  initiatedByKeyEquivalent
    ? .mruCycleStepped(direction: direction)
    : .mruCycleOneShot(direction: direction)
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
  case keyDown(
    character: Character?,
    modifiers: DanTermProtocol.KeyModifiers,
    matchesJumpCommand: Bool
  )
  case escape(
    modifiers: DanTermProtocol.KeyModifiers,
    matchesJumpCommand: Bool
  )
  case mouseDown
}

enum JumpAction: Equatable {
  case passthrough
  case commit(char: Character)
  case cancel(consumeEvent: Bool)
}

/// Classifies only continuation events for an active held-MRU gesture.
func classifySwitcherInput(
  kind: SwitcherInputKind,
  requiredModifiers: DanTermProtocol.KeyModifiers,
  olderChord: KeyChord,
  newerChord: KeyChord,
  cycleActive: Bool
) -> SwitcherAction {
  guard cycleActive else { return .passthrough }

  switch kind {
  case .keyDown(let chord):
    if chord == olderChord { return .stepOlder }
    if chord == newerChord { return .stepNewer }
    return .passthrough
  case .escape:
    return .cancel
  case .flagsChanged(let modifiers):
    return modifiers.isSuperset(of: requiredModifiers) ? .passthrough : .commit
  }
}

/// Classifies only continuation events for active tab jump mode.
func classifyJumpInput(
  kind: JumpInputKind,
  jumpActive: Bool
) -> JumpAction {
  guard jumpActive else { return .passthrough }

  switch kind {
  case .mouseDown:
    return .cancel(consumeEvent: false)
  case .escape(let modifiers, let matchesJumpCommand):
    if matchesJumpCommand { return .cancel(consumeEvent: true) }
    let commandModifiers: DanTermProtocol.KeyModifiers = [.command, .control, .option]
    let consumeEvent = modifiers.intersection(commandModifiers).isEmpty
    return .cancel(consumeEvent: consumeEvent)
  case .keyDown(let character, let modifiers, let matchesJumpCommand):
    if matchesJumpCommand { return .cancel(consumeEvent: true) }
    let commandModifiers: DanTermProtocol.KeyModifiers = [.command, .control, .option]
    if !modifiers.intersection(commandModifiers).isEmpty {
      return .cancel(consumeEvent: false)
    }
    guard let character else { return .cancel(consumeEvent: true) }
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
// shared by AppDelegate (keyboard/menu) and the reducer's sidebar request path.
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

/// Batch-capable menubar tab actions that share one target rule and message
/// construction path.
enum MenubarTabAction {
    case setColor(TabColor)
    case clearColor
    case clearCustomTitles
    case clearAlerts
    case close
}

/// Build the Msg for a menubar tab action by preferring the sidebar's
/// multi-selection and falling back to the selected tab.
func menubarTabActionMsg(
    _ action: MenubarTabAction,
    sidebarSelection: [TabId],
    in model: AppModel
) -> Msg? {
    let tabIds = !sidebarSelection.isEmpty
        ? sidebarSelection
        : model.selectedTabId.map { [$0] } ?? []
    guard !tabIds.isEmpty else { return nil }

    switch action {
    case .setColor(let color):
        return .setTabColors(
            tabIds: tabIds,
            color: resolveColorForBatch(tabIds: tabIds, requested: color, in: model))
    case .clearColor:
        return .setTabColors(tabIds: tabIds, color: nil)
    case .clearCustomTitles:
        return .clearCustomTitles(tabIds: tabIds)
    case .clearAlerts:
        return .clearAlertsForTabs(tabIds: tabIds)
    case .close:
        // Always the batch message: the reducer collapses a one-id batch back
        // to .requestCloseTab, so single-target behavior stays untouched.
        return .requestCloseTabs(ids: tabIds)
    }
}
