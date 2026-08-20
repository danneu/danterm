// Runtime-owned scheduled work census, the terminal callback gate used at app shutdown,
// and the owner type that binds one scheduled handle to its census entry. The concrete
// scheduling policies -- what a timer waits for, when a monitor is installed -- belong to
// the runtime, not here.
import Foundation

/// Names the exhaustive kinds of scheduled ownership that the application runtime may retain.
enum AppRuntimeSchedulingCategory: String, CaseIterable, Hashable {
    case timer
    case debouncer
    case eventMonitor
    case subscription
    case deferredCallback
    case ipcServer
}

/// Identifies one owner registration so a callback captured before shutdown can fail closed.
struct AppRuntimeSchedulingToken: Hashable {
    fileprivate let id = UUID()
}

/// Owns cancellation and callback admission so application shutdown is terminal and observable.
@MainActor
final class AppRuntimeSchedulingLifecycle {
    /// Separates normal scheduling from the permanent post-termination state.
    private enum State: Equatable {
        case active
        case shutdown
    }

    /// Couples one census entry to the mechanism that retires its concrete owner.
    private struct Owner {
        let category: AppRuntimeSchedulingCategory
        let cancel: () -> Void
    }

    private var state = State.active
    private var owners: [AppRuntimeSchedulingToken: Owner] = [:]

    /// Cheap O(1) hot-path gate; per-delivery and per-reconcile guards read this.
    var isActive: Bool { state == .active }

    /// Walks every registered owner to tally a handle-free census. This is the only
    /// window tests have onto runtime ownership: which owners a command armed, and which
    /// ones a close or a shutdown retired. Production never calls it -- it carries no
    /// shutdown state, and hot-path guards read `isActive` instead of paying for the walk.
    func captureOwnerCensus() -> [AppRuntimeSchedulingCategory: Int] {
        owners.values.reduce(into: [:]) { counts, owner in
            counts[owner.category, default: 0] += 1
        }
    }

    /// Admits one cancellable owner only while the runtime remains active.
    func arm(
        _ category: AppRuntimeSchedulingCategory,
        cancel: @escaping () -> Void
    ) -> AppRuntimeSchedulingToken? {
        guard state == .active else { return nil }
        let token = AppRuntimeSchedulingToken()
        owners[token] = Owner(category: category, cancel: cancel)
        return token
    }

    /// Consumes a one-shot callback token before allowing its effect to run.
    @discardableResult
    func run(_ token: AppRuntimeSchedulingToken, action: () -> Void) -> Bool {
        guard state == .active, owners.removeValue(forKey: token) != nil else { return false }
        action()
        return true
    }

    /// Retires one owner early and invokes its concrete cancellation mechanism once.
    func cancel(_ token: AppRuntimeSchedulingToken?) {
        guard let token, let owner = owners.removeValue(forKey: token) else { return }
        owner.cancel()
    }

    /// Enters the permanent shutdown state before cancelling every registered owner.
    func shutdown() {
        guard state == .active else { return }
        state = .shutdown
        let pendingOwners = Array(owners.values)
        owners.removeAll()
        for owner in pendingOwners {
            owner.cancel()
        }
    }
}

/// The gate a scheduled handle calls when it goes off. It consumes the census entry of the
/// arm that produced it and then runs the caller's work, so a handler is free to re-arm.
typealias AppRuntimeScheduledFire = (() -> Void) -> Void

/// Holds one scheduled resource and its census registration as a single value, so a live
/// handle without a census entry -- or a census entry whose handle is gone -- cannot be
/// written.
///
/// While armed, the census entry owns this object: the retire closure it registers captures
/// it strongly, so dropping every other reference cannot separate the entry from the handle.
/// The route back to the census is non-owning, which is what keeps the runtime that owns
/// both out of a cycle.
@MainActor
final class AppRuntimeScheduledOwner<Handle> {
    /// One arm. `generation` is that arm's identity: a fire gate or a retire closure made
    /// by an earlier arm carries an older generation and does nothing.
    private struct Arm {
        let handle: Handle
        let token: AppRuntimeSchedulingToken
        let generation: UInt64
    }

    private weak var lifecycle: AppRuntimeSchedulingLifecycle?
    private let category: AppRuntimeSchedulingCategory
    private let retire: (Handle) -> Void
    private var current: Arm?
    private var lastGeneration: UInt64 = 0

    /// `retire` is the concrete mechanism that ends the handle -- cancel the source, remove
    /// the monitor, close the listener. It never runs on a fire: a handle that went off has
    /// already ended itself.
    init(
        lifecycle: AppRuntimeSchedulingLifecycle,
        category: AppRuntimeSchedulingCategory,
        retire: @escaping (Handle) -> Void
    ) {
        self.lifecycle = lifecycle
        self.category = category
        self.retire = retire
    }

    /// Whether a handle is live right now. This is the same fact as "present in the census",
    /// which is why guards read it instead of testing a separate handle field for nil.
    var isArmed: Bool { current != nil }

    /// The live handle, or nil while unarmed. A caller that has to talk to the resource
    /// mid-arm -- read a listening socket's path, start its accept loop -- reads it here,
    /// so no second field can hold a handle the census has already retired.
    var handle: Handle? { current?.handle }

    /// Retires any previous arm, then builds one handle and registers it. `build` receives
    /// the fire gate for the arm it is building, which the handle's own callback must call.
    /// A lifecycle that has shut down refuses the registration, and the offered handle is
    /// retired at once rather than left running unowned.
    func arm(_ build: (_ fire: @escaping AppRuntimeScheduledFire) -> Handle) {
        cancel()
        lastGeneration += 1
        let generation = lastGeneration
        let handle = build { [weak self] action in
            self?.fire(generation: generation, action: action)
        }
        guard let lifecycle,
              let token = lifecycle.arm(category, cancel: { [self] in
                  retireArm(generation: generation)
              })
        else {
            retire(handle)
            return
        }
        current = Arm(handle: handle, token: token, generation: generation)
    }

    /// Ends the current arm early. Retiring runs through the census so the one registered
    /// closure stays the single route, whether an owner cancels or shutdown sweeps.
    func cancel() {
        guard let current else { return }
        guard let lifecycle else {
            retireArm(generation: current.generation)
            return
        }
        lifecycle.cancel(current.token)
    }

    private func fire(generation: UInt64, action: () -> Void) {
        guard let current, current.generation == generation else { return }
        // The gate that reached us can be owned by the handle itself -- a dispatch source
        // owns its event handler -- so the handle outlives the handler call.
        let firedHandle = current.handle
        self.current = nil
        lifecycle?.run(current.token, action: action)
        withExtendedLifetime(firedHandle) {}
    }

    private func retireArm(generation: UInt64) {
        guard let current, current.generation == generation else { return }
        self.current = nil
        retire(current.handle)
    }
}

extension AppRuntimeScheduledOwner where Handle == DispatchSourceTimer {
    /// The census category is a parameter because a debounce and a coalescing window are
    /// the same mechanism reported under different names.
    convenience init(
        timerIn lifecycle: AppRuntimeSchedulingLifecycle,
        category: AppRuntimeSchedulingCategory = .timer
    ) {
        self.init(lifecycle: lifecycle, category: category, retire: { $0.cancel() })
    }

    /// Arms one main-queue timer that goes off once. Re-arming replaces the pending one.
    func armTimer(
        deadline: DispatchTime,
        leeway: DispatchTimeInterval = .nanoseconds(0),
        handler: @escaping () -> Void
    ) {
        arm { fire in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: deadline, leeway: leeway)
            timer.setEventHandler { fire(handler) }
            timer.resume()
            return timer
        }
    }
}
