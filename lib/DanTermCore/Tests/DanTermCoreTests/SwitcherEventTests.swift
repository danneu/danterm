// Swift Testing migration of the legacy `tests/SwitcherEventTests.swift`
// harness suite. Pins the two pure event classifiers (no Cocoa): the
// MRU switcher's `classifySwitcherInput` (keyDown trigger combos,
// passthrough cases, Escape gating, flagsChanged transitions to commit
// or passthrough) and the jump-mode `classifyJumpInput` (activate / commit
// / cancel / passthrough). Both classifier suites coexist in this file
// for parity with the legacy harness; the inventory groups them under
// SwitcherEventTests.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct SwitcherEventTests {
    private static let kVK_ANSI_I: UInt16 = 0x22
    private static let kVK_ANSI_O: UInt16 = 0x1F
    private static let kVK_ANSI_A: UInt16 = 0x00
    private static let kVK_ANSI_F: UInt16 = 0x03
    private static let kVK_Escape: UInt16 = 0x35

    // MARK: - keyDown trigger combos

    @Test("cmd-shift-o with cycle inactive → stepOlder")
    func cmdShiftOWithCycleInactiveStepOlder() {
        // Intent: cmd-shift-o when no cycle is active starts the cycle
        //   by stepping older.
        // Why it exists: pins the primary direction.
        // Scenario: spec-first idle stepOlder.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [.command, .shift],
            cycleActive: false
        )
        #expect(action == .stepOlder)
    }

    @Test("cmd-shift-o with cycle active → stepOlder")
    func cmdShiftOWithCycleActiveStepOlder() {
        // Intent: cmd-shift-o during an active cycle continues stepping
        //   older.
        // Why it exists: pins the in-cycle advance.
        // Scenario: spec-first in-cycle stepOlder.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [.command, .shift],
            cycleActive: true
        )
        #expect(action == .stepOlder)
    }

    @Test("cmd-shift-i → stepNewer")
    func cmdShiftIStepNewer() {
        // Intent: cmd-shift-i is the reverse direction (newer).
        // Why it exists: pins the reverse-direction key.
        // Scenario: spec-first stepNewer.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_I),
            modifiers: [.command, .shift],
            cycleActive: true
        )
        #expect(action == .stepNewer)
    }

    // MARK: - keyDown passthrough cases

    @Test("cmd-o (no shift) → passthrough")
    func cmdONoShiftPassthrough() {
        // Intent: cmd-o without shift passes through (not a trigger).
        // Why it exists: pins the modifier-strict trigger rule.
        // Scenario: spec-first missing shift.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [.command],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("shift-o (no cmd) → passthrough")
    func shiftONoCmdPassthrough() {
        // Intent: shift-o without cmd passes through.
        // Why it exists: pins the modifier-strict trigger rule.
        // Scenario: spec-first missing cmd.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [.shift],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("cmd-shift-opt-o (extra modifier) → passthrough")
    func cmdShiftOptOExtraModifierPassthrough() {
        // Intent: an extra option modifier disqualifies the trigger.
        // Why it exists: pins the modifier-set-equality rule.
        // Scenario: spec-first extra modifier.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [.command, .shift, .option],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("bare o → passthrough (must reach terminal)")
    func bareOPassthrough() {
        // Intent: bare o passes through so the terminal receives it.
        // Why it exists: pins the no-modifier passthrough rule.
        // Scenario: spec-first bare o.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_O),
            modifiers: [],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("bare i → passthrough")
    func bareIPassthrough() {
        // Intent: bare i passes through.
        // Why it exists: pins the symmetric bare-key rule.
        // Scenario: spec-first bare i.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_I),
            modifiers: [],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("cmd-shift-a → passthrough (different key)")
    func cmdShiftADifferentKeyPassthrough() {
        // Intent: cmd-shift-a passes through (wrong key).
        // Why it exists: pins the key-strict trigger rule.
        // Scenario: spec-first wrong key.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_A),
            modifiers: [.command, .shift],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    // MARK: - Escape

    @Test("Esc with cycle inactive → passthrough")
    func escWithCycleInactivePassthrough() {
        // Intent: Esc with no active cycle passes through.
        // Why it exists: pins the no-cycle Esc gating.
        // Scenario: spec-first Esc inactive.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_Escape),
            modifiers: [],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("Esc with cycle active → cancel")
    func escWithCycleActiveCancel() {
        // Intent: Esc during an active cycle cancels.
        // Why it exists: pins the active-cycle Esc cancel.
        // Scenario: spec-first Esc cancel.
        let action = classifySwitcherInput(
            kind: .keyDown(keyCode: Self.kVK_Escape),
            modifiers: [],
            cycleActive: true
        )
        #expect(action == .cancel)
    }

    // MARK: - flagsChanged

    @Test("flagsChanged with cycle inactive → passthrough")
    func flagsChangedWithCycleInactivePassthrough() {
        // Intent: flagsChanged with no active cycle passes through.
        // Why it exists: pins the idle flagsChanged behavior.
        // Scenario: spec-first idle flagsChanged.
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command, .shift],
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("flagsChanged still holding cmd-shift → passthrough")
    func flagsChangedStillHoldingCmdShiftPassthrough() {
        // Intent: still-holding cmd-shift during a cycle is a
        //   passthrough (no commit yet).
        // Why it exists: pins the hold-keys-still-pressed rule.
        // Scenario: spec-first still-holding.
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command, .shift],
            cycleActive: true
        )
        #expect(action == .passthrough)
    }

    @Test("flagsChanged released shift (cmd held) → commit")
    func flagsChangedReleasedShiftCmdHeldCommit() {
        // Intent: releasing shift while cmd is still held commits.
        // Why it exists: pins the partial-release commit (one modifier
        //   leaves the trigger set).
        // Scenario: spec-first released shift.
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.command],
            cycleActive: true
        )
        #expect(action == .commit)
    }

    @Test("flagsChanged released cmd (shift held) → commit")
    func flagsChangedReleasedCmdShiftHeldCommit() {
        // Intent: releasing cmd while shift is still held commits.
        // Why it exists: pins the symmetric partial-release rule.
        // Scenario: spec-first released cmd.
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [.shift],
            cycleActive: true
        )
        #expect(action == .commit)
    }

    @Test("flagsChanged released both → commit")
    func flagsChangedReleasedBothCommit() {
        // Intent: releasing both modifiers commits.
        // Why it exists: pins the full-release commit.
        // Scenario: spec-first both released.
        let action = classifySwitcherInput(
            kind: .flagsChanged,
            modifiers: [],
            cycleActive: true
        )
        #expect(action == .commit)
    }

    // MARK: - Jump mode (classifyJumpInput)

    @Test("cmd-shift-f with jump inactive returns activate")
    func cmdShiftFWithJumpInactiveActivate() {
        // Intent: cmd-shift-f with jump inactive activates jump mode.
        // Why it exists: pins the activate trigger.
        // Scenario: spec-first activate.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_F, character: "f"),
            modifiers: [.command, .shift],
            jumpActive: false
        )
        #expect(action == .activate)
    }

    @Test("plain a with jump active returns commit")
    func plainAWithJumpActiveCommit() {
        // Intent: a printable bare key during jump mode commits with
        //   that char.
        // Why it exists: pins the commit-with-char path.
        // Scenario: spec-first commit a.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_A, character: "a"),
            modifiers: [],
            jumpActive: true
        )
        #expect(action == .commit(char: "a"))
    }

    @Test("escape with jump active returns cancel")
    func escapeWithJumpActiveCancel() {
        // Intent: Esc during jump mode cancels.
        // Why it exists: pins the Esc cancel branch.
        // Scenario: spec-first jump Esc.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: Self.kVK_Escape, character: nil),
            modifiers: [],
            jumpActive: true
        )
        #expect(action == .cancel)
    }

    @Test("modifier-bearing keyDown with jump active returns cancel")
    func modifierBearingKeyDownWithJumpActiveCancel() {
        // Intent: any modifier-bearing keyDown during jump mode
        //   cancels.
        // Why it exists: pins the strict-bare-key rule.
        // Scenario: spec-first modifier-bearing cancel.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_A, character: "a"),
            modifiers: [.command],
            jumpActive: true
        )
        #expect(action == .cancel)
    }

    @Test("flagsChanged with jump active returns passthrough")
    func flagsChangedWithJumpActivePassthrough() {
        // Intent: flagsChanged during jump mode passes through.
        // Why it exists: pins the modifier-event-no-op rule.
        // Scenario: spec-first jump flagsChanged.
        let action = classifyJumpInput(
            kind: .flagsChanged,
            modifiers: [],
            jumpActive: true
        )
        #expect(action == .passthrough)
    }

    @Test("bare f with jump active commits instead of activating")
    func bareFWithJumpActiveCommits() {
        // Intent: pressing f during jump mode commits as `f`, not
        //   re-activates.
        // Why it exists: pins the precedence of commit over activate
        //   in jump mode.
        // Scenario: spec-first commit f.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: Self.kVK_ANSI_F, character: "f"),
            modifiers: [],
            jumpActive: true
        )
        #expect(action == .commit(char: "f"))
    }

    @Test("bare non-printing key with jump active returns cancel")
    func bareNonPrintingKeyWithJumpActiveCancel() {
        // Intent: a bare non-printing key during jump mode cancels.
        // Why it exists: pins the no-printable-character fallback.
        // Scenario: spec-first non-printing.
        let action = classifyJumpInput(
            kind: .keyDown(keyCode: 0x7B, character: nil),
            modifiers: [],
            jumpActive: true
        )
        #expect(action == .cancel)
    }
}
