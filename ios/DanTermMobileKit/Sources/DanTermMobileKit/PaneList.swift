// Decodes the `ls` reply into the flat, stable pane order shown by the phone client.
import DanTermProtocol
import Foundation

/// One leaf in the phone's pane browser, with tab selection and focus already projected.
public struct MobilePaneListItem: Equatable, Sendable {
    public let groupId: GroupId
    public let groupName: String
    public let tabId: TabId
    public let tabTitle: String
    public let paneId: PaneId
    public let paneTitle: String
    public let isSelectedTab: Bool
    public let isFocused: Bool
}

/// Rejects an `ls` result whose required identity or split-tree fields are unusable.
public enum PaneListProjectionError: Error, Equatable, Sendable {
    case malformedReply
    case duplicatePane(PaneId)
}

/// Walks group, tab, and split-tree order once so every pane leaf appears exactly once.
public func projectPaneList(from value: JSONValue) throws -> [MobilePaneListItem] {
    guard let groups = value["groups"]?.asArray else {
        throw PaneListProjectionError.malformedReply
    }
    let selectedTabId = typedId(value["selectedTabId"]?.asString, as: TabId.self)
    var seen = Set<PaneId>()
    var result: [MobilePaneListItem] = []
    for groupValue in groups {
        guard let group = groupValue.asObject,
              let groupId = typedId(group["id"]?.asString, as: GroupId.self),
              let groupName = group["name"]?.asString,
              let tabs = group["tabs"]?.asArray
        else { throw PaneListProjectionError.malformedReply }
        for tabValue in tabs {
            guard let tab = tabValue.asObject,
                  let tabId = typedId(tab["id"]?.asString, as: TabId.self),
                  let focusedPaneId = typedId(
                      tab["focusedPaneId"]?.asString,
                      as: PaneId.self
                  ),
                  let root = tab["rootNode"]
            else { throw PaneListProjectionError.malformedReply }
            let leaves = try paneLeaves(in: root)
            guard let focused = leaves.first(where: { $0.id == focusedPaneId }) else {
                throw PaneListProjectionError.malformedReply
            }
            let terminalTitle = focused.title == "Terminal" ? nil : focused.title
            let tabTitle = tab["customTitle"]?.asString
                ?? terminalTitle
                ?? focused.runningCommand
                ?? focused.title
            for leaf in leaves {
                guard seen.insert(leaf.id).inserted else {
                    throw PaneListProjectionError.duplicatePane(leaf.id)
                }
                result.append(MobilePaneListItem(
                    groupId: groupId,
                    groupName: groupName,
                    tabId: tabId,
                    tabTitle: tabTitle,
                    paneId: leaf.id,
                    paneTitle: leaf.title,
                    isSelectedTab: tabId == selectedTabId,
                    isFocused: leaf.id == focusedPaneId
                ))
            }
        }
    }
    return result
}

private struct PaneLeaf {
    let id: PaneId
    let title: String
    let runningCommand: String?
}

private func paneLeaves(in node: JSONValue) throws -> [PaneLeaf] {
    guard let object = node.asObject, let type = object["type"]?.asString else {
        throw PaneListProjectionError.malformedReply
    }
    switch type {
    case "leaf":
        guard let pane = object["pane"]?.asObject,
              let id = typedId(pane["id"]?.asString, as: PaneId.self),
              let title = pane["title"]?.asString
        else { throw PaneListProjectionError.malformedReply }
        let command = pane["command"]?.asObject
        let runningCommand = command?["state"]?.asString == "running"
            ? command?["text"]?.asString
            : nil
        return [PaneLeaf(id: id, title: title, runningCommand: runningCommand)]
    case "split":
        guard let first = object["first"], let second = object["second"] else {
            throw PaneListProjectionError.malformedReply
        }
        return try paneLeaves(in: first) + paneLeaves(in: second)
    default:
        throw PaneListProjectionError.malformedReply
    }
}

private func typedId<Tag>(_ value: String?, as: TypedId<Tag>.Type) -> TypedId<Tag>? {
    value.flatMap(UUID.init(uuidString:)).map(TypedId<Tag>.init(rawValue:))
}
