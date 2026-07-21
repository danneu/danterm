// NSView host for Ghostty surfaces and terminal input forwarding.

import Cocoa
import DanTermProtocol
import GhosttyKit

class SurfaceBridge {
    weak var view: TerminalView?
    init() {}
    init(view: TerminalView) { self.view = view }

    deinit {
        #if DEBUG
        print("[bridge] SurfaceBridge deallocated")
        #endif
    }
}

class TerminalView: NSView, NSTextInputClient, TerminalSession {
    let ghosttyApp: GhosttyApp
    var surface: ghostty_surface_t?
    let bridge: SurfaceBridge
    private var bridgeRetain: Unmanaged<SurfaceBridge>?
    private let callbackGate = TerminalSessionCallbackGate()
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var linkPreview: LinkPreviewView?

    // Back-pointer to the wrapper currently hosting this terminal. Weak: the wrapper owns us.
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
            scrollbarEnabled: scrollbarEnabled,
            cellHeight: cellSize.height,
            scrollPosition: scrollbarState.map {
                TerminalScrollPosition(total: $0.total, offset: $0.offset, length: $0.len)
            }
        )
    }

    /// Whether the surface has a text selection; drives the context menu's Copy item.
    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    var cellSize: NSSize = .zero {
        didSet { emitState() }
    }

    var scrollbarState: (total: UInt64, offset: UInt64, len: UInt64)? {
        didSet { emitState() }
    }

    var scrollbarEnabled: Bool = true {
        didSet { emitState() }
    }

    /// Effective copy-on-select for this surface. Seeded at creation and kept in
    /// sync from surface-target config-change actions, because libghostty exposes
    /// no per-surface effective-config getter.
    var copyOnSelectEnabled: Bool = true

    override var acceptsFirstResponder: Bool { true }

    private func emitState() {
        callbackGate.emit(state)
    }

    /// Accept a typed product event from the Ghostty callback adapter.
    func emit(_ event: TerminalSessionEvent) {
        callbackGate.emit(event)
    }

    // MARK: - Init

    init(
        ghosttyApp: GhosttyApp,
        workingDirectory: String? = nil,
        command: String? = nil,
        launchCommand: String? = nil,
        waitAfterCommand: Bool = true,
        restoreCommandBehavior: RestoreCommandBehavior = .execute,
        envVars: [(String, String)] = []
    ) {
        self.ghosttyApp = ghosttyApp
        self.bridge = SurfaceBridge() // set after super.init
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.bridge.view = self

        guard let app = ghosttyApp.app else { return }

        // Create surface config
        var config = ghostty_surface_config_new()
        let retain = Unmanaged.passRetained(bridge)
        config.userdata = retain.toOpaque()
        bridgeRetain = retain
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // Helper to create the surface with current config state
        func createSurface() {
            guard let newSurface = ghostty_surface_new(app, &config) else {
                print("ghostty_surface_new failed")
                return
            }
            self.surface = newSurface
        }

        // Direct Ghostty commands use `launchCommand` and must not also seed
        // shell input. Without `launchCommand`, `command` becomes initial shell
        // input for restore and IPC --cmd launches.
        // Hazard: Ghostty exec's `launchCommand` via bash in the pane's
        // exec-time environment, which is the bare launchd env (the app no
        // longer snapshots a login env). A bare command name resolves against
        // that minimal PATH, so any future non-nil caller must pass an absolute
        // path, not a bare name. Today every caller passes nil.
        let initialInput = launchCommand == nil
            ? restoreInitialInput(for: command, behavior: restoreCommandBehavior)
            : nil

        // Build env var structs (strdup'd so pointers stay alive through createSurface)
        var envVarStructs = envVars.map { (key, value) in
            ghostty_env_var_s(key: strdup(key), value: strdup(value))
        }
        defer {
            for ev in envVarStructs {
                free(UnsafeMutablePointer(mutating: ev.key))
                free(UnsafeMutablePointer(mutating: ev.value))
            }
        }

        // Wire env vars into config
        envVarStructs.withUnsafeMutableBufferPointer { buf in
            config.env_vars = buf.baseAddress
            config.env_var_count = buf.count
        }

        // Apply optional strings, then create the surface while the C string
        // pointers are still alive.
        func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            if let string {
                return string.withCString { body($0) }
            }
            return body(nil)
        }

        withOptionalCString(workingDirectory) { dirPtr in
            withOptionalCString(initialInput) { inputPtr in
                withOptionalCString(launchCommand) { commandPtr in
                    config.working_directory = dirPtr
                    config.initial_input = inputPtr
                    if let commandPtr {
                        config.command = commandPtr
                        config.wait_after_command = waitAfterCommand
                    }
                    createSurface()
                }
            }
        }

        // Surface creation failed — release the bridge retain immediately
        if surface == nil {
            bridgeRetain?.release()
            bridgeRetain = nil
        }

        // Register for file/URL/string drag-and-drop
        registerForDraggedTypes([.fileURL, .URL, .string])

        // Set up tracking area for mouse events
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func closeSurface() {
        callbackGate.tearDown()
        guard let surface = surface else { return }
        self.surface = nil
        // Defer surface free to next main-actor turn to avoid re-entrant
        // callback loops during free (Ghostty and cmux both do this).
        // Bridge stays alive until after free completes so any in-flight
        // callbacks can safely dereference it and find bridge.view == nil.
        let retain = bridgeRetain
        bridgeRetain = nil
        Task { @MainActor in
            ghostty_surface_free(surface)
            retain?.release()
        }
    }

    deinit {
        closeSurface()
    }

    // MARK: - View Lifecycle

    // Single source of truth for pushing content scale plus backing-pixel size
    // to Ghostty. Degenerate sizes are skipped because 0x0 corrupts terminal
    // state and divide-by-zero scale can clobber Retina rendering.
    private func syncSurfaceGeometry(logicalSize: NSSize) {
        guard let surface else { return }
        let backingSize = convertToBacking(logicalSize)
        guard let geometry = surfaceGeometry(logicalSize: logicalSize, backingSize: backingSize) else { return }

        ghostty_surface_set_content_scale(surface, geometry.xScale, geometry.yScale)
        ghostty_surface_set_size(surface, geometry.pixelWidth, geometry.pixelHeight)
    }

    // NSView: seed display ID and initial geometry after the view enters a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let window else { return }

        if let screen = window.screen {
            ghostty_surface_set_display_id(surface, screen.displayID)
        }

        syncSurfaceGeometry(logicalSize: frame.size)
    }

    // NSView: resync layer scale and Ghostty geometry after backing-store changes.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard surface != nil else { return }

        // The view is layer-hosting: Ghostty assigns its IOSurfaceLayer to
        // .layer. AppKit only suppresses implicit actions for layer-backed
        // views, so disable animations around the scale write.
        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        syncSurfaceGeometry(logicalSize: frame.size)
    }

    // NSView: push new layout geometry to Ghostty after AppKit changes the frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceGeometry(logicalSize: newSize)
        linkPreview?.layoutPill(in: bounds)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, true)
            callbackGate.emit(.becameFirstResponder)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        reassertCopyOnSelect()
    }

    /// Guarantee the system clipboard holds the finalized mouse selection when
    /// copy-on-select is enabled. This is idempotent: the common path where
    /// libghostty already wrote the same text does not bump pasteboard history.
    private func reassertCopyOnSelect() {
        guard let surface = surface else { return }
        guard copyOnSelectEnabled, ghostty_surface_has_selection(surface) else { return }
        guard let selection = readSelectionText(surface), selection.isEmpty == false else { return }

        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) != selection else { return }
        pasteboard.clearContents()
        pasteboard.setString(selection, forType: .string)
    }

    /// Read and decode the current selection while keeping libghostty buffer
    /// ownership in one place.
    private func readSelectionText(_ surface: ghostty_surface_t) -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return decodeGhosttyText(text)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
        if !consumed { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
        if !consumed { super.rightMouseUp(with: event) }
    }

    // NSView: returns the right-click context menu. Called by AppKit from
    // super.rightMouseDown (normal right-click) or before mouseDown (ctrl+click).
    // This handles the ghostty event handshake; the menu itself comes from the
    // hosting wrapper's unified builder.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }

        switch event.type {
        case .rightMouseDown:
            break

        case .leftMouseDown:
            // Ctrl+click: AppKit calls menu(for:) BEFORE mouse events.
            // If mouse capture is active, return nil so the terminal app gets the event.
            if !event.modifierFlags.contains(.control) { return nil }
            if ghostty_surface_mouse_captured(surface) { return nil }
            // Send synthetic right-button press since AppKit won't deliver mouseDown
            // when we return a menu.
            let mods = Self.ghosttyMods(event.modifierFlags)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)

        default:
            return nil
        }

        // Unified pane context menu: one builder (PaneWrapperView.makePaneMenu)
        // serves surface right-click, the "..." toolbar button, and the
        // drag-handle right-click. Only this entry point includes clipboard items.
        return paneWrapper?.makePaneMenu(includeClipboard: true)
    }

    // MARK: - Clipboard Actions (targets of makePaneMenu's clipboard items)

    /// Copy the current selection to the clipboard via ghostty's binding action.
    @objc func copySelection(_ sender: Any?) {
        guard let surface = surface else { return }
        sendBindingAction(surface, "copy_to_clipboard")
    }

    /// Paste from the clipboard via ghostty's binding action.
    @objc func pasteClipboard(_ sender: Any?) {
        guard let surface = surface else { return }
        sendBindingAction(surface, "paste_from_clipboard")
    }

    // NSView: re-establish mouse position after a prior mouseExited sent -1/-1.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
    }

    // NSView: tell libghostty the pointer left the viewport so it clears hover state.
    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
        linkPreview?.pointerMoved(to: pos, in: bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }

        let mods = ghostty_input_scroll_mods_t(
            event.hasPreciseScrollingDeltas ? 1 : 0
        )
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            interpretKeyEvents([event])
            return
        }

        var translationMods = event.modifierFlags
        if Self.hasExplicitMacOSOptionAsAlt(ghosttyApp.config) {
            let translationModsGhostty = Self.eventModifierFlags(
                ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags))
            )

            // Preserve hidden event bits that AppKit uses for some dead keys while applying
            // only Ghostty's translated modifier state to the IME event.
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translationModsGhostty.contains(flag) {
                    translationMods.insert(flag)
                } else {
                    translationMods.remove(flag)
                }
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Accumulate text from interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        interpretKeyEvents([translationEvent])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            // We got text from the input system — send key events with text
            for text in texts {
                sendKeyEvent(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // No text — send key event without text.
            // Filter out PUA function key characters (arrow keys, etc.) — libghostty
            // handles these via keycode, not text.
            let text: String? = {
                guard let chars = translationEvent.characters,
                      chars.count == 1,
                      let scalar = chars.unicodeScalars.first
                else { return translationEvent.characters }
                // PUA range = function keys (arrows, F1-F12, etc.) — let libghostty
                // handle via keycode
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
                // Control characters — let libghostty handle ctrl encoding
                if scalar.value < 0x20 {
                    return translationEvent.characters(byApplyingModifiers:
                        translationEvent.modifierFlags.subtracting(.control))
                }
                return chars
            }()
            sendKeyEvent(
                action,
                event: event,
                translationEvent: translationEvent,
                text: text,
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = Self.ghosttyMods(event.modifierFlags)
        let action: ghostty_input_action_e =
            (mods.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        sendKeyEvent(action, event: event, text: nil)
    }

    private func sendKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String?,
        composing: Bool = false
    ) {
        guard let surface = surface else { return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = Self.ghosttyMods(
            (translationEvent ?? event).modifierFlags.subtracting([.control, .command])
        )
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = composing

        // Unshifted codepoint
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        if let text = text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    // MARK: - Mouse Cursor

    func updateMouseCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL:
            NSCursor.openHand.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            NSCursor.resizeUpDown.set()
        default:
            NSCursor.arrow.set()
        }
    }

    /// Show or hide libghostty's Cmd-hover link URL preview for this surface.
    func setHoverUrl(_ url: String?) {
        guard let url, !url.isEmpty else {
            linkPreview?.hide()
            return
        }

        let preview = ensureLinkPreview()
        preview.show(url: url)
        preview.layoutPill(in: bounds)

        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            preview.pointerMoved(to: point, in: bounds)
        }
    }

    private func ensureLinkPreview() -> LinkPreviewView {
        if let linkPreview { return linkPreview }

        let preview = LinkPreviewView()
        addSubview(preview)
        linkPreview = preview
        return preview
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        return NSRange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        // Update preedit in ghostty
        if let surface = surface {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            if let surface = surface {
                ghostty_surface_preedit(surface, nil, 0)
            }
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = window else { return .zero }
        // Return a rect near the top-left of the view for IME positioning
        let viewRect = NSRect(x: 0, y: frame.height - 20, width: 0, height: 20)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear preedit
        unmarkText()

        // If we're in a keyDown event, accumulate text
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Otherwise, send text directly
        guard let surface = surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
    }

    override func doCommand(by selector: Selector) {
        // Prevent NSBeep for unhandled commands
    }

    // MARK: - Focus Border

    func setFocusBorder(_ focused: Bool, hasBell: Bool) {
        guard let layer = layer else { return }
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

    // MARK: - Helpers

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func hasExplicitMacOSOptionAsAlt(_ config: ghostty_config_t?) -> Bool {
        guard let config else { return false }
        var value: UnsafePointer<Int8>?
        let key = "macos-option-as-alt"
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count))
    }
}

// MARK: - TerminalSession

extension TerminalView {
    func sendText(_ text: String) {
        guard text.isEmpty == false, let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    func sendInputText(_ text: String) {
        guard text.isEmpty == false, let surface else { return }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = 0
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = 0
        event.composing = false
        text.withCString { ptr in
            event.text = ptr
            _ = ghostty_surface_key(surface, event)
        }
    }

    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {
        guard let surface else { return }
        let (keycode, codepoint) = Self.macKeyMapping(for: key)
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = keycode
        event.mods = Self.ghosttyMods(modifiers)
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = codepoint
        event.composing = false
        event.text = nil
        _ = ghostty_surface_key(surface, event)
        event.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, event)
    }

    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func setDisplayID(_ displayID: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func setScrollbarEnabled(_ enabled: Bool) {
        scrollbarEnabled = enabled
    }

    func refreshBackingProperties() {
        viewDidChangeBackingProperties()
    }

    func applyTheme(_ themeName: String) {
        guard let surface, let config = ghosttyApp.loadConfigWithTheme(themeName) else { return }
        ghostty_surface_update_config(surface, config)
        ghostty_config_free(config)
    }

    func clearTheme() {
        guard let surface else { return }
        ghosttyApp.reloadConfig(surface: surface, soft: false)
    }

    func startSearch() {
        guard let surface else { return }
        sendBindingAction(surface, "start_search")
    }

    func setSearchNeedle(_ needle: String) {
        guard let surface else { return }
        sendBindingAction(surface, "search:\(needle)")
    }

    func navigateSearch(_ direction: SearchDirection) {
        guard let surface else { return }
        let value = direction == .next ? "next" : "previous"
        sendBindingAction(surface, "navigate_search:\(value)")
    }

    func endSearch() {
        guard let surface else { return }
        sendBindingAction(surface, "end_search")
    }

    func readViewportText() -> String? {
        readSurfaceRegion(GHOSTTY_POINT_VIEWPORT)
    }

    func readFullHistoryText() -> String? {
        readSurfaceRegion(GHOSTTY_POINT_SCREEN)
    }

    func readPrimaryHistoryText() -> String? {
        readFullHistoryText()
    }

    func scroll(toRow row: Int) {
        guard let surface else { return }
        sendBindingAction(surface, "scroll_to_row:\(row)")
    }

    func copySelection() {
        copySelection(nil)
    }

    func pasteClipboard() {
        pasteClipboard(nil)
    }

    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    func tearDown() {
        closeSurface()
    }

    private func readSurfaceRegion(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let topLeft = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return decodeGhosttyText(text)
    }

    private static func macKeyMapping(for key: KeyName) -> (UInt32, UInt32) {
        switch key {
        case .named(let name):
            switch name {
            case .enter:  return (36, 0)
            case .tab:    return (48, 0)
            case .bspace: return (51, 0)
            case .escape: return (53, 0)
            case .up:     return (126, 0)
            case .down:   return (125, 0)
            case .left:   return (123, 0)
            case .right:  return (124, 0)
            case .home:   return (115, 0)
            case .end:    return (119, 0)
            case .pgUp:   return (116, 0)
            case .pgDn:   return (121, 0)
            case .delete: return (117, 0)
            case .f1:  return (122, 0)
            case .f2:  return (120, 0)
            case .f3:  return (99, 0)
            case .f4:  return (118, 0)
            case .f5:  return (96, 0)
            case .f6:  return (97, 0)
            case .f7:  return (98, 0)
            case .f8:  return (100, 0)
            case .f9:  return (101, 0)
            case .f10: return (109, 0)
            case .f11: return (103, 0)
            case .f12: return (111, 0)
            }
        case .letter(let character):
            let keycode = letterKeycodes[character] ?? 0
            return (keycode, UInt32(character.asciiValue ?? 0))
        }
    }

    private static let letterKeycodes: [Character: UInt32] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
        "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
    ]

    private static func ghosttyMods(_ modifiers: KeyMods) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if modifiers.contains(.ctrl) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if modifiers.contains(.alt) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if modifiers.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        return ghostty_input_mods_e(raw)
    }
}

// MARK: - Drag & Drop

extension TerminalView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        let accepted: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]
        if Set(types).isDisjoint(with: accepted) { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // Extract pasteboard values into plain strings for the pure helper
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let filePaths = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        let urlString = pb.string(forType: .URL)
        let plainString = pb.string(forType: .string)

        guard let content = DragDropInput.buildContent(filePaths: filePaths, urlString: urlString, plainString: plainString),
              let surface = surface else { return false }
        content.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(content.utf8.count))
        }
        return true
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? UInt32 ?? 0
    }
}
