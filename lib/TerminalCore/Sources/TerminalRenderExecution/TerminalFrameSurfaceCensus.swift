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
    /// One buffer's allocated surface, with the pixel extent that explains its size.
    public struct Store: Equatable, Sendable {
        public let bytes: Int
        public let pixelWidth: Int
        public let pixelHeight: Int

        public init(bytes: Int, pixelWidth: Int, pixelHeight: Int) {
            self.bytes = bytes
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
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
}
