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

@Test("Backspace from the software keyboard sends the named bspace key")
func softwareBackspaceSendsNamedKey() {
    // Intent: a backspace from the keyboard reaches the pane as the same named key a
    //   hardware backspace does, with no modifiers.
    // Why it exists: the old composer swallowed it -- the text view rejected every change
    //   and an empty replacement string carried nothing to forward -- so the phone could
    //   type but never correct a typo.
    var mapper = MobileInputMapper()
    #expect(mapper.deleteBackward() == .send(.events([.key(.named(.bspace), [])])))
}

@Test("The accessory row maps named keys and a one-shot Ctrl modifier")
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
        #expect(plainMapper.latchedModifiers == [])

        var controlledMapper = MobileInputMapper()
        #expect(controlledMapper.accessory(.control) == nil)
        #expect(controlledMapper.latchedModifiers == .ctrl)
        #expect(controlledMapper.accessory(key) == controlled)
        #expect(controlledMapper.latchedModifiers == [])
    }
}

@Test("Every accessory key reaches the pane, and only the latch keys stay local")
func everyAccessoryKeyIsMapped() {
    // Intent: the mapper answers for every case of the row's vocabulary -- traffic for
    //   each key, and only the latch for a latch key.
    // Why it exists: the bar builds its row from `MobileAccessoryKey.allCases`, so a case
    //   the mapper drops would draw a button that sends nothing.
    for key in MobileAccessoryKey.allCases {
        var mapper = MobileInputMapper()
        let action = mapper.accessory(key)
        if let modifier = MobileInputMapper.latchModifier(for: key) {
            #expect(action == nil)
            #expect(mapper.latchedModifiers == modifier)
        } else {
            #expect(action != nil, "\(key) produced no input")
            #expect(mapper.latchedModifiers == [])
        }
    }
}

@Test("An armed Ctrl latch chords the next key from any source and is consumed by it")
func controlLatchIsOneShotAcrossSources() {
    // Intent: the latch applies to the next key-shaped input whatever produced it -- a
    //   keyboard commit, backspace, or a hardware key -- and that input clears it.
    // Why it exists: the latch used to be read only by the accessory row, so Ctrl-F from
    //   the software keyboard was unreachable.
    var mapper = MobileInputMapper()

    _ = mapper.accessory(.control)
    #expect(mapper.text("f") == .send(.events([.key(.character("f"), .ctrl)])))
    #expect(mapper.latchedModifiers == [])
    #expect(mapper.text("f") == .send(.events([.text("f")])))

    _ = mapper.accessory(.control)
    #expect(mapper.deleteBackward() == .send(.events([.key(.named(.bspace), .ctrl)])))
    #expect(mapper.latchedModifiers == [])

    _ = mapper.accessory(.control)
    #expect(mapper.hardwareKey(.enter, modifiers: [.shift]) == .send(.events([
        .key(.named(.enter), [.shift, .ctrl]),
    ])))
    #expect(mapper.latchedModifiers == [])

    _ = mapper.accessory(.control)
    #expect(mapper.hardwareCharacter("c", modifiers: []) == .send(.events([
        .key(.character("c"), .ctrl),
    ])))
    #expect(mapper.latchedModifiers == [])
}

@Test("A multi-character commit and a paste send their text unchanged and clear the latch")
func multiCharacterCommitAndPasteClearTheLatch() {
    // Intent: input that is not a single key -- an autocorrect or IME commit, a paste --
    //   goes to the wire untouched, and still consumes the latch.
    // Why it exists: a latch that survived a commit it could not chord would chord some
    //   later keystroke the user never aimed it at.
    var mapper = MobileInputMapper()

    _ = mapper.accessory(.control)
    #expect(mapper.text("hello") == .send(.events([.text("hello")])))
    #expect(mapper.latchedModifiers == [])

    _ = mapper.accessory(.control)
    #expect(mapper.paste("hello") == .send(.text("hello")))
    #expect(mapper.latchedModifiers == [])
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
    let mapper = MobileInputMapper()
    #expect(mapper.scroll(toTopRow: 9, alternateScreen: false) == .scrollViewport(.toTopRow(9)))
    #expect(mapper.scroll(toTopRow: 9, alternateScreen: true) == nil)

    #expect(mapper.scroll(byRows: -1, column: 3, row: 4, alternateScreen: false)
        == .scrollViewport(.byRows(-1)))
    #expect(mapper.scroll(byRows: 0, column: 3, row: 4, alternateScreen: true) == nil)
    #expect(mapper.scroll(byRows: -2, column: 3, row: 4, alternateScreen: true) == .send(.events([
        .wheel(.up, column: 3, row: 4),
        .wheel(.up, column: 3, row: 4),
    ])))
}

@Test("A Return commit from the software keyboard is the named enter key")
func softwareReturnSendsNamedEnterKey() {
    // Intent: the software keyboard's Return reaches the pane as `enter`, so the owner
    //   encodes it mode-aware, and not as the literal newline UIKit delivers.
    // Why it exists: UIKit hands Return to `UIKeyInput` as `insertText("\n")`, which fell
    //   through the ordinary-text path and put a bare LF on the wire. A TUI composer reads
    //   LF as "insert a line", so typing a prompt and tapping Return never submitted it.
    var mapper = MobileInputMapper()
    #expect(mapper.text("\n") == .send(.events([.key(.named(.enter), [])])))
    #expect(mapper.text("\r") == .send(.events([.key(.named(.enter), [])])))
}

@Test("An armed Shift latch chords Return into a newline instead of a submit")
func shiftLatchTurnsReturnIntoANewline() {
    // Intent: the row's Shift key arms the same one-shot latch Ctrl does, and the next
    //   Return carries Shift, which the owner encodes as a bare LF.
    // Why it exists: the software keyboard has no Shift+Return, so a phone could submit a
    //   TUI composer but never add a second line to one.
    var mapper = MobileInputMapper()

    #expect(mapper.accessory(.shift) == nil)
    #expect(mapper.latchedModifiers == .shift)
    #expect(mapper.text("\n") == .send(.events([.key(.named(.enter), .shift)])))
    #expect(mapper.latchedModifiers == [])
    #expect(mapper.text("\n") == .send(.events([.key(.named(.enter), [])])))
}

@Test("The latch holds Ctrl and Shift together and one input spends both")
func latchCombinesModifiers() {
    // Intent: the two latch keys arm independently, chord the same next input, and are
    //   spent together by it.
    // Why it exists: the latch was a single Bool, so arming one modifier could not carry
    //   the other and a two-modifier chord was unreachable from the row.
    var mapper = MobileInputMapper()

    #expect(mapper.accessory(.control) == nil)
    #expect(mapper.accessory(.shift) == nil)
    #expect(mapper.latchedModifiers == [.ctrl, .shift])
    #expect(mapper.accessory(.tab) == .send(.events([.key(.named(.tab), [.ctrl, .shift])])))
    #expect(mapper.latchedModifiers == [])
}

@Test("Tapping a latch key twice disarms it")
func latchKeysToggle() {
    var mapper = MobileInputMapper()
    #expect(mapper.accessory(.shift) == nil)
    #expect(mapper.accessory(.shift) == nil)
    #expect(mapper.latchedModifiers == [])
}
