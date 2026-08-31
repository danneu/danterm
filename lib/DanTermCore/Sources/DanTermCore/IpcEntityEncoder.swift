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
            "sidebar": .object([
                "isCollapsed": .bool(model.sidebar.isCollapsed),
                "width": .number(Double(model.sidebar.width)),
            ]),
        ]
        if let selectedTabId = model.selectedTabId {
            object["selectedTabId"] = .string(selectedTabId.rawValue.uuidString)
        }
        // Absent means no editor is open. The model holds the target for every
        // writer, so this reads as the live session rather than a stale request.
        switch model.sidebarRenameTarget {
        case .tab(let id):
            object["inlineRename"] = .object([
                "type": .string("tab"),
                "tabId": .string(id.rawValue.uuidString),
            ])
        case .group(let id):
            object["inlineRename"] = .object([
                "type": .string("group"),
                "groupId": .string(id.rawValue.uuidString),
            ])
        case nil:
            break
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
            "rootNode": splitNode(
                tab.paneTree.root,
                zoomedPaneId: tab.paneTree.zoomedPaneId,
                includeLifecycles: includeLifecycles),
        ]
        if let customTitle = tab.customTitle {
            object["customTitle"] = .string(customTitle)
        }
        if let color = tab.color {
            object["color"] = .string(color.rawValue)
        }
        if tab.todos.isEmpty == false {
            object["todos"] = .array(tab.todos.map(Self.todo))
        }
        return .object(object)
    }

    private func pane(
        _ pane: PaneModel,
        zoomedPaneId: PaneId?,
        includeLifecycles: Bool
    ) -> JSONValue {
        var object = paneFields(
            pane,
            cwd: pane.session?.cwd.map { abbreviateHome($0, home: home) },
            includeNullCwd: false,
            includeLifecycles: includeLifecycles,
            isZoomed: zoomedPaneId == pane.id
        )
        if let theme = pane.theme {
            object["theme"] = .string(theme)
        }
        if pane.fontSizeSteps != 0 {
            object["fontSizeSteps"] = .number(Double(pane.fontSizeSteps))
        }
        if pane.todos.isEmpty == false {
            object["todos"] = .array(pane.todos.map(Self.todo))
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
                includeLifecycles: true,
                isZoomed: tab.paneTree.zoomedPaneId == pane.id
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

    private func splitNode(
        _ node: SplitNodeModel,
        zoomedPaneId: PaneId?,
        includeLifecycles: Bool
    ) -> JSONValue {
        switch node {
        case .leaf(let pane):
            return .object([
                "type": .string(SplitNodeType.leaf.rawValue),
                "pane": self.pane(
                    pane, zoomedPaneId: zoomedPaneId, includeLifecycles: includeLifecycles),
            ])
        case .split(let id, let direction, let first, let second, let ratio):
            return .object([
                "type": .string(SplitNodeType.split.rawValue),
                "id": .string(id.rawValue.uuidString),
                "direction": .string(direction.rawValue),
                "first": splitNode(
                    first, zoomedPaneId: zoomedPaneId, includeLifecycles: includeLifecycles),
                "second": splitNode(
                    second, zoomedPaneId: zoomedPaneId, includeLifecycles: includeLifecycles),
                "ratio": .number(Double(ratio.value)),
            ])
        }
    }

    /// `isZoomed` is a per-pane fact rather than the owning tab's flag, so one
    /// reply says where a zoom landed instead of only that the tab has one.
    private func paneFields(
        _ pane: PaneModel,
        cwd: String?,
        includeNullCwd: Bool,
        includeLifecycles: Bool,
        isZoomed: Bool
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(pane.id.rawValue.uuidString),
            "title": pane.session?.titleState.declared.map(JSONValue.string) ?? .null,
            "isZoomed": .bool(isZoomed),
        ]
        if includeLifecycles {
            let lifecycleFields = paneLifecycleInspectionFields(pane.session)
            object.merge(lifecycleFields) { _, lifecycle in lifecycle }
            object["processPhase"] = .string(
                pane.session?.processPhase.rawValue ?? SessionProcessPhase.spawning.rawValue
            )
            if let launchInput = pane.session?.launchInput {
                object["launchInput"] = launchInputJSON(launchInput)
            }
        }
        if let cwd {
            object["cwd"] = .string(cwd)
        } else if includeNullCwd {
            object["cwd"] = .null
        }
        // Here rather than in the `ls`-only fields, so `pane info` and `ls`
        // report a claimed grid identically. Absent means the pane's grid
        // follows its slot.
        if let gridOverride = pane.gridOverride {
            object["gridOverride"] = .object([
                "columns": .number(Double(gridOverride.columns)),
                "rows": .number(Double(gridOverride.rows)),
            ])
        }
        return object
    }

    /// Encodes launch delivery with explicit state and a stable typed rejection reason.
    private func launchInputJSON(_ state: LaunchInputState) -> JSONValue {
        switch state {
        case .pending:
            return .object(["state": .string("pending")])
        case .delivered:
            return .object(["state": .string("delivered")])
        case .rejected(let failure):
            var object: [String: JSONValue] = [
                "state": .string("rejected"),
                "reason": .string(inputSubmissionFailureReason(failure)),
            ]
            if case .writeFailed(let code) = failure {
                object["errno"] = .number(Double(code))
            }
            return .object(object)
        }
    }

    /// Names the one todo shape used by both entity trees and todo command replies.
    static func todo(_ item: TodoItem) -> JSONValue {
        .object([
            "id": .string(item.id.rawValue.uuidString),
            "text": .string(item.text.value),
            "isDone": .bool(item.isDone),
        ])
    }
}
