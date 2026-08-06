// Typed settings projected from DanTerm's versioned JSON configuration document.
import Foundation

enum AlertClearMode: String, Equatable {
    case focus   // auto-clear alerts when pane gains focus (default)
    case manual  // require explicit Cmd+. (tab) or Cmd+Shift+. (pane) to clear
}

struct DanTermConfig: Equatable {
    /// Explicit local theme, or nil when the catalog-backed default applies.
    var defaultTheme: String? = nil
    /// Theme applied to panes during SSH/remote sessions.
    var remoteTheme: String = "Purplepeter"
    /// Explicit terminal font family, or nil when system monospace applies.
    var fontFamily: String? = nil
    /// Explicit terminal font size, or nil when the engine default applies.
    var fontSize: Double? = nil
    /// When alerts are cleared: on pane focus (.focus) or only via Cmd+./Cmd+Shift+. (.manual).
    var alertClearMode: AlertClearMode = .focus
    /// Whether finishing a mouse selection copies it to the clipboard. Defaults on,
    /// matching the behavior DanTerm had while it ran on libghostty.
    var copyOnSelect: Bool = true

    static let `default` = DanTermConfig()

    var resolvedDefaultTheme: String { defaultTheme ?? "Monokai Remastered" }
    var resolvedFontSize: Double { fontSize ?? 13 }
}
