// Pure coverage for active jump and held-MRU event classification.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermCore

@Suite struct SwitcherEventTests {
    private let older = KeyChord(compact: "cmd+option+left")!
    private let newer = KeyChord(compact: "cmd+option+right")!

    @Test("MRU key equivalent starts a held cycle while a menu click stays one-shot")
    func mruActivationPreservesKeyboardAndMenuSemantics() {
        if case .mruCycleStepped(direction: .older) = mruActivationMessage(
            direction: .older,
            initiatedByKeyEquivalent: true
        ) {} else {
            Issue.record("key equivalent must start the held cycle")
        }
        if case .mruCycleOneShot(direction: .newer) = mruActivationMessage(
            direction: .newer,
            initiatedByKeyEquivalent: false
        ) {} else {
            Issue.record("menu activation must remain one-shot")
        }
    }

    @Test("inactive MRU input never activates a configurable command")
    func inactiveMRUInputPassesThrough() {
        let action = classifySwitcherInput(
            kind: .keyDown(chord: older),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("active MRU uses the effective Older and Newer chords")
    func activeMRUUsesEffectiveChords() {
        #expect(classifySwitcherInput(
            kind: .keyDown(chord: older), requiredModifiers: older.modifiers,
            olderChord: older, newerChord: newer, cycleActive: true
        ) == .stepOlder)
        #expect(classifySwitcherInput(
            kind: .keyDown(chord: newer), requiredModifiers: older.modifiers,
            olderChord: older, newerChord: newer, cycleActive: true
        ) == .stepNewer)
    }

    @Test("active MRU ignores an unrelated chord")
    func activeMRUIgnoresUnrelatedChord() {
        let action = classifySwitcherInput(
            kind: .keyDown(chord: KeyChord(compact: "cmd+option+a")),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
            cycleActive: true
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
            kind: .escape,
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
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
            kind: .escape,
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
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
            kind: .flagsChanged(modifiers: older.modifiers),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
            cycleActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("flagsChanged still holding configured modifiers returns passthrough")
    func flagsChangedStillHoldingConfiguredModifiersPassthrough() {
        // Intent: still-holding cmd-shift during a cycle is a
        //   passthrough (no commit yet).
        // Why it exists: pins the hold-keys-still-pressed rule.
        // Scenario: spec-first still-holding.
        let action = classifySwitcherInput(
            kind: .flagsChanged(modifiers: older.modifiers),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
            cycleActive: true
        )
        #expect(action == .passthrough)
    }

    @Test("flagsChanged releasing one configured modifier commits")
    func flagsChangedReleasedConfiguredModifierCommits() {
        // Intent: releasing shift while cmd is still held commits.
        // Why it exists: pins the partial-release commit (one modifier
        //   leaves the trigger set).
        // Scenario: spec-first released shift.
        let action = classifySwitcherInput(
            kind: .flagsChanged(modifiers: [.command]),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
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
            kind: .flagsChanged(modifiers: []),
            requiredModifiers: older.modifiers,
            olderChord: older,
            newerChord: newer,
            cycleActive: true
        )
        #expect(action == .commit)
    }

    // MARK: - Jump mode (classifyJumpInput)

    @Test("inactive jump input never activates a configurable command")
    func inactiveJumpInputPassesThrough() {
        let action = classifyJumpInput(
            kind: .keyDown(
                character: "f",
                modifiers: [.command],
                matchesJumpCommand: true
            ),
            jumpActive: false
        )
        #expect(action == .passthrough)
    }

    @Test("plain a with jump active returns commit")
    func plainAWithJumpActiveCommit() {
        // Intent: a printable bare key during jump mode commits with
        //   that char.
        // Why it exists: pins the commit-with-char path.
        // Scenario: spec-first commit a.
        let action = classifyJumpInput(
            kind: .keyDown(character: "a", modifiers: [], matchesJumpCommand: false),
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
            kind: .escape(modifiers: [], matchesJumpCommand: false),
            jumpActive: true
        )
        #expect(action == .cancel(consumeEvent: true))
    }

    @Test("Shift-only jump target commits")
    func shiftOnlyJumpTargetCommits() {
        let action = classifyJumpInput(
            kind: .keyDown(character: "a", modifiers: [.shift], matchesJumpCommand: false),
            jumpActive: true
        )
        #expect(action == .commit(char: "a"))
    }

    @Test("modified printable chords cancel jump mode and pass through")
    func modifiedPrintableChordsCancelAndPassThrough() {
        // Intent: Command, Control, and Option chords cancel jump mode without
        //   swallowing the original command.
        // Why it exists: prevents jump mode from intercepting menu and terminal chords.
        // Scenario: INPUT-7 in the improvement audit.
        for modifiers: DanTermProtocol.KeyModifiers in [[.command], [.control], [.option]] {
            let action = classifyJumpInput(
                kind: .keyDown(
                    character: "w",
                    modifiers: modifiers,
                    matchesJumpCommand: false
                ),
                jumpActive: true
            )
            #expect(action == .cancel(consumeEvent: false))
        }
    }

    @Test("modified Escape cancels jump mode and passes through")
    func modifiedEscapeCancelsAndPassesThrough() {
        let action = classifyJumpInput(
            kind: .escape(modifiers: [.option], matchesJumpCommand: false),
            jumpActive: true
        )
        #expect(action == .cancel(consumeEvent: false))
    }

    @Test("effective jump command chords cancel and are consumed")
    func effectiveJumpCommandChordsCancelAndAreConsumed() {
        // Intent: every effective jump chord toggles active jump mode off.
        // Why it exists: passing the chord through would reactivate jump mode.
        // Scenario: a configured secondary jump chord is pressed while labels are visible.
        let action = classifyJumpInput(
            kind: .keyDown(
                character: "j",
                modifiers: [.control, .option],
                matchesJumpCommand: true
            ),
            jumpActive: true
        )
        #expect(action == .cancel(consumeEvent: true))
    }

    @Test("mouse down cancels jump mode and passes through")
    func mouseDownCancelsAndPassesThrough() {
        let action = classifyJumpInput(kind: .mouseDown, jumpActive: true)
        #expect(action == .cancel(consumeEvent: false))
    }

    @Test("bare f with jump active commits instead of activating")
    func bareFWithJumpActiveCommits() {
        // Intent: pressing f during jump mode commits as `f`, not
        //   re-activates.
        // Why it exists: pins the precedence of commit over activate
        //   in jump mode.
        // Scenario: spec-first commit f.
        let action = classifyJumpInput(
            kind: .keyDown(character: "f", modifiers: [], matchesJumpCommand: false),
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
            kind: .keyDown(character: nil, modifiers: [], matchesJumpCommand: false),
            jumpActive: true
        )
        #expect(action == .cancel(consumeEvent: true))
    }
}
