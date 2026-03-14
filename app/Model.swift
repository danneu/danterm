import Foundation

// MARK: - Typed ID Wrappers

enum TabTag {}
enum PaneTag {}
enum GroupTag {}
enum SplitTag {}
enum AlertTag {}

struct TypedId<Tag>: Hashable, RawRepresentable, Codable {
    let rawValue: UUID
    init() { self.rawValue = UUID() }
    init(rawValue: UUID) { self.rawValue = rawValue }
}

typealias TabId = TypedId<TabTag>
typealias PaneId = TypedId<PaneTag>
typealias GroupId = TypedId<GroupTag>
typealias SplitId = TypedId<SplitTag>
typealias AlertId = TypedId<AlertTag>

enum AlertKind: Hashable {
    case bell
    case desktopNotification
}

struct AlertModel: Equatable {
    let id: AlertId
    let kind: AlertKind
    let paneId: PaneId
    let title: String
    let body: String
    let createdAt: Date
    var isUnread: Bool
}

// MARK: - Progress State

enum ProgressState: Equatable {
    case set(percent: UInt8)       // 0–100
    case indeterminate
    case error(percent: UInt8?)
    case pause(percent: UInt8?)
}

// MARK: - Search

struct SearchModel: Equatable {
    var needle: String = ""
    var total: Int?      // nil = unknown/not yet reported
    var selected: Int?   // nil = no selection
}

// MARK: - Model

struct PaneModel: Equatable {
    let id: PaneId
    var title: String = "Terminal"
    var cwd: String?
    var lastCommand: String?
    var progress: ProgressState? = nil
    var theme: String? = nil  // ghostty theme name; nil = app default
}

indirect enum SplitNodeModel: Equatable {
    case leaf(PaneId)
    case split(id: SplitId, direction: Direction, first: SplitNodeModel, second: SplitNodeModel, ratio: CGFloat)

    enum Direction: Equatable {
        case horizontal // divider is vertical, panes side-by-side (split right)
        case vertical   // divider is horizontal, panes stacked (split down)
    }

    enum Side: Equatable {
        case first  // left or top
        case second // right or bottom
    }
}

enum TabColor: String, Codable, CaseIterable, Equatable {
    case red, orange, yellow, green, blue, purple, gray
}

struct TabModel: Equatable {
    let id: TabId
    var title: String = "Terminal"
    var subtitle: String?
    var customTitle: String?
    var focusedPaneId: PaneId
    var rootNode: SplitNodeModel
    var isZoomed: Bool = false
    var color: TabColor? = nil

    var displayTitle: String { customTitle ?? title }
}

struct GroupModel: Equatable {
    let id: GroupId
    var name: String
    var isCollapsed: Bool = false
    var tabs: [TabModel] = []
}

struct AppModel: Equatable {
    var groups: [GroupModel]
    var panes: [PaneId: PaneModel]
    var selectedTabId: TabId?
    var alerts: [AlertModel] = []  // newest first, capped at 100
    var lastNotificationTime: [PaneId: [AlertKind: Date]] = [:]
    var searchState: [PaneId: SearchModel] = [:]  // ephemeral — excluded from snapshots
}

// MARK: - Session Lock

/// Written to ~/Library/Application Support/DanTerm/Recovery/session.json at launch
/// and deleted on clean exit. If this file exists at next launch, the previous exit
/// was unclean (crash or kill -9) and we prompt before restoring.
struct SessionLock: Codable {
    let pid: Int32
    let startedAt: Date
}

enum RestoreCommandBehavior: String, Equatable {
    case prefill
    case execute
}

// MARK: - Init Snapshot Types

struct AppInitFile: Codable {
    let version: Int
    let model: AppModelSnapshot
}

struct AppModelSnapshot: Codable {
    let groups: [GroupSnapshot]
    let panes: [PaneSnapshot]
    let selectedTabId: String?
}

struct GroupSnapshot: Codable {
    let id: String?
    let name: String
    let isCollapsed: Bool?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    let id: String?
    let customTitle: String?
    let focusedPaneId: String?
    let rootNode: SplitNodeSnapshot
    let color: TabColor?
}

indirect enum SplitNodeSnapshot: Codable {
    case leaf(paneId: String?)
    case split(id: String?, direction: String, first: SplitNodeSnapshot, second: SplitNodeSnapshot, ratio: Double?)

    enum CodingKeys: String, CodingKey {
        case type, paneId, id, direction, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "leaf":
            let paneId = try container.decodeIfPresent(String.self, forKey: .paneId)
            self = .leaf(paneId: paneId)
        case "split":
            let id = try container.decodeIfPresent(String.self, forKey: .id)
            let direction = try container.decode(String.self, forKey: .direction)
            let first = try container.decode(SplitNodeSnapshot.self, forKey: .first)
            let second = try container.decode(SplitNodeSnapshot.self, forKey: .second)
            let ratio = try container.decodeIfPresent(Double.self, forKey: .ratio)
            self = .split(id: id, direction: direction, first: first, second: second, ratio: ratio)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneId):
            try container.encode("leaf", forKey: .type)
            try container.encode(paneId, forKey: .paneId)
        case .split(let id, let direction, let first, let second, let ratio):
            try container.encode("split", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(direction, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encodeIfPresent(ratio, forKey: .ratio)
        }
    }
}

struct PaneSnapshot: Codable {
    let id: String?
    let title: String?
    let cwd: String?
    let launch: PaneLaunchSnapshot?
    let scrollback: String?  // optional for backward compat
    let theme: String?       // raw ghostty theme name; nil = default

}

struct PaneLaunchSnapshot: Codable {
    let command: String?
    let cwd: String?
}

// MARK: - Snapshot Validation & Build

struct SnapshotValidationError: Error {
    let message: String
}

func validateAndBuild(_ snapshot: AppModelSnapshot) -> AppModel? {
    validateAndBuildDetailed(snapshot)?.model
}

func validateAndBuildDetailed(_ snapshot: AppModelSnapshot) -> (model: AppModel, paneSnapshots: [PaneId: PaneSnapshot])? {
    // 1. Parse all pane snapshots into a lookup
    var paneSnapshotById: [PaneId: PaneSnapshot] = [:]
    var autoPaneIds: [PaneId] = []
    for ps in snapshot.panes {
        let id: PaneId
        if let idStr = ps.id {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid pane UUID: \(idStr)")
                return nil
            }
            id = PaneId(rawValue: parsed)
        } else {
            id = PaneId()
            autoPaneIds.append(id)
        }
        guard paneSnapshotById[id] == nil else {
            print("[init] Duplicate pane ID: \(id)")
            return nil
        }
        paneSnapshotById[id] = ps
    }

    // 2. Parse groups and tabs, collecting all referenced pane IDs.
    // Seed global IDs with pane IDs so collisions across domains are rejected.
    var allIds = Set(paneSnapshotById.keys.map(\.rawValue)) // track global uniqueness
    var referencedPaneIds = Set<PaneId>()
    var parsedGroups: [GroupModel] = []
    var allTabIds: [TabId] = []
    var autoPaneCursor = 0

    for gs in snapshot.groups {
        let groupId: GroupId
        if let idStr = gs.id {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid group UUID: \(idStr)")
                return nil
            }
            groupId = GroupId(rawValue: parsed)
        } else {
            groupId = GroupId()
        }
        guard allIds.insert(groupId.rawValue).inserted else {
            print("[init] Duplicate ID: \(groupId)")
            return nil
        }

        var tabs: [TabModel] = []
        for ts in gs.tabs {
            let tabId: TabId
            if let idStr = ts.id {
                guard let parsed = UUID(uuidString: idStr) else {
                    print("[init] Invalid tab UUID: \(idStr)")
                    return nil
                }
                tabId = TabId(rawValue: parsed)
            } else {
                tabId = TabId()
            }
            guard allIds.insert(tabId.rawValue).inserted else {
                print("[init] Duplicate ID: \(tabId)")
                return nil
            }

            // Parse split tree
            guard let rootNode = parseSplitNode(
                ts.rootNode,
                allIds: &allIds,
                autoPaneIds: autoPaneIds,
                autoPaneCursor: &autoPaneCursor
            ) else {
                return nil
            }

            let leafIdList = allPaneIds(rootNode)
            let leafIds = Set(leafIdList)

            // Reject duplicate pane references within one tab tree.
            if leafIds.count != leafIdList.count {
                print("[init] Duplicate pane ID appears multiple times within tab \(tabId)")
                return nil
            }

            // Check all leaf pane IDs exist in panes array
            for pid in leafIds {
                guard paneSnapshotById[pid] != nil else {
                    print("[init] Pane \(pid) referenced in tree but not in panes array")
                    return nil
                }
                guard referencedPaneIds.insert(pid).inserted else {
                    print("[init] Pane \(pid) appears in multiple tab trees")
                    return nil
                }
            }

            // Validate focusedPaneId
            let focusedPaneId: PaneId
            if let fpStr = ts.focusedPaneId, let fp = UUID(uuidString: fpStr), leafIds.contains(PaneId(rawValue: fp)) {
                focusedPaneId = PaneId(rawValue: fp)
            } else {
                focusedPaneId = firstLeafId(rootNode)
            }

            let focusedPs = paneSnapshotById[focusedPaneId]!
            let chrome = deriveTabChromeFromSnapshot(focusedPs)

            let tab = TabModel(
                id: tabId,
                title: chrome.title,
                subtitle: chrome.subtitle,
                customTitle: ts.customTitle,
                focusedPaneId: focusedPaneId,
                rootNode: rootNode,
                color: ts.color
            )
            tabs.append(tab)
            allTabIds.append(tabId)
        }

        let group = GroupModel(
            id: groupId,
            name: gs.name,
            isCollapsed: gs.isCollapsed ?? false,
            tabs: tabs
        )
        parsedGroups.append(group)
    }

    // 3. Check for orphan panes
    let paneIds = Set(paneSnapshotById.keys)
    let orphans = paneIds.subtracting(referencedPaneIds)
    if !orphans.isEmpty {
        print("[init] Orphan panes not referenced by any tab tree: \(orphans)")
        return nil
    }

    // 4. Must have at least one group with at least one tab
    guard !parsedGroups.isEmpty, !allTabIds.isEmpty else {
        print("[init] Must have at least one group with at least one tab")
        return nil
    }

    // 5. Build panes dictionary
    var panes: [PaneId: PaneModel] = [:]
    for (id, ps) in paneSnapshotById {
        let expandedCwd = ps.cwd.map { expandTilde($0) }
        panes[id] = PaneModel(id: id, title: ps.title ?? "Terminal", cwd: expandedCwd, theme: ps.theme)
    }

    // 6. Resolve selectedTabId. Default to first group's first tab.
    let selectedTabId: TabId?
    if let selStr = snapshot.selectedTabId, let selId = UUID(uuidString: selStr), allTabIds.contains(TabId(rawValue: selId)) {
        selectedTabId = TabId(rawValue: selId)
    } else {
        selectedTabId = parsedGroups.first?.tabs.first?.id
    }

    return (
        model: AppModel(groups: parsedGroups, panes: panes, selectedTabId: selectedTabId),
        paneSnapshots: paneSnapshotById
    )
}

/// Resolve launch metadata for a pane snapshot: returns (cwd, command) for surface creation.
func resolveLaunch(_ paneSnapshot: PaneSnapshot) -> (cwd: String?, command: String?) {
    let cwd: String?
    if let launchCwd = paneSnapshot.launch?.cwd {
        cwd = expandTilde(launchCwd)
    } else if let paneCwd = paneSnapshot.cwd {
        cwd = expandTilde(paneCwd)
    } else {
        cwd = nil
    }
    let command = paneSnapshot.launch?.command
    return (cwd, command)
}

func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    return NSHomeDirectory() + path.dropFirst(1)
}

private func parseSplitNode(
    _ snapshot: SplitNodeSnapshot,
    allIds: inout Set<UUID>,
    autoPaneIds: [PaneId],
    autoPaneCursor: inout Int
) -> SplitNodeModel? {
    switch snapshot {
    case .leaf(let paneIdStr):
        let paneId: PaneId
        if let paneIdStr {
            guard let parsed = UUID(uuidString: paneIdStr) else {
                print("[init] Invalid pane UUID in tree: \(paneIdStr)")
                return nil
            }
            paneId = PaneId(rawValue: parsed)
        } else if autoPaneCursor < autoPaneIds.count {
            paneId = autoPaneIds[autoPaneCursor]
            autoPaneCursor += 1
        } else {
            paneId = PaneId()
        }
        return .leaf(paneId)
    case .split(let idStr, let dirStr, let first, let second, let ratio):
        let splitId: SplitId
        if let idStr {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid split UUID: \(idStr)")
                return nil
            }
            splitId = SplitId(rawValue: parsed)
        } else {
            splitId = SplitId()
        }
        guard allIds.insert(splitId.rawValue).inserted else {
            print("[init] Duplicate ID: \(splitId)")
            return nil
        }
        let direction: SplitNodeModel.Direction
        switch dirStr {
        case "horizontal": direction = .horizontal
        case "vertical": direction = .vertical
        default:
            print("[init] Unknown direction: \(dirStr)")
            return nil
        }
        guard let firstNode = parseSplitNode(
            first,
            allIds: &allIds,
            autoPaneIds: autoPaneIds,
            autoPaneCursor: &autoPaneCursor
        ),
              let secondNode = parseSplitNode(
                  second,
                  allIds: &allIds,
                  autoPaneIds: autoPaneIds,
                  autoPaneCursor: &autoPaneCursor
              ) else {
            return nil
        }
        return .split(id: splitId, direction: direction, first: firstNode, second: secondNode, ratio: CGFloat(ratio ?? 0.5))
    }
}
