// The presentation surfaces a runtime is given for its four dialog windows --
// MRU switcher, confirmation, notice, preferences -- plus the live AppKit
// implementations that own the panels.
//
// A reconcile pass drives a surface and never builds or orders a window itself,
// so a runtime handed recording surfaces cannot put anything on screen whatever
// hosts it is also given. What a panel draws does not belong here: this file
// owns when a panel exists and where it sits, not its content.
import Cocoa

/// The part of a dialog surface that does not name its projection type, so the
/// four surfaces can be walked as one list for session teardown and runtime
/// shutdown.
@MainActor
protocol DialogSurfaceLifecycle: AnyObject {
    /// Late-binds the runtime a dialog sends its answers back to. Called once
    /// from `AppRuntime.init`, before any message can reach a pass, so no pass
    /// can apply a projection to a surface that cannot build its window yet.
    /// Held weakly: the runtime owns the surfaces, so a strong hold back would
    /// be a cycle across the boundary the object-lifetime rules guard.
    func bind(runtime: AppRuntime)
    /// Takes the dialog off screen, keeping whatever window it has for reuse.
    func hide()
    /// Takes the dialog off screen and gives up the window it was reusing.
    func discard()
}

/// A surface that presents by rendering alone. `apply` puts the projection on
/// screen and is called on every change, so a surface whose size or position
/// follows its content re-computes both from here.
@MainActor
protocol OverlaySurface<Projection>: DialogSurfaceLifecycle {
    associatedtype Projection: Equatable
    func apply(_ projection: Projection)
}

/// A surface that also comes forward and takes key focus when it opens. `raise`
/// runs only on the closed-to-open transition, so a refresh while the dialog is
/// open cannot pull first responder off the pane underneath it.
///
/// The MRU switcher deliberately does not conform: it must never become key, and
/// having no `raise` at all is how that is kept true rather than remembered.
@MainActor
protocol DialogSurface<Projection>: OverlaySurface {
    func raise()
}

/// The dialog surfaces one runtime was given. A runtime holds exactly these and
/// has no other route to a window, which is what makes "presents nothing" a
/// property of what the runtime was handed rather than a check any pass makes.
@MainActor
struct DialogSurfaces {
    let switcher: any OverlaySurface<SwitcherProjection>
    let confirmation: any DialogSurface<ConfirmationProjection>
    let notice: any DialogSurface<NoticeProjection>
    let preferences: any DialogSurface<PreferencesPanelProjection>

    /// Every surface as its projection-free half, for the two runtime-wide
    /// sweeps: session teardown discards, runtime shutdown hides.
    var all: [any DialogSurfaceLifecycle] { [switcher, confirmation, notice, preferences] }

    /// The AppKit surfaces the shipping app runs on.
    static func live() -> DialogSurfaces {
        DialogSurfaces(
            switcher: LiveSwitcherSurface(),
            confirmation: LiveConfirmationSurface(),
            notice: LiveNoticeSurface(),
            preferences: LivePreferencesSurface()
        )
    }
}

/// Live MRU switcher overlay. The panel is built with the surface rather than on
/// first use: the cost is a first frame, and paying it at app launch is what
/// keeps the first cmd-shift-i instant.
@MainActor
final class LiveSwitcherSurface: OverlaySurface {
    private weak var runtime: AppRuntime?
    private let panel = SwitcherPanel()

    func bind(runtime: AppRuntime) { self.runtime = runtime }

    /// Renders and re-positions on every change: the row count sets the panel
    /// height, so a cycle step that changes the list also changes where the
    /// overlay belongs on screen.
    func apply(_ projection: SwitcherProjection) {
        panel.apply(rows: projection.rows, cursorIndex: projection.cursorIndex)
        panel.centerOnScreen(of: runtime?.window)
        panel.orderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    /// The overlay outlives a session: it holds no session state, and rebuilding
    /// it would pay the first-frame cost again on the next cycle.
    func discard() { hide() }
}

/// Live confirmation panel. Created on first use, then reused: a refresh while
/// the panel is open must not re-center a panel the user dragged.
@MainActor
final class LiveConfirmationSurface: DialogSurface {
    private weak var runtime: AppRuntime?
    private var panel: ConfirmationPanel?

    func bind(runtime: AppRuntime) { self.runtime = runtime }

    func apply(_ projection: ConfirmationProjection) {
        guard let runtime else { return }  // the runtime is gone; build nothing
        let panel = self.panel ?? ConfirmationPanel(runtime: runtime)
        self.panel = panel
        panel.configure(projection)
    }

    func raise() {
        panel?.center(on: runtime?.window)
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    func discard() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Live notice panel. One panel serves the whole FIFO, so it survives between
/// queued notices and only the closed-to-open transition centers and raises it.
@MainActor
final class LiveNoticeSurface: DialogSurface {
    private weak var runtime: AppRuntime?
    private var panel: NoticePanel?

    func bind(runtime: AppRuntime) { self.runtime = runtime }

    func apply(_ projection: NoticeProjection) {
        guard let runtime else { return }  // the runtime is gone; build nothing
        let panel = self.panel ?? NoticePanel(runtime: runtime)
        self.panel = panel
        panel.configure(projection)
    }

    func raise() {
        panel?.center(on: runtime?.window)
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    func discard() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Live preferences panel. Unlike the notice and confirmation panels it never
/// centers -- it keeps wherever the user left it -- and it is a normal window,
/// so discarding closes it rather than only ordering it out.
@MainActor
final class LivePreferencesSurface: DialogSurface {
    private weak var runtime: AppRuntime?
    private var panel: PreferencesPanel?

    func bind(runtime: AppRuntime) { self.runtime = runtime }

    func apply(_ projection: PreferencesPanelProjection) {
        guard let runtime else { return }  // the runtime is gone; build nothing
        let panel = self.panel ?? PreferencesPanel(runtime: runtime)
        self.panel = panel
        panel.apply(projection)
    }

    func raise() { panel?.makeKeyAndOrderFront(nil) }

    func hide() { panel?.orderOut(nil) }

    func discard() {
        panel?.close()
        panel = nil
    }
}
