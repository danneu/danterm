// Tests for classifySwitcherInput, the pure event classifier that decides
// whether to swallow or pass through key events for the MRU tab switcher.
// Domain-native types only — runs in the no-Cocoa test target.

import Foundation

func switcherEventTests() {
    print("Switcher Event Classifier Tests...")

    let kVK_ANSI_I: UInt16 = 0x22
    let kVK_ANSI_O: UInt16 = 0x1F
    let kVK_ANSI_A: UInt16 = 0x00
    let kVK_Escape: UInt16 = 0x35

    // MARK: - keyDown trigger combos
    // cmd-shift-o is the primary direction (older, like cmd-tab).
    // cmd-shift-i is the reverse direction (newer, like cmd-shift-tab).

    test("cmd-shift-o with cycle inactive → stepOlder") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [.command, .shift],
            cycleActive: false
        )
        try expectEqual(action, .stepOlder)
    }

    test("cmd-shift-o with cycle active → stepOlder") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [.command, .shift],
            cycleActive: true
        )
        try expectEqual(action, .stepOlder)
    }

    test("cmd-shift-i → stepNewer") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_I),
            modifiers: [.command, .shift],
            cycleActive: true
        )
        try expectEqual(action, .stepNewer)
    }

    // MARK: - keyDown passthrough cases

    test("cmd-o (no shift) → passthrough") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [.command],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("shift-o (no cmd) → passthrough") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [.shift],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("cmd-shift-opt-o (extra modifier) → passthrough") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [.command, .shift, .option],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("bare o → passthrough (must reach terminal)") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_O),
            modifiers: [],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("bare i → passthrough") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_I),
            modifiers: [],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("cmd-shift-a → passthrough (different key)") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_ANSI_A),
            modifiers: [.command, .shift],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    // MARK: - Escape

    test("Esc with cycle inactive → passthrough") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_Escape),
            modifiers: [],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("Esc with cycle active → cancel") {
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: kVK_Escape),
            modifiers: [],
            cycleActive: true
        )
        try expectEqual(action, .cancel)
    }

    // MARK: - flagsChanged

    test("flagsChanged with cycle inactive → passthrough") {
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command, .shift],
            cycleActive: false
        )
        try expectEqual(action, .passthrough)
    }

    test("flagsChanged still holding cmd-shift → passthrough") {
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command, .shift],
            cycleActive: true
        )
        try expectEqual(action, .passthrough)
    }

    test("flagsChanged released shift (cmd held) → commit") {
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command],
            cycleActive: true
        )
        try expectEqual(action, .commit)
    }

    test("flagsChanged released cmd (shift held) → commit") {
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.shift],
            cycleActive: true
        )
        try expectEqual(action, .commit)
    }

    test("flagsChanged released both → commit") {
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [],
            cycleActive: true
        )
        try expectEqual(action, .commit)
    }
}
