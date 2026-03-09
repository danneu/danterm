import Cocoa
import GhosttyKit

class GhosttyApp {
    var app: ghostty_app_t?
    weak var runtime: AppRuntime?

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
            write_clipboard_cb: { userdata, data, location, confirm in
                guard let data = data else { return }
                let str = String(cString: data)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(str, forType: .string)
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

        // Config is copied by ghostty_app_new, we can free our reference
        ghostty_config_free(config)
    }

    deinit {
        if let app = app {
            ghostty_app_free(app)
        }
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
                        // Don't shrink below the app-level minimum set on the window
                        window.minSize = NSSize(
                            width: max(CGFloat(limits.min_width), window.minSize.width),
                            height: max(CGFloat(limits.min_height), window.minSize.height)
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

        default:
            return false
        }
    }
}
