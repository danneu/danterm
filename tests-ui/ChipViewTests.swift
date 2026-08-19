// UI-harness tests for the pane-kind chips: that the chip a surface shows
// follows the pane's agent kind, and that the toolbar does not spell out in
// text what the chip already says.
//
// That a kind reaches distinct pixels is proved in the ChipArtwork package's
// own suite, which the phone rests on too.
//
// The assertions walk the view tree for a ChipView or for visible label text
// rather than reaching at named subviews, so rearranging the toolbar's stacks
// does not break them.
import Cocoa
import DanTermProtocol

@MainActor
func chipViewTests() {
    print("ChipView")

    uiTest("the toolbar chip follows the pane's agent kind") {
        // Intent: whatever kind the projection hands updateToolbar is the kind
        //   the pane's chip shows.
        // Why it exists: the chip is the only thing identifying a pane at a
        //   glance, so a stale or ignored kind is a silent wrong answer rather
        //   than a visible breakage. Spec-first.
        let wrapper = makeChipWrapper()

        for kind in ChipKind.allCases {
            wrapper.updateToolbar(label: "t", chipKind: kind)
            let chip = try onlyChipView(in: wrapper)
            try uiExpect(chip.kind == kind, "expected \(kind), got \(chip.kind)")
        }
    }

    uiTest("an agent with its own chip is not also spelled out in text") {
        // Intent: attaching a claude session paints the claude chip and adds no
        //   text naming the kind.
        // Why it exists: the chip and the old indigo agent pill both name the
        //   kind, so showing both is redundancy the chip was meant to remove.
        //   Spec-first.
        let wrapper = makeChipWrapper()

        wrapper.updateToolbar(
            label: "t", agentLabel: nil, chipTooltip: "claude session abc123", chipKind: .claude)

        try uiExpect(try onlyChipView(in: wrapper).kind == .claude, "chip should be claude")
        try uiExpect(
            !visibleLabelTexts(in: wrapper).contains("claude"),
            "kind should not be repeated as text, got \(visibleLabelTexts(in: wrapper))")
    }

    uiTest("an agent with no chip of its own is named in text") {
        // Intent: a kind DanTerm ships no mark for gets the generic agent chip,
        //   and the toolbar still names it in text.
        // Why it exists: hook `kind` strings are open-ended, so unknown kinds
        //   are normal, not exceptional. The generic chip says a pane is running
        //   *an* agent; only the text can say which one. Spec-first.
        let wrapper = makeChipWrapper()

        wrapper.updateToolbar(
            label: "t", agentLabel: "aider", chipTooltip: "aider session abc123", chipKind: .agent)

        try uiExpect(try onlyChipView(in: wrapper).kind == .agent, "chip should be the generic agent")
        try uiExpect(
            visibleLabelTexts(in: wrapper).contains("aider"),
            "unknown kind should be named in text, got \(visibleLabelTexts(in: wrapper))")
    }

    uiTest("the session id survives the text fallback being hidden") {
        // Intent: the chip carries the "<kind> session <id>" tooltip whenever a
        //   session is attached, whether or not the text fallback is shown.
        // Why it exists: the tooltip used to live on the agent pill, which is
        //   now hidden for every kind that has a chip -- so without moving it
        //   the session id would have become unreachable for claude and codex.
        let wrapper = makeChipWrapper()

        wrapper.updateToolbar(
            label: "t", agentLabel: nil, chipTooltip: "claude session abc123", chipKind: .claude)

        let chip = try onlyChipView(in: wrapper)
        try uiExpect(
            chip.toolTip == "claude session abc123",
            "expected the session tooltip, got \(String(describing: chip.toolTip))")
    }

    uiTest("detaching an agent clears the chip tooltip and the text fallback") {
        // Intent: going from attached back to a plain shell leaves no trace of
        //   the departed session.
        // Why it exists: updateToolbar is a diffed push, so a field only ever
        //   cleared on the attach path would strand the old value forever.
        let wrapper = makeChipWrapper()
        wrapper.updateToolbar(
            label: "t", agentLabel: "aider", chipTooltip: "aider session abc123", chipKind: .agent)

        wrapper.updateToolbar(label: "t", agentLabel: nil, chipTooltip: nil, chipKind: .terminal)

        let chip = try onlyChipView(in: wrapper)
        try uiExpect(chip.toolTip == nil, "tooltip should clear, got \(String(describing: chip.toolTip))")
        try uiExpect(
            !visibleLabelTexts(in: wrapper).contains("aider"),
            "text fallback should clear, got \(visibleLabelTexts(in: wrapper))")
    }
}

/// A PaneWrapperView with one plain pane, which is all these tests need.
@MainActor
private func makeChipWrapper() -> PaneWrapperView {
    let paneId = PaneId()
    let pane = PaneModel(id: paneId, session: SessionModel(id: SessionId()))
    let tab = TabModel(id: TabId(), customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    var model = AppModel(groups: [GroupModel(id: GroupId(), name: "g", tabs: [tab])])
    model.selectedTabId = tab.id
    return PaneWrapperView(
        paneId: paneId, terminalView: TerminalView(),
        isZoomed: false, hasSplits: false, runtime: AppRuntime(model: model))
}

/// The single ChipView under a view, found by walking rather than by name so the
/// tests survive the toolbar's stacks being rearranged.
@MainActor
private func onlyChipView(in root: NSView) throws -> ChipView {
    let found = descendants(of: root).compactMap { $0 as? ChipView }
    try uiExpect(found.count == 1, "expected exactly one ChipView, got \(found.count)")
    return found[0]
}

/// Text a user can actually read: the stringValue of every visible label in the
/// tree, with empties dropped.
@MainActor
private func visibleLabelTexts(in root: NSView) -> Set<String> {
    var result: Set<String> = []
    for view in descendants(of: root) {
        guard let field = view as? NSTextField, !field.stringValue.isEmpty else { continue }
        // A visible label inside a hidden container is not on screen either.
        var node: NSView? = field
        while let current = node, current !== root {
            if current.isHidden { break }
            node = current.superview
        }
        if node === root { result.insert(field.stringValue) }
    }
    return result
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
