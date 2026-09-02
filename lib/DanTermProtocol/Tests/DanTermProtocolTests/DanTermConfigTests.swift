// Behavioral proofs for the typed settings shared across DanTerm processes.
import Testing

@testable import DanTermProtocol

struct DanTermConfigTests {
    @Test("defaults name resolvable local and remote themes with a 13 point font")
    func defaults() {
        let config = DanTermConfig.default

        #expect(config.resolvedDefaultTheme == "Monokai Remastered")
        #expect(config.remoteTheme == "Purplepeter")
        #expect(config.fontFamily == nil)
        #expect(config.resolvedFontSize == 13)
        #expect(config.alertClearMode == .focus)
        #expect(config.copyOnSelect)
        #expect(config.optionAsAlt == nil)
        #expect(config.tailnet == nil)
        #expect(config.keybindingOverrides == .empty)
        #expect(config.resolvedUnfocusedPaneOpacity == 1)
    }

    @Test("every unfocused-pane opacity a config file can name resolves inside the range",
          arguments: [
            (Double?.none, 1.0),
            (0.7, 0.7),
            (0.1, 0.1),
            (1.0, 1.0),
            (0.0, 0.1),
            (-4.0, 0.1),
            (2.5, 1.0),
            (Double.nan, 1.0),
            (Double.infinity, 1.0),
          ])
    func unfocusedPaneOpacityResolvesInsideRange(configured: Double?, resolved: Double) {
        // Intent: the read path answers with a usable opacity for any number a
        //   hand-edited config can hold, including none at all.
        // Why it exists: nothing downstream re-checks the value -- the projection
        //   subtracts it from 1 and the view writes the result to a layer -- so a
        //   0 or a NaN here would make a pane vanish or stop compositing.
        var config = DanTermConfig.default
        config.unfocusedPaneOpacity = configured

        #expect(config.resolvedUnfocusedPaneOpacity == resolved)
    }
}
