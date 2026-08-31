// Typed settings shared by the app and CLI through DanTerm's versioned JSON config.

/// Defines whether pane alerts clear on focus or require an explicit command.
public enum AlertClearMode: String, Equatable, Sendable {
    case focus   // auto-clear alerts when pane gains focus (default)
    case manual  // require explicit Cmd+. (tab) or Cmd+Shift+. (pane) to clear
}

/// Selects which physical macOS Option key sends terminal Alt instead of native text.
public enum OptionAsAlt: String, Equatable, Sendable {
    /// The left Option key sends terminal Alt; the right key keeps native handling.
    case left
    /// The right Option key sends terminal Alt; the left key keeps native handling.
    case right
    /// Either physical Option key sends terminal Alt.
    case both
}

/// Names the one tailnet endpoint and stable node identities admitted at app launch.
public struct DanTermTailnetConfig: Equatable, Sendable {
    /// Explicit tailnet IPv4 address and port in `address:port` form.
    public let listen: String
    /// Stable Tailscale node ids allowed to use the remote IPC surface.
    public let admittedNodeIds: [String]
    /// Whether this section is live. False parks an intact section: the settings stay
    /// on disk, and the listener stays closed. Absent in the file means true, so a
    /// config written before the flag existed keeps its meaning.
    public let enable: Bool

    /// Creates the launch-time remote-service contract read from the shared config.
    public init(listen: String, admittedNodeIds: [String], enable: Bool = true) {
        self.listen = listen
        self.admittedNodeIds = admittedNodeIds
        self.enable = enable
    }
}

/// Projects the modeled settings shared by every reader of DanTerm's config file.
public struct DanTermConfig: Equatable, Sendable {
    /// Explicit local theme, or nil when the catalog-backed default applies.
    public var defaultTheme: String? = nil
    /// Theme applied to panes during SSH/remote sessions.
    public var remoteTheme: String = "Purplepeter"
    /// Explicit terminal font family, or nil when system monospace applies.
    public var fontFamily: String? = nil
    /// Explicit terminal font size, or nil when the engine default applies.
    public var fontSize: Double? = nil
    /// When alerts are cleared: on pane focus (.focus) or only via Cmd+./Cmd+Shift+. (.manual).
    public var alertClearMode: AlertClearMode = .focus
    /// Whether finishing a mouse selection copies it to the clipboard. Defaults on,
    /// matching the behavior DanTerm had while it ran on libghostty.
    public var copyOnSelect: Bool = true
    /// Physical Option key policy, or nil when macOS keeps native text handling.
    public var optionAsAlt: OptionAsAlt? = nil
    /// Whether locally spawned panes receive a supported LANG when no locale is inherited.
    public var localeFallback: Bool = true
    /// Tailnet remote-service settings, or nil when the listener is disabled.
    public var tailnet: DanTermTailnetConfig? = nil
    /// Valid explicit shortcut replacements committed by the application boundary.
    public var keybindingOverrides: KeybindingOverrides = .empty

    /// Stable settings used when the config file omits a modeled value.
    public static let `default` = DanTermConfig()

    /// Font size used when the config does not provide a finite value.
    public static let defaultFontSize: Double = 13

    /// Bounds every configured terminal font size to a renderable base value.
    public static let fontSizeRange: ClosedRange<Double> = 8...72

    public var resolvedDefaultTheme: String { defaultTheme ?? "Monokai Remastered" }

    /// Creates a complete modeled settings value while retaining stable defaults.
    public init(
        defaultTheme: String? = nil,
        remoteTheme: String = "Purplepeter",
        fontFamily: String? = nil,
        fontSize: Double? = nil,
        alertClearMode: AlertClearMode = .focus,
        copyOnSelect: Bool = true,
        optionAsAlt: OptionAsAlt? = nil,
        localeFallback: Bool = true,
        tailnet: DanTermTailnetConfig? = nil,
        keybindingOverrides: KeybindingOverrides = .empty
    ) {
        self.defaultTheme = defaultTheme
        self.remoteTheme = remoteTheme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.alertClearMode = alertClearMode
        self.copyOnSelect = copyOnSelect
        self.optionAsAlt = optionAsAlt
        self.localeFallback = localeFallback
        self.tailnet = tailnet
        self.keybindingOverrides = keybindingOverrides
    }

    /// Map a size into `fontSizeRange`. Preferences applies this to what it
    /// commits, so the stored setting is the one panes render at; the read path
    /// below applies it again to a hand-edited file, which no one validated.
    public static func boundedFontSize(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// The configured size mapped into `fontSizeRange`. A hand-edited config can
    /// name any number, including one no renderer can use; nothing downstream
    /// re-checks, so the bound belongs here.
    public var resolvedFontSize: Double {
        guard let fontSize, fontSize.isFinite else { return Self.defaultFontSize }
        return Self.boundedFontSize(fontSize)
    }
}
