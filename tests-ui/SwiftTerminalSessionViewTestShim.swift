// Test-only terminal-engine values and controller used to compile the real Swift pane view.
import Cocoa

enum PaneLifecycleResult {
    case exited
}

struct RenderColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct RenderTheme {
    static let dark = RenderTheme()
    let defaultBackground = RenderColor(red: 0, green: 0, blue: 0)
}

struct RenderFramePlan {
    let defaultBackground: RenderColor
}

struct TerminalDimensions: Equatable {
    let columns: Int
    let rows: Int
}

struct TerminalRenderMetrics: Equatable {
    let cellSize = CGSize(width: 8, height: 16)

    init?(displayScale: CGFloat) {
        guard displayScale > 0 else { return nil }
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

enum TerminalInputKey {
    case returnKey
    case tab
    case backspace
    case escape
    case up
    case down
    case right
    case left
    case home
    case end
    case pageUp
    case pageDown
    case deleteForward
    case letter(Unicode.Scalar)
}

struct TerminalKeyModifiers: OptionSet {
    let rawValue: UInt8

    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

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

@MainActor
final class TerminalPaneSessionController {
    var onPlan: ((RenderFramePlan) -> Void)?
    var onSessionEnded: ((PaneLifecycleResult) -> Void)?
    var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?
    var currentPlan: RenderFramePlan?
    var viewportState: TerminalPaneViewportState
    private(set) var wheelRows: [Int] = []
    private(set) var scrolledTopRows: [Int] = []

    init(viewportState: TerminalPaneViewportState = .init(
        isScrollbarEnabled: true,
        projection: .init(totalRows: 30, topRow: 10, windowRows: 20, isFollowing: false)
    )) {
        self.viewportState = viewportState
    }

    func sendText(_ text: String) {}
    func sendKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {}
    func sendWheel(rows: Int) { wheelRows.append(rows) }
    func scroll(toTopRow row: Int) { scrolledTopRows.append(row) }
    func setVisible(_ visible: Bool) {}
    func synchronizeState() {}
    func readViewportText() -> String { "" }
    func readFullHistoryText() -> String { "" }
    func readPrimaryHistoryText() -> String { "" }
    func setGridDimensions(_ dimensions: TerminalDimensions) {}
    func tearDown() {}

    func emitViewportState(_ state: TerminalPaneViewportState) {
        viewportState = state
        onViewportStateChange?(state)
    }
}
