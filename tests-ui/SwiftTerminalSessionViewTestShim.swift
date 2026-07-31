// Test-only terminal-engine values and controller used to compile the real Swift pane view.
import Cocoa

enum PaneLifecycleResult {
    case exited
}

enum TerminalSearchStatus {
    case empty
    case matched(selected: Int, total: Int)
}

enum TerminalSemanticEvent {
    case title(String)
    case workingDirectory(String?)
    case bell
    case commandStarted(String)
    case commandEnded
    case remoteStarted
    case remoteHost(user: String, host: String)
    case desktopNotification(title: String, body: String)
    case progress(TerminalProgress?)
}

enum TerminalProgress {
    case set(percent: UInt8)
    case indeterminate
    case error(percent: UInt8?)
    case pause(percent: UInt8?)
}

struct RenderColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// Test-only fixed-palette stand-in used by the real app-side bridge.
struct RenderANSIColors {
    init?(exactly colors: [RenderColor]) {
        guard colors.count == 16 else { return nil }
    }
}

struct RenderTheme {
    static let dark = RenderTheme(defaultBackground: .init(red: 0, green: 0, blue: 0))
    let defaultBackground: RenderColor

    init(defaultBackground: RenderColor) {
        self.defaultBackground = defaultBackground
    }

    init(
        ansiColors: RenderANSIColors,
        defaultForeground: RenderColor,
        defaultBackground: RenderColor,
        selectionForeground: RenderColor,
        selectionBackground: RenderColor,
        cursor: RenderColor,
        cursorText: RenderColor
    ) {
        self.defaultBackground = defaultBackground
    }
}

struct RenderFramePlan {
    let defaultBackground: RenderColor
    let columns = 10
    let rows = 10
}

struct TerminalDamage: Equatable {
    let isFull: Bool
    let rows: Set<Int>

    init(isFull: Bool = false, rows: Set<Int> = []) {
        self.isFull = isFull
        self.rows = rows
    }

    static let none = TerminalDamage()
}

struct TerminalPaneFrame {
    let plan: RenderFramePlan
    let damage: TerminalDamage
}

struct TerminalDimensions: Equatable {
    let columns: Int
    let rows: Int
}

struct TerminalRenderMetrics: Equatable {
    let cellSize: CGSize

    init?(displayScale: CGFloat, fontSize: CGFloat = 13) {
        guard displayScale > 0, fontSize > 0 else { return nil }
        cellSize = CGSize(width: 8 * fontSize / 13, height: 16 * fontSize / 13)
    }
}

func terminalGridDimensions(
    size: TerminalRenderExecutionSize,
    cellSize: TerminalRenderExecutionSize
) -> TerminalDimensions? {
    guard size.width > 0, size.height > 0, cellSize.width > 0, cellSize.height > 0 else {
        return nil
    }
    return TerminalDimensions(
        columns: Int(size.width / cellSize.width),
        rows: Int(size.height / cellSize.height)
    )
}

struct TerminalRenderExecutionSize {
    let width: Double
    let height: Double
}

func drawRenderFrame(
    _ plan: RenderFramePlan,
    metrics: TerminalRenderMetrics,
    in context: CGContext
) {}

struct TerminalScrollProjection: Equatable {
    let totalRows: Int
    let topRow: Int
    let windowRows: Int
    let isFollowing: Bool
}

struct TerminalPaneViewportState: Equatable {
    let isScrollbarEnabled: Bool
    let projection: TerminalScrollProjection
}

struct TerminalViewportCell: Equatable {
    let column: Int
    let row: Int
}

struct TerminalHyperlink: Equatable {
    let uri: String
    let explicitId: String?

    init(uri: String, explicitId: String? = nil) {
        self.uri = uri
        self.explicitId = explicitId
    }
}

enum TerminalPointerEvent: Equatable {
    case down(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    )
    case up(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
    case move(column: Int, row: Int, modifiers: TerminalKeyModifiers = [])
}

enum TerminalWheelPhase: Equatable {
    case began
    case changed
    case ended
    case momentumBegan
    case momentumChanged
    case momentumEnded
    case standalone
}

struct TerminalWheelEvent: Equatable {
    let rowDelta: Double
    let column: Int
    let row: Int
    let modifiers: TerminalKeyModifiers
    let phase: TerminalWheelPhase

    init(
        rowDelta: Double,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.rowDelta = rowDelta
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.phase = phase
    }
}

func terminalCell(
    at point: TerminalPoint,
    cellSize: TerminalCellSize,
    columns: Int,
    rows: Int
) -> TerminalViewportCell? {
    guard cellSize.width > 0, cellSize.height > 0, columns > 0, rows > 0 else { return nil }
    return TerminalViewportCell(
        column: min(max(Int((point.x / cellSize.width).rounded(.down)), 0), columns - 1),
        row: min(max(Int((point.y / cellSize.height).rounded(.down)), 0), rows - 1)
    )
}

struct TerminalPoint {
    let x: Double
    let y: Double
}

struct TerminalCellSize {
    let width: Double
    let height: Double
}

@MainActor
final class TerminalPaneSessionController {
    var onFrame: ((TerminalPaneFrame) -> Void)?
    var onClipboardWrite: ((String) -> Void)?
    var onSemanticEvents: (([TerminalSemanticEvent]) -> Void)?
    var onSessionEnded: ((PaneLifecycleResult) -> Void)?
    var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?
    var onPaneMenu: ((TerminalViewportCell) -> Void)?
    var onOpenLink: ((TerminalHyperlink) -> Void)?
    var onSearchStatus: ((TerminalSearchStatus?) -> Void)?
    var onPrimaryHistoryMutation: (() -> Void)?
    var currentPlan: RenderFramePlan?
    private(set) var renderTheme = RenderTheme.dark
    private(set) var appliedThemes: [RenderTheme] = []
    var viewportState: TerminalPaneViewportState
    private(set) var scrolledTopRows: [Int] = []
    private(set) var textInputs: [String] = []
    private(set) var inputBytes: [[UInt8]] = []
    private(set) var focusChanges: [Bool] = []
    private(set) var pointerEvents: [TerminalPointerEvent] = []
    private(set) var wheelEvents: [TerminalWheelEvent] = []
    private(set) var searchQueries: [String] = []
    private(set) var searchNextRequests = 0
    private(set) var searchPreviousRequests = 0
    private(set) var clearSearchRequests = 0
    private(set) var synchronizedSelectionReads = 0
    private(set) var linkInteractionCancellations = 0
    var allowsPaneMenu = true
    var cachedHasSelection = false
    var selectedTextOnFence: String?
    var hoveredLinkForCommandMove: TerminalHyperlink?
    var linkForCommandClick: TerminalHyperlink?
    private var cachedHoveredLink: TerminalHyperlink?
    private var linkClickArmed = false
    var inputModes = TerminalInputModes.default

    init(
        viewportState: TerminalPaneViewportState = .init(
            isScrollbarEnabled: true,
            projection: .init(totalRows: 30, topRow: 10, windowRows: 20, isFollowing: false)
        ),
        theme: RenderTheme = .dark,
        currentPlan: RenderFramePlan? = nil
    ) {
        self.viewportState = viewportState
        renderTheme = theme
        self.currentPlan = currentPlan
    }

    func sendText(_ text: String) { textInputs.append(text) }
    func sendKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {
        inputBytes.append(encodeTerminalKey(key, modifiers: modifiers, modes: inputModes))
    }
    func sendPaste(_ text: String) {
        inputBytes.append(encodeTerminalPaste(text, modes: inputModes))
    }
    func beginSearch(_ query: String) { searchQueries.append(query) }
    func searchNext() { searchNextRequests += 1 }
    func searchPrevious() { searchPreviousRequests += 1 }
    func clearSearch() { clearSearchRequests += 1 }
    func sendFocus(_ focused: Bool) {
        focusChanges.append(focused)
        let bytes = encodeTerminalFocus(focused: focused, modes: inputModes)
        if bytes.isEmpty == false { inputBytes.append(bytes) }
    }
    func sendWheel(_ event: TerminalWheelEvent) { wheelEvents.append(event) }
    func sendPointer(_ event: TerminalPointerEvent) {
        pointerEvents.append(event)
        if allowsPaneMenu, case let .up(.right, column, row, _) = event {
            onPaneMenu?(.init(column: column, row: row))
        }
        switch event {
        case let .move(_, _, modifiers):
            cachedHoveredLink = modifiers.contains(.command) ? hoveredLinkForCommandMove : nil
            emitFrame()
        case let .down(.left, _, _, modifiers, _):
            linkClickArmed = modifiers.contains(.command) && linkForCommandClick != nil
        case let .up(.left, _, _, modifiers):
            if linkClickArmed, modifiers.contains(.command), let linkForCommandClick {
                onOpenLink?(linkForCommandClick)
            }
            linkClickArmed = false
        default:
            break
        }
    }
    func cancelLinkInteraction() {
        linkInteractionCancellations += 1
        cachedHoveredLink = nil
        linkClickArmed = false
        emitFrame()
    }
    func readHoveredLink() -> TerminalHyperlink? { cachedHoveredLink }
    private(set) var selectAllRequests = 0
    func selectAll() {
        selectAllRequests += 1
        cachedHasSelection = true
    }
    var hasSelection: Bool { cachedHasSelection }
    func readSelectedTextSynchronizing() -> String? {
        synchronizedSelectionReads += 1
        cachedHasSelection = selectedTextOnFence != nil
        return selectedTextOnFence
    }
    func scroll(toTopRow row: Int) { scrolledTopRows.append(row) }
    func setVisible(_ visible: Bool) {}
    func setTheme(_ theme: RenderTheme) {
        renderTheme = theme
        appliedThemes.append(theme)
    }
    func fenceForApplicationExit() {}
    func synchronizeState() {}
    func readViewportText() -> String { "" }
    func readFullHistoryText() -> String { "" }
    func readPrimaryHistoryText() -> String { "" }
    private(set) var gridDimensions: [TerminalDimensions] = []

    func setGridDimensions(_ dimensions: TerminalDimensions) {
        gridDimensions.append(dimensions)
    }
    func tearDown() {
        onOpenLink = nil
        onSearchStatus = nil
        onSemanticEvents = nil
    }

    func emitViewportState(_ state: TerminalPaneViewportState) {
        viewportState = state
        onViewportStateChange?(state)
    }

    func emitClipboardWrite(_ text: String) {
        onClipboardWrite?(text)
    }

    func emitSemanticEvents(_ events: [TerminalSemanticEvent]) {
        onSemanticEvents?(events)
    }

    func emitSearchStatus(_ status: TerminalSearchStatus?) {
        onSearchStatus?(status)
    }

    func emitFrameForTest() {
        emitFrame()
    }

    func emitHoveredLinkForTest(_ link: TerminalHyperlink) {
        cachedHoveredLink = link
        emitFrame()
    }

    private func emitFrame() {
        let plan = currentPlan ?? RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        onFrame?(.init(plan: plan, damage: .init(isFull: true)))
    }
}
