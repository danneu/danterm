// The single way this app registers a NotificationCenter block observer.
// It holds one function, `observeOnMain`, and nothing else belongs here: the
// point is that every registration in the app reads the same, so no call site
// gets to re-decide which thread its body runs on.

import Foundation

/// Registers a notification observer whose body runs on the main actor.
///
/// `NotificationCenter.addObserver(forName:object:queue:using:)` takes a
/// `@Sendable` block, so a body written inline is nonisolated and nothing ties
/// it to the `queue: .main` argument a few lines above it. This helper makes
/// the delivery queue and the isolation one decision: it hard-wires `.main` and
/// takes a `@MainActor` body, so the guarantee and the code that depends on it
/// are stated together, in one place, instead of being re-promised per site.
///
/// The body runs synchronously. When the notification is posted on the main
/// thread, NotificationCenter invokes it inside `post`, so the observer's work
/// lands in the same pass that produced the notification. Some observers need
/// exactly that -- an override that has to take effect before anything can
/// draw, for instance -- so this must never hop through `Task { @MainActor in }`,
/// which would defer the body by a main-actor turn.
///
/// The body takes no `Notification`. `Notification` is not `Sendable`, so
/// handing one to a main-actor body would be a data race the helper could only
/// hide, and every observer in the app wants the fact that the notification
/// arrived, not its payload. A call site that genuinely needs `userInfo` should
/// extend this function to read what it needs, rather than reopen the question
/// for every other site.
///
/// `center` defaults to `NotificationCenter.default` and is named only by the
/// sites that cannot use it: `NSWorkspace` posts to its own center, and one
/// observer takes an injected center so a test can post to it. Those are the
/// reasons this function takes a center at all -- without it they would each
/// hand-roll the registration and re-decide the delivery queue, which is the
/// one thing this file exists to prevent.
///
/// Callers that pass a center must keep it to remove the token with, because a
/// token is only valid at the center that issued it.
///
/// Returns the observer token. Callers own it and must remove it on teardown,
/// per rule 2 of docs/design/2026-06-09-appkit-lifetime-safety.md.
@MainActor
func observeOnMain(
    _ name: Notification.Name,
    object: Any? = nil,
    center: NotificationCenter = .default,
    using body: @escaping @MainActor () -> Void
) -> NSObjectProtocol {
    center.addObserver(forName: name, object: object, queue: .main) { _ in
        // `assumeIsolated` reads back the guarantee `queue: .main` just made,
        // rather than hopping and giving up the same pass.
        MainActor.assumeIsolated {
            body()
        }
    }
}
