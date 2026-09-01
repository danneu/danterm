// Core value types for the DanTerm Elm-style application model.
import Foundation
import DanTermProtocol

// MARK: - Core-only Typed IDs

typealias TypedId<Tag> = DanTermProtocol.TypedId<Tag>
typealias TabId = DanTermProtocol.TabId
typealias PaneId = DanTermProtocol.PaneId
typealias GroupId = DanTermProtocol.GroupId
typealias TodoId = DanTermProtocol.TodoId
typealias TodoOwner = DanTermProtocol.TodoOwner

/// Keeps terminal-session identity distinct from its owning pane identity.
enum SessionTag {}
enum SplitTag {}
enum AlertTag {}
/// Separates panel answers from every replaced confirmation transaction.
enum ConfirmationTag {}
/// Separates panel answers from every queued user-visible notice.
enum NoticeTag {}
/// Separates one inline rename session from its successor on the same row.
enum RenameSessionTag {}

/// Identifies one terminal lifetime so late reports cannot target its replacement.
typealias SessionId = TypedId<SessionTag>
typealias SplitId = TypedId<SplitTag>
typealias AlertId = TypedId<AlertTag>
/// Names the exact confirmation transaction a panel answer belongs to.
typealias ConfirmationId = TypedId<ConfirmationTag>
/// Names the exact queued notice a panel answer belongs to.
typealias NoticeId = TypedId<NoticeTag>
/// Names the exact inline rename session an end belongs to.
typealias RenameSessionId = TypedId<RenameSessionTag>

enum AlertKind: Hashable {
    case bell
    case desktopNotification
}

/// Tracks the app-visible child phase without depending on shell integration.
enum SessionProcessPhase: String, Equatable {
    case spawning
    case running
}

/// Identifies one IPC input item until its PTY submission reaches a terminal result.
enum InputSubmissionTag {}

/// Prevents one input submission identity from being confused with another entity ID.
typealias InputSubmissionId = TypedId<InputSubmissionTag>

/// Preserves why PTY delivery failed across the app and IPC boundaries.
enum InputSubmissionFailure: Equatable {
    case bufferLimitExceeded
    case canonicalModeTimeout
    case launchFailed
    case processEnded
    case writeFailed(Int32)
}

/// Restates one PTY submission's exactly-once terminal result in the pure model.
enum InputSubmissionResult: Equatable {
    case delivered
    case rejected(InputSubmissionFailure)
}

/// Makes launch input's pending and terminal states queryable with its owning session.
enum LaunchInputState: Equatable {
    case pending
    case delivered
    case rejected(InputSubmissionFailure)
}

/// Holds a creation reply until the identified session reaches a terminating spawn edge.
struct PendingSessionCreation: Equatable {
    let requestId: UUID
    let result: JSONValue
}

/// One in-flight `pane.input` submission. It names the request that replies
/// once no submission of its own is left, and the pane whose teardown must fail
/// that request early. Storing both here keeps the request->submission and
/// submission->request directions from being able to disagree: the
/// request-to-submissions direction is derived by scanning values, and in-flight
/// counts are single digits.
struct PendingInputSubmission: Equatable {
    let requestId: UUID
    let paneId: PaneId
}

struct AlertModel: Equatable {
    let id: AlertId
    let kind: AlertKind
    let paneId: PaneId
    /// Derived presentation, normalized once when the alert is raised: it is
    /// rendered straight into a one-line label. The body is not -- see
    /// AlertPresentation.swift.
    let title: DisplayLine
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

/// Records which control owns focus while a pane search remains active.
enum SearchFocusOwner: Equatable {
    case terminal
    case field
}

struct SearchModel: Equatable {
    var needle: String = ""
    var status: SearchMatchStatus?   // nil = nothing reported yet
    var focusOwner: SearchFocusOwner = .field
}

// MARK: - Remote Session

struct RemoteSession: Equatable {
    var user: String
    var host: String

    var displayString: String { "\(user)@\(host)" }
}

// MARK: - TODO

struct TodoItem: Equatable, Codable {
    let id: TodoId
    var text: TodoText
    var isDone: Bool

    init(id: TodoId, text: TodoText, isDone: Bool) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

// MARK: - Model

/// A session's one title slot, with the three states it can legally be in.
///
/// Two optionals -- a declared title beside a recovered label -- could also hold
/// "declared and inherited at once", a state the feature forbids and only a
/// remembered assignment kept out. Here it cannot be written. The type also owns
/// the OSC 0/2 transition table and the one reading rule, so no consumer
/// restates either.
///
/// The empty case is deliberately not called `none`: `session?.titleState ==
/// .none` would resolve against `Optional` and compile while meaning something
/// else entirely.
enum SessionTitleState: Equatable {
    /// No program in this session has declared a title, and no checkpoint left
    /// one behind. The cwd fallback is resolved at display, never stored here.
    case undeclared
    /// The title the pane's previous session had when the checkpoint this
    /// session was restored from was written. It stands in for a declared title
    /// until this session declares one of its own. A recovery memo like
    /// `lastCommand`: restore is the only writer, because restore is the only
    /// thing that swaps a pane's session.
    case inherited(String)
    /// The title a program in this pane declared, and nothing else. DanTerm
    /// never manufactures one to put here.
    case declared(String)

    /// Lifts the optional title a restore recovered from a checkpoint.
    init(inherited label: String?) {
        self = label.map(Self.inherited) ?? .undeclared
    }

    /// Lifts the optional title a launch asked for. A launch title is a
    /// declaration: it is exactly as clearable as one a program sends.
    init(declared title: String?) {
        self = title.map(Self.declared) ?? .undeclared
    }

    /// What a pane calls itself before the cwd is considered, and what a
    /// checkpoint stores. One definition, so the tab a user reads and the
    /// checkpoint written beside it cannot name the pane differently.
    var claimed: String? {
        switch self {
        case .undeclared: return nil
        case .inherited(let label): return label
        case .declared(let title): return title
        }
    }

    /// The title a program declared, and never an inherited label. IPC reports
    /// this one, so `ls` and `pane info` speak only for programs.
    var declared: String? {
        guard case .declared(let title) = self else { return nil }
        return title
    }

    /// Applies one OSC 0/2 payload. Two rules in one slot, because the OSC
    /// itself has two meanings: a non-empty payload is a claim, an empty one is
    /// a clear. Only a claim retires an inherited label -- the clear a fresh
    /// shell sends at its first prompt would otherwise erase a restored pane's
    /// name within a second. Once retired, the label cannot come back, because
    /// nothing but a restore can write it.
    mutating func applyDeclaration(_ payload: String) {
        if payload.isEmpty {
            if case .declared = self { self = .undeclared }
        } else {
            self = .declared(payload)
        }
    }
}

/// Owns every terminal-reported fact and recovery memo whose lifetime is
/// bounded by this identified terminal session.
struct SessionModel: Equatable {
    let id: SessionId
    var processPhase: SessionProcessPhase = .spawning
    var titleState: SessionTitleState = .undeclared
    var cwd: String?
    var progress: ProgressState?
    var integration: IntegrationLatch = .neverReported
    var command: CommandLifecycle = .idle
    var connection: ConnectionLifecycle = .local
    var agent: AgentLifecycle = .none
    var lastCommand: String?
    var lastAgentSession: AgentSession?
    var launchInput: LaunchInputState?
    /// Counts the wait generations minted for this session. It is per session
    /// because retraction is too: input to one pane can only name that pane's
    /// wait, so generations never have to be unique across panes.
    private(set) var waitGenerationCounter: UInt64 = 0

    /// Hands out the next never-before-used wait generation for this session.
    mutating func mintWaitGeneration() -> AgentWaitGeneration {
        waitGenerationCounter &+= 1
        return AgentWaitGeneration(rawValue: waitGenerationCounter)
    }
}

/// Groups state that exists only while its owning pane leaf is alive and never
/// participates in snapshots or light-checkpoint projections.
struct PaneLiveState: Equatable {
    var search: SearchModel? = nil
    var lastNotificationTime: [AlertKind: Date] = [:]
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
    /// The grid this pane runs at when a client has claimed its size. Absent,
    /// the grid follows the pane's slot rectangle; present, it is exactly this
    /// grid regardless of every rectangle input. Durable until an explicit
    /// clear -- no layout event writes it.
    var gridOverride: PaneGridOverride? = nil
    var todos: [TodoItem] = []
    var live = PaneLiveState()

    /// The command this pane is running, if any. The single place that turns the
    /// session's command state into the optional every close-impact and
    /// confirmation rollup wants, so the two cannot disagree about what
    /// "running" means.
    var runningCommand: String? {
        guard case .running(let command) = session?.command else { return nil }
        return command
    }
}

indirect enum SplitNodeModel: Equatable {
    // The leaf owns its pane's full content. A pane exists iff a tree leaf owns
    // it (no separate `AppModel.panes` dict), so the old dual-write drift between
    // dict and tree is structurally impossible. `PaneModel.id` is a `let`, so
    // identity travels with the payload.
    case leaf(PaneModel)
    case split(id: SplitId, direction: SplitDirection, first: SplitNodeModel, second: SplitNodeModel, ratio: SplitRatio)

    enum Side: Equatable {
        case first  // left or top
        case second // right or bottom
    }
}

/// Owns a tab's pane shape, focus, and zoom as one value so those facts cannot drift apart.
struct PaneTree: Equatable {
    private(set) var root: SplitNodeModel
    private(set) var focusedPaneId: PaneId
    private(set) var isZoomed: Bool

    /// Repairs external or persisted inputs while constructing a valid pane tree.
    init(root: SplitNodeModel, focusedPaneId: PaneId? = nil, isZoomed: Bool = false) {
        self.root = root
        self.focusedPaneId = focusedPaneId.flatMap { containsPane(root, $0) ? $0 : nil }
            ?? firstLeafId(root)
        if case .split = root {
            self.isZoomed = isZoomed
        } else {
            self.isZoomed = false
        }
    }

    /// The focused pane is non-optional because construction and every mutator preserve it.
    var focusedPane: PaneModel {
        paneInNode(root, id: focusedPaneId)!
    }

    /// Rebuilds one pane payload without changing shape, focus, or zoom.
    @discardableResult
    mutating func updatePane<Result>(
        where predicate: (PaneModel) -> Bool,
        _ body: (inout PaneModel) -> Result
    ) -> Result? {
        guard let mutation = updatePaneInNode(root, where: predicate, body) else { return nil }
        root = mutation.node
        return mutation.result
    }

    /// Rebuilds one identified pane payload without changing shape, focus, or zoom.
    @discardableResult
    mutating func updatePane(_ paneId: PaneId, _ body: (inout PaneModel) -> Void) -> Bool {
        guard let newRoot = updatePaneInNode(root, id: paneId, body) else { return false }
        root = newRoot
        return true
    }

    /// Splits one leaf and applies the caller's foreground-focus policy atomically.
    @discardableResult
    mutating func split(
        paneId: PaneId,
        direction: SplitDirection,
        newPane: PaneModel,
        newSplitId: SplitId,
        focusNewPane: Bool
    ) -> Bool {
        guard let newRoot = splitLeaf(
            root, paneId: paneId, direction: direction, newPane: newPane,
            newSplitId: newSplitId
        ) else { return false }
        root = newRoot
        if focusNewPane { focusedPaneId = newPane.id }
        isZoomed = false
        return true
    }

    /// Keeps pane removal states exhaustive so an empty result cannot expose an invalid tree.
    enum RemovalOutcome {
        case notFound
        case emptied(PaneModel)
        case surviving(tree: PaneTree, removed: PaneModel)
    }

    /// Returns the result of removing one pane without changing the input tree.
    func remove(_ paneId: PaneId) -> RemovalOutcome {
        let focusMoved = focusedPaneId == paneId
        switch removeLeaf(root, paneId: paneId) {
        case .notFound:
            return .notFound
        case .emptied(let removedPane):
            return .emptied(removedPane)
        case .surviving(let newRoot, let nextFocus, let removedPane):
            return .surviving(
                tree: PaneTree(
                    root: newRoot,
                    focusedPaneId: focusMoved ? nextFocus : focusedPaneId,
                    isZoomed: false
                ),
                removed: removedPane
            )
        }
    }

    /// Swaps two pane positions, focuses the moved source, and clears zoom.
    @discardableResult
    mutating func swap(source: PaneId, target: PaneId) -> Bool {
        guard let newRoot = swapLeaves(root, source, target) else { return false }
        root = newRoot
        focusedPaneId = source
        isZoomed = false
        return true
    }

    /// Moves one pane beside another, focuses it, and clears zoom.
    @discardableResult
    mutating func move(
        source: PaneId,
        target: PaneId,
        direction: SplitDirection,
        insertFirst: Bool,
        newSplitId: SplitId
    ) -> Bool {
        guard let newRoot = moveLeaf(
            root, source: source, target: target, direction: direction,
            insertFirst: insertFirst, newSplitId: newSplitId
        ) else { return false }
        root = newRoot
        focusedPaneId = source
        isZoomed = false
        return true
    }

    /// Adds a pane as the trailing child, focuses it, and clears zoom.
    mutating func adopt(_ pane: PaneModel, splitId: SplitId) {
        root = .split(
            id: splitId, direction: .horizontal,
            first: root, second: .leaf(pane), ratio: 0.5
        )
        focusedPaneId = pane.id
        isZoomed = false
    }

    /// Changes focus only when the pane belongs to this tree and preserves zoom.
    @discardableResult
    mutating func focus(_ paneId: PaneId) -> Bool {
        guard paneInNode(root, id: paneId) != nil else { return false }
        let changed = focusedPaneId != paneId
        focusedPaneId = paneId
        return changed
    }

    /// The one definition of which pane a tab's zoom is on. Every path that
    /// asks "is this pane zoomed" -- the reducer, the toolbar projection, the
    /// container reconcile, and the scripted replies -- resolves against this,
    /// so they cannot disagree about where a zoom landed.
    var zoomedPaneId: PaneId? {
        isZoomed ? focusedPaneId : nil
    }

    /// Clears zoom without changing focus.
    mutating func unzoom() {
        isZoomed = false
    }

    /// Zooms one named pane of a split tree. Zoom hides every sibling, so the
    /// zoomed pane has to hold the tab's focus; moving focus is part of the
    /// zoom rather than a separate step a caller could forget.
    @discardableResult
    mutating func zoom(_ paneId: PaneId) -> Bool {
        guard case .split = root, paneInNode(root, id: paneId) != nil else { return false }
        focusedPaneId = paneId
        isZoomed = true
        return true
    }

    /// Rebuilds split ratios without changing shape, focus, or zoom.
    mutating func updateRatio(splitId: SplitId, ratio: SplitRatio) {
        root = setRatio(root, splitId: splitId, ratio: ratio)
    }
}

enum TabColor: String, Codable, CaseIterable, Equatable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
}

struct TabModel: Equatable {
    let id: TabId
    var customTitle: String?
    var paneTree: PaneTree
    var color: TabColor? = nil
    var todos: [TodoItem] = []
    /// When this tab last became the selection, on `AppModel.focusClock`'s
    /// scale; 0 means it has never been selected in this run. Ephemeral, never
    /// serialized, and deliberately not an init parameter: only
    /// `reconcileTabState` writes it, so recency cannot be minted anywhere
    /// else. Owning recency here is what makes it die with the tab.
    var focusStamp: UInt64 = 0

    init(
        id: TabId,
        customTitle: String? = nil,
        paneTree: PaneTree,
        color: TabColor? = nil,
        todos: [TodoItem] = []
    ) {
        self.id = id
        self.customTitle = customTitle
        self.paneTree = paneTree
        self.color = color
        self.todos = todos
    }
}

struct GroupModel: Equatable {
    let id: GroupId
    var name: String
    var isCollapsed: Bool = false
    var tabs: [TabModel] = []
}

/// Form state for the settings window: the config the panel would commit, plus
/// the one piece of form state a config cannot carry. Text-entry values remain
/// raw until save; picker values retain the exact catalog name that was
/// selected.
/// Names the reusable Settings window section selected in its toolbar.
enum PreferencesSection: Equatable {
    case general
    case keybindings
}

/// Holds the complete candidate config and transient state for one Settings session.
/// `fontSizeText` stays separate because a half-typed number must survive until save.
struct PreferencesDraft: Equatable {
    /// The settings a save would commit, with every field already edited in
    /// place -- except `fontSize`, which `fontSizeText` owns until save.
    var config: DanTermConfig
    /// Raw font-size entry; blank means no `fontSize` key, so the built-in default applies.
    var fontSizeText: String
    /// Presentation state stays in the model so full AppKit rebuilds do not lose it.
    var section: PreferencesSection
    var keybindingSearchText: String
    /// The browser selection survives table rebuilds and remains separate from its sheet.
    var selectedKeybindingAction: KeybindingActionID?
    /// One transactional editor candidate, or nil while the browser has no sheet.
    var keybindingEditor: KeybindingEditorDraft?
    /// True while Reset All waits for explicit confirmation in Settings.
    var isResetAllKeybindingsConfirmationPresented: Bool

    /// Seeds the form from committed settings, rendering the saved size as the
    /// text the field shows. Used both on open and on an external reload, so the
    /// two paths cannot drift.
    init(seededFrom config: DanTermConfig) {
        self.config = config
        self.fontSizeText = config.fontSize.map(configFontSizeText) ?? ""
        self.section = .general
        self.keybindingSearchText = ""
        self.selectedKeybindingAction = nil
        self.keybindingEditor = nil
        self.isResetAllKeybindingsConfirmationPresented = false
    }
}

/// Identifies which shortcut row owns the active sheet recorder.
enum KeybindingEditorRecordingTarget: Equatable {
    case adding
    case replacing(Int)
}

/// Owns one sheet's complete candidate and the transient state needed to edit it.
struct KeybindingEditorDraft: Equatable {
    let actionID: KeybindingActionID
    var candidate: KeybindingOverrides
    var retainedChords: [KeyChord]
    var recordingTarget: KeybindingEditorRecordingTarget?
    var diagnostic: KeybindingDiagnostic?
    let removedHeldMRUShortcutCount: Int
}


// MRU tab switcher state. Ephemeral — never serialized into AppModelSnapshot.
// No recency order is stored: `tabsByRecency` derives one from the tabs' focus
// stamps when a cycle starts, and the cycle then walks that frozen copy, so
// repeated cmd-shift-i taps go back through history instead of toggling between
// two tabs. Nothing that happens during the cycle rewrites frozenOrder.
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

/// Freezes one close target and exactly the request-time facts valid for it.
enum CloseTarget: Equatable {
    case pane(PaneId, quitAuthorized: Bool)
    case otherPanes(retaining: PaneId)
    case tab(TabId, title: DisplayLine, quitAuthorized: Bool)
    case tabs([TabId], quitAuthorized: Bool)
}

/// Freezes the cost of a close by pane so later work cannot hide behind equal command text.
struct CloseImpact: Equatable {
    /// Couples one affected pane with the command named for it, if any.
    struct Pane: Equatable {
        let paneId: PaneId
        let runningCommand: String?
    }

    let panes: [Pane]
    let uncompletedTodoCount: Int

    var hasWarning: Bool {
        uncompletedTodoCount > 0 || panes.contains { $0.runningCommand != nil }
    }
}

/// Carries pure alert copy and the full command list the close would end.
struct CloseConfirmationCopy: Equatable {
    let informativeText: String
    /// One entry per running command among the affected panes, in pane order,
    /// flattened by the display boundary but never shortened by length. The view
    /// decides how much of it to draw; the model keeps all of it so a copy can
    /// hand over what the user was asked to decide about.
    let commands: [DisplayLine]
}

/// Freezes the tabs and destination named by a delete-group confirmation.
struct DeleteGroupConfirmation: Equatable {
    let groupName: DisplayLine
    let tabIds: [TabId]
    let destinationGroupId: GroupId
    let destinationGroupName: DisplayLine
}

/// Carries exactly the data required by one kind of pending confirmation.
enum ConfirmationKind: Equatable {
    case quit
    case close(target: CloseTarget, impact: CloseImpact)
    case deleteGroup(groupId: GroupId, confirmation: DeleteGroupConfirmation)
}

/// Keeps one confirmation atomic across model changes while its UI is open.
/// This state is ephemeral and never serialized into AppModelSnapshot.
struct PendingConfirmation: Equatable {
    let id: ConfirmationId
    let kind: ConfirmationKind
}

/// The copy and launch semantics frozen when a user-visible notice is reported.
enum NoticeSubject: Equatable {
    case message(title: DisplayLine, message: String)
    case restorePrompt(message: String)
}

/// One queued notice transaction. The id makes stale panel answers inert.
struct PendingNotice: Equatable {
    let id: NoticeId
    let subject: NoticeSubject
}

let minSidebarWidth: CGFloat = 200
let maxSidebarWidth: CGFloat = 300

/// Owns the sidebar facts that must survive collapse, restore, and view rebuilds.
struct SidebarPresentation: Equatable {
    var isCollapsed: Bool
    let width: CGFloat

    init(isCollapsed: Bool = false, width: CGFloat = minSidebarWidth) {
        self.isCollapsed = isCollapsed
        self.width = width.isFinite
            ? min(max(width, minSidebarWidth), maxSidebarWidth)
            : minSidebarWidth
    }
}

struct AppModel: Equatable {
    var groups: [GroupModel]
    var selectedTabId: TabId?
    var sidebar = SidebarPresentation()
    var isAppActive: Bool = true  // ephemeral -- excluded from snapshots; gates focused-pane notification suppression
    var alerts: [AlertModel] = []  // newest first, capped at 100
    var showAllAlerts: Bool = false  // ephemeral — excluded from snapshots
    var alertsPopoverOpen: Bool = false  // ephemeral -- projected alerts-popover existence
    var themeBrowserOpen: Bool = false  // ephemeral -- projected theme-browser existence
    var config: DanTermConfig = .default  // ephemeral — loaded from disk, not snapshots
    // The canonical installed family `config.fontFamily` resolved to, or nil for the
    // system monospace font. Ephemeral: re-derived from disk on every config apply,
    // never snapshotted. The core cannot compute it (that is a CoreText question), so
    // the impure caller injects it alongside the config it came from -- which is also
    // why "the configured font is missing" is derived from the pair rather than stored:
    // a second copy of the requested name could drift from `config`.
    var resolvedFontFamily: String? = nil
    // What this instance's tailnet listener is doing, authored by the IPC server and
    // republished on every transition. Ephemeral, and never derived here: the core
    // cannot resolve an address or bind a socket, so it copies the server's verdict
    // out to the preferences pane and the `tailnet.status` reply unchanged. The
    // default is the truth for a runtime with no IPC server at all.
    var tailnetStatus: DanTermTailnetStatus = .disabled(reason: "no tailnet listener was started")
    var preferencesDraft: PreferencesDraft? = nil  // ephemeral — non-nil while prefs panel is open
    // The font families installed on this machine, injected when the preferences
    // panel opens and dropped when it closes. Ephemeral and panel-scoped: the
    // syntax-only core never queries CoreText and cannot enumerate them, and the
    // catalog is deliberately a snapshot per open rather than a live view.
    var installedFontFamilies: [String] = []
    // Bundled theme names injected when Settings opens. Ephemeral and
    // panel-scoped for the same reason as `installedFontFamilies`.
    var availableThemeNames: [String] = []
    var todoPopover: TodoOwner? = nil  // ephemeral -- which TODO popover (pane or tab) is open
    var sidebarRename: SidebarRenameSession? = nil  // ephemeral -- one projected request to begin inline editing

    /// Which row the pending inline rename edits, for readers that do not care
    /// which session it is (the row-op guard, the `ls` encoder).
    var sidebarRenameTarget: RenameTarget? { sidebarRename?.target }
    // The stamp the most recently focused tab carries, incremented each time the
    // selection lands somewhere new. Ephemeral, and the only writer is
    // reconcileTabState. It is a clock, not an ordering: no live tab set is
    // stored anywhere, so there is nothing here that can drift from the tab tree.
    var focusClock: UInt64 = 0
    var mruCycle: MruCycleState? = nil  // ephemeral — non-nil while cmd-shift held
    var jumpMode: JumpModeState? = nil  // ephemeral — non-nil while tab jump mode is active
    var pendingConfirmation: PendingConfirmation? = nil  // ephemeral -- non-nil while the confirmation panel is active
    var noticeQueue: [PendingNotice] = []  // ephemeral -- oldest first; projected one at a time
    var pendingSessionCreations: [SessionId: PendingSessionCreation] = [:]
    var pendingInputSubmissions: [InputSubmissionId: PendingInputSubmission] = [:]

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
                if let found = paneInNode(tab.paneTree.root, id: id) { return found }
            }
        }
        return nil
    }

    /// Finds the pane that owns a live session, so inbound session identity can
    /// never resolve independently from the pane tree that owns its state.
    func pane(owning sessionId: SessionId) -> PaneModel? {
        for group in groups {
            for tab in group.tabs {
                if let found = paneInNode(tab.paneTree.root, where: { $0.session?.id == sessionId }) {
                    return found
                }
            }
        }
        return nil
    }

    /// All pane ids, in tab then tree order. Replaces the old `panes.keys`.
    var allPaneIds: [PaneId] {
        groups.flatMap { group in
            group.tabs.flatMap { paneIdsInNode($0.paneTree.root) }
        }
    }

    /// Mutate the leaf-owned pane with the given id in place, rebuilding only the
    /// spine down to that leaf (like `setRatio`). No-op if no leaf owns the id.
    /// Stops at the first match -- pane ids are unique across the whole model.
    mutating func updatePane(_ id: PaneId, _ body: (inout PaneModel) -> Void) {
        for gi in groups.indices {
            for ti in groups[gi].tabs.indices {
                if groups[gi].tabs[ti].paneTree.updatePane(id, body) {
                    return
                }
            }
        }
    }

    /// Mutates a tab without exposing group and tab array locations to callers.
    mutating func updateTab(_ id: TabId, _ body: (inout TabModel) -> Void) {
        guard let (groupIndex, tabIndex) = tabLocation(id, in: self) else { return }
        body(&groups[groupIndex].tabs[tabIndex])
    }

    /// Reads the todo collection for either supported owner kind.
    func todos(for owner: TodoOwner) -> [TodoItem]? {
        switch owner {
        case .pane(let paneId): return pane(paneId)?.todos
        case .tab(let tabId): return tabById(tabId, in: self)?.todos
        }
    }

    /// Mutates the todo collection only when its owner still exists.
    mutating func updateTodos(for owner: TodoOwner, _ body: (inout [TodoItem]) -> Void) {
        switch owner {
        case .pane(let paneId):
            guard pane(paneId) != nil else { return }
            updatePane(paneId) { body(&$0.todos) }
        case .tab(let tabId):
            guard tabById(tabId, in: self) != nil else { return }
            updateTab(tabId) { body(&$0.todos) }
        }
    }

    /// Mutates a session through its owning leaf and returns the identity and
    /// change result produced by that same tree walk.
    @discardableResult
    mutating func updateSession(
        _ id: SessionId,
        _ body: (inout SessionModel) -> Void
    ) -> (paneId: PaneId, didChange: Bool)? {
        for groupIndex in groups.indices {
            for tabIndex in groups[groupIndex].tabs.indices {
                guard let result = groups[groupIndex].tabs[tabIndex].paneTree.updatePane(
                    where: { $0.session?.id == id },
                    { pane -> (paneId: PaneId, didChange: Bool) in
                        guard var session = pane.session else {
                            return (pane.id, false)
                        }
                        let previous = session
                        body(&session)
                        pane.session = session
                        return (pane.id, session != previous)
                    }
                ) else { continue }
                return result
            }
        }
        return nil
    }
}

// MARK: - View-Owned State Inputs

/// Tracks whether an inline-editing sidebar row is renaming a tab or a group.
/// Kept in the pure layer so the sidebar rename guard and completion policy share
/// one typed vocabulary with the runtime-owned view session.
enum RenameTarget: Equatable {
    case tab(TabId)
    case group(GroupId)
}

/// One inline sidebar rename session: the row it edits, and which edit of that
/// row it is.
///
/// The identity exists because the view tears a session down long before its
/// end reaches the model -- a recycled cell buffers the end, a click-away
/// delivers it a turn later -- and two successive edits of one row are
/// otherwise indistinguishable. An end names the session, so a late end can
/// neither retract a successor nor block a second rename of the same row.
struct SidebarRenameSession: Equatable {
    var id: RenameSessionId
    var target: RenameTarget
}

// MARK: - Init Snapshot Types

// Current on-disk/wire format version. v3 keeps one pane cwd, stores the launch
// command directly on the pane, and rejects invalid persisted agent sessions.
let appInitFileVersion = 3

struct AppInitFile: Codable {
    let version: Int
    let model: AppModelSnapshot
}

struct AppModelSnapshot: Codable, Equatable, Sendable {
    var groups: [GroupSnapshot]
    let selectedTabId: TabId?
    let sidebar: SidebarSnapshot?

    private enum CodingKeys: String, CodingKey { case groups, selectedTabId, sidebar }

    init(groups: [GroupSnapshot], selectedTabId: TabId?, sidebar: SidebarSnapshot? = nil) {
        self.groups = groups
        self.selectedTabId = selectedTabId
        self.sidebar = sidebar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decode([GroupSnapshot].self, forKey: .groups)
        selectedTabId = try container.decodeRepairableId(TabId.self, forKey: .selectedTabId)
        sidebar = try container.decodeIfPresent(SidebarSnapshot.self, forKey: .sidebar)
    }
}

extension AppModelSnapshot {
    /// The one restorability rule every persistence surface shares: the loader's build
    /// guard and every checkpoint writer refuse by this predicate, so no checkpoint
    /// write can replace a restorable session on disk with one the next launch refuses.
    var isRestorable: Bool {
        groups.contains { !$0.tabs.isEmpty }
    }
}

/// Carries sidebar presentation across the JSON boundary without exposing CGFloat.
struct SidebarSnapshot: Codable, Equatable, Sendable {
    let isCollapsed: Bool
    let width: Double
}

struct GroupSnapshot: Codable, Equatable, Sendable {
    let id: GroupId?
    let name: String
    let isCollapsed: Bool?
    var tabs: [TabSnapshot]
}

struct TabSnapshot: Codable, Equatable, Sendable {
    let id: TabId?
    let customTitle: String?
    let focusedPaneId: PaneId?
    var rootNode: SplitNodeSnapshot
    let color: TabColor?
    var todos: [TodoSnapshot]? = nil  // nil for backward compat

    private enum CodingKeys: String, CodingKey {
        case id, customTitle, focusedPaneId, rootNode, color, todos
    }

    init(
        id: TabId?,
        customTitle: String?,
        focusedPaneId: PaneId?,
        rootNode: SplitNodeSnapshot,
        color: TabColor?,
        todos: [TodoSnapshot]? = nil
    ) {
        self.id = id
        self.customTitle = customTitle
        self.focusedPaneId = focusedPaneId
        self.rootNode = rootNode
        self.color = color
        self.todos = todos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(TabId.self, forKey: .id)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        focusedPaneId = try container.decodeRepairableId(PaneId.self, forKey: .focusedPaneId)
        rootNode = try container.decode(SplitNodeSnapshot.self, forKey: .rootNode)
        color = try container.decodeIfPresent(TabColor.self, forKey: .color)
        todos = try container.decodeLossyTodoSnapshotsIfPresent(forKey: .todos)
    }
}

/// Declares the stable node discriminator shared by snapshots and IPC entities.
enum SplitNodeType: String, Codable {
    case leaf
    case split
}

indirect enum SplitNodeSnapshot: Codable, Equatable, Sendable {
    // A leaf owns its full PaneSnapshot inline.
    case leaf(PaneSnapshot)
    case split(id: SplitId?, direction: SplitDirection, first: SplitNodeSnapshot, second: SplitNodeSnapshot, ratio: Double?)

    enum CodingKeys: String, CodingKey {
        case type, pane, id, direction, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SplitNodeType.self, forKey: .type)
        switch type {
        case .leaf:
            // `pane` is optional so a hand-authored snapshot can write a bare
            // `{ "type": "leaf" }` (id and all fields minted/defaulted on decode) --
            // preserving the v1 omitted-id authoring affordance.
            let pane = try container.decodeIfPresent(PaneSnapshot.self, forKey: .pane)
            self = .leaf(pane ?? PaneSnapshot(id: nil, title: nil, cwd: nil, command: nil, scrollback: nil, theme: nil))
        case .split:
            let id = try container.decodeIfPresent(SplitId.self, forKey: .id)
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let first = try container.decode(SplitNodeSnapshot.self, forKey: .first)
            let second = try container.decode(SplitNodeSnapshot.self, forKey: .second)
            let ratio = try container.decodeIfPresent(Double.self, forKey: .ratio)
            self = .split(id: id, direction: direction, first: first, second: second, ratio: ratio)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try container.encode(SplitNodeType.leaf, forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let id, let direction, let first, let second, let ratio):
            try container.encode(SplitNodeType.split, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(direction, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
            try container.encodeIfPresent(ratio, forKey: .ratio)
        }
    }
}

extension AppModelSnapshot {
    /// Copies the complete snapshot hierarchy while replacing only pane leaves.
    func mapPaneSnapshots(_ transform: (PaneSnapshot) -> PaneSnapshot) -> AppModelSnapshot {
        var snapshot = self
        snapshot.groups = groups.map { group in
            var group = group
            group.tabs = group.tabs.map { tab in
                var tab = tab
                tab.rootNode = tab.rootNode.mapPaneSnapshots(transform)
                return tab
            }
            return group
        }
        return snapshot
    }
}

private extension SplitNodeSnapshot {
    func mapPaneSnapshots(_ transform: (PaneSnapshot) -> PaneSnapshot) -> SplitNodeSnapshot {
        switch self {
        case .leaf(let pane):
            return .leaf(transform(pane))
        case .split(let id, let direction, let first, let second, let ratio):
            return .split(
                id: id,
                direction: direction,
                first: first.mapPaneSnapshots(transform),
                second: second.mapPaneSnapshots(transform),
                ratio: ratio
            )
        }
    }
}

struct TodoSnapshot: Codable, Equatable, Sendable {
    let id: TodoId
    let text: TodoText
    let isDone: Bool
}

/// Strictly decoded checkpoint DTO validated through `AgentSession` during load.
struct AgentSessionSnapshot: Codable, Equatable, Sendable {
    let kind: String
    let sessionId: String

    init(kind: String, sessionId: String) {
        self.kind = kind
        self.sessionId = sessionId
    }
}

struct PaneSnapshot: Codable, Equatable, Sendable {
    let id: PaneId?
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
    // Absent for a pane whose grid follows its slot.
    var gridOverride: PaneGridOverrideSnapshot? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, command, scrollback, theme, todos, agentSession, fontSizeSteps, gridOverride
    }

    init(
        id: PaneId?,
        title: String?,
        cwd: String?,
        command: String?,
        scrollback: String?,
        theme: String?,
        todos: [TodoSnapshot]? = nil,
        agentSession: AgentSessionSnapshot? = nil,
        fontSizeSteps: Int? = nil,
        gridOverride: PaneGridOverrideSnapshot? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.command = command
        self.scrollback = scrollback
        self.theme = theme
        self.todos = todos
        self.agentSession = agentSession
        self.fontSizeSteps = fontSizeSteps
        self.gridOverride = gridOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(PaneId.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        todos = try container.decodeLossyTodoSnapshotsIfPresent(forKey: .todos)
        agentSession = try container.decodeIfPresent(AgentSessionSnapshot.self, forKey: .agentSession)
        fontSizeSteps = try container.decodeIfPresent(Int.self, forKey: .fontSizeSteps)
        gridOverride = try container.decodeIfPresent(PaneGridOverrideSnapshot.self, forKey: .gridOverride)
    }
}

/// Keeps malformed todo identity local while decoding every other field strictly.
private struct LossyTodoSnapshotWireValue: Decodable {
    let id: TodoId?
    let text: TodoText?
    let isDone: Bool

    private enum CodingKeys: String, CodingKey { case id, text, isDone }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            id = try container.decode(TodoId.self, forKey: .id)
        } catch DecodingError.dataCorrupted {
            id = nil
        }
        do {
            text = try container.decode(TodoText.self, forKey: .text)
        } catch DecodingError.dataCorrupted {
            text = nil
        }
        isDone = try container.decode(Bool.self, forKey: .isDone)
    }
}

private extension KeyedDecodingContainer {
    func decodeRepairableId<ID: Decodable>(
        _ type: ID.Type,
        forKey key: Key
    ) throws -> ID? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch DecodingError.dataCorrupted {
            return nil
        }
    }

    func decodeLossyTodoSnapshotsIfPresent(forKey key: Key) throws -> [TodoSnapshot]? {
        try decodeIfPresent([LossyTodoSnapshotWireValue].self, forKey: key)?.compactMap { value in
            guard let id = value.id, let text = value.text else { return nil }
            return TodoSnapshot(id: id, text: text, isDone: value.isDone)
        }
    }
}

/// Strictly decoded grid DTO validated through `PaneGridOverride` during load,
/// so an out-of-range persisted grid restores as no override at all.
struct PaneGridOverrideSnapshot: Codable, Equatable, Sendable {
    let columns: Int
    let rows: Int
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
    // The shared restorability rule, stated once on the snapshot type (the checkpoint
    // writers refuse by the same predicate). Guarding the input here is equivalent to
    // guarding the parsed result: the loop below appends one group per snapshot group
    // and one tab per snapshot tab, or fails the whole load.
    guard snapshot.isRestorable else {
        print("[init] Must have at least one group with at least one tab")
        return nil
    }

    // Panes, sessions, groups, tabs, and splits share one UUID namespace. A leaf pane id
    // colliding with any other domain's id is rejected -- session lookup and
    // updatePane are id-keyed, so a duplicate would reintroduce exactly the
    // drift this refactor removes.
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
        if let persistedId = gs.id {
            groupId = persistedId
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
            if let persistedId = ts.id {
                tabId = persistedId
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

            // Validate focusedPaneId
            let focusedPaneId: PaneId
            if let persistedId = ts.focusedPaneId, containsPane(rootNode, persistedId) {
                focusedPaneId = persistedId
            } else {
                focusedPaneId = firstLeafId(rootNode)
            }

            var tab = TabModel(
                id: tabId,
                customTitle: ts.customTitle,
                paneTree: PaneTree(root: rootNode, focusedPaneId: focusedPaneId),
                color: ts.color
            )
            if let todoSnaps = ts.todos {
                tab.todos = todoSnaps.map { snapshot in
                    TodoItem(id: snapshot.id, text: snapshot.text, isDone: snapshot.isDone)
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

    // Resolve selectedTabId. Default to first group's first tab.
    let selectedTabId: TabId?
    if let persistedId = snapshot.selectedTabId, allTabIds.contains(persistedId) {
        selectedTabId = persistedId
    } else {
        selectedTabId = parsedGroups.first?.tabs.first?.id
    }

    // Restore does not pass through update(), so it normalizes the selection's
    // visibility itself: the app never opens with the selected tab hidden
    // inside a group that was saved collapsed.
    let sidebar = snapshot.sidebar.map {
        SidebarPresentation(isCollapsed: $0.isCollapsed, width: CGFloat($0.width))
    } ?? SidebarPresentation()
    var model = AppModel(groups: parsedGroups, selectedTabId: selectedTabId, sidebar: sidebar)
    expandGroupHoldingSelection(&model)

    return (model: model, paneSnapshots: paneSnapshotById)
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
        let persistedAgent = ps.agentSession.flatMap {
            AgentSession(kind: $0.kind, sessionId: $0.sessionId)
        }
        // Resolve the pane id: explicit (validated UUID) or freshly minted for an
        // id-less leaf. The mint is the hand-authoring affordance that the old
        // autoPaneIds / autoPaneCursor pre-pass provided; it now happens inline.
        let paneId: PaneId
        if let persistedId = ps.id {
            paneId = persistedId
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
                titleState: SessionTitleState(inherited: ps.title),
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
        // A corrupt or hand-edited grid yields no override rather than a
        // clamped one: the pane then launches at its slot-derived size, which
        // is a size some client could have asked for.
        paneModel.gridOverride = ps.gridOverride.flatMap {
            PaneGridOverride(columns: $0.columns, rows: $0.rows)
        }
        if let todoSnaps = ps.todos {
            paneModel.todos = todoSnaps.map { snapshot in
                TodoItem(id: snapshot.id, text: snapshot.text, isDone: snapshot.isDone)
            }
        }
        paneSnapshotById[paneId] = ps
        return .leaf(paneModel)
    case .split(let persistedId, let direction, let first, let second, let ratio):
        let splitId: SplitId
        if let persistedId {
            splitId = persistedId
        } else {
            splitId = SplitId(rawValue: env.newId())
        }
        guard allIds.insert(splitId.rawValue).inserted else {
            print("[init] Duplicate ID: \(splitId)")
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
        let admittedRatio = ratio.flatMap { SplitRatio(CGFloat($0)) } ?? 0.5
        return .split(id: splitId, direction: direction, first: firstNode, second: secondNode, ratio: admittedRatio)
    }
}
