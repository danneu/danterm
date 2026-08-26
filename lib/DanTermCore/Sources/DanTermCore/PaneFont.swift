// The font one pane renders at, as one value. Only the request lives here:
// resolving a family name against the installed faces is a side effect the app
// performs before the answer reaches the model, and turning the request into
// concrete glyph metrics belongs to the render layer.

import DanTermProtocol

/// The font a pane renders at: the pane's effective point size and the family
/// the app has verified is installed.
///
/// One value rather than two fields because every consumer needs both together.
/// A pane rebuilds its metrics once per font it is handed, so a size and a
/// family that travel apart cost two rebuilds for one visible change, and a
/// type that stores them apart can hold a pair no producer ever derived.
struct PaneFont: Equatable, Sendable {
  /// The verified-installed family, or nil for the system monospace face. The raw
  /// name from config never reaches rendering; only a canonical resolved family may.
  let family: String?

  /// The point size the pane renders at, after its own zoom steps.
  let size: Double

  init(family: String? = nil, size: Double = DanTermConfig.default.resolvedFontSize) {
    self.family = family
    self.size = size
  }
}
