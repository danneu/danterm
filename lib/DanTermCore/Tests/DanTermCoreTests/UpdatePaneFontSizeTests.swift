// Per-pane font-size zoom: the pane-local step count, the effective size it
// projects through `desiredPaneConfig`, the bounds every ingress applies, and
// how the step count survives a snapshot round-trip.
//
// Assertions go through `desiredPaneConfig` rather than the stored field
// wherever the projected size is the contract; the stored bound is asserted
// directly only where the bound itself is the contract.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct UpdatePaneFontSizeTests {

    // MARK: - Helpers

    /// The two pane ids of a freshly split selected tab, in tree order.
    private func splitPaneIds(_ model: inout AppModel) -> (first: PaneId, second: PaneId) {
        createTab(&model)
        let first = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let second = selectedTab(in: model)!.paneTree.focusedPaneId
        return (first, second)
    }

    private func size(_ model: AppModel, _ paneId: PaneId) -> Double? {
        desiredPaneConfig(in: model)[paneId]?.font.size
    }

    private func config(fontSize: Double) -> DanTermConfig {
        var c = DanTermConfig.default
        c.fontSize = fontSize
        return c
    }

    // MARK: - PO1

    @Test("adjusting one pane leaves its sibling's projected size unchanged")
    func adjustingOnePaneLeavesSiblingUnchanged() {
        var model = makeModel()
        let (first, second) = splitPaneIds(&model)
        let baseline = size(model, first)

        update(&model, .adjustPaneFontSize(paneId: second, steps: 3))

        #expect(size(model, second) == baseline! + 3)
        #expect(size(model, first) == baseline)
    }

    // MARK: - PO2

    @Test("a configured-size change shifts zoomed and unzoomed panes alike")
    func configuredSizeChangePreservesTheOffset() {
        // Intent: the stored zoom is relative, so changing the configured font
        //   size moves a zoomed pane and an unzoomed one by the same delta, and
        //   reset lands exactly on the configured size.
        // Why it exists: this is the case that separates a step count from an
        //   absolute per-pane override, which would strand the zoomed pane at
        //   its old point size when the configuration moves.
        // Scenario: spec-first -- one pane of a split is zoomed by +2, then the
        //   configured size goes from 15 to 18.
        var model = makeModel()
        let (plain, zoomed) = splitPaneIds(&model)
        update(&model, .configLoaded(config(fontSize: 15), resolvedFontFamily: nil))
        update(&model, .adjustPaneFontSize(paneId: zoomed, steps: 2))
        #expect(size(model, plain) == 15)
        #expect(size(model, zoomed) == 17)

        update(&model, .configLoaded(config(fontSize: 18), resolvedFontFamily: nil))

        #expect(size(model, plain) == 18)
        #expect(size(model, zoomed) == 20, "the +2 offset rides the configuration change")

        update(&model, .resetPaneFontSize(paneId: zoomed))
        #expect(size(model, zoomed) == 18)
    }

    // MARK: - PO3

    @Test("every configured endpoint crossed with every step endpoint is renderable")
    func rangeEndpointsProjectRenderableSizes() {
        // Intent: the configured-size range and the step range are chosen so
        //   their sum always lands inside the renderable range, with no clamp
        //   in the projection.
        // Why it exists: a projection-only clamp cannot coexist with the
        //   relative-zoom contract -- it would silently eat steps the model
        //   still holds.
        // Scenario: spec-first -- the four corners of (configured, steps).
        for configured in [DanTermConfig.fontSizeRange.lowerBound, DanTermConfig.fontSizeRange.upperBound] {
            for steps in [paneFontSizeStepRange.lowerBound, paneFontSizeStepRange.upperBound] {
                var model = makeModel()
                createTab(&model)
                let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
                update(&model, .configLoaded(config(fontSize: configured), resolvedFontFamily: nil))
                update(&model, .adjustPaneFontSize(paneId: paneId, steps: steps))
                let projected = size(model, paneId)!
                #expect(
                    renderableFontSizeRange.contains(projected),
                    "configured \(configured) with \(steps) steps projected \(projected)"
                )
            }
        }
    }

    @Test("a configured size outside the range resolves to the nearest endpoint")
    func configuredSizeOutsideRangeResolvesToNearestEndpoint() {
        #expect(config(fontSize: 1).resolvedFontSize == DanTermConfig.fontSizeRange.lowerBound)
        #expect(config(fontSize: 500).resolvedFontSize == DanTermConfig.fontSizeRange.upperBound)
        #expect(config(fontSize: 0).resolvedFontSize == DanTermConfig.fontSizeRange.lowerBound)
        #expect(config(fontSize: -10).resolvedFontSize == DanTermConfig.fontSizeRange.lowerBound)
    }

    @Test("a fully zoomed-out pane under a tiny configured size still projects a renderable size")
    func tinyConfiguredSizeStillProjectsRenderable() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .configLoaded(config(fontSize: 1), resolvedFontFamily: nil))
        update(&model, .adjustPaneFontSize(paneId: paneId, steps: paneFontSizeStepRange.lowerBound))
        #expect(renderableFontSizeRange.contains(size(model, paneId)!))
    }

    // MARK: - PO4

    @Test("one increment after many decrements projects a larger size than the floor")
    func incrementAfterManyDecrementsMovesOffTheFloor() {
        // Intent: repeated presses at the floor accumulate no hidden state, so
        //   a single increment is immediately visible.
        // Why it exists: an unbounded stored step count would need as many
        //   increments as the user spent decrements before anything moved.
        // Scenario: spec-first -- 50 decrements, then one increment.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        for _ in 0..<50 { update(&model, .adjustPaneFontSize(paneId: paneId, steps: -1)) }
        let floor = size(model, paneId)!

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: 1))

        #expect(size(model, paneId)! > floor)
    }

    @Test("a snapshot step count beyond the range restores to the bound")
    func outOfRangeSnapshotStepCountRestoresToTheBound() throws {
        // Intent: a hand-edited or corrupt step count is bounded at restore, and
        //   the restored pane then behaves exactly like one adjusted to that bound.
        // Why it exists: an unbounded restored value would trap on the next
        //   adjustment or dead-press until the user spent the excess back.
        // Scenario: spec-first -- a snapshot leaf carrying Int.max steps.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "fontSizeSteps": 9223372036854775807
                } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: json.data(using: .utf8)!)
        var model = try #require(validateAndBuild(initFile.model))
        let paneId = try #require(model.allPanes.first?.id)

        #expect(model.pane(paneId)?.fontSizeSteps == paneFontSizeStepRange.upperBound)
        let ceiling = size(model, paneId)!

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: -1))
        #expect(size(model, paneId)! < ceiling)

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: 1))
        #expect(size(model, paneId)! == ceiling)

        #expect(update(&model, .adjustPaneFontSize(paneId: paneId, steps: 1)).isEmpty)
        #expect(size(model, paneId)! == ceiling)
    }

    @Test("an adjustment far past a bound lands exactly on that bound")
    func hugeAdjustmentSaturatesOnTheBound() {
        // Intent: `steps` is a delta, so an arbitrarily large one moves the pane
        //   all the way to the bound in its direction, from either starting end.
        // Why it exists: bounding the delta against the step range instead of
        //   against the room the pane has left saturates short -- a pane at the
        //   floor jumped by Int.max would stop 8 steps below the ceiling -- and
        //   an unbounded delta would overflow the addition outright.
        // Scenario: spec-first -- a pane parked at one bound, jumped by Int.max
        //   and Int.min toward the other.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: paneFontSizeStepRange.lowerBound))
        #expect(model.pane(paneId)?.fontSizeSteps == paneFontSizeStepRange.lowerBound)
        update(&model, .adjustPaneFontSize(paneId: paneId, steps: .max))
        #expect(model.pane(paneId)?.fontSizeSteps == paneFontSizeStepRange.upperBound)

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: .min))
        #expect(model.pane(paneId)?.fontSizeSteps == paneFontSizeStepRange.lowerBound)
    }

    // MARK: - Preferences ingress

    @Test("a font size saved from Preferences is bounded, and the panel shows what renders")
    func preferencesSaveBoundsTheFontSize() throws {
        // Intent: the size Preferences commits is the size panes render at, so a
        //   value outside `fontSizeRange` is bounded on the way in and echoed
        //   back into the field.
        // Why it exists: `resolvedFontSize` bounds at read while the panel showed
        //   the raw saved number, so typing 200 displayed 200 over panes drawing
        //   at 72 -- the stored setting no longer described the terminal.
        // Scenario: spec-first -- save 200, then 4, with a pane on screen.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .preferencesOpened())

        update(&model, .prefSet(.fontSize("200")))
        update(&model, .prefSave)
        #expect(model.config.fontSize == DanTermConfig.fontSizeRange.upperBound)
        #expect(size(model, paneId) == DanTermConfig.fontSizeRange.upperBound)
        var panel = try #require(desiredPreferencesPanel(in: model))
        #expect(panel.fontSizeText == "72")

        update(&model, .prefSet(.fontSize("4")))
        update(&model, .prefSave)
        #expect(model.config.fontSize == DanTermConfig.fontSizeRange.lowerBound)
        #expect(size(model, paneId) == DanTermConfig.fontSizeRange.lowerBound)
        panel = try #require(desiredPreferencesPanel(in: model))
        #expect(panel.fontSizeText == "8")
    }

    // MARK: - PO5

    @Test("snapshot round-trip preserves a non-default zoom")
    func roundTripPreservesZoom() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .adjustPaneFontSize(paneId: paneId, steps: 3))

        let restored = try #require(validateAndBuild(toSnapshot(model)))

        #expect(size(restored, paneId) == size(model, paneId))
    }

    @Test("an unzoomed pane writes no zoom key and a snapshot without one restores to the default")
    func defaultZoomIsAbsentFromTheSnapshot() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        let snapshot = toSnapshot(model)
        #expect(paneSnapshot(paneId, in: snapshot)?.fontSizeSteps == nil)

        let restored = try #require(validateAndBuild(snapshot))
        #expect(restored.pane(paneId)?.fontSizeSteps == 0)
        #expect(size(restored, paneId) == DanTermConfig.default.resolvedFontSize)
    }

    // MARK: - PO6

    @Test("zoom travels with the pane across splits, tabs, and moves")
    func zoomTravelsWithThePane() {
        // Intent: a split inherits its source pane's zoom, a new tab starts at
        //   the default, and rearranging a split keeps each pane's zoom.
        // Why it exists: zoom is pane-scoped state, so it must follow the same
        //   inheritance and relocation rules the pane theme already follows.
        // Scenario: spec-first -- zoom a pane, split it, open a new tab, then
        //   swap the two panes of the original split.
        var model = makeModel()
        createTab(&model)
        let source = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .adjustPaneFontSize(paneId: source, steps: 2))

        update(&model, .splitFocusedPane(direction: .horizontal))
        let child = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(size(model, child) == size(model, source), "the split inherits the source pane's zoom")

        createTab(&model)
        let freshTabPane = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(size(model, freshTabPane) == DanTermConfig.default.resolvedFontSize)

        update(&model, .selectTab(id: model.groups[0].tabs[0].id))
        update(&model, .resetPaneFontSize(paneId: child))
        let zoomedSize = size(model, source)
        update(&model, .movePane(source: source, target: child, intent: .swap))
        #expect(size(model, source) == zoomedSize, "a moved pane keeps its zoom")
    }

    // MARK: - PO7

    @Test("adjustments that change nothing schedule no checkpoint")
    func noOpAdjustmentsReturnNoCommands() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        #expect(update(&model, .resetPaneFontSize(paneId: paneId)).isEmpty)

        update(&model, .adjustPaneFontSize(paneId: paneId, steps: paneFontSizeStepRange.upperBound))
        #expect(update(&model, .adjustPaneFontSize(paneId: paneId, steps: 1)).isEmpty)
    }

    // MARK: - PO8

    @Test("an adjustment targets the focused pane, or the named pane in a background tab")
    func adjustmentTargetsTheRightPane() {
        // Intent: a nil pane id means the selected tab's focused pane (the
        //   menubar path); a named pane is adjusted in whichever tab owns it.
        // Why it exists: mirrors the `.toggleZoomPane` targeting contract, so a
        //   context menu built for a background tab still acts on that tab.
        // Scenario: spec-first -- two tabs, adjust the focused pane by nil and
        //   the background tab's pane by id.
        var model = makeModel()
        createTab(&model)
        let backgroundPane = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let focusedPane = selectedTab(in: model)!.paneTree.focusedPaneId
        let baseline = DanTermConfig.default.resolvedFontSize

        update(&model, .adjustPaneFontSize(paneId: nil, steps: 1))
        #expect(size(model, focusedPane) == baseline + 1)
        #expect(size(model, backgroundPane) == baseline)

        update(&model, .adjustPaneFontSize(paneId: backgroundPane, steps: -1))
        #expect(size(model, backgroundPane) == baseline - 1)
        #expect(size(model, focusedPane) == baseline + 1)
    }

    // MARK: - PO9

    @Test("a restored model carries the live configuration before anything reads it")
    func restoredModelCarriesLiveAppearance() throws {
        // Intent: a model rebuilt from a snapshot arrives with `config` and
        //   `resolvedFontFamily` at their defaults, so the live values are
        //   carried onto it before any session is created from it.
        // Why it exists: without the carry-over a restored +2 pane under a
        //   configured size of 18 would be built at the default size, and the
        //   committed model would revert the user's configured size and theme.
        // Scenario: spec-first -- restore a split snapshot with one +2 pane
        //   under a live config of size 18 and a non-default theme.
        var live = makeModel()
        let (plain, zoomed) = splitPaneIds(&live)
        update(&live, .adjustPaneFontSize(paneId: zoomed, steps: 2))
        let restored = try #require(validateAndBuild(toSnapshot(live)))
        #expect(restored.config == .default, "the snapshot carries structure, not appearance")

        var liveConfig = DanTermConfig.default
        liveConfig.fontSize = 18
        liveConfig.defaultTheme = "Gruvbox Dark"
        let carried = carryingLiveAppearance(restored, config: liveConfig, resolvedFontFamily: "Menlo")

        let projected = desiredPaneConfig(in: carried)
        #expect(projected[zoomed]?.font.size == 20)
        #expect(projected[plain]?.font.size == 18)
        #expect(projected[plain]?.theme == "Gruvbox Dark")
        #expect(projected[plain]?.font.family == "Menlo")
    }
}
