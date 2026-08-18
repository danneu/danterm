// Runtime-owned scheduled work census and the terminal callback gate used at app shutdown.
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
