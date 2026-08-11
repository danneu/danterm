// Pure row model for the tab-todo popover: the flattened `TabTodoRow` list (a tab
// section plus one section per pane) and the keyboard/drag-drop/reorder logic over it
// -- `buildTabTodoRows`, the `resolveTabTodo*` edit/drop/bucket/reorder resolvers, and
// their `TabTodo*` enums. This is the data `TabTodoPopoverView` renders and that the
// reconciler's `desiredTabTodoPopover` projection (in Projections.swift) builds its
// rows from. Split out of ModelOperations.swift because the row model is a sizable,
// self-contained, separately-tested cluster; kept apart from the *projection*
// (`TabTodoPopoverProjection`, which lives with the other projections) so the
// projection boundary stays clean. `import Foundation` only -- no AppKit.
import Foundation

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

  var item: TodoItem? {
    switch self {
    case .tabItem(let item), .paneItem(_, let item):
      return item
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

func resolveTabTodoEditTarget(
  _ target: TabTodoEditTarget,
  in projection: TabTodoPopoverProjection
) -> TabTodoEditTarget? {
  if projection.rows.contains(where: { $0.editTarget == target }) {
    return target
  }

  let todoId = tabTodoTargetId(target)
  return projection.rows.compactMap(\.editTarget).first { tabTodoTargetId($0) == todoId }
}

func newlyAddedTabTodoTarget(
  previousTabTodoIds: Set<UUID>,
  in projection: TabTodoPopoverProjection
) -> TabTodoEditTarget? {
  for row in projection.rows {
    if case .tabItem(let item) = row, !previousTabTodoIds.contains(item.id) {
      return .tab(todoId: item.id)
    }
  }
  return nil
}

private func tabTodoTargetId(_ target: TabTodoEditTarget) -> UUID {
  switch target {
  case .tab(let todoId), .pane(_, let todoId):
    return todoId
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
    rows.append(.paneSectionHeader(
      paneId: paneId,
      title: pane.session?.title ?? "Terminal"
    ))
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
  tabId: TabId,
  proposedRow: Int,
  dropOperation: TabTodoDropOperation
) -> (destination: TodoDestination, atIndex: Int)? {
  switch dropOperation {
  case .on:
    guard rows.indices.contains(proposedRow) else { return nil }
    switch rows[proposedRow] {
    case .tabSectionHeader:
      return (.tab(tabId), tabTodoCount(for: .tab(tabId), rows: rows))
    case .paneSectionHeader(let paneId, _):
      return (.pane(paneId), tabTodoCount(for: .pane(paneId), rows: rows))
    case .tabEmptyPlaceholder:
      return (.tab(tabId), 0)
    case .paneEmptyPlaceholder(let paneId):
      return (.pane(paneId), 0)
    case .tabItem, .paneItem:
      return nil
    }

  case .above:
    guard proposedRow >= 0, proposedRow <= rows.count else { return nil }
    if proposedRow == rows.count {
      guard let last = rows.last,
            let destination = tabTodoDestination(for: last, tabId: tabId) else { return nil }
      return (destination, tabTodoCount(for: destination, rows: rows))
    }

    switch rows[proposedRow] {
    case .tabSectionHeader:
      return nil
    case .paneSectionHeader:
      guard proposedRow > 0,
            let destination = tabTodoDestination(for: rows[proposedRow - 1], tabId: tabId) else { return nil }
      return (destination, tabTodoCount(for: destination, rows: rows))
    case .tabItem:
      let atIndex = rows[..<proposedRow].count { row in
        if case .tabItem = row { return true }
        return false
      }
      return (.tab(tabId), atIndex)
    case .tabEmptyPlaceholder:
      return (.tab(tabId), 0)
    case .paneItem(let paneId, _):
      let atIndex = rows[..<proposedRow].count { row in
        if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
        return false
      }
      return (.pane(paneId), atIndex)
    case .paneEmptyPlaceholder(let paneId):
      return (.pane(paneId), 0)
    }
  }
}

func resolveTabTodoDropTarget(
  rows: [TabTodoRow],
  model: AppModel,
  tabId: TabId,
  proposedRow: Int,
  dropOperation: TabTodoDropOperation
) -> (destination: TodoDestination, atIndex: Int)? {
  guard tabById(tabId, in: model) != nil,
        let target = resolveTabTodoDropTarget(
          rows: rows,
          tabId: tabId,
          proposedRow: proposedRow,
          dropOperation: dropOperation
        ) else { return nil }
  switch target.destination {
  case .tab(let destinationTabId):
    guard tabById(destinationTabId, in: model) != nil else { return nil }
  case .pane(let paneId):
    guard model.pane(paneId) != nil else { return nil }
  }
  return target
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

private func tabTodoCount(for destination: TodoDestination, rows: [TabTodoRow]) -> Int {
  switch destination {
  case .tab:
    return rows.count { row in
      if case .tabItem = row { return true }
      return false
    }
  case .pane(let paneId):
    return rows.count { row in
      if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
      return false
    }
  }
}
