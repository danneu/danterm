// Tests for the pure copy-on-select config decision used by the app's
// per-session mouse-up clipboard reassertion gate.
import Testing

@testable import DanTermCore

@Suite struct CopyOnSelectTests {
    @Test("copy-on-select true is enabled")
    func trueSettingIsEnabled() {
        // Intent: the explicit `true` config value enables DanTerm's mouse-up
        //   clipboard reassertion.
        // Why it exists: pins the normal macOS copy-on-select path so the app
        //   does not accidentally suppress the default-enabled behavior.
        // Scenario: spec-first config read -- libghostty returns the enum tag
        //   name "true" for a session's effective config.
        #expect(isCopyOnSelectEnabled(setting: "true") == true)
    }

    @Test("copy-on-select clipboard is enabled")
    func clipboardSettingIsEnabled() {
        // Intent: the explicit `clipboard` config value enables DanTerm's
        //   mouse-up clipboard reassertion.
        // Why it exists: pins libghostty's non-false enabled enum case so the
        //   gate does not treat only literal "true" as enabled.
        // Scenario: spec-first config read -- libghostty returns the enum tag
        //   name "clipboard" for a session's effective config.
        #expect(isCopyOnSelectEnabled(setting: "clipboard") == true)
    }

    @Test("copy-on-select false is disabled")
    func falseSettingIsDisabled() {
        // Intent: the explicit `false` config value disables DanTerm's mouse-up
        //   clipboard reassertion.
        // Why it exists: pins that user intent to disable copy-on-select is
        //   honored even though the reassertion is DanTerm-owned.
        // Scenario: spec-first config read -- a session's effective config
        //   resolves `copy-on-select = false`.
        #expect(isCopyOnSelectEnabled(setting: "false") == false)
    }

    @Test("copy-on-select nil defaults enabled")
    func nilSettingDefaultsEnabled() {
        // Intent: an unreadable config value defaults to enabled.
        // Why it exists: pins the macOS default so a failed C config read does
        //   not silently turn copy-on-select off.
        // Scenario: spec-first fallback -- the impure config reader cannot
        //   retrieve `copy-on-select` for a session.
        #expect(isCopyOnSelectEnabled(setting: nil) == true)
    }
}
