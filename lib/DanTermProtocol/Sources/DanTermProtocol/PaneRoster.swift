// The pane roster: the whole, flat list of panes a client renders, with tab
// selection, focus, and the resolved tab title already decided by the server.
// It lives at the protocol boundary because the server projects it and every
// client renders it verbatim -- there is no second projection on the client
// side, so this file is the only place the roster's shape is written down.
//
// Not here: how a roster is built from the model (a pure DanTermCore
// projection), and who is subscribed to receive one (the app runtime).
import Foundation

/// One pane leaf of the roster. Flat rather than nested, because every consumer
/// draws a list of panes and would otherwise re-flatten the split tree itself.
public struct PaneRosterItem: Equatable, Sendable {
    public let groupId: GroupId
    public let groupName: String
    public let tabId: TabId
    /// The tab title as the server resolved it. A client shows this verbatim.
    public let tabTitle: String
    public let paneId: PaneId
    public let paneTitle: String
    /// The chip this pane shows, already resolved from its agent by the server.
    /// A client draws the named mark and never classifies an agent itself.
    public let chip: ChipKind
    public let isSelectedTab: Bool
    /// Whether this pane holds focus within its own tab, which is what a client
    /// marks in the list. Only the selected tab's focused pane holds app focus.
    public let isFocused: Bool

    public init(
        groupId: GroupId,
        groupName: String,
        tabId: TabId,
        tabTitle: String,
        paneId: PaneId,
        paneTitle: String,
        chip: ChipKind,
        isSelectedTab: Bool,
        isFocused: Bool
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.tabId = tabId
        self.tabTitle = tabTitle
        self.paneId = paneId
        self.paneTitle = paneTitle
        self.chip = chip
        self.isSelectedTab = isSelectedTab
        self.isFocused = isFocused
    }
}

/// The complete roster, in group then tab then split-tree order. Whole-state by
/// design: every roster a client receives replaces the one before it, so a
/// client can never hold a partially applied list.
public struct PaneRoster: Equatable, Sendable {
    public let panes: [PaneRosterItem]

    public init(panes: [PaneRosterItem]) {
        self.panes = panes
    }

    public var jsonValue: JSONValue {
        .object(["panes": .array(panes.map(\.jsonValue))])
    }

    /// Decodes a roster, or returns nil when any required field is missing or
    /// mistyped. Nil rather than a thrown vocabulary of reasons: a client that
    /// cannot read a roster has the same one recovery whatever the field was.
    public init?(jsonValue: JSONValue) {
        guard let encoded = jsonValue["panes"]?.asArray else { return nil }
        var panes: [PaneRosterItem] = []
        panes.reserveCapacity(encoded.count)
        for value in encoded {
            guard let item = PaneRosterItem(jsonValue: value) else { return nil }
            panes.append(item)
        }
        self.panes = panes
    }
}

extension PaneRosterItem {
    var jsonValue: JSONValue {
        .object([
            "groupId": .string(groupId.rawValue.uuidString),
            "groupName": .string(groupName),
            "tabId": .string(tabId.rawValue.uuidString),
            "tabTitle": .string(tabTitle),
            "paneId": .string(paneId.rawValue.uuidString),
            "paneTitle": .string(paneTitle),
            "chip": .string(chip.rawValue),
            "isSelectedTab": .bool(isSelectedTab),
            "isFocused": .bool(isFocused),
        ])
    }

    init?(jsonValue: JSONValue) {
        guard let groupId = TypedId<GroupTag>(wire: jsonValue["groupId"]),
              let groupName = jsonValue["groupName"]?.asString,
              let tabId = TypedId<TabTag>(wire: jsonValue["tabId"]),
              let tabTitle = jsonValue["tabTitle"]?.asString,
              let paneId = TypedId<PaneTag>(wire: jsonValue["paneId"]),
              let paneTitle = jsonValue["paneTitle"]?.asString,
              let chip = jsonValue["chip"]?.asString.flatMap(ChipKind.init(rawValue:)),
              let isSelectedTab = jsonValue["isSelectedTab"]?.asBool,
              let isFocused = jsonValue["isFocused"]?.asBool
        else { return nil }
        self.init(
            groupId: groupId,
            groupName: groupName,
            tabId: tabId,
            tabTitle: tabTitle,
            paneId: paneId,
            paneTitle: paneTitle,
            chip: chip,
            isSelectedTab: isSelectedTab,
            isFocused: isFocused
        )
    }
}

extension TypedId {
    /// Reads a typed id out of its wire spelling, which is always a UUID string.
    fileprivate init?(wire: JSONValue?) {
        guard let uuid = wire?.asString.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(rawValue: uuid)
    }
}
