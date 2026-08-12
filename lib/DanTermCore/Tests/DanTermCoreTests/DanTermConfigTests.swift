// Formatting tests for the core's presentation of shared config values.
import Testing

@testable import DanTermCore

struct DanTermConfigTests {
    @Test("font size text omits an unnecessary decimal point")
    func fontSizeText() {
        #expect(configFontSizeText(13) == "13")
        #expect(configFontSizeText(13.5) == "13.5")
    }
}
