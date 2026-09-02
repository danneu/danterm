// What one swapchain costs the process, derived from the buffers it holds.
// Nothing here counts events: the value is built at read time by asking each
// live store for its own kernel-reported size, so no create or release path
// can leave it stale. It carries no identity of its own -- the caller names
// which pane or view the swapchain belongs to (research/41 T1).
import Foundation

/// The live IOSurface cost of one frame rotation, one entry per buffer.
///
/// A count that is the buffers themselves, not a configured depth: a chain
/// that failed to build every buffer it asked for must not report the size it
/// wanted.
public struct TerminalFrameSurfaceCensus: Equatable, Sendable {
    /// What the kernel says about one buffer's pages, restated without the
    /// IOSurface vocabulary so a reader of this census needs no framework.
    ///
    /// `unknown` is the refused read, kept distinct from `nonVolatile` because a
    /// surface whose state could not be read must never be summed as one whose
    /// pages are charged to the process (research/41 D4, and the
    /// measurement-discipline rule that zero stays distinguishable from
    /// unmeasured).
    public enum Purgeability: String, Equatable, Sendable {
        case nonVolatile
        case volatile
        case empty
        case unknown
    }

    /// One buffer's allocated surface, with the pixel extent that explains its size.
    public struct Store: Equatable, Sendable {
        public let bytes: Int
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Read when the census is read, never remembered: purgeability is the
        /// kernel's fact about the pages, and a stored copy would go stale the
        /// moment the kernel discarded them.
        public let purgeability: Purgeability

        public init(
            bytes: Int,
            pixelWidth: Int,
            pixelHeight: Int,
            purgeability: Purgeability = .nonVolatile
        ) {
            self.bytes = bytes
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.purgeability = purgeability
        }
    }

    public let stores: [Store]

    public init(stores: [Store]) {
        self.stores = stores
    }

    /// The sum every caller wants; kept derived so it cannot disagree with `stores`.
    public var bytes: Int {
        stores.reduce(0) { $0 + $1.bytes }
    }

    /// The bytes the process is still charged for. A volatile store keeps its
    /// mapped size -- which is what `bytes` reports and what a `vmmap` line sums
    /// -- and loses only its resident pages, so this is the figure a footprint
    /// reading can be reconciled against (research/41 D2).
    public var nonVolatileBytes: Int {
        stores.reduce(0) { $0 + ($1.purgeability == .volatile ? 0 : $1.bytes) }
    }

    /// How many buffers are in each state, so an aggregate can carry its counts.
    public func storeCount(_ purgeability: Purgeability) -> Int {
        stores.count(where: { $0.purgeability == purgeability })
    }
}
