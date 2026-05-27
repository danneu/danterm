import Cocoa
import GhosttyKit

class GhosttyApp {
    var app: ghostty_app_t?
    weak var runtime: AppRuntime?
    /// Retained clone of the ghostty config for runtime reads (e.g. scrollbar setting).
    var config: ghostty_config_t?
    /// Coalesces high-volume libghostty wakeups into one main-queue tick per turn.
    let tickCoalescer = TickCoalescer()

    /// Read the scrollbar setting from any config. Returns true unless set to "never".
    static func readScrollbarEnabled(from config: ghostty_config_t?) -> Bool {
        guard let config = config else { return true }
        var v: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return true }
        guard let ptr = v else { return true }
        return String(cString: ptr) != "never"
    }

    /// Whether scrollbar is enabled based on the current app config.
    var scrollbarEnabled: Bool { Self.readScrollbarEnabled(from: config) }

    /// Read a C-string config value from the retained app config.
    /// Only valid for keys whose C export type is a string pointer (e.g. theme, scrollbar).
    func readConfigString(key: String) -> String? {
        guard let config = config else { return nil }
        var v: UnsafePointer<Int8>?
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return nil }
        guard let ptr = v else { return nil }
        return String(cString: ptr)
    }

    /// Read an f32 config value from the retained app config.
    /// Only valid for keys whose C export type is f32 (e.g. font-size).
    func readConfigFloat(key: String) -> Float? {
        guard let config = config else { return nil }
        var v: Float = 0
        guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return nil }
        return v
    }

    /// Read an f32 config value and format it as a display string.
    /// Integer values render without decimals (e.g. "14" not "14.0").
    func readConfigFloatString(key: String) -> String? {
        guard let v = readConfigFloat(key: key) else { return nil }
        return v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(v)
    }

    /// Create a fresh config by loading default files, then layering the DanTerm overlay.
    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        // Layer DanTerm config overlay on top of Ghostty defaults.
        // No recursive file expansion — DanTerm overlay is flat key=value only.
        loadDanTermOverlay(into: config)
        ghostty_config_finalize(config)
        return config
    }

    /// Load the DanTerm config overlay file into an existing ghostty config.
    private static func loadDanTermOverlay(into config: ghostty_config_t) {
        let path = DanTermConfigParser.configFilePath()
        guard FileManager.default.fileExists(atPath: path) else { return }
        path.withCString { ghostty_config_load_file(config, $0) }
    }

    /// Return the path to the Ghostty config file (e.g. ~/.config/ghostty/config).
    static func configFilePath() -> String? {
        let gs = ghostty_config_open_path()
        defer { ghostty_string_free(gs) }
        guard let ptr = gs.ptr else { return nil }
        return String(
            bytes: UnsafeRawBufferPointer(start: ptr, count: Int(gs.len)),
            encoding: .utf8
        )
    }

    /// App-level config reload: re-reads config files from disk (or soft-applies the existing config).
    func reloadConfig(soft: Bool = false) {
        guard let app = app else { return }
        if soft {
            guard let config = config else { return }
            ghostty_app_update_config(app, config)
            return
        }
        guard let newConfig = Self.loadConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        ghostty_config_free(newConfig)
    }

    /// Create a config with a specific theme applied.
    /// Loads the theme file directly from the app bundle to override colors.
    func loadConfigWithTheme(_ themeName: String) -> ghostty_config_t? {
        guard let themeURL = Bundle.main.url(
            forResource: themeName, withExtension: nil,
            subdirectory: "ghostty/themes"
        ) else {
            print("[theme] Theme file not found in bundle: \(themeName)")
            return nil
        }
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        Self.loadDanTermOverlay(into: config)
        // Theme overlay applied last so per-pane theme colors take priority
        themeURL.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_finalize(config)
        return config
    }

    /// Surface-level config reload.
    func reloadConfig(surface: ghostty_surface_t, soft: Bool = false) {
        if soft {
            guard let config = config else { return }
            ghostty_surface_update_config(surface, config)
            return
        }
        guard let newConfig = Self.loadConfig() else { return }
        ghostty_surface_update_config(surface, newConfig)
        ghostty_config_free(newConfig)
    }

    init() {
        // Create and load config
        guard let config = Self.loadConfig() else {
            print("ghostty_config_new failed")
            return
        }

        // Set up runtime config with C function pointer callbacks.
        // The userdata is a pointer to this GhosttyApp instance.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata = userdata else { return }
                let ghosttyApp = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                guard ghosttyApp.tickCoalescer.noteWakeup() else { return }
                DispatchQueue.main.async {
                    ghosttyApp.tickCoalescer.runTick {
                        guard let app = ghosttyApp.app else { return }
                        ghostty_app_tick(app)
                    }
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
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.requestQuit)
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

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                reloadConfig(soft: soft)
                // Bump the model generation so themed panes re-layer over the new base config.
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.ghosttyConfigReloaded)
                }
            case GHOSTTY_TARGET_SURFACE:
                if let surface = Self.targetSurface(target) {
                    reloadConfig(surface: surface, soft: soft)
                    DispatchQueue.main.async { [weak self] in
                        self?.runtime?.send(.ghosttyConfigReloaded)
                    }
                }
            default:
                break
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            let changeConfig = action.action.config_change.config
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                let newConfig = ghostty_config_clone(changeConfig)
                if let old = self.config { ghostty_config_free(old) }
                self.config = newConfig
                // Fan out scrollbar setting to all surfaces
                let enabled = Self.readScrollbarEnabled(from: newConfig)
                // Read Ghostty prefs from the freshly-cloned config for the prefs panel.
                let prefs = GhosttyPrefs(
                    theme: self.readConfigString(key: "theme"),
                    fontSize: self.readConfigFloatString(key: "font-size")
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    for (_, view) in self.runtime?.surfaces ?? [:] {
                        view.scrollbarEnabled = enabled
                    }
                    self.runtime?.send(.ghosttyPrefsRefreshed(prefs))
                }

            case GHOSTTY_TARGET_SURFACE:
                // Update only the addressed surface
                if let surface = Self.targetSurface(target),
                   let bridge = Self.surfaceBridge(from: surface),
                   let view = bridge.view {
                    let enabled = Self.readScrollbarEnabled(from: changeConfig)
                    view.scrollbarEnabled = enabled
                }

            default:
                break
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
