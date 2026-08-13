// Typed IPC entity encoding, independent of the persistence snapshot codec.
import Foundation
import DanTermProtocol

/// Builds wire documents from live model entities so IPC reply shape cannot
/// drift with the recovery format or require runtime JSON patching.
struct IpcEntityEncoder {
    let home: String

    func list(_ model: AppModel) -> JSONValue {
        var object: [String: JSONValue] = [
            "groups": .array(model.groups.map { group($0, in: model) }),
        ]
        if let selectedTabId = model.selectedTabId {
            object["selectedTabId"] = .string(selectedTabId.rawValue.uuidString)
        }
        return .object(object)
    }

    func group(_ group: GroupModel, in model: AppModel) -> JSONValue {
        .object([
            "id": .string(group.id.rawValue.uuidString),
            "name": .string(group.name),
            "isCollapsed": .bool(group.isCollapsed),
            "tabs": .array(group.tabs.map { tab($0, in: model) }),
        ])
    }

    func tab(_ tab: TabModel, in model: AppModel) -> JSONValue {
        self.tab(tab, in: model, includeLifecycles: true)
    }

    private func tab(_ tab: TabModel, in model: AppModel, includeLifecycles: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(tab.id.rawValue.uuidString),
            "focusedPaneId": .string(tab.paneTree.focusedPaneId.rawValue.uuidString),
            "rootNode": splitNode(tab.paneTree.root, includeLifecycles: includeLifecycles),
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
            cwd: pane.session?.cwd.map { abbreviateHome($0, home: home) },
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

    func paneInfo(
        pane: PaneModel,
        tab: TabModel,
        group: GroupModel,
        in model: AppModel
    ) -> JSONValue {
        .object([
            "pane": .object(paneFields(
                pane,
                cwd: pane.session?.cwd,
                includeNullCwd: true,
                includeLifecycles: true
            )),
            "tab": .object([
                "id": .string(tab.id.rawValue.uuidString),
                "title": .string(tabDisplayTitle(tab)),
                "groupId": .string(group.id.rawValue.uuidString),
                "isZoomed": .bool(tab.paneTree.isZoomed),
            ]),
            "group": groupReference(group),
        ])
    }

    /// Names the one group shape every reply that only identifies a group uses,
    /// so `pane info`, `tab new`, and `group rename` cannot drift apart.
    func groupReference(_ group: GroupModel) -> JSONValue {
        .object([
            "id": .string(group.id.rawValue.uuidString),
            "name": .string(group.name),
        ])
    }

    func tabNew(tab: TabModel?, group: GroupModel?, in model: AppModel) -> JSONValue {
        var object: [String: JSONValue] = [
            "tab": tab.map { self.tab($0, in: model, includeLifecycles: false) } ?? .null,
            "panes": .array(tab.map { tab in
                allPaneIds(tab.paneTree.root)
                    .map { .object(["id": .string($0.rawValue.uuidString)]) }
            } ?? []),
        ]
        if let group {
            object["group"] = groupReference(group)
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
            "title": .string(pane.session?.title ?? "Terminal"),
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
            "id": .string(item.id.rawValue.uuidString),
            "text": .string(item.text),
            "isDone": .bool(item.isDone),
        ])
    }
}
