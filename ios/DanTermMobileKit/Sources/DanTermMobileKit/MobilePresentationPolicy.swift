// Pure surface ownership and retry policy for damage-gated phone presentation.

/// Names the only work the UIKit shell may perform for the current presentation state.
public enum MobilePresentationAction<SurfaceId: Equatable & Sendable>: Equatable, Sendable {
    case render(surfaceId: SurfaceId)
    case publish(surfaceId: SurfaceId)
    case retryPublish(surfaceId: SurfaceId)
}

/// Keeps rendering detached from the attached surface and makes idle scheduling decidable.
public struct MobilePresentationPolicy<SurfaceId: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var attachedSurfaceId: SurfaceId?

    private let surfaceIds: [SurfaceId]
    private var hasDamage = false
    private var renderedSurfaceId: SurfaceId?
    private var retrySurfaceId: SurfaceId?

    /// Creates an idle policy over the shell-owned reusable surface identities.
    public init(surfaceIds: [SurfaceId]) {
        precondition(surfaceIds.count >= 2, "presentation requires at least two surfaces")
        for index in surfaceIds.indices {
            precondition(
                surfaceIds[..<index].contains(surfaceIds[index]) == false,
                "presentation surface identities must be unique"
            )
        }
        self.surfaceIds = surfaceIds
    }

    /// Reports whether the shell must schedule a display-link tick.
    public var needsTick: Bool { nextAction != nil }

    /// Names the next allowed operation without mutating presentation state.
    public var nextAction: MobilePresentationAction<SurfaceId>? {
        if let retrySurfaceId { return .retryPublish(surfaceId: retrySurfaceId) }
        if let renderedSurfaceId { return .publish(surfaceId: renderedSurfaceId) }
        guard hasDamage,
              let detached = surfaceIds.first(where: { $0 != attachedSurfaceId })
        else { return nil }
        return .render(surfaceId: detached)
    }

    /// Coalesces any amount of terminal damage into one pending render.
    public mutating func noteDamage() {
        hasDamage = true
    }

    /// Moves a detached surface from render ownership to publish ownership.
    public mutating func didRender(surfaceId: SurfaceId) {
        guard nextAction == .render(surfaceId: surfaceId) else { return }
        hasDamage = false
        renderedSurfaceId = surfaceId
    }

    /// Retains a rendered surface for a later publish retry.
    public mutating func didCoalescePublish(surfaceId: SurfaceId) {
        guard renderedSurfaceId == surfaceId else { return }
        renderedSurfaceId = nil
        retrySurfaceId = surfaceId
    }

    /// Attaches a published surface and returns to idle unless newer damage is pending.
    public mutating func didPublish(surfaceId: SurfaceId) {
        guard renderedSurfaceId == surfaceId || retrySurfaceId == surfaceId else { return }
        renderedSurfaceId = nil
        retrySurfaceId = nil
        attachedSurfaceId = surfaceId
    }
}
