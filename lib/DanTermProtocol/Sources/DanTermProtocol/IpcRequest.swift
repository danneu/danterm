// The exhaustive typed request catalog shared by the CLI and app daemon.
import Foundation

/// Forces every IPC method to state all policies that consumers derive from the catalog.
private struct IpcRequestMethodTraits {
    let terminatesInstance: Bool
    let requiresLocalCaller: Bool
    let producesAuditRecord: Bool
}

/// Carries the authenticated caller facts with each request through pure dispatch.
public enum IpcCallerIdentity: Equatable, Sendable {
    /// Identifies a caller connected through the Mac-local control socket.
    case local
    /// Identifies an admitted tailnet peer without coupling protocol to its resolver.
    case remote(nodeId: String, user: String, machineName: String)
}

/// Names every client-to-daemon request method admitted by DanTerm.
public enum IpcRequestMethod: String, CaseIterable, Sendable {
    /// Asks the instance to prove it is still servicing requests. Takes no target:
    /// the answer is about the connection the request arrived on. It is an ordinary
    /// method on purpose -- a reply that came from anywhere but dispatch would say
    /// nothing about whether this instance can still do work.
    case ping
    /// Requests the app-owned permission facts used by `danterm doctor`.
    case doctorPermissions = "doctor.permissions"
    /// Requests the complete inspectable application snapshot.
    case ls
    /// Requests the main window's live key focus owner.
    case focusInfo = "focus.info"
    /// Subscribes this connection to the pane roster. Takes no target: the roster is
    /// the whole application's, and the subscription belongs to the connection the
    /// request arrived on. The reply is the current roster; every later roster goes
    /// out as a `roster.event` notification until the connection ends.
    case roster
    /// Reports what this instance's tailnet listener is doing. Takes no target: the
    /// answer is about the instance the request reached. Open to remote callers,
    /// because it reveals only what a peer already proved by arriving.
    case tailnetStatus = "tailnet.status"
    /// Ends the answering instance the way Cmd-Q does. Takes no target: the
    /// instance the request reached is the instance that exits.
    case quit
    /// Creates a group and its first tab. Takes no target: there is nothing to
    /// anchor a group to.
    case groupNew = "group.new"
    /// Changes one explicitly named group's name.
    case groupRename = "group.rename"
    /// Closes one explicitly named group.
    case groupClose = "group.close"
    /// Creates a tab from an explicit group or tab anchor.
    case tabNew = "tab.new"
    /// Changes one explicitly named tab's custom title.
    case tabRename = "tab.rename"
    /// Closes one explicitly named tab.
    case tabClose = "tab.close"
    /// Focuses one explicitly named pane.
    case paneFocus = "pane.focus"
    /// Requests metadata for one explicitly named pane.
    case paneInfo = "pane.info"
    /// Splits one named pane or chooses a split within one named tab.
    case paneSplit = "pane.split"
    /// Closes one explicitly named pane.
    case paneClose = "pane.close"
    /// Sends input to one explicitly named pane.
    case paneInput = "pane.input"
    /// Reads text from one explicitly named pane.
    case paneRead = "pane.read"
    /// Reads row structure from one explicitly named pane.
    case paneRows = "pane.rows"
    /// Changes zoom state for one explicitly named pane's tab.
    case paneZoom = "pane.zoom"
    /// Sets or clears the grid one explicitly named pane runs at.
    case paneResize = "pane.resize"
    /// Reads or follows the flight recording for one explicitly named pane.
    case paneTape = "pane.tape"
    /// Streams one exact terminal-state snapshot for an explicitly named pane.
    case paneSnapshot = "pane.snapshot"
    /// Changes the theme override for one explicitly named pane.
    case themeSet = "theme.set"
    /// Attaches an agent session to one explicitly named pane.
    case agentAttach = "agent.attach"
    /// Updates agent activity for one explicitly named pane.
    case agentActivity = "agent.activity"
    /// Detaches an agent session from one explicitly named pane.
    case agentDetach = "agent.detach"
    /// Lists todos for one explicitly named pane.
    case todoList = "todo.list"
    /// Adds a todo to one explicitly named pane.
    case todoAdd = "todo.add"
    /// Edits a todo in one explicitly named pane.
    case todoEdit = "todo.edit"
    /// Completes a todo in one explicitly named pane.
    case todoDone = "todo.done"
    /// Reopens a todo in one explicitly named pane.
    case todoOpen = "todo.open"
    /// Deletes a todo from one explicitly named pane.
    case todoDelete = "todo.delete"
    /// Removes completed todos from one explicitly named pane.
    case todoClearCompleted = "todo.clearCompleted"

    /// Names the methods whose success ends the instance that answered them.
    ///
    /// Two client rules follow from this one fact, and the switch is exhaustive
    /// so a future method has to decide both: such a method resolves its target
    /// only from an explicit `--socket`, and reads a closed connection as
    /// success, because a working quit takes the socket down with it.
    public var terminatesInstance: Bool {
        traits.terminatesInstance
    }

    /// Makes remote authority classification exhaustive when a method joins the catalog.
    public var requiresLocalCaller: Bool {
        traits.requiresLocalCaller
    }

    /// Makes durable-audit classification exhaustive when a method joins the catalog.
    ///
    /// Only a heartbeat is exempt: it exercises no authority and names no target, and
    /// one record every half-bound would evict the events the log exists for. Close-time
    /// accounting still counts pings, so a connection that only ever pinged stays
    /// distinguishable from one that was admitted and never read.
    public var producesAuditRecord: Bool {
        traits.producesAuditRecord
    }

    private var traits: IpcRequestMethodTraits {
        switch self {
        case .ping:
            return IpcRequestMethodTraits(
                terminatesInstance: false,
                requiresLocalCaller: false,
                producesAuditRecord: false
            )
        case .quit:
            return IpcRequestMethodTraits(
                terminatesInstance: true,
                requiresLocalCaller: true,
                producesAuditRecord: true
            )
        case .doctorPermissions, .ls, .focusInfo, .roster, .tailnetStatus,
             .groupNew, .groupRename, .groupClose,
             .tabNew, .tabRename, .tabClose,
             .paneFocus, .paneInfo, .paneSplit, .paneClose, .paneInput,
             .paneRead, .paneRows, .paneZoom, .paneResize, .paneTape, .paneSnapshot, .themeSet,
             .agentAttach, .agentActivity, .agentDetach,
             .todoList, .todoAdd, .todoEdit, .todoDone, .todoOpen,
             .todoDelete, .todoClearCompleted:
            return IpcRequestMethodTraits(
                terminatesInstance: false,
                requiresLocalCaller: false,
                producesAuditRecord: true
            )
        }
    }
}

/// Restricts group-anchored tab creation to its two meaningful positions.
public enum IpcGroupTabPosition: Equatable, Sendable {
    /// Preserves explicit selected-tab-relative placement within a named group.
    case afterSelected
    /// Makes group-end placement independent of current selection.
    case atGroupEnd
}

/// Makes the required tab-new anchor explicit and internally consistent.
public enum IpcTabTarget: Equatable, Sendable {
    /// Couples a group target to the only positions meaningful within that group.
    case group(GroupId, position: IpcGroupTabPosition)
    /// Uses the referenced tab as both the group and insertion anchor.
    case afterTab(TabId)
}

/// Makes the pane-or-tab split target exclusive and couples pane targets to a direction.
public enum IpcPaneSplitTarget: Equatable, Sendable {
    /// Splits this exact pane along the caller-selected axis.
    case pane(PaneId, direction: PaneSplitDirection)
    /// Lets the Mac choose a pane and axis from this tab's arranged geometry.
    case tab(TabId)
}

/// Names the accepted pane-zoom transitions before core dispatch.
public enum IpcPaneZoomState: String, Equatable, Sendable {
    /// Requests a known zoomed state.
    case on
    /// Requests a known unzoomed state.
    case off
    /// Preserves the explicitly requested state-relative operation.
    case toggle
}

/// Names the two forms a pane resize request can take, so a request can never
/// carry a grid and a fit at once.
public enum IpcPaneResize: Equatable, Sendable {
    /// Asks the pane to run at exactly this grid, whatever rectangle it occupies.
    case grid(columns: Int, rows: Int)
    /// Returns the pane to the grid its slot rectangle implies.
    case fit
}

/// Separates paste-style text from parsed key events in pane input requests.
public enum IpcPaneInput: Equatable, Sendable {
    /// Keeps top-level text on the terminal's paste-style input path.
    case text(String)
    /// Keeps parsed key events ordered through dispatch.
    case events([InputEvent])
}

/// Carries the hook-reported agent identity without coupling protocol to core validation.
public struct IpcAgentSession: Equatable, Sendable {
    /// Names the agent implementation after core applies its stricter validation.
    public let kind: String
    /// Qualifies lifecycle reports so stale hooks cannot mutate a replacement session.
    public let id: String

    /// Preserves the two fields as one value through decode and dispatch.
    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Names the accepted agent activity states before core dispatch.
public enum IpcAgentActivity: String, Equatable, Sendable {
    /// Reports that the attached agent is actively processing.
    case working
    /// Reports that the attached agent is awaiting external input.
    case waiting
    /// Reports that the attached agent is attached but inactive.
    case idle
}

/// Keeps one named request target available to both wire and audit projections.
struct IpcRequestTargetEntry: Equatable, Sendable {
    let key: String
    let id: UUID

    /// Erases only the phantom tag after the typed id has selected its wire key.
    init<Tag>(key: String, id: TypedId<Tag>) {
        self.key = key
        self.id = id.rawValue
    }

    /// Preserves the existing UUID spelling in JSON-RPC params.
    var wireValue: JSONValue { .string(id.uuidString) }

    /// Applies durable audit redaction at the projection boundary.
    var auditValue: String { id.uuidString.lowercased() }
}

/// Carries one trusted request's wire params and the facts admitted to its audit record.
struct IpcRequestProjection: Sendable {
    let params: [String: JSONValue]
    let targetEntries: [IpcRequestTargetEntry]
    let auditCommand: String?
    let auditCwd: String?
    let auditInput: IpcAuditInputAccounting?

    init(
        params: [String: JSONValue],
        targetEntries: [IpcRequestTargetEntry] = [],
        auditCommand: String? = nil,
        auditCwd: String? = nil,
        auditInput: IpcAuditInputAccounting? = nil
    ) {
        self.params = params
        self.targetEntries = targetEntries
        self.auditCommand = auditCommand
        self.auditCwd = auditCwd
        self.auditInput = auditInput
    }

    static func launch(
        _ launch: LaunchSpec?,
        background: Bool,
        params additionalParams: [String: JSONValue],
        targetEntries: [IpcRequestTargetEntry] = []
    ) -> IpcRequestProjection {
        var params = launchParams(launch, background: background)
        params.merge(additionalParams) { _, new in new }
        return IpcRequestProjection(
            params: params,
            targetEntries: targetEntries,
            auditCommand: launch?.cmd,
            auditCwd: launch?.cwd
        )
    }

    static func input(_ input: IpcPaneInput, pane: PaneId) -> IpcRequestProjection {
        let params: [String: JSONValue]
        let accounting: IpcAuditInputAccounting
        switch input {
        case .text(let text):
            params = ["text": .string(text)]
            accounting = .textBytes(text.utf8.count)
        case .events(let events):
            params = ["input": .array(events.map(inputEventJSON))]
            accounting = .eventCount(events.count)
        }
        return IpcRequestProjection(
            params: params,
            targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)],
            auditInput: accounting
        )
    }
}

/// Reports the stable JSON-RPC error produced while decoding a request catalog case.
public enum IpcRequestDecodeError: Error, Equatable, Sendable {
    /// Rejects methods outside the exhaustive request catalog.
    case methodNotFound
    /// Preserves the stable invalid-params message for the rejected shape.
    case invalidParams(String)
    /// Maps decoding failures to the JSON-RPC error code expected by clients.
    public var code: Int {
        switch self {
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        }
    }

    /// Maps decoding failures to the existing client-facing error vocabulary.
    public var message: String {
        switch self {
        case .methodNotFound: return "method not found"
        case .invalidParams(let message): return message
        }
    }
}

/// Represents every admitted IPC request with non-optional typed targets.
public enum IpcRequest: Equatable, Sendable {
    /// Asks for proof of service without a target. Its reply carries no facts: the
    /// fact it establishes is that dispatch produced a reply at all.
    case ping
    /// Defers permission probing to the app runtime.
    case doctorPermissions
    /// Requests the complete application snapshot without a target.
    case ls
    /// Requests the main window's live key focus owner without a target.
    case focusInfo
    /// Subscribes the answering connection to the pane roster, without a target.
    case roster
    /// Reports this instance's tailnet listener state, without a target.
    case tailnetStatus
    /// Ends the answering instance without a target. Dispatch refuses it unless
    /// the instance holds a launcher pool slot.
    case quit
    /// Creates a group without a target. `.createGroup` also creates the group's
    /// first tab, so the launch spec and focus policy apply to that tab.
    case groupNew(name: String, launch: LaunchSpec?, background: Bool)
    /// Renames a structurally required group. A group always has a name, so
    /// unlike `tabRename` there is no clear-to-nil form.
    case groupRename(group: GroupId, name: String)
    /// Closes a structurally required group, either with its tabs or after
    /// reparenting them into the adjacent group.
    case groupClose(group: GroupId, moveTabs: Bool)
    /// Creates a tab from a structurally required anchor.
    case tabNew(target: IpcTabTarget, launch: LaunchSpec?, background: Bool)
    /// Renames or clears the title of a structurally required tab.
    case tabRename(tab: TabId, title: String?)
    /// Closes a structurally required tab.
    case tabClose(tab: TabId)
    /// Focuses a structurally required pane.
    case paneFocus(pane: PaneId)
    /// Inspects a structurally required pane.
    case paneInfo(pane: PaneId)
    /// Splits an explicit pane or asks the Mac to resolve a split within an explicit tab.
    case paneSplit(target: IpcPaneSplitTarget, launch: LaunchSpec?, background: Bool)
    /// Closes a structurally required pane.
    case paneClose(pane: PaneId)
    /// Sends one decoded input form to a structurally required pane.
    case paneInput(pane: PaneId, input: IpcPaneInput)
    /// Reads a structurally required pane with an optional validated tail limit.
    case paneRead(pane: PaneId, lineLimit: Int?)
    /// Reads row structure from a structurally required pane.
    case paneRows(pane: PaneId)
    /// Applies a decoded zoom operation to a structurally required pane.
    case paneZoom(pane: PaneId, state: IpcPaneZoomState)
    /// Sets or clears the grid a structurally required pane runs at. The grid
    /// itself is validated by the core, which owns the accepted range.
    case paneResize(pane: PaneId, resize: IpcPaneResize)
    /// Reads or follows recording data from a structurally required pane.
    case paneTape(
        pane: PaneId,
        follow: Bool,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    )
    /// Streams exact terminal state from one owner fence.
    case paneSnapshot(pane: PaneId)
    /// Sets or clears the theme of a structurally required pane.
    case themeSet(pane: PaneId, themeName: String?)
    /// Attaches a decoded agent identity to a structurally required pane.
    case agentAttach(pane: PaneId, session: IpcAgentSession)
    /// Reports decoded activity for an agent on a structurally required pane.
    case agentActivity(pane: PaneId, session: IpcAgentSession, activity: IpcAgentActivity)
    /// Detaches a decoded agent identity from a structurally required pane.
    case agentDetach(pane: PaneId, session: IpcAgentSession)
    /// Lists todos from a structurally required pane or tab owner.
    case todoList(owner: TodoOwner)
    /// Adds validated text to a structurally required owner's todos.
    case todoAdd(owner: TodoOwner, text: String)
    /// Edits a named todo in a structurally required owner.
    case todoEdit(owner: TodoOwner, todoId: TodoId, text: String)
    /// Sets the completion state of a named todo in a structurally required owner.
    /// The state is a value here, not a case: `todo.done` and `todo.open` differ by
    /// nothing else, so branches read `isDone` instead of recovering it from a tag.
    case todoSetDone(owner: TodoOwner, todoId: TodoId, isDone: Bool)
    /// Deletes a named todo from a structurally required owner.
    case todoDelete(owner: TodoOwner, todoId: TodoId)
    /// Clears completed todos from a structurally required owner.
    case todoClearCompleted(owner: TodoOwner)

    /// Identifies the wire method for this catalog case.
    public var method: IpcRequestMethod {
        switch self {
        case .ping: return .ping
        case .doctorPermissions: return .doctorPermissions
        case .ls: return .ls
        case .focusInfo: return .focusInfo
        case .roster: return .roster
        case .tailnetStatus: return .tailnetStatus
        case .quit: return .quit
        case .groupNew: return .groupNew
        case .groupRename: return .groupRename
        case .groupClose: return .groupClose
        case .tabNew: return .tabNew
        case .tabRename: return .tabRename
        case .tabClose: return .tabClose
        case .paneFocus: return .paneFocus
        case .paneInfo: return .paneInfo
        case .paneSplit: return .paneSplit
        case .paneClose: return .paneClose
        case .paneInput: return .paneInput
        case .paneRead: return .paneRead
        case .paneRows: return .paneRows
        case .paneZoom: return .paneZoom
        case .paneResize: return .paneResize
        case .paneTape: return .paneTape
        case .paneSnapshot: return .paneSnapshot
        case .themeSet: return .themeSet
        case .agentAttach: return .agentAttach
        case .agentActivity: return .agentActivity
        case .agentDetach: return .agentDetach
        case .todoList: return .todoList
        case .todoAdd: return .todoAdd
        case .todoEdit: return .todoEdit
        case .todoSetDone(_, _, let isDone): return isDone ? .todoDone : .todoOpen
        case .todoDelete: return .todoDelete
        case .todoClearCompleted: return .todoClearCompleted
        }
    }

    /// Projects wire params and permitted audit facts through one exhaustive catalog.
    var projection: IpcRequestProjection {
        switch self {
        case .ping, .doctorPermissions, .ls, .focusInfo, .roster, .tailnetStatus, .quit:
            return IpcRequestProjection(params: [:])
        case .groupNew(let name, let launch, let background):
            return .launch(
                launch,
                background: background,
                params: ["name": .string(name)]
            )
        case .groupRename(let group, let name):
            return IpcRequestProjection(
                params: ["name": .string(name)],
                targetEntries: [IpcRequestTargetEntry(key: "group", id: group)]
            )
        case .groupClose(let group, let moveTabs):
            return IpcRequestProjection(
                params: ["moveTabs": .bool(moveTabs)],
                targetEntries: [IpcRequestTargetEntry(key: "group", id: group)]
            )
        case .tabNew(let target, let launch, let background):
            switch target {
            case .group(let group, let position):
                return .launch(
                    launch,
                    background: background,
                    params: [
                        "position": .string(
                            position == .afterSelected ? "afterSelected" : "atGroupEnd"
                        ),
                    ],
                    targetEntries: [IpcRequestTargetEntry(key: "group", id: group)]
                )
            case .afterTab(let tab):
                return .launch(
                    launch,
                    background: background,
                    params: ["position": .string("afterTab")],
                    targetEntries: [IpcRequestTargetEntry(key: "afterTabId", id: tab)]
                )
            }
        case .tabRename(let tab, let title):
            return IpcRequestProjection(
                params: ["title": title.map(JSONValue.string) ?? .null],
                targetEntries: [IpcRequestTargetEntry(key: "tab", id: tab)]
            )
        case .tabClose(let tab):
            return IpcRequestProjection(
                params: [:],
                targetEntries: [IpcRequestTargetEntry(key: "tab", id: tab)]
            )
        case .paneFocus(let pane), .paneInfo(let pane), .paneClose(let pane),
             .paneRows(let pane), .paneSnapshot(let pane):
            return IpcRequestProjection(
                params: [:],
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .paneSplit(let target, let launch, let background):
            switch target {
            case .pane(let pane, let direction):
                return .launch(
                    launch,
                    background: background,
                    params: [
                        "direction": .string(
                            direction == .horizontal ? "horizontal" : "vertical"
                        ),
                    ],
                    targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
                )
            case .tab(let tab):
                return .launch(
                    launch,
                    background: background,
                    params: [:],
                    targetEntries: [IpcRequestTargetEntry(key: "tab", id: tab)]
                )
            }
        case .paneInput(let pane, let input):
            return .input(input, pane: pane)
        case .paneRead(let pane, let lineLimit):
            return IpcRequestProjection(
                params: lineLimit.map { ["lines": .number(Double($0))] } ?? [:],
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .paneZoom(let pane, let state):
            return IpcRequestProjection(
                params: ["state": .string(state.rawValue)],
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .paneResize(let pane, let resize):
            let params: [String: JSONValue]
            switch resize {
            case .grid(let columns, let rows):
                params = [
                    "columns": .number(Double(columns)),
                    "rows": .number(Double(rows)),
                ]
            case .fit:
                params = ["fit": .bool(true)]
            }
            return IpcRequestProjection(
                params: params,
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .paneTape(let pane, let follow, let start, let policy):
            var params: [String: JSONValue] = [
                "start": paneTapeStartJSON(start),
                "mode": .string(policy.mode.rawValue),
            ]
            if follow { params["follow"] = .bool(true) }
            if case .reconstructible(let budget) = policy, let budget {
                params["syncHistoryBytes"] = .number(Double(budget))
            }
            return IpcRequestProjection(
                params: params,
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .themeSet(let pane, let themeName):
            return IpcRequestProjection(
                params: ["themeName": themeName.map(JSONValue.string) ?? .null],
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .agentAttach(let pane, let session), .agentDetach(let pane, let session):
            return IpcRequestProjection(
                params: agentParams(session: session),
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .agentActivity(let pane, let session, let activity):
            var params = agentParams(session: session)
            params["state"] = .string(activity.rawValue)
            return IpcRequestProjection(
                params: params,
                targetEntries: [IpcRequestTargetEntry(key: "pane", id: pane)]
            )
        case .todoList(let owner), .todoClearCompleted(let owner):
            return IpcRequestProjection(params: [:], targetEntries: ownerTargetEntries(owner))
        case .todoAdd(let owner, let text):
            return IpcRequestProjection(
                params: ["text": .string(text)],
                targetEntries: ownerTargetEntries(owner)
            )
        case .todoEdit(let owner, let todoId, let text):
            return IpcRequestProjection(
                params: ["text": .string(text)],
                targetEntries: ownerTargetEntries(owner)
                    + [IpcRequestTargetEntry(key: "todoId", id: todoId)]
            )
        // `isDone` stays out of params on purpose: the wire method carries it.
        case .todoSetDone(let owner, let todoId, _), .todoDelete(let owner, let todoId):
            return IpcRequestProjection(
                params: [:],
                targetEntries: ownerTargetEntries(owner)
                    + [IpcRequestTargetEntry(key: "todoId", id: todoId)]
            )
        }
    }

    /// Encodes this typed request into its JSON-RPC parameter object.
    public var params: [String: JSONValue] {
        let requestProjection = projection
        var params = requestProjection.params
        for entry in requestProjection.targetEntries {
            params[entry.key] = entry.wireValue
        }
        return params
    }

    /// Decodes untrusted wire params into the one typed catalog consumed by core dispatch.
    public static func decode(
        method rawMethod: String,
        params: JSONValue
    ) throws(IpcRequestDecodeError) -> IpcRequest {
        guard let method = IpcRequestMethod(rawValue: rawMethod) else {
            throw IpcRequestDecodeError.methodNotFound
        }
        let object = params.asObject

        switch method {
        case .ping: return .ping
        case .doctorPermissions: return .doctorPermissions
        case .ls: return .ls
        case .focusInfo: return .focusInfo
        case .roster: return .roster
        case .tailnetStatus: return .tailnetStatus
        case .quit: return .quit
        case .groupNew:
            guard case .string(let name)? = object?["name"] else { throw invalid("invalid name") }
            let launch = try decodedLaunch(object?["launch"])
            let background = try optionalBool(object?["background"], name: "background")
            return .groupNew(name: name, launch: launch, background: background)
        case .groupRename:
            let group: GroupId = try target("group", object: object)
            guard case .string(let name)? = object?["name"] else { throw invalid("invalid name") }
            return .groupRename(group: group, name: name)
        case .groupClose:
            let group: GroupId = try target("group", object: object)
            let moveTabs = try optionalBool(object?["moveTabs"], name: "moveTabs")
            return .groupClose(group: group, moveTabs: moveTabs)
        case .tabNew:
            guard let object else { throw invalid("invalid params") }
            let launch = try decodedLaunch(object["launch"])
            let background = try optionalBool(object["background"], name: "background")
            let target = try tabTarget(object)
            return .tabNew(target: target, launch: launch, background: background)
        case .tabRename:
            let tab: TabId = try target("tab", object: object)
            guard let titleValue = object?["title"] else { throw invalid("invalid title") }
            switch titleValue {
            case .string(let title): return .tabRename(tab: tab, title: title)
            case .null: return .tabRename(tab: tab, title: nil)
            default: throw invalid("invalid title")
            }
        case .tabClose:
            return .tabClose(tab: try target("tab", object: object))
        case .paneFocus:
            return .paneFocus(pane: try target("pane", object: object))
        case .paneInfo:
            return .paneInfo(pane: try target("pane", object: object))
        case .paneSplit:
            let target = try paneSplitTarget(object)
            let launch = try decodedLaunch(object?["launch"])
            let background = try optionalBool(object?["background"], name: "background")
            return .paneSplit(target: target, launch: launch, background: background)
        case .paneClose:
            return .paneClose(pane: try target("pane", object: object))
        case .paneInput:
            let pane: PaneId = try target("pane", object: object)
            return .paneInput(pane: pane, input: try decodePaneInput(object))
        case .paneRead:
            let pane: PaneId = try target("pane", object: object)
            return .paneRead(pane: pane, lineLimit: try lineLimit(object?["lines"]))
        case .paneRows:
            return .paneRows(pane: try target("pane", object: object))
        case .paneZoom:
            let pane: PaneId = try target("pane", object: object)
            guard case .string(let rawState)? = object?["state"],
                  let state = IpcPaneZoomState(rawValue: rawState)
            else { throw invalid("state must be one of on, off, toggle") }
            return .paneZoom(pane: pane, state: state)
        case .paneResize:
            let pane: PaneId = try target("pane", object: object)
            return .paneResize(pane: pane, resize: try decodePaneResize(object))
        case .paneTape:
            let pane: PaneId = try target("pane", object: object)
            let follow = try optionalBool(object?["follow"], name: "follow")
            guard let start = decodePaneTapeStart(object?["start"]) else {
                throw invalid("invalid tape start")
            }
            guard case .string(let rawMode)? = object?["mode"],
                  let mode = PaneTapeStreamMode(rawValue: rawMode)
            else { throw invalid("invalid tape mode") }
            let policy: PaneTapeSyncPolicy
            do {
                policy = try paneTapeSyncPolicy(
                    mode: mode,
                    requestedHistoryBudgetBytes: try decodePaneTapeSyncHistoryBytes(
                        object?["syncHistoryBytes"]
                    )
                )
            } catch let error {
                switch error {
                case .budgetNotWholeBytes:
                    throw invalid("syncHistoryBytes must be a whole number of bytes, zero or more")
                case .budgetOnRawStream:
                    throw invalid("syncHistoryBytes applies only to a reconstructible tape stream")
                }
            }
            return .paneTape(pane: pane, follow: follow, start: start, policy: policy)
        case .paneSnapshot:
            return .paneSnapshot(pane: try target("pane", object: object))
        case .themeSet:
            let pane: PaneId = try target("pane", object: object)
            guard let value = object?["themeName"] else { throw invalid("invalid theme params") }
            switch value {
            case .string(let name): return .themeSet(pane: pane, themeName: name)
            case .null: return .themeSet(pane: pane, themeName: nil)
            default: throw invalid("invalid theme name")
            }
        case .agentAttach:
            let pane: PaneId = try target("pane", object: object)
            return .agentAttach(pane: pane, session: try agentSession(object))
        case .agentActivity:
            let pane: PaneId = try target("pane", object: object)
            let session = try agentSession(object)
            guard case .string(let rawActivity)? = object?["state"],
                  let activity = IpcAgentActivity(rawValue: rawActivity)
            else { throw invalid("invalid agent activity") }
            return .agentActivity(pane: pane, session: session, activity: activity)
        case .agentDetach:
            let pane: PaneId = try target("pane", object: object)
            return .agentDetach(pane: pane, session: try agentSession(object))
        case .todoList:
            return .todoList(owner: try todoOwner(object))
        case .todoAdd:
            let owner = try todoOwner(object)
            guard case .string(let text)? = object?["text"] else { throw invalid("invalid todo text") }
            return .todoAdd(owner: owner, text: text)
        case .todoEdit:
            let owner = try todoOwner(object)
            guard case .string(let rawTodoId)? = object?["todoId"],
                  case .string(let text)? = object?["text"],
                  let todoId = UUID(uuidString: rawTodoId),
                  text.trimmingCharacters(in: .whitespaces).isEmpty == false
            else { throw invalid("invalid todo") }
            return .todoEdit(owner: owner, todoId: TodoId(rawValue: todoId), text: text)
        case .todoDone:
            let (owner, todoId) = try todoOwnerAndId(object)
            return .todoSetDone(owner: owner, todoId: todoId, isDone: true)
        case .todoOpen:
            let (owner, todoId) = try todoOwnerAndId(object)
            return .todoSetDone(owner: owner, todoId: todoId, isDone: false)
        case .todoDelete:
            let (owner, todoId) = try todoOwnerAndId(object)
            return .todoDelete(owner: owner, todoId: todoId)
        case .todoClearCompleted:
            return .todoClearCompleted(owner: try todoOwner(object))
        }
    }
}

private func paneTapeStartJSON(_ start: PaneTapeStartPosition) -> JSONValue {
    switch start {
    case .beginning:
        return .string("beginning")
    case .now:
        return .string("now")
    case .cursor(let cursor):
        return .object(["cursor": paneTapeCursorJSON(cursor)])
    }
}

private func decodePaneTapeStart(_ value: JSONValue?) -> PaneTapeStartPosition? {
    switch value {
    case .string("beginning")?: return .beginning
    case .string("now")?: return .now
    case .object(let object)?:
        return decodePaneTapeCursor(object["cursor"]).map(PaneTapeStartPosition.cursor)
    default: return nil
    }
}

private func todoOwner(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> TodoOwner {
    let hasPane = object?["pane"] != nil
    let hasTab = object?["tab"] != nil
    guard hasPane || hasTab else { throw invalid("pane or tab required") }
    guard hasPane != hasTab else { throw invalid("exactly one of pane or tab required") }
    if hasPane {
        let pane: PaneId = try target("pane", object: object)
        return .pane(pane)
    }
    let tab: TabId = try target("tab", object: object)
    return .tab(tab)
}

/// Shares the owner-plus-id extraction across the todo methods that name one todo,
/// so each of them can decode in its own case arm without a grouped re-switch.
private func todoOwnerAndId(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> (TodoOwner, TodoId) {
    let owner = try todoOwner(object)
    guard case .string(let rawTodoId)? = object?["todoId"], let todoId = UUID(uuidString: rawTodoId) else {
        throw invalid("invalid todo")
    }
    return (owner, TodoId(rawValue: todoId))
}

private func ownerTargetEntries(_ owner: TodoOwner) -> [IpcRequestTargetEntry] {
    switch owner {
    case .pane(let pane): return [IpcRequestTargetEntry(key: "pane", id: pane)]
    case .tab(let tab): return [IpcRequestTargetEntry(key: "tab", id: tab)]
    }
}

private func invalid(_ message: String) -> IpcRequestDecodeError {
    .invalidParams(message)
}

private func target<Tag>(
    _ entity: String,
    object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> TypedId<Tag> {
    guard let raw = object?[entity] else { throw invalid("\(entity) required") }
    guard case .string(let string) = raw else { throw invalid("\(entity) must be a string") }
    guard let uuid = UUID(uuidString: string) else { throw invalid("\(entity) not found") }
    return TypedId(rawValue: uuid)
}

private func decodedLaunch(_ value: JSONValue?) throws(IpcRequestDecodeError) -> LaunchSpec? {
    do {
        return try parseLaunchSpec(value)
    } catch let error {
        switch error {
        case .notObject:
            throw invalid("launch must be an object")
        case .fieldNotString(let field):
            throw invalid("launch.\(field) must be a string")
        }
    }
}

private func optionalBool(
    _ value: JSONValue?,
    name: String
) throws(IpcRequestDecodeError) -> Bool {
    switch value {
    case .none, .some(.null): return false
    case .some(.bool(let value)): return value
    default: throw invalid("\(name) must be a boolean")
    }
}

private func paneSplitTarget(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> IpcPaneSplitTarget {
    let hasPane = object?["pane"] != nil
    let hasTab = object?["tab"] != nil
    switch (hasPane, hasTab) {
    case (false, false):
        throw invalid("pane or tab required")
    case (true, true):
        throw invalid("exactly one of pane or tab required")
    case (false, true):
        guard object?["direction"] == nil else {
            throw invalid("direction is not valid with tab")
        }
        let tab: TabId = try target("tab", object: object)
        return .tab(tab)
    case (true, false):
        guard let directionValue = object?["direction"] else {
            throw invalid("direction required with pane")
        }
        guard case .string(let rawDirection) = directionValue else {
            throw invalid("invalid pane split params")
        }
        let direction: PaneSplitDirection
        switch rawDirection {
        case "horizontal": direction = .horizontal
        case "vertical": direction = .vertical
        default: throw invalid("invalid pane split params")
        }
        let pane: PaneId = try target("pane", object: object)
        return .pane(pane, direction: direction)
    }
}

private func tabTarget(
    _ object: [String: JSONValue]
) throws(IpcRequestDecodeError) -> IpcTabTarget {
    let positionValue = object["position"]
    let afterTabValue = object["afterTabId"]
    if afterTabValue != nil {
        switch positionValue {
        case .none:
            throw invalid("afterTabId is only valid when position == \"afterTab\"")
        case .some(.string(let value)) where value != "afterTab":
            throw invalid("afterTabId is only valid when position == \"afterTab\"")
        default:
            break
        }
    }
    guard let positionValue else {
        let group: GroupId = try target("group", object: object)
        return .group(group, position: .atGroupEnd)
    }
    guard case .string(let position) = positionValue else {
        throw invalid("position must be a string")
    }
    switch position {
    case "afterSelected", "atGroupEnd":
        let group: GroupId = try target("group", object: object)
        return .group(group, position: position == "afterSelected" ? .afterSelected : .atGroupEnd)
    case "afterTab":
        guard let afterTabValue else { throw invalid("position=afterTab requires afterTabId") }
        guard case .string(let rawTab) = afterTabValue else {
            throw invalid("afterTabId must be a string")
        }
        guard let uuid = UUID(uuidString: rawTab) else {
            throw invalid("afterTabId is not a valid tab id")
        }
        guard object["group"] == nil else {
            throw invalid("tab.new requires exactly one of group or afterTabId")
        }
        return .afterTab(TabId(rawValue: uuid))
    default:
        throw invalid("position must be one of: afterSelected, atGroupEnd, afterTab")
    }
}

private func decodePaneInput(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> IpcPaneInput {
    let text = object?["text"]
    let input = object?["input"]
    switch (text, input) {
    case (.some, .some): throw invalid("text or input required, not both")
    case (.none, .none): throw invalid("text or input required")
    case (.some(.string(let text)), .none) where text.isEmpty == false:
        return .text(text)
    case (.some, .none): throw invalid("invalid text")
    case (.none, .some(.array(let values))):
        return .events(try values.map(decodeInputEvent))
    case (.none, .some): throw invalid("input must be an array")
    }
}

private func decodeInputEvent(_ value: JSONValue) throws(IpcRequestDecodeError) -> InputEvent {
    guard case .object(let object) = value else { throw invalid("input event must be an object") }
    let textPresent = object["text"] != nil
    let keyPresent = object["key"] != nil
    let wheelPresent = object["wheel"] != nil
    guard [textPresent, keyPresent, wheelPresent].filter({ $0 }).count == 1 else {
        throw invalid("input event must have exactly one of text, key, or wheel")
    }
    if textPresent {
        guard case .string(let text)? = object["text"] else {
            throw invalid("input event text must be a string")
        }
        return .text(text)
    }
    if wheelPresent {
        guard case .string(let rawDirection)? = object["wheel"],
              let direction = InputWheelDirection(rawValue: rawDirection)
        else {
            throw invalid("wheel must be one of up or down")
        }
        let column = try inputCellCoordinate(object["column"], name: "column")
        let row = try inputCellCoordinate(object["row"], name: "row")
        return .wheel(direction, column: column, row: row)
    }
    guard case .string(let keyName)? = object["key"] else {
        throw invalid("input event key must be a string")
    }
    guard let key = KeyName(wireName: keyName) else { throw invalid("unknown key \(keyName)") }
    var mods: KeyMods = []
    if let value = object["mods"] {
        guard case .array(let entries) = value else { throw invalid("mods must be an array") }
        var names: [String] = []
        for entry in entries {
            guard case .string(let name) = entry else { throw invalid("mods entries must be strings") }
            names.append(name)
        }
        do {
            mods = try KeyMods.decode(wire: names)
        } catch let error {
            switch error {
            case .unknown(let name):
                throw invalid("unknown mod \(name)")
            }
        }
    }
    if case .character = key, mods.isEmpty {
        throw invalid("character key requires at least one modifier")
    }
    return .key(key, mods)
}

private func inputCellCoordinate(
    _ value: JSONValue?,
    name: String
) throws(IpcRequestDecodeError) -> Int {
    guard case .number(let number)? = value,
          let coordinate = Int(exactly: number),
          coordinate >= 0
    else {
        throw invalid("\(name) must be a non-negative integer")
    }
    return coordinate
}

private func lineLimit(_ value: JSONValue?) throws(IpcRequestDecodeError) -> Int? {
    switch value {
    case .none, .some(.null): return nil
    case .some(.number(let number)):
        guard let value = Int(exactly: number), value > 0 else {
            throw invalid("lines must be a positive integer")
        }
        return value
    default:
        throw invalid("lines must be a positive integer")
    }
}

/// Admits exactly one of the two resize forms, so "fit to my slot" and "run at
/// this grid" can never arrive in the same request and leave the daemon
/// guessing which one the caller meant. The grid's accepted range is the core's
/// to enforce; this only reads the shape.
private func decodePaneResize(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> IpcPaneResize {
    let usage = "params must be columns and rows, or fit"
    let fit = try optionalBool(object?["fit"], name: "fit")
    let columnsValue = object?["columns"]
    let rowsValue = object?["rows"]
    if fit {
        guard columnsValue == nil, rowsValue == nil else { throw invalid(usage) }
        return .fit
    }
    guard case .number(let columns)? = columnsValue,
          case .number(let rows)? = rowsValue,
          let columns = Int(exactly: columns),
          let rows = Int(exactly: rows)
    else { throw invalid(usage) }
    return .grid(columns: columns, rows: rows)
}

private func agentSession(
    _ object: [String: JSONValue]?
) throws(IpcRequestDecodeError) -> IpcAgentSession {
    guard case .string(let kind)? = object?["kind"],
          case .string(let id)? = object?["id"]
    else { throw invalid("invalid agent session") }
    return IpcAgentSession(kind: kind, id: id)
}

private func launchParams(_ launch: LaunchSpec?, background: Bool) -> [String: JSONValue] {
    var object: [String: JSONValue] = ["background": .bool(background)]
    if let launch { object["launch"] = launch.jsonValue }
    return object
}

private func agentParams(session: IpcAgentSession) -> [String: JSONValue] {
    ["kind": .string(session.kind), "id": .string(session.id)]
}

private func inputEventJSON(_ event: InputEvent) -> JSONValue {
    switch event {
    case .text(let text):
        return .object(["text": .string(text)])
    case .key(let key, let mods):
        var object: [String: JSONValue] = ["key": .string(key.wireName)]
        if mods.isEmpty == false {
            var names: [JSONValue] = []
            if mods.contains(.ctrl) { names.append(.string("ctrl")) }
            if mods.contains(.alt) { names.append(.string("alt")) }
            if mods.contains(.shift) { names.append(.string("shift")) }
            object["mods"] = .array(names)
        }
        return .object(object)
    case .wheel(let direction, let column, let row):
        return .object([
            "wheel": .string(direction.rawValue),
            "column": .number(Double(column)),
            "row": .number(Double(row)),
        ])
    }
}
