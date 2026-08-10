// Neutral baked terminal defaults shared by protocol replies and presentation layers.

/// Carries an eight-bit sRGB color without introducing renderer or platform policy.
public struct TerminalRGBColor: Equatable, Sendable {
    /// Red component in eight-bit sRGB.
    public let red: UInt8

    /// Green component in eight-bit sRGB.
    public let green: UInt8

    /// Blue component in eight-bit sRGB.
    public let blue: UInt8

    /// Creates a neutral color value that consumers can convert at their own boundary.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Keeps the protocol-visible defaults paired so terminal and renderer consumers cannot drift.
public struct TerminalDefaultColors: Equatable, Sendable {
    /// Default foreground reported by OSC 10 and used for semantic default text.
    public let foreground: TerminalRGBColor

    /// Default background reported by OSC 11 and used for semantic default fills.
    public let background: TerminalRGBColor

    /// The one baked default pair used while configurable themes remain out of scope.
    public static let baked = TerminalDefaultColors(
        foreground: TerminalRGBColor(red: 229, green: 229, blue: 229),
        background: TerminalRGBColor(red: 0, green: 0, blue: 0)
    )

    /// Creates a complete pair so a consumer cannot provide only one default.
    public init(foreground: TerminalRGBColor, background: TerminalRGBColor) {
        self.foreground = foreground
        self.background = background
    }
}
