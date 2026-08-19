// UI-harness tests for DialogActionRow, the one type that decides where a
// dialog's buttons go. Every assertion reads drawn frames rather than stack
// view properties, so a rewrite that keeps the layout keeps the suite passing.
import Cocoa

/// Registers DialogActionRow coverage in the standalone UI harness.
@MainActor
func dialogActionRowTests() {
    print("DialogActionRow")

    uiTest("orders alternate, cancel, default from leading to trailing") {
        // Intent: role decides position, whatever order the caller listed the
        //   actions in.
        // Why it exists: the bug this type replaces was three surfaces each
        //   re-deriving the order, and each getting it wrong differently.
        // Scenario: spec-first; the actions go in scrambled.
        let row = laidOutRow([
            action("Cancel", .cancel),
            action("Default", .defaultAction),
            action("Alternate", .alternate),
        ])

        try uiExpect(titlesByPosition(row) == ["Alternate", "Cancel", "Default"],
                     "expected alternate, cancel, default; got \(titlesByPosition(row))")
    }

    uiTest("packs the cancel and default pair against the trailing edge") {
        // Intent: the pair hugs the row's trailing edge with no slack after it,
        //   and cancel is nowhere near the leading edge.
        // Why it exists: this is the original defect. The confirmation panel
        //   drew Cancel at x is about 0 with all the slack on the right.
        // Scenario: spec-first; a two-action row in a wide container.
        let row = laidOutRow([
            action("Cancel", .cancel),
            action("Close Tab", .defaultAction),
        ])
        let cancel = try button(row, titled: "Cancel")
        let confirm = try button(row, titled: "Close Tab")

        try uiExpect(abs(confirm.frame.maxX - row.bounds.maxX) < 1,
                     "default should end at the row's trailing edge, got \(confirm.frame.maxX) of \(row.bounds.maxX)")
        try uiExpect(cancel.frame.minX > row.bounds.midX,
                     "cancel should sit past the row midpoint, got \(cancel.frame.minX)")
    }

    uiTest("separates an alternate from the trailing pair") {
        // Intent: alternates hold the leading edge, and the gap between them and
        //   the cancel/default pair is real slack, not the button spacing.
        let row = laidOutRow([
            action("Close Tabs", .alternate),
            action("Cancel", .cancel),
            action("Move to General", .defaultAction),
        ])
        let alternate = try button(row, titled: "Close Tabs")
        let cancel = try button(row, titled: "Cancel")

        try uiExpect(abs(alternate.frame.minX - row.bounds.minX) < 1,
                     "alternate should start at the leading edge, got \(alternate.frame.minX)")
        try uiExpect(cancel.frame.minX - alternate.frame.maxX > 20,
                     "expected slack between the alternate and the pair, got \(cancel.frame.minX - alternate.frame.maxX)")
    }

    uiTest("each button runs its own action exactly once") {
        var fired: [String] = []
        let row = laidOutRow([
            action("Close Tabs", .alternate) { fired.append("alternate") },
            action("Cancel", .cancel) { fired.append("cancel") },
            action("Move to General", .defaultAction) { fired.append("default") },
        ])

        for title in ["Move to General", "Cancel", "Close Tabs"] {
            let target = try button(row, titled: title)
            target.performClick(nil)
        }

        try uiExpect(fired == ["default", "cancel", "alternate"],
                     "each click should run its own handler once, got \(fired)")
    }

    uiTest("claims Return and Escape only when it reserves them") {
        let reserving = laidOutRow([
            action("Cancel", .cancel),
            action("Save", .defaultAction),
        ])
        let deferring = laidOutRow([
            action("Cancel", .cancel),
            action("Save", .defaultAction),
        ], reservesKeyEquivalents: false)

        try uiExpect(try button(reserving, titled: "Save").keyEquivalent == "\r",
                     "the default should take Return")
        try uiExpect(try button(reserving, titled: "Cancel").keyEquivalent == "\u{1b}",
                     "cancel should take Escape")
        try uiExpect(try button(deferring, titled: "Save").keyEquivalent.isEmpty,
                     "a deferring row must leave Return to its host")
        try uiExpect(try button(deferring, titled: "Cancel").keyEquivalent.isEmpty,
                     "a deferring row must leave Escape to its host")
    }

    uiTest("a long alternate title truncates instead of squeezing the pair") {
        // Intent: when the actions do not fit, the alternate gives up width and
        //   cancel and the default keep theirs.
        // Why it exists: a dialog whose width is fixed by its text column must
        //   not be widened, and must not break a constraint, by long button copy.
        let natural = laidOutRow([
            action("Cancel", .cancel),
            action("Move to General", .defaultAction),
        ])
        let cancelWidth = try button(natural, titled: "Cancel").frame.width
        let defaultWidth = try button(natural, titled: "Move to General").frame.width

        let crowded = laidOutRow([
            action(String(repeating: "Close Every Tab ", count: 8), .alternate),
            action("Cancel", .cancel),
            action("Move to General", .defaultAction),
        ])
        let alternate = try button(crowded, titled: String(repeating: "Close Every Tab ", count: 8))

        try uiExpect(abs(try button(crowded, titled: "Cancel").frame.width - cancelWidth) < 1,
                     "cancel should keep its natural width")
        try uiExpect(abs(try button(crowded, titled: "Move to General").frame.width - defaultWidth) < 1,
                     "the default should keep its natural width")
        try uiExpect(alternate.frame.maxX <= crowded.bounds.maxX + 1,
                     "the alternate should stay inside the row, got \(alternate.frame.maxX) of \(crowded.bounds.maxX)")
    }

    uiTest("dropping an action leaves no button holding its space") {
        // Intent: after setActions narrows three actions to two, exactly two
        //   buttons are drawn and the pair still ends at the trailing edge.
        // Why it exists: the panel this replaces hid its secondary button
        //   without detachesHiddenViews, so an unused button kept its width.
        // Scenario: spec-first; the delete-group row becoming a close-tab row.
        let row = laidOutRow([
            action("Close Tabs", .alternate),
            action("Cancel", .cancel),
            action("Move to General", .defaultAction),
        ])
        row.setActions([action("Cancel", .cancel), action("Close Tab", .defaultAction)])
        layOut(row)

        try uiExpect(titlesByPosition(row) == ["Cancel", "Close Tab"],
                     "expected only the new pair, got \(titlesByPosition(row))")
        let confirm = try button(row, titled: "Close Tab")
        try uiExpect(abs(confirm.frame.maxX - row.bounds.maxX) < 1,
                     "the narrowed row should still hug the trailing edge, got \(confirm.frame.maxX) of \(row.bounds.maxX)")
    }
}

// MARK: - Fixtures

private func action(
    _ title: String,
    _ role: DialogActionRole,
    perform: @escaping () -> Void = {}
) -> DialogAction {
    DialogAction(title: title, role: role, perform: perform)
}

/// Hosts the row in a container whose width is fixed, so trailing gravity has
/// slack to work with and over-wide button copy has to give somewhere. Without
/// the required width the container grows to fit and no layout rule is tested.
@MainActor
private func laidOutRow(
    _ actions: [DialogAction],
    reservesKeyEquivalents: Bool = true
) -> DialogActionRow {
    let row = DialogActionRow(actions: actions, reservesKeyEquivalents: reservesKeyEquivalents)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 40))
    container.addSubview(row)
    container.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: 460),
        container.heightAnchor.constraint(equalToConstant: 40),
        row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    layOut(row)
    return row
}

@MainActor
private func layOut(_ row: DialogActionRow) {
    row.superview?.layoutSubtreeIfNeeded()
}

@MainActor
private func titlesByPosition(_ row: DialogActionRow) -> [String] {
    row.buttonsInVisualOrder
        .sorted { $0.frame.minX < $1.frame.minX }
        .map(\.title)
}

@MainActor
private func button(_ row: DialogActionRow, titled title: String) throws -> NSButton {
    guard let match = row.buttonsInVisualOrder.first(where: { $0.title == title }) else {
        throw UITestFailure(message: "no button titled \(title)")
    }
    return match
}
