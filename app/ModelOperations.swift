import Foundation

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
    return insertAtLeaf(stripped, at: target, inserting: source, direction: direction, insertFirst: insertFirst)
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
        if let newFirst = insertAtLeaf(first, at: targetId, inserting: sourceId, direction: direction, insertFirst: insertFirst) {
            return .split(id: splitId, direction: dir, first: newFirst, second: second, ratio: ratio)
        }
        if let newSecond = insertAtLeaf(second, at: targetId, inserting: sourceId, direction: direction, insertFirst: insertFirst) {
            return .split(id: splitId, direction: dir, first: first, second: newSecond, ratio: ratio)
        }
        return nil
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

func tabById(_ tabId: TabId, in model: AppModel) -> TabModel? {
    for group in model.groups {
        if let tab = group.tabs.first(where: { $0.id == tabId }) { return tab }
    }
    return nil
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

// MARK: - Restore

/// Parse the restore command behavior from CLI arguments.
/// Defaults to `.prefill` to avoid surprising command execution during restore.
func restoreCommandBehavior(from arguments: [String]) -> RestoreCommandBehavior {
    guard let idx = arguments.firstIndex(of: "--restore-commands"),
          idx + 1 < arguments.count else {
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

func deleteGroupAction(for groupId: GroupId, in model: AppModel) -> DeleteGroupAction? {
    guard let group = model.groups.first(where: { $0.id == groupId }),
          !group.isDefault else { return nil }
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
                      let pane = model.panes[paneId] else { continue }
                let abbrevCwd = pane.cwd.map { abbreviateHome($0) }
                let launch: PaneLaunchSnapshot?
                if pane.lastCommand != nil || abbrevCwd != nil {
                    launch = PaneLaunchSnapshot(command: pane.lastCommand, cwd: abbrevCwd)
                } else {
                    launch = nil
                }
                paneSnapshots.append(PaneSnapshot(
                    id: paneId.rawValue.uuidString,
                    title: pane.title,
                    cwd: abbrevCwd,
                    launch: launch,
                    scrollback: nil
                ))
            }

            return TabSnapshot(
                id: tab.id.rawValue.uuidString,
                customTitle: tab.customTitle,
                focusedPaneId: tab.focusedPaneId.rawValue.uuidString,
                rootNode: toSplitNodeSnapshot(tab.rootNode),
                color: tab.color
            )
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

// MARK: - Scrollback Truncation

/// Truncate scrollback text to the last `maxLines` lines and `maxChars` characters.
/// Returns nil for empty/whitespace-only input.
func truncateScrollback(_ text: String, maxLines: Int = 4000, maxChars: Int = 400_000) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var result = text

    // Keep the last maxLines lines
    let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > maxLines {
        result = lines.suffix(maxLines).joined(separator: "\n")
    }

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
/// Returns nil when the message should be dropped (CMD_END, bad token, malformed event).
/// Normal (non-event) messages pass through unchanged.
func translateMsg(_ msg: Msg, tokenForPane: (PaneId) -> String?) -> Msg? {
    guard case .surfaceTitle(let paneId, let title) = msg,
          title.hasPrefix("__DANTERM_EVT__:") else {
        return msg
    }
    guard let token = tokenForPane(paneId),
          let event = parseDantermEvent(title, expectedToken: token) else {
        return nil
    }
    switch event {
    case .commandStarted(let command):
        return .commandStarted(paneId: paneId, command: command)
    case .commandEnded:
        return nil
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
              !cmd.isEmpty else { return nil }
        return .commandStarted(command: cmd)
    } else if event == "CMD_END" {
        return .commandEnded
    }
    return nil
}
