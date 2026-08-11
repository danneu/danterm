// Typed IPC entity encoding, independent of the persistence snapshot codec.
import Foundation
import DanTermProtocol

/// Builds wire documents from live model entities so IPC reply shape cannot
/// drift with the recovery format or require runtime JSON patching.
struct IpcEntityEncoder {
    let home: String

    func list(_ model: AppModel) -> JSONValue {
        var object: [String: JSONValue] = [
            "groups": .array(model.groups.map(group)),
        ]
        if let selectedTabId = model.selectedTabId {
            object["selectedTabId"] = .string(selectedTabId.rawValue.uuidString)
        }
        return .object(object)
    }

    func group(_ group: GroupModel) -> JSONValue {
        .object([
            "id": .string(group.id.rawValue.uuidString),
            "name": .string(group.name),
            "isCollapsed": .bool(group.isCollapsed),
            "tabs": .array(group.tabs.map(tab)),
        ])
    }

    func tab(_ tab: TabModel) -> JSONValue {
        self.tab(tab, includeLifecycles: true)
    }

    private func tab(_ tab: TabModel, includeLifecycles: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(tab.id.rawValue.uuidString),
            "focusedPaneId": .string(tab.focusedPaneId.rawValue.uuidString),
            "rootNode": splitNode(tab.rootNode, includeLifecycles: includeLifecycles),
        ]
        if let customTitle = tab.customTitle {
            object["customTitle"] = .string(customTitle)
        }
        if let color = tab.color {
            object["color"] = .string(color.rawValue)
        }
        if tab.todos.isEmpty == false {
            object["todos"] = .array(tab.todos.map(todo))
        }
        return .object(object)
    }

    private func pane(_ pane: PaneModel, includeLifecycles: Bool) -> JSONValue {
        var object = paneFields(
            pane,
            cwd: pane.cwd.map { abbreviateHome($0, home: home) },
            includeNullCwd: false,
            includeLifecycles: includeLifecycles
        )
        if let theme = pane.theme {
            object["theme"] = .string(theme)
        }
        if pane.fontSizeSteps != 0 {
            object["fontSizeSteps"] = .number(Double(pane.fontSizeSteps))
        }
        if pane.todos.isEmpty == false {
            object["todos"] = .array(pane.todos.map(todo))
        }
        return .object(object)
    }

    func paneInfo(pane: PaneModel, tab: TabModel, group: GroupModel) -> JSONValue {
        .object([
            "pane": .object(paneFields(
                pane,
                cwd: pane.cwd,
                includeNullCwd: true,
                includeLifecycles: true
            )),
            "tab": .object([
                "id": .string(tab.id.rawValue.uuidString),
                "title": .string(tab.displayTitle),
                "groupId": .string(group.id.rawValue.uuidString),
                "isZoomed": .bool(tab.isZoomed),
            ]),
            "group": .object([
                "id": .string(group.id.rawValue.uuidString),
                "name": .string(group.name),
            ]),
        ])
    }

    func tabNew(tab: TabModel?, group: GroupModel?) -> JSONValue {
        var object: [String: JSONValue] = [
            "tab": tab.map { self.tab($0, includeLifecycles: false) } ?? .null,
            "panes": .array(tab.map { tab in
                allPaneIds(tab.rootNode)
                    .map { .object(["id": .string($0.rawValue.uuidString)]) }
            } ?? []),
        ]
        if let group {
            object["group"] = .object([
                "id": .string(group.id.rawValue.uuidString),
                "name": .string(group.name),
            ])
        }
        return .object(object)
    }

    func paneReference(_ pane: PaneModel?) -> JSONValue {
        .object([
            "pane": pane.map { .object(["id": .string($0.id.rawValue.uuidString)]) } ?? .null,
        ])
    }

    func paneTheme(_ pane: PaneModel?) -> JSONValue {
        .object([
            "pane": pane.map { pane in
                .object([
                    "id": .string(pane.id.rawValue.uuidString),
                    "theme": pane.theme.map(JSONValue.string) ?? .null,
                ])
            } ?? .null,
        ])
    }

    private func splitNode(_ node: SplitNodeModel, includeLifecycles: Bool) -> JSONValue {
        switch node {
        case .leaf(let pane):
            return .object([
                "type": .string("leaf"),
                "pane": self.pane(pane, includeLifecycles: includeLifecycles),
            ])
        case .split(let id, let direction, let first, let second, let ratio):
            return .object([
                "type": .string("split"),
                "id": .string(id.rawValue.uuidString),
                "direction": .string(direction == .horizontal ? "horizontal" : "vertical"),
                "first": splitNode(first, includeLifecycles: includeLifecycles),
                "second": splitNode(second, includeLifecycles: includeLifecycles),
                "ratio": .number(Double(ratio)),
            ])
        }
    }

    private func paneFields(
        _ pane: PaneModel,
        cwd: String?,
        includeNullCwd: Bool,
        includeLifecycles: Bool
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(pane.id.rawValue.uuidString),
            "title": .string(pane.title),
        ]
        if includeLifecycles {
            let lifecycleFields = paneLifecycleInspectionFields(pane.session)
            object.merge(lifecycleFields) { _, lifecycle in lifecycle }
        }
        if let cwd {
            object["cwd"] = .string(cwd)
        } else if includeNullCwd {
            object["cwd"] = .null
        }
        return object
    }

    private func todo(_ item: TodoItem) -> JSONValue {
        .object([
            "id": .string(item.id.uuidString),
            "text": .string(item.text),
            "isDone": .bool(item.isDone),
        ])
    }
}
