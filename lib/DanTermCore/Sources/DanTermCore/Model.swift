// Core value types for the DanTerm Elm-style application model.
import Foundation

// MARK: - Typed ID Wrappers

enum TabTag {}
enum PaneTag {}
/// Keeps terminal-session identity distinct from its owning pane identity.
enum SessionTag {}
enum GroupTag {}
enum SplitTag {}
enum AlertTag {}

struct TypedId<Tag>: Hashable, RawRepresentable, Codable {
    let rawValue: UUID
    init(rawValue: UUID) { self.rawValue = rawValue }
}

typealias TabId = TypedId<TabTag>
typealias PaneId = TypedId<PaneTag>
/// Identifies one terminal lifetime so late reports cannot target its replacement.
typealias SessionId = TypedId<SessionTag>
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

/// The find overlay's match counter as one value, so "a selected match with no
/// total" -- which two independent `Int?`s allowed -- cannot be represented. This
/// mirrors the engine's own `TerminalSearchStatus`, with the extra `.counted` state
/// for the window between a backend reporting the total and reporting which match
/// it selected.
enum SearchMatchStatus: Equatable {
    /// Matches counted, none selected yet -- renders `-/N`. `total` is 0 for a
    /// needle that matched nothing.
    case counted(total: Int)
    case matched(selected: Int, total: Int)

    var total: Int {
        switch self {
        case .counted(let total): return total
        case .matched(_, let total): return total
        }
    }
}

struct SearchModel: Equatable {
    var needle: String = ""
    var status: SearchMatchStatus?   // nil = nothing reported yet
}

// MARK: - Remote Session

struct RemoteSession: Equatable {
    var user: String
    var host: String

    var displayString: String { "\(user)@\(host)" }
}

// MARK: - TODO

struct TodoItem: Equatable, Codable {
    let id: UUID
    var text: String
    var isDone: Bool
}

// MARK: - Model

/// Owns every terminal-reported fact and recovery memo whose lifetime is
/// bounded by this identified terminal session.
struct SessionModel: Equatable {
    let id: SessionId
    var title: String = "Terminal"
    var cwd: String?
    var progress: ProgressState?
    var integration: IntegrationLatch = .neverReported
    var command: CommandLifecycle = .idle
    var connection: ConnectionLifecycle = .local
    var agent: AgentLifecycle = .none
    var lastCommand: String?
    var lastAgentSession: AgentSession?
}

struct PaneModel: Equatable {
    let id: PaneId
    var session: SessionModel? = nil
    var theme: String? = nil  // catalog theme name; nil = app default
    /// Font-size zoom relative to the configured size, in `paneFontSizeStepPoints`
    /// steps; 0 = follow the configuration. Relative rather than absolute so a
    /// configuration change moves zoomed and unzoomed panes alike. Always inside
    /// `paneFontSizeStepRange` -- every ingress bounds it.
    var fontSizeSteps: Int = 0
    var todos: [TodoItem] = []
}

indirect enum SplitNodeModel: Equatable {
    // The leaf owns its pane's full content. A pane exists iff a tree leaf owns
    // it (no separate `AppModel.panes` dict), so the old dual-write drift between
    // dict and tree is structurally impossible. `PaneModel.id` is a `let`, so
    // identity travels with the payload.
    case leaf(PaneModel)
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
    var customTitle: String?
    var focusedPaneId: PaneId
    var rootNode: SplitNodeModel
    var isZoomed: Bool = false
    var color: TabColor? = nil
    var todos: [TodoItem] = []

}

/// Which TODO popover (if any) is currently open. Replaces the old
/// `todoPopoverPaneId` slot so opening a tab popover and a pane popover are
/// mutually exclusive by construction.
enum TodoPopoverScope: Equatable {
    case pane(PaneId)
    case tab(TabId)
}

struct GroupModel: Equatable {
    let id: GroupId
    var name: String
    var isCollapsed: Bool = false
    var tabs: [TabModel] = []
}

/// Form state for the settings window. Text-entry values remain raw until save;
/// picker values retain the exact catalog name that was selected.
///
/// `fontSize` is text rather than a number precisely because it is mid-edit
/// state: a half-typed "1" must stay "1" until save, not be reinterpreted as a
/// size. Comparing it against the committed `config.fontSize` therefore renders
/// that number with `configFontSizeText` at the point of comparison -- the model
/// never stores a second copy of it.
struct PreferencesDraft: Equatable {
    var alertClearMode: AlertClearMode
    var remoteTheme: String  // selected catalog name
    var theme: String?       // selected catalog name; nil uses the catalog default
    var fontSize: String?    // nil = no `fontSize` key; use the built-in default
    var fontFamily: String?  // nil = use the system monospace font (remove key from config)
    var copyOnSelect: Bool
}

// MRU tab switcher state. Ephemeral — never serialized into AppModelSnapshot.
// mruOrder[0] is the most-recently-used tab; reconcileMru maintains this
// invariant whenever mruCycle is nil. While mruCycle is non-nil, mruOrder is
// frozen so repeated cmd-shift-i taps walk back through history instead of
// toggling between two tabs.
struct MruCycleState: Equatable {
    let frozenOrder: [TabId]
    var cursorIndex: Int  // 0 = current tab, 1 = previous, etc.
}

// Tab jump mode state. Ephemeral -- never serialized into AppModelSnapshot.
// The key map is frozen at activation so the displayed badges match the next
// accepted keystroke even if sidebar rows refresh in place.
struct JumpModeState: Equatable {
    let keyMap: [TabId: Character]
}

// Ephemeral -- never serialized into AppModelSnapshot. Non-nil while a
// confirmation sheet is in flight. Quit and close-tab confirmations share this
// single slot so neither kind can stack a sheet on top of the other.
enum PendingConfirmation: Equatable {
    case terminate
    case closeTab
}

struct AppModel: Equatable {
    var groups: [GroupModel]
    var selectedTabId: TabId?
    var isAppActive: Bool = true  // ephemeral -- excluded from snapshots; gates focused-pane notification suppression
    var alerts: [AlertModel] = []  // newest first, capped at 100
    var lastNotificationTime: [PaneId: [AlertKind: Date]] = [:]
    var searchState: [PaneId: SearchModel] = [:]  // ephemeral — excluded from snapshots
    var showAllAlerts: Bool = false  // ephemeral — excluded from snapshots
    var config: DanTermConfig = .default  // ephemeral — loaded from disk, not snapshots
    // The canonical installed family `config.fontFamily` resolved to, or nil for the
    // system monospace font. Ephemeral: re-derived from disk on every config apply,
    // never snapshotted. The core cannot compute it (that is a CoreText question), so
    // the impure caller injects it alongside the config it came from -- which is also
    // why "the configured font is missing" is derived from the pair rather than stored:
    // a second copy of the requested name could drift from `config`.
    var resolvedFontFamily: String? = nil
    var preferencesDraft: PreferencesDraft? = nil  // ephemeral — non-nil while prefs panel is open
    // The font families installed on this machine, injected when the preferences
    // panel opens and dropped when it closes. Ephemeral and panel-scoped: the
    // syntax-only core never queries CoreText and cannot enumerate them, and the
    // catalog is deliberately a snapshot per open rather than a live view.
    var installedFontFamilies: [String] = []
    // Bundled theme names injected when Settings opens. Ephemeral and
    // panel-scoped for the same reason as `installedFontFamilies`.
    var availableThemeNames: [String] = []
    var todoPopover: TodoPopoverScope? = nil  // ephemeral — which TODO popover (pane or tab) is open
    var mruOrder: [TabId] = []  // ephemeral — most-recently-used tab ordering
    var mruCycle: MruCycleState? = nil  // ephemeral — non-nil while cmd-shift held
    var jumpMode: JumpModeState? = nil  // ephemeral — non-nil while tab jump mode is active
    var pendingConfirmation: PendingConfirmation? = nil  // ephemeral -- non-nil while a confirmation sheet is active

    /// Whether any group holds at least one tab. Short-circuits on the first
    /// non-empty group without materializing `groups.flatMap(\.tabs)`, which
    /// several close/quit arms previously did only to test emptiness.
    var hasAnyTab: Bool { groups.contains { !$0.tabs.isEmpty } }
}

// MARK: - Pane Access (tree is the single source of truth)
//
// Panes live only in the split-tree leaves; these walk groups -> tabs -> leaves
// rather than reading a dict. Lookups are O(tree size) but run per-`Msg`, never
// on a render frame, and the model already does whole-tree walks on every
// relevant message. NO stored index is kept (that would reintroduce the drift
// this refactor removes).
extension AppModel {
    /// Find a pane by id. Returns nil if no leaf owns it.
    func pane(_ id: PaneId) -> PaneModel? {
        for group in groups {
            for tab in group.tabs {
                if let found = paneInNode(tab.rootNode, id: id) { return found }
            }
        }
        return nil
    }

    /// Finds the pane that owns a live session, so inbound session identity can
    /// never resolve independently from the pane tree that owns its state.
    func pane(owning sessionId: SessionId) -> PaneModel? {
        allPanes.first { $0.session?.id == sessionId }
    }

    /// All panes, in tab then tree (left-to-right) order. A few reconcile passes
    /// rebuild this per sweep, which is acceptable for the same per-`Msg`,
    /// never-per-render-frame reason above; see `Projection Scan Cost` in
    /// `docs/design/2026-05-27-model-driven-view-reconciliation.md`.
    var allPanes: [PaneModel] {
        groups.flatMap { $0.tabs.flatMap { panesInNode($0.rootNode) } }
    }

    /// All pane ids, in tab then tree order. Replaces the old `panes.keys`.
    var allPaneIds: [PaneId] {
        allPanes.map(\.id)
    }

    /// Mutate the leaf-owned pane with the given id in place, rebuilding only the
    /// spine down to that leaf (like `setRatio`). No-op if no leaf owns the id.
    /// Stops at the first match -- pane ids are unique across the whole model.
    mutating func updatePane(_ id: PaneId, _ body: (inout PaneModel) -> Void) {
        for gi in groups.indices {
            for ti in groups[gi].tabs.indices {
                if let newRoot = updatePaneInNode(groups[gi].tabs[ti].rootNode, id: id, body) {
                    groups[gi].tabs[ti].rootNode = newRoot
                    return
                }
            }
        }
    }

    /// Mutates a session only through the pane leaf that owns its complete value.
    mutating func updateSession(_ id: SessionId, _ body: (inout SessionModel) -> Void) {
        guard let paneId = pane(owning: id)?.id else { return }
        updatePane(paneId) { pane in
            guard var session = pane.session, session.id == id else { return }
            body(&session)
            pane.session = session
        }
    }
}

// MARK: - View-Local State (reconciler sidecar)

/// Tracks whether an inline-editing sidebar row is renaming a tab or a group.
/// Hoisted out of `SidebarView` (where it was a `private enum`) into the model
/// layer so the reconciler -- which lives in `AppRuntime` and can read neither a
/// `private` view type nor a per-text-field associated object -- can tell which
/// row is being edited. Pure data, no AppKit.
enum RenameTarget: Equatable {
    case tab(TabId)
    case group(GroupId)
}

/// Ephemeral view state with no natural AppKit owner that the reconciler reads as a
/// second input (alongside `AppModel`) and never clobbers. Stored on `AppRuntime`
/// next to `model`. Deliberately minimal -- just the inline-rename target. The theme
/// browser owns its own filter/focus, and `NSOutlineView` owns sidebar
/// multi-selection; mirroring either here would be dead weight no pass reads.
struct ViewLocalState {
    var sidebarRenameTarget: RenameTarget?
}

// MARK: - Init Snapshot Types

// Current on-disk/wire format version. v3 keeps one pane cwd, stores the launch
// command directly on the pane, and rejects invalid persisted agent sessions.
let appInitFileVersion = 3

struct AppInitFile: Codable {
    let version: Int
    let model: AppModelSnapshot
}

struct AppModelSnapshot: Codable, Equatable {
    let groups: [GroupSnapshot]
    let selectedTabId: String?
}

struct GroupSnapshot: Codable, Equatable {
    let id: String?
    let name: String
    let isCollapsed: Bool?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable, Equatable {
    let id: String?
    let customTitle: String?
    let focusedPaneId: String?
    let rootNode: SplitNodeSnapshot
    let color: TabColor?
    var todos: [TodoSnapshot]? = nil  // nil for backward compat
}

indirect enum SplitNodeSnapshot: Codable, Equatable {
    // A leaf owns its full PaneSnapshot inline.
    case leaf(PaneSnapshot)
    case split(id: String?, direction: String, first: SplitNodeSnapshot, second: SplitNodeSnapshot, ratio: Double?)

    enum CodingKeys: String, CodingKey {
        case type, pane, id, direction, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "leaf":
            // `pane` is optional so a hand-authored snapshot can write a bare
            // `{ "type": "leaf" }` (id and all fields minted/defaulted on decode) --
            // preserving the v1 omitted-id authoring affordance.
            let pane = try container.decodeIfPresent(PaneSnapshot.self, forKey: .pane)
            self = .leaf(pane ?? PaneSnapshot(id: nil, title: nil, cwd: nil, command: nil, scrollback: nil, theme: nil))
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
        case .leaf(let pane):
            try container.encode("leaf", forKey: .type)
            try container.encode(pane, forKey: .pane)
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

struct TodoSnapshot: Codable, Equatable {
    let id: String
    let text: String
    let isDone: Bool
}

/// Strictly decoded checkpoint DTO validated through `AgentSession` during load.
struct AgentSessionSnapshot: Codable, Equatable {
    let kind: String
    let sessionId: String

    init(kind: String, sessionId: String) {
        self.kind = kind
        self.sessionId = sessionId
    }
}

struct PaneSnapshot: Codable, Equatable {
    let id: String?
    let title: String?
    let cwd: String?
    var command: String?
    var scrollback: String?  // optional for backward compat; var so scrollback grafting can set it
    let theme: String?       // raw catalog theme name; nil = default
    var todos: [TodoSnapshot]? = nil  // nil for backward compat
    var agentSession: AgentSessionSnapshot? = nil  // nil for backward compat; raw recovery-only DTO
    // Absent for an unzoomed pane, so a pane at the configured size persists
    // exactly as it did before per-pane zoom existed.
    var fontSizeSteps: Int? = nil
}

// MARK: - Snapshot Validation & Build

struct SnapshotValidationError: Error {
    let message: String
}

func validateAndBuild(_ snapshot: AppModelSnapshot, env: CoreEnv = .live) -> AppModel? {
    validateAndBuildDetailed(snapshot, env: env)?.model
}

/// Validate a snapshot and rebuild the live model. Takes `env` (defaulting to
/// `.live`) the same way `update()` does: id-less snapshot entries mint fresh ids
/// through `env.newId()`, and tilde-expanded cwds resolve against
/// `env.homeDirectory()`. App restore omits `env` (live ambient); a test passes a
/// `makeTestEnv` with a fixed id sequence / home to make restore reproducible.
func validateAndBuildDetailed(_ snapshot: AppModelSnapshot, env: CoreEnv = .live) -> (model: AppModel, paneSnapshots: [PaneId: PaneSnapshot])? {
    // Panes, sessions, groups, tabs, and splits share one UUID namespace. A leaf pane id
    // colliding with any other domain's id is rejected -- sessions / searchState /
    // lastNotificationTime / updatePane are all id-keyed, so a dup would
    // reintroduce exactly the drift this refactor removes.
    var allIds = Set<UUID>()
    // Walk-wide leaf-id uniqueness: a pane id may appear on at most one leaf. This
    // is the lone surviving duplicate check (subsumes the old within-tab and
    // cross-tree pane-id duplicate checks).
    var seenPaneIds = Set<PaneId>()
    // Each leaf's embedded PaneSnapshot, collected during the tree walk and
    // returned for the restore replay path (carries scrollback). With the pane
    // embedded in the leaf, a pane exists iff a leaf owns it -- the old
    // orphan / missing-pane / cross-tree-duplicate checks are structurally
    // impossible and gone.
    var paneSnapshotById: [PaneId: PaneSnapshot] = [:]
    var parsedGroups: [GroupModel] = []
    var allTabIds: [TabId] = []

    // MARK: Snapshot Decode Nondeterministic ID Mints
    //
    // Id-less init-file entries intentionally mint fresh IDs here. Hand-authored
    // snapshots can omit ids as a user-facing convenience; deterministic replay
    // should feed a fully-id'd snapshot through update(), not re-decode id-less
    // entries through this builder.
    for gs in snapshot.groups {
        let groupId: GroupId
        if let idStr = gs.id {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid group UUID: \(idStr)")
                return nil
            }
            groupId = GroupId(rawValue: parsed)
        } else {
            groupId = GroupId(rawValue: env.newId())
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
                tabId = TabId(rawValue: env.newId())
            }
            guard allIds.insert(tabId.rawValue).inserted else {
                print("[init] Duplicate ID: \(tabId)")
                return nil
            }

            // Walk the split tree: builds each leaf's PaneModel from its embedded
            // PaneSnapshot, mints an id for an id-less leaf, records the snapshot,
            // and enforces leaf-id + cross-domain uniqueness.
            guard let rootNode = parseSplitNode(
                ts.rootNode,
                allIds: &allIds,
                seenPaneIds: &seenPaneIds,
                paneSnapshotById: &paneSnapshotById,
                env: env
            ) else {
                return nil
            }

            let leafIds = Set(allPaneIds(rootNode))

            // Validate focusedPaneId
            let focusedPaneId: PaneId
            if let fpStr = ts.focusedPaneId, let fp = UUID(uuidString: fpStr), leafIds.contains(PaneId(rawValue: fp)) {
                focusedPaneId = PaneId(rawValue: fp)
            } else {
                focusedPaneId = firstLeafId(rootNode)
            }

            var tab = TabModel(
                id: tabId,
                customTitle: ts.customTitle,
                focusedPaneId: focusedPaneId,
                rootNode: rootNode,
                color: ts.color
            )
            if let todoSnaps = ts.todos {
                tab.todos = todoSnaps.compactMap { ts in
                    guard let uuid = UUID(uuidString: ts.id) else { return nil }
                    return TodoItem(id: uuid, text: ts.text, isDone: ts.isDone)
                }
            }
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

    // Must have at least one group with at least one tab
    guard !parsedGroups.isEmpty, !allTabIds.isEmpty else {
        print("[init] Must have at least one group with at least one tab")
        return nil
    }

    // Resolve selectedTabId. Default to first group's first tab.
    let selectedTabId: TabId?
    if let selStr = snapshot.selectedTabId, let selId = UUID(uuidString: selStr), allTabIds.contains(TabId(rawValue: selId)) {
        selectedTabId = TabId(rawValue: selId)
    } else {
        selectedTabId = parsedGroups.first?.tabs.first?.id
    }

    return (
        model: AppModel(groups: parsedGroups, selectedTabId: selectedTabId),
        paneSnapshots: paneSnapshotById
    )
}

/// Resolve launch metadata for a pane snapshot: returns (cwd, command) for session
/// creation. `home` is the tilde-expansion base; it defaults to the real ambient
/// home (nil), so the app's session-creation caller and the restore builder both
/// expand against the live home unless a test pins one.
func resolveLaunch(_ paneSnapshot: PaneSnapshot, home: String? = nil) -> (cwd: String?, command: String?) {
    let h = home ?? CoreEnv.live.homeDirectory()
    let cwd = paneSnapshot.cwd.map { expandTilde($0, home: h) }
    return (cwd, paneSnapshot.command)
}

/// Expand a leading `~` to an absolute path. `home` defaults to the real ambient
/// home so production restore expands against the user's *current* home (the whole
/// point of storing `~/`); the injectable `home` lets a test assert machine-
/// independent expansion against a fixed home.
func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {  // core-purity: ambient-seam
    guard path == "~" || path.hasPrefix("~/") else { return path }
    return home + path.dropFirst(1)
}

private func parseSplitNode(
    _ snapshot: SplitNodeSnapshot,
    allIds: inout Set<UUID>,
    seenPaneIds: inout Set<PaneId>,
    paneSnapshotById: inout [PaneId: PaneSnapshot],
    env: CoreEnv
) -> SplitNodeModel? {
    switch snapshot {
    case .leaf(let ps):
        let persistedAgent: AgentSession?
        if let snapshot = ps.agentSession {
            guard let agent = AgentSession(kind: snapshot.kind, sessionId: snapshot.sessionId) else {
                print("[init] Invalid agent session")
                return nil
            }
            persistedAgent = agent
        } else {
            persistedAgent = nil
        }
        // Resolve the pane id: explicit (validated UUID) or freshly minted for an
        // id-less leaf. The mint is the hand-authoring affordance that the old
        // autoPaneIds / autoPaneCursor pre-pass provided; it now happens inline.
        let paneId: PaneId
        if let idStr = ps.id {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid pane UUID in tree: \(idStr)")
                return nil
            }
            paneId = PaneId(rawValue: parsed)
        } else {
            paneId = PaneId(rawValue: env.newId())
        }
        // Leaf-id uniqueness, then cross-domain id-collision guard.
        guard seenPaneIds.insert(paneId).inserted else {
            print("[init] Pane \(paneId) appears on more than one leaf")
            return nil
        }
        guard allIds.insert(paneId.rawValue).inserted else {
            print("[init] Duplicate ID: \(paneId)")
            return nil
        }
        let sessionId = SessionId(rawValue: env.newId())
        guard allIds.insert(sessionId.rawValue).inserted else {
            print("[init] Duplicate ID: \(sessionId)")
            return nil
        }
        // Build the PaneModel from the embedded snapshot; record the snapshot for
        // the returned paneSnapshots map (the restore replay/scrollback source).
        let expandedCwd = resolveLaunch(ps, home: env.homeDirectory()).cwd
        var paneModel = PaneModel(
            id: paneId,
            session: SessionModel(
                id: sessionId,
                title: ps.title ?? "Terminal",
                cwd: expandedCwd,
                lastCommand: ps.command,
                lastAgentSession: persistedAgent
            ),
            theme: ps.theme
        )
        // A hand-edited or corrupt step count is bounded here rather than at
        // projection, so the restored pane responds to the next adjustment
        // exactly as one the user zoomed to that bound would.
        paneModel.fontSizeSteps = clampedPaneFontSizeSteps(ps.fontSizeSteps ?? 0)
        if let todoSnaps = ps.todos {
            paneModel.todos = todoSnaps.compactMap { ts in
                guard let uuid = UUID(uuidString: ts.id) else { return nil }
                return TodoItem(id: uuid, text: ts.text, isDone: ts.isDone)
            }
        }
        paneSnapshotById[paneId] = ps
        return .leaf(paneModel)
    case .split(let idStr, let dirStr, let first, let second, let ratio):
        let splitId: SplitId
        if let idStr {
            guard let parsed = UUID(uuidString: idStr) else {
                print("[init] Invalid split UUID: \(idStr)")
                return nil
            }
            splitId = SplitId(rawValue: parsed)
        } else {
            splitId = SplitId(rawValue: env.newId())
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
            seenPaneIds: &seenPaneIds,
            paneSnapshotById: &paneSnapshotById,
            env: env
        ),
              let secondNode = parseSplitNode(
                  second,
                  allIds: &allIds,
                  seenPaneIds: &seenPaneIds,
                  paneSnapshotById: &paneSnapshotById,
                  env: env
              ) else {
            return nil
        }
        return .split(id: splitId, direction: direction, first: firstNode, second: secondNode, ratio: CGFloat(ratio ?? 0.5))
    }
}
