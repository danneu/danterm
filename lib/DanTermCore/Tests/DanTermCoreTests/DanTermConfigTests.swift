// Typed-default and Preferences-formatting tests for DanTerm's JSON-backed config.
import Testing

@testable import DanTermCore

struct DanTermConfigTests {
    @Test("defaults name resolvable local and remote themes with a 13 point font")
    func defaults() {
        let config = DanTermConfig.default

        #expect(config.resolvedDefaultTheme == "Monokai Remastered")
        #expect(config.remoteTheme == "Purplepeter")
        #expect(config.fontFamily == nil)
        #expect(config.resolvedFontSize == 13)
        #expect(config.alertClearMode == .focus)
    }

    @Test("font size text omits an unnecessary decimal point")
    func fontSizeText() {
        #expect(configFontSizeText(13) == "13")
        #expect(configFontSizeText(13.5) == "13.5")
    }
}
