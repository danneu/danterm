// AppKit host for one Swift terminal session: geometry, drawing, text input,
// and the stable DanTerm TerminalSession boundary live here and nowhere else.
import Cocoa
import DanTermProtocol
import PaneLifecycle
import TerminalPaneSession
import TerminalRenderExecution
import TerminalRenderPlanning

/// Adapts one headless Swift terminal controller into DanTerm's AppKit pane contract.
final class SwiftTerminalSessionView: NSView, NSTextInputClient, TerminalSession {
    private let controller: TerminalPaneSessionController
    private let callbackGate = TerminalSessionCallbackGate()
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var currentMetrics: TerminalRenderMetrics?
    private var publishedFrame: (plan: RenderFramePlan, metrics: TerminalRenderMetrics)?
    private var isTornDown = false

    weak var paneWrapper: PaneWrapperView?

    var hostView: NSView { self }
    var onEvent: ((TerminalSessionEvent) -> Void)? {
        get { callbackGate.onEvent }
        set { callbackGate.onEvent = newValue }
    }
    weak var stateObserver: (any TerminalSessionStateObserver)? {
        get { callbackGate.stateObserver }
        set { callbackGate.stateObserver = newValue }
    }
    var state: TerminalSessionState {
        TerminalSessionState(
            scrollbarEnabled: false,
            cellHeight: currentMetrics?.cellSize.height ?? 0,
            scrollPosition: nil
        )
    }
    var hasSelection: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// Installs the controller's sole end callback while preserving backend evidence
    /// work ahead of the app's close request and any resulting pane teardown.
    init(
        controller: TerminalPaneSessionController,
        onSessionEnded: ((PaneLifecycleResult) -> Void)? = nil
    ) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.cgColor(RenderTheme.dark.defaultBackground)

        controller.onPlan = { [weak self] plan in
            self?.publish(plan)
        }
        controller.onSessionEnded = { [weak self] result in
            onSessionEnded?(result)
            self?.callbackGate.emit(.closeRequested)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    isolated deinit {
        tearDown()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = publishedFrame
        let background = frame?.plan.defaultBackground ?? RenderTheme.dark.defaultBackground
        context.setFillColor(Self.cgColor(background))
        context.fill(dirtyRect)
        if let frame {
            drawRenderFrame(frame.plan, metrics: frame.metrics, in: context)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeGeometry()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { callbackGate.emit(.becameFirstResponder) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) == false else { return }
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])
        if let texts = keyTextAccumulator, texts.isEmpty == false,
           texts.allSatisfy(Self.isCommittedTerminalText) {
            for text in texts { controller.sendText(text) }
            return
        }
        guard let key = Self.terminalKey(for: event) else { return }
        controller.sendKey(key, modifiers: Self.terminalModifiers(event.modifierFlags))
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: state.cellHeight)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }
        unmarkText()
        guard Self.isCommittedTerminalText(text) else { return }
        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
        } else {
            controller.sendText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        // Fixed terminal keys are encoded after interpretKeyEvents returns.
    }

    func sendText(_ text: String) {
        controller.sendText(text)
    }

    func sendInputText(_ text: String) {
        controller.sendText(text)
    }

    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {
        guard let key = Self.terminalKey(for: key) else { return }
        controller.sendKey(key, modifiers: Self.terminalModifiers(modifiers))
    }

    func setFocused(_ focused: Bool) {}

    func setVisible(_ visible: Bool) {
        controller.setVisible(visible)
    }

    func setDisplayID(_ displayID: UInt32) {}
    func setScrollbarEnabled(_ enabled: Bool) {}

    func refreshBackingProperties() {
        synchronizeGeometry()
    }

    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func startSearch() {}
    func setSearchNeedle(_ needle: String) {}
    func navigateSearch(_ direction: SearchDirection) {}
    func endSearch() {}

    func readViewportText() -> String? {
        controller.synchronizeState()
        return controller.readViewportText()
    }

    func readFullHistoryText() -> String? {
        controller.synchronizeState()
        return controller.readFullHistoryText()
    }

    func readPrimaryHistoryText() -> String? {
        controller.synchronizeState()
        return controller.readPrimaryHistoryText()
    }

    func scroll(toRow row: Int) {}
    func copySelection() {}
    func pasteClipboard() {}

    func requestClose() {
        callbackGate.emit(.closeRequested)
    }

    func setFocusBorder(_ focused: Bool, hasBell: Bool) {
        guard let layer else { return }
        if focused {
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemGreen.cgColor
        } else if hasBell {
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemRed.cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }

    func tearDown() {
        guard isTornDown == false else { return }
        isTornDown = true
        callbackGate.tearDown()
        controller.tearDown()
    }

    private func synchronizeGeometry() {
        guard isTornDown == false,
              bounds.width > 0, bounds.height > 0,
              let scale = window?.backingScaleFactor,
              let metrics = TerminalRenderMetrics(displayScale: scale),
              let dimensions = terminalGridDimensions(
                  size: .init(width: Double(bounds.width), height: Double(bounds.height)),
                  cellSize: .init(
                      width: Double(metrics.cellSize.width),
                      height: Double(metrics.cellSize.height)
                  )
              )
        else {
            return
        }

        let metricsChanged = metrics != currentMetrics
        currentMetrics = metrics
        controller.setGridDimensions(dimensions)
        if metricsChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scale
            CATransaction.commit()
            if let plan = controller.currentPlan {
                publishedFrame = (plan, metrics)
            }
            callbackGate.emit(state)
            needsDisplay = true
        }
    }

    private func publish(_ plan: RenderFramePlan) {
        guard isTornDown == false, let metrics = currentMetrics else { return }
        #if DANTERM_TERMINAL_CHARACTERIZATION
        recordTerminalCharacterizationPlanDelivery()
        #endif
        publishedFrame = (plan, metrics)
        needsDisplay = true
    }

    private static func cgColor(_ color: RenderColor) -> CGColor {
        CGColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    private static func isCommittedTerminalText(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private static func terminalKey(for event: NSEvent) -> TerminalInputKey? {
        switch event.keyCode {
        case 36: return .returnKey
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 124: return .right
        case 123: return .left
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .deleteForward
        default:
            guard event.modifierFlags.contains(.control),
                  let text = event.charactersIgnoringModifiers?.lowercased(),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first,
                  scalar.isASCII, CharacterSet.letters.contains(scalar)
            else {
                return nil
            }
            return .letter(scalar)
        }
    }

    private static func terminalKey(for key: KeyName) -> TerminalInputKey? {
        switch key {
        case .letter(let character):
            guard let scalar = character.lowercased().unicodeScalars.first else { return nil }
            return .letter(scalar)
        case .named(let name):
            switch name {
            case .enter: return .returnKey
            case .tab: return .tab
            case .bspace: return .backspace
            case .escape: return .escape
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            case .home: return .home
            case .end: return .end
            case .pgUp: return .pageUp
            case .pgDn: return .pageDown
            case .delete: return .deleteForward
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                return nil
            }
        }
    }

    private static func terminalModifiers(_ flags: NSEvent.ModifierFlags) -> TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func terminalModifiers(_ modifiers: KeyMods) -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        if modifiers.contains(.ctrl) { result.insert(.control) }
        if modifiers.contains(.alt) { result.insert(.option) }
        return result
    }
}
