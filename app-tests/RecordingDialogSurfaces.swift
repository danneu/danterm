// Dialog surfaces for headless app-tests: they record what a pass asked for
// instead of putting a window on screen.
//
// Every app-test runtime is built with these, which is what keeps `just test`
// from filling the developer's desktop with panels -- the reconcile sweep runs
// on every send(), so every app-test that sends is a presentation site.
@testable import DanTerm

/// Records the apply/raise/hide/discard sequence one dialog pass drove, in
/// order, so a test can tell "refreshed while open" from "opened again".
@MainActor
final class RecordingDialogSurface<Projection: Equatable>: DialogSurface {
    enum Event: Equatable {
        case apply(Projection)
        case raise
        case hide
        case discard
    }

    private(set) var events: [Event] = []
    /// How many times the runtime bound itself. Proves the surface was in place
    /// before the runtime could send anything.
    private(set) var bindCount = 0

    /// The projections applied, oldest first.
    var applied: [Projection] {
        events.compactMap { event in
            guard case .apply(let projection) = event else { return nil }
            return projection
        }
    }

    var raiseCount: Int { events.filter { $0 == .raise }.count }
    var hideCount: Int { events.filter { $0 == .hide }.count }
    var discardCount: Int { events.filter { $0 == .discard }.count }

    func bind(runtime: AppRuntime) { bindCount += 1 }
    func apply(_ projection: Projection) { events.append(.apply(projection)) }
    func raise() { events.append(.raise) }
    func hide() { events.append(.hide) }
    func discard() { events.append(.discard) }
}

/// The four recording surfaces one test runtime was given, kept together so a
/// test can read any of them after handing `value` to the runtime.
@MainActor
final class RecordingDialogSurfaces {
    let switcher = RecordingDialogSurface<SwitcherProjection>()
    let confirmation = RecordingDialogSurface<ConfirmationProjection>()
    let notice = RecordingDialogSurface<NoticeProjection>()
    let preferences = RecordingDialogSurface<PreferencesPanelProjection>()

    var value: DialogSurfaces {
        DialogSurfaces(
            switcher: switcher,
            confirmation: confirmation,
            notice: notice,
            preferences: preferences
        )
    }
}
