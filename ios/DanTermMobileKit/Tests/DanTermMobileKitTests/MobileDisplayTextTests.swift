// Behavioral tests for the display text the phone renders outside the grid: which
// scalars get a presentation stated for them, and which reach UIKit as they arrived.
import DanTermMobileKit
import Testing

private let textSelector = "\u{FE0E}"

@Test("A bare default-text variation base gets the text selector appended")
func defaultTextBaseStatesTextPresentation() {
    // Intent: a single-scalar cluster whose Unicode default is text carries U+FE0E.
    // Why it exists: the phone's UI faces map no glyph for U+2733, so CoreText falls
    //   through to the color emoji face and draws a green tile where the Mac and the
    //   grid draw a flat asterisk.
    // Scenario: a pane titled "✳ build" reaches the status pill.
    #expect(MobileDisplayText(preparing: "\u{2733} build").text == "\u{2733}\(textSelector) build")
}

@Test("An East Asian Wide default-text base is transformed too")
func wideDefaultTextBaseStatesTextPresentation() {
    // Intent: the decision comes from the presentation table, not from a width proxy.
    // Why it exists: U+3297 is Wide and default-text; a width-based rule would skip it.
    #expect(MobileDisplayText(preparing: "\u{3297}").text == "\u{3297}\(textSelector)")
}

@Test("Everything else reaches the label unchanged")
func excludedShapesPassThrough() {
    // Intent: a cluster carrying its own selector, a ZWJ sequence, a default-emoji
    //   scalar, and plain text are not touched.
    let untouched = [
        "\u{2733}\u{FE0F}",
        "\u{2733}\u{FE0E}",
        "\u{1F469}\u{200D}\u{1F4BB}",
        "\u{1F600}",
        "plain title",
        "",
    ]
    for raw in untouched {
        #expect(MobileDisplayText(preparing: raw).text == raw)
    }
}
