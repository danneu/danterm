// Pure copy-on-select config decisions. The app owns the impure Ghostty config
// read and passes the raw enum tag name here so the mouse-up clipboard gate is
// unit-testable without AppKit or GhosttyKit.

/// Whether copy-on-select is effectively enabled for a raw `copy-on-select`
/// config value. Mirrors libghostty's per-surface `.false` gate: nil and
/// unknown values stay enabled, and `clipboard` counts as enabled.
func isCopyOnSelectEnabled(setting: String?) -> Bool {
    (setting ?? "true") != "false"
}
