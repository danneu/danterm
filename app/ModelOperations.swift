import Foundation

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

func splitLeaf(_ node: SplitNodeModel, paneId: PaneId, direction: SplitNodeModel.Direction, newPaneId: PaneId) -> SplitNodeModel? {
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
        if let newSecond = splitLeaf(second, paneId: paneId, direction: direction, newPaneId: newPaneId) {
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
            return (.split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio), focusFromFirst)
        }

        let (newSecond, focusFromSecond) = removeLeaf(second, paneId: paneId)
        if let newSecond = newSecond, newSecond != second {
            return (.split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio), focusFromSecond)
        }

        return (node, nil)
    }
}

func nearestLeaf(_ node: SplitNodeModel, from paneId: PaneId, direction: SplitNodeModel.Direction, side: SplitNodeModel.Side) -> PaneId? {
    // Build path from root to paneId
    var path: [(SplitNodeModel, Bool)] = [] // (splitNode, isInFirstChild)
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
private func enterSubtree(_ node: SplitNodeModel, navigating direction: SplitNodeModel.Direction, side: SplitNodeModel.Side, hints: [(SplitNodeModel, Bool)]) -> PaneId {
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

private func buildPath(_ node: SplitNodeModel, target: PaneId, path: inout [(SplitNodeModel, Bool)]) -> Bool {
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

func selectedTab(in model: AppModel) -> TabModel? {
    guard let id = model.selectedTabId else { return nil }
    for group in model.groups {
        if let tab = group.tabs.first(where: { $0.id == id }) { return tab }
    }
    return nil
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

func adjacentTabId(direction: TabDirection, in model: AppModel) -> TabId? {
    let allTabs = model.groups.flatMap(\.tabs)
    guard let idx = allTabs.firstIndex(where: { $0.id == model.selectedTabId }) else { return nil }
    let newIdx: Int
    switch direction {
    case .next: newIdx = idx + 1
    case .prev: newIdx = idx - 1
    }
    guard newIdx >= 0, newIdx < allTabs.count else { return nil }
    return allTabs[newIdx].id
}

// MARK: - Termination Helpers

func totalTabCount(_ model: AppModel) -> Int {
    model.groups.flatMap(\.tabs).count
}

func wouldQuitFromClose(_ model: AppModel) -> Bool {
    totalTabCount(model) == 1
}

// MARK: - Bell Helpers

func bellCount(for tab: TabModel, panes: [PaneId: PaneModel]) -> Int {
    allPaneIds(tab.rootNode).filter { panes[$0]?.hasBell == true }.count
}

func groupBellCount(for group: GroupModel, panes: [PaneId: PaneModel]) -> Int {
    group.tabs.reduce(0) { $0 + bellCount(for: $1, panes: panes) }
}
