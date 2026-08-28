// The split proportion stored by the model. Persistence and view projection
// keep their number formats, but neither can observe an invalid proportion.
import Foundation

/// Makes a finite proportion from zero through one the only split ratio the
/// model, reducer, and layout pipeline can carry.
struct SplitRatio: Equatable, Sendable, ExpressibleByFloatLiteral {
    let value: CGFloat

    /// Rejects invalid external input instead of choosing a nearby split that
    /// the caller did not request.
    init?(_ value: CGFloat) {
        guard value.isFinite, (0...1).contains(value) else { return nil }
        self.value = value
    }

    /// Keeps source-level literals concise at split construction sites. A bad
    /// literal is a programmer error, while runtime input uses the failable init.
    init(floatLiteral value: Double) {
        guard let admitted = SplitRatio(CGFloat(value)) else {
            preconditionFailure("split ratio literal must be finite and inside 0...1")
        }
        self = admitted
    }
}
