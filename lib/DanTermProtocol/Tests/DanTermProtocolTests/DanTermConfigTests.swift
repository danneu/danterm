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
        #expect(config.tailnet == nil)
    }
}
