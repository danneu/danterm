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

/// Describes whether runtime scheduling is live and how many owners remain in each category.
struct AppRuntimeSchedulingSnapshot: Equatable {
    /// Separates normal scheduling from the permanent post-termination state.
    enum State: Equatable {
        case active
        case shutdown
    }

    let state: State
    let ownerCounts: [AppRuntimeSchedulingCategory: Int]

    static let shutdown = AppRuntimeSchedulingSnapshot(state: .shutdown, ownerCounts: [:])
}

/// Owns cancellation and callback admission so application shutdown is terminal and observable.
@MainActor
final class AppRuntimeSchedulingLifecycle {
    /// Couples one census entry to the mechanism that retires its concrete owner.
    private struct Owner {
        let category: AppRuntimeSchedulingCategory
        let cancel: () -> Void
    }

    private var state = AppRuntimeSchedulingSnapshot.State.active
    private var owners: [AppRuntimeSchedulingToken: Owner] = [:]

    /// Cheap hot-path gate: `snapshot` walks the owner census, so per-delivery and
    /// per-reconcile guards read this instead.
    var isActive: Bool { state == .active }

    /// Returns a handle-free census suitable for termination assertions and diagnostics.
    var snapshot: AppRuntimeSchedulingSnapshot {
        AppRuntimeSchedulingSnapshot(
            state: state,
            ownerCounts: owners.values.reduce(into: [:]) { counts, owner in
                counts[owner.category, default: 0] += 1
            }
        )
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

    /// Gates a repeating callback without retiring its owner registration.
    @discardableResult
    func runRepeating(_ token: AppRuntimeSchedulingToken, action: () -> Void) -> Bool {
        guard state == .active, owners[token] != nil else { return false }
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
