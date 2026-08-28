// Proves the alerts-popover age refresh owns one fixed-window scheduled callback
// only while the popover is open, without waiting for the production interval.
import Foundation
import DanTermProtocol
import Testing
@testable import DanTerm

/// Drives the runtime's alert-age scheduling seam with deterministic callbacks.
@MainActor
struct AppRuntimeAlertAgeRefreshTests {
    @Test("open alert ages keep one refresh until the popover closes")
    func openAlertAgesKeepOneRefreshUntilClose() {
        let scheduler = RecordingAlertAgeRefreshScheduler()
        var model = AppModel(groups: [])
        model.alertsPopoverOpen = true
        let runtime = makeRuntime(model: model, scheduler: scheduler)
        defer { runtime.shutdown() }
        runtime.caches.alertsPopover = desiredAlertsPopover(
            in: runtime.model,
            now: Date(timeIntervalSince1970: 0))

        // The light-checkpoint window also reports as a `.timer`, and a send opens it, so
        // every census assertion below is a delta rather than an absolute count.
        func armedTimers() -> Int {
            runtime.schedulingLifecycle.captureOwnerCensus()[.timer] ?? 0
        }
        let beforeRefresh = armedTimers()

        runtime.reconcileAlertAgeRefresh()
        #expect(scheduler.scheduleCount == 1)
        #expect(armedTimers() == beforeRefresh + 1)

        runtime.send(.appBecameActive)
        #expect(scheduler.scheduleCount == 1, "an unrelated reconcile must not postpone the refresh")
        let withRefresh = armedTimers()

        scheduler.fire()
        #expect(runtime.sentMessages.contains { msg in
            if case .alertsAgeRefreshTick = msg { return true }
            return false
        }, "a fired refresh must enter through the clock message")
        #expect(scheduler.scheduleCount == 2, "a fired refresh must leave one successor")
        #expect(armedTimers() == withRefresh)

        runtime.send(.alertsPopoverClosed)
        #expect(scheduler.cancelCount == 1)
        #expect(armedTimers() == withRefresh - 1)
    }
}

/// Records the message boundary while preserving the real reducer and reconcile path.
@MainActor
private final class ObservingAlertAgeRuntime: AppRuntime {
    private(set) var sentMessages: [Msg] = []

    override func send(_ msg: Msg) {
        sentMessages.append(msg)
        super.send(msg)
    }
}

@MainActor
private final class RecordingAlertAgeRefreshScheduler {
    private var handler: (() -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(_ handler: @escaping () -> Void) -> () -> Void {
        scheduleCount += 1
        self.handler = handler
        return { [weak self] in
            self?.cancelCount += 1
            self?.handler = nil
        }
    }

    func fire() {
        let handler = handler
        self.handler = nil
        handler?()
    }
}

@MainActor
private func makeRuntime(
    model: AppModel,
    scheduler: RecordingAlertAgeRefreshScheduler
) -> ObservingAlertAgeRuntime {
    let instance = TemporaryInstancePaths()
    let now = Date(timeIntervalSince1970: 0)
    return ObservingAlertAgeRuntime(
        ports: RecordingAppRuntimePorts().value,
        dialogSurfaces: RecordingDialogSurfaces().value,
        instancePaths: instance.paths,
        configStore: DanTermConfigStore(url: instance.absentConfigURL),
        coreEnv: CoreEnv(
            newId: { UUID() },
            now: { now },
            homeDirectory: { "/tmp" },
            instanceIdentity: { DanTermInstanceIdentity(bundleIdentifier: "dt.alert-age-tests") }),
        alertAgeRefreshScheduler: scheduler.schedule,
        initialModel: model,
        startsApplicationServices: false,
        applicationActive: true)
}
