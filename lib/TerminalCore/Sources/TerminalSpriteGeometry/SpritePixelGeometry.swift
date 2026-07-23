// Shared integer physical-pixel primitives for procedural terminal sprites.

/// Describes one half-open rectangle in cell-local physical pixels so sprite
/// families can share geometry without depending on a drawing framework.
public struct SpritePixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
