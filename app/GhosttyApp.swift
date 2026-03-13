import Cocoa
import GhosttyKit

class GhosttyApp {
    var app: ghostty_app_t?
    weak var runtime: AppRuntime?
    /// Retained clone of the ghostty config for runtime reads (e.g. scrollbar setting).
    var config: ghostty_config_t?

    /// Whether scrollbar is enabled based on ghostty config.
    var scrollbarEnabled: Bool {
        guard let config = config else { return true }
        var v: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return true }
        guard let ptr = v else { return true }
        return String(cString: ptr) != "never"
    }

    init() {
        // Create and load config
        guard let config = ghostty_config_new() else {
            print("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        // Set up runtime config with C function pointer callbacks.
        // The userdata is a pointer to this GhosttyApp instance.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata = userdata else { return }
                let ghosttyApp = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    guard let app = ghosttyApp.app else { return }
                    ghostty_app_tick(app)
                }
            },
            action_cb: { app, target, action in
                guard let app = app else { return false }
                guard let ud = ghostty_app_userdata(app) else { return false }
                let ghosttyApp = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
                return ghosttyApp.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                guard let userdata = userdata else { return }
                let bridge = Unmanaged<SurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = bridge.view, let surface = view.surface else { return }
                let str = NSPasteboard.general.string(forType: .string) ?? ""
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                guard let userdata = userdata else { return }
                let bridge = Unmanaged<SurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = bridge.view, let surface = view.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, str, state, true)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                guard let content = content, len > 0 else { return }
                // Find the text/plain entry in the content array
                for i in 0..<len {
                    let item = content[i]
                    guard let mime = item.mime, String(cString: mime) == "text/plain" else { continue }
                    guard let data = item.data else { continue }
                    let str = String(cString: data)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(str, forType: .string)
                    break
                }
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata = userdata else { return }
                let bridge = Unmanaged<SurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = bridge.view, let paneId = bridge.paneId else { return }
                DispatchQueue.main.async {
                    view.runtime?.send(.surfaceClosed(paneId: paneId))
                }
            }
        )

        // Create the ghostty app
        guard let newApp = ghostty_app_new(&runtime, config) else {
            print("ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }
        self.app = newApp

        // Clone config for runtime reads (e.g. scrollbar setting), then free the original
        self.config = ghostty_config_clone(config)
        ghostty_config_free(config)
    }

    deinit {
        if let config = config { ghostty_config_free(config) }
        if let app = app { ghostty_app_free(app) }
    }

    /// Resolve a ghostty_surface_t to its SurfaceBridge via userdata.
    static func surfaceBridge(from surface: ghostty_surface_t) -> SurfaceBridge? {
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfaceBridge>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Extract the surface from a target, returning nil if not a surface target.
    private static func targetSurface(_ target: ghostty_target_s) -> ghostty_surface_t? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        return target.target.surface
    }

    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface) {
                DispatchQueue.main.async { [weak view = bridge.view] in
                    view?.needsDisplay = true
                }
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId,
               let titlePtr = action.action.set_title.title {
                let title = String(cString: titlePtr)
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.surfaceTitle(paneId: paneId, title: title))
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId,
               let pwdPtr = action.action.pwd.pwd {
                let cwd = String(cString: pwdPtr)
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.surfaceCwd(paneId: paneId, cwd: cwd))
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface) {
                DispatchQueue.main.async { [weak view = bridge.view] in
                    view?.updateMouseCursor(action.action.mouse_shape)
                }
            }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface) {
                DispatchQueue.main.async { [weak view = bridge.view] in
                    view?.window?.close()
                }
            }
            return true

        case GHOSTTY_ACTION_SIZE_LIMIT:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface) {
                let limits = action.action.size_limit
                DispatchQueue.main.async { [weak view = bridge.view] in
                    guard let window = view?.window else { return }
                    if limits.min_width > 0 && limits.min_height > 0 {
                        // Use the reported limits but never go below the app-level floor
                        window.minSize = NSSize(
                            width: max(CGFloat(limits.min_width), AppDelegate.minWindowWidth),
                            height: max(CGFloat(limits.min_height), AppDelegate.minWindowHeight)
                        )
                    }
                    if limits.max_width > 0 && limits.max_height > 0 {
                        window.maxSize = NSSize(
                            width: CGFloat(limits.max_width),
                            height: CGFloat(limits.max_height)
                        )
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface) {
                let size = action.action.initial_size
                DispatchQueue.main.async { [weak view = bridge.view] in
                    guard let window = view?.window else { return }
                    let newSize = NSSize(width: CGFloat(size.width), height: CGFloat(size.height))
                    window.setContentSize(newSize)
                    window.center()
                }
            }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            // Synchronous — action callback is already on main thread via wakeup_cb.
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let view = bridge.view {
                let backingSize = NSSize(
                    width: Double(action.action.cell_size.width),
                    height: Double(action.action.cell_size.height)
                )
                view.cellSize = view.convertFromBacking(backingSize)
            }
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            // Synchronous — no async dispatch to avoid thumb lag during scrollbar drag.
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let view = bridge.view {
                let sb = action.action.scrollbar
                view.scrollbarState = (total: sb.total, offset: sb.offset, len: sb.len)
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            let newConfig = ghostty_config_clone(action.action.config_change.config)
            if let old = self.config { ghostty_config_free(old) }
            self.config = newConfig
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.configDidChange)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.surfaceBell(paneId: paneId))
                }
            }
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                let raw = action.action.progress_report
                let progress: UInt8? = raw.progress >= 0 ? UInt8(raw.progress) : nil
                let state: ProgressState?
                switch raw.state {
                case GHOSTTY_PROGRESS_STATE_REMOVE:        state = nil
                case GHOSTTY_PROGRESS_STATE_SET:           state = .set(percent: progress ?? 0)
                case GHOSTTY_PROGRESS_STATE_ERROR:         state = .error(percent: progress)
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:         state = .pause(percent: progress)
                default:                                   state = nil
                }
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.surfaceProgress(paneId: paneId, state: state))
                }
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                let notif = action.action.desktop_notification
                let title = String(cString: notif.title)
                let body = String(cString: notif.body)
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.desktopNotification(paneId: paneId, title: title, body: body))
                }
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                let needle: String
                if let ptr = action.action.start_search.needle {
                    needle = String(cString: ptr)
                } else {
                    needle = ""
                }
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.ghosttyStartSearch(paneId: paneId, needle: needle))
                }
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                let raw = action.action.search_total.total
                let total: Int? = raw >= 0 ? Int(raw) : nil
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.ghosttySearchTotal(paneId: paneId, total: total))
                }
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            if let surface = Self.targetSurface(target),
               let bridge = Self.surfaceBridge(from: surface),
               let paneId = bridge.paneId {
                let raw = action.action.search_selected.selected
                let selected: Int? = raw >= 0 ? Int(raw) : nil
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.ghosttySearchSelected(paneId: paneId, selected: selected))
                }
            }
            return true

        default:
            return false
        }
    }
}
