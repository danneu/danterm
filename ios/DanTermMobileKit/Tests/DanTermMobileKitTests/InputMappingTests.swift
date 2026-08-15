// Behavioral tests for mapping phone input into owner-side D8 intent.
import DanTermMobileKit
import DanTermProtocol
import Testing

@Test("Plain typing and paste keep the two text paths distinct")
func textPathsStayDistinct() {
    var mapper = MobileInputMapper()
    #expect(mapper.text("hello") == .send(.events([.text("hello")])))
    #expect(mapper.paste("hello") == .send(.text("hello")))
}

@Test("The accessory row maps named keys and a latching Ctrl modifier")
func accessoryRowMapping() {
    let cases: [(MobileAccessoryKey, MobileInputAction, MobileInputAction)] = [
        (.escape, .send(.events([.key(.named(.escape), [])])), .send(.events([.key(.named(.escape), .ctrl)]))),
        (.tab, .send(.events([.key(.named(.tab), [])])), .send(.events([.key(.named(.tab), .ctrl)]))),
        (.up, .send(.events([.key(.named(.up), [])])), .send(.events([.key(.named(.up), .ctrl)]))),
        (.down, .send(.events([.key(.named(.down), [])])), .send(.events([.key(.named(.down), .ctrl)]))),
        (.left, .send(.events([.key(.named(.left), [])])), .send(.events([.key(.named(.left), .ctrl)]))),
        (.right, .send(.events([.key(.named(.right), [])])), .send(.events([.key(.named(.right), .ctrl)]))),
        (.pipe, .send(.events([.text("|")])), .send(.events([.key(.character("|"), .ctrl)]))),
        (.tilde, .send(.events([.text("~")])), .send(.events([.key(.character("~"), .ctrl)]))),
        (.slash, .send(.events([.text("/")])), .send(.events([.key(.character("/"), .ctrl)]))),
    ]
    for (key, plain, controlled) in cases {
        var plainMapper = MobileInputMapper()
        #expect(plainMapper.accessory(key) == plain)

        var controlledMapper = MobileInputMapper()
        #expect(controlledMapper.accessory(.control) == nil)
        #expect(controlledMapper.isControlLatched)
        #expect(controlledMapper.accessory(key) == controlled)
        #expect(controlledMapper.accessory(.control) == nil)
        #expect(controlledMapper.isControlLatched == false)
    }
}

@Test("Hardware character chords carry modifiers while plain characters stay text")
func hardwareKeyboardMapping() {
    var mapper = MobileInputMapper()
    #expect(mapper.hardwareCharacter("a", modifiers: []) == .send(.events([.text("a")])))
    #expect(mapper.hardwareCharacter("c", modifiers: [.ctrl]) == .send(.events([
        .key(.character("c"), .ctrl),
    ])))
    #expect(mapper.hardwareKey(.enter, modifiers: [.shift]) == .send(.events([
        .key(.named(.enter), .shift),
    ])))
}

@Test("Scroll stays local on primary screen and becomes wheel intent on alternate screen")
func scrollPolicyUsesReplicatedScreenState() {
    var mapper = MobileInputMapper()
    #expect(mapper.scroll(.up, column: 3, row: 4, alternateScreen: false) == .scrollViewport(-1))
    #expect(mapper.scroll(.down, column: 3, row: 4, alternateScreen: true) == .send(.events([
        .wheel(.down, column: 3, row: 4),
    ])))
}
