// NSView host for Ghostty surfaces and terminal input forwarding.

import Cocoa
import GhosttyKit

class SurfaceBridge {
    weak var view: TerminalView?
    var paneId: PaneId?
    init() {}
    init(view: TerminalView) { self.view = view }

    deinit {
        #if DEBUG
        print("[bridge] SurfaceBridge deallocated (paneId: \(paneId?.rawValue.uuidString.prefix(5) ?? "nil"))")
        #endif
    }
}

class TerminalView: NSView, NSTextInputClient {
    let ghosttyApp: GhosttyApp
    var surface: ghostty_surface_t?
    let bridge: SurfaceBridge
    private var bridgeRetain: Unmanaged<SurfaceBridge>?
    weak var runtime: AppRuntime?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    // Scrollbar support: updated synchronously from ghostty action callbacks.
    weak var scrollDelegate: ScrollableTerminalView?

    // Back-pointer to the wrapper currently hosting this terminal. Weak: the wrapper owns us.
    weak var paneWrapper: PaneWrapperView?

    /// Whether the surface has a text selection; drives the context menu's Copy item.
    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    var cellSize: NSSize = .zero {
        didSet { scrollDelegate?.scrollbarStateDidChange() }
    }

    var scrollbarState: (total: UInt64, offset: UInt64, len: UInt64)? {
        didSet { scrollDelegate?.scrollbarStateDidChange() }
    }

    var scrollbarEnabled: Bool = true {
        didSet { scrollDelegate?.scrollbarConfigDidChange() }
    }

    override var acceptsFirstResponder: Bool { true }

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
            if let paneId = bridge.paneId {
                runtime?.send(.paneBecameFirstResponder(paneId: paneId))
            }
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
        "copy_to_clipboard".withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Paste from the clipboard via ghostty's binding action.
    @objc func pasteClipboard(_ sender: Any?) {
        guard let surface = surface else { return }
        "paste_from_clipboard".withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
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
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Accumulate text from interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            // We got text from the input system — send key events with text
            for text in texts {
                sendKeyEvent(action, event: event, text: text)
            }
        } else {
            // No text — send key event without text.
            // Filter out PUA function key characters (arrow keys, etc.) — libghostty
            // handles these via keycode, not text.
            let text: String? = {
                guard let chars = event.characters,
                      chars.count == 1,
                      let scalar = chars.unicodeScalars.first
                else { return event.characters }
                // PUA range = function keys (arrows, F1-F12, etc.) — let libghostty
                // handle via keycode
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
                // Control characters — let libghostty handle ctrl encoding
                if scalar.value < 0x20 {
                    return event.characters(byApplyingModifiers:
                        event.modifierFlags.subtracting(.control))
                }
                return chars
            }()
            sendKeyEvent(action, event: event, text: text)
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
        text: String?,
        composing: Bool = false
    ) {
        guard let surface = surface else { return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
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
