// The pane grid override: the stored size policy a remote client claims, the
// two messages that write it, and how it survives -- or is deliberately
// dropped by -- a snapshot round-trip.
//
// The rendering seam that reads the override (rectangle versus grid) is the
// app layer's; this suite covers only what the pure core stores and refuses.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct UpdatePaneGridOverrideTests {

    // MARK: - Helpers

    /// The two pane ids of a freshly split selected tab, in tree order.
    private func splitPaneIds(_ model: inout AppModel) -> (first: PaneId, second: PaneId) {
        createTab(&model)
        let first = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let second = selectedTab(in: model)!.paneTree.focusedPaneId
        return (first, second)
    }

    private func grid(_ columns: Int, _ rows: Int) -> PaneGridOverride {
        PaneGridOverride(columns: columns, rows: rows)!
    }

    // MARK: - The two writers

    @Test("a pane starts with no override and a set stores exactly the requested grid")
    func setStoresTheRequestedGrid() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(model.pane(paneId)?.gridOverride == nil)

        update(&model, .setPaneGridOverride(paneId: paneId, grid: grid(60, 30)))

        #expect(model.pane(paneId)?.gridOverride == grid(60, 30))
    }

    @Test("a second set replaces the first")
    func lastWriterWins() {
        // Intent: the override is a size policy, not a claim -- a later writer
        //   simply replaces the stored grid.
        // Why it exists: no ownership, tenure, or lock is stored anywhere, so
        //   concurrent claimers must self-heal by last-writer-wins.
        // Scenario: spec-first -- two clients claim the same pane in turn.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .setPaneGridOverride(paneId: paneId, grid: grid(60, 30)))
        update(&model, .setPaneGridOverride(paneId: paneId, grid: grid(100, 40)))

        #expect(model.pane(paneId)?.gridOverride == grid(100, 40))
    }

    @Test("clearing returns the pane to its slot-derived grid, and clearing twice is inert")
    func clearRemovesTheOverride() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .setPaneGridOverride(paneId: paneId, grid: grid(60, 30)))

        update(&model, .clearPaneGridOverride(paneId: paneId))
        #expect(model.pane(paneId)?.gridOverride == nil)

        update(&model, .clearPaneGridOverride(paneId: paneId))
        #expect(model.pane(paneId)?.gridOverride == nil)
    }

    @Test("the take-back gesture clears the focused pane's override and leaves its sibling alone")
    func clearWithoutAPaneIdTargetsTheFocusedPane() {
        // Intent: the Mac take-back gesture names no pane, so an id-less clear
        //   must land on the focused pane only.
        // Why it exists: a take-back that cleared every pane, or the wrong one,
        //   would silently drop another client's deliberate claim.
        // Scenario: spec-first -- both panes of a split are claimed, then the
        //   focused one is taken back.
        var model = makeModel()
        let (first, second) = splitPaneIds(&model)
        update(&model, .setPaneGridOverride(paneId: first, grid: grid(60, 30)))
        update(&model, .setPaneGridOverride(paneId: second, grid: grid(80, 24)))
        #expect(selectedTab(in: model)?.paneTree.focusedPaneId == second)

        update(&model, .clearPaneGridOverride(paneId: nil))

        #expect(model.pane(second)?.gridOverride == nil)
        #expect(model.pane(first)?.gridOverride == grid(60, 30))
    }

    @Test("splitting an overridden pane starts the new pane without one")
    func splitDoesNotPropagateTheOverride() {
        // Intent: the override describes one pane's size policy, so a pane born
        //   from a split fits its own slot.
        // Why it exists: an inherited override would give a brand-new local pane
        //   a remote client's grid with nothing to take it back from.
        // Scenario: spec-first -- claim a pane, then split it.
        var model = makeModel()
        createTab(&model)
        let source = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .setPaneGridOverride(paneId: source, grid: grid(60, 30)))

        update(&model, .splitFocusedPane(direction: .horizontal))
        let created = selectedTab(in: model)!.paneTree.focusedPaneId

        #expect(created != source)
        #expect(model.pane(created)?.gridOverride == nil)
        #expect(model.pane(source)?.gridOverride == grid(60, 30))
    }

    // MARK: - The projection to the view

    @Test("desiredPaneConfig carries the override and drops it on a clear")
    func paneConfigCarriesTheOverride() {
        // Intent: the override reaches the pane's session on the same per-pane
        //   config channel that already carries theme, font, and copy-on-select.
        // Why it exists: the reconciler only pushes a key that changed, so an
        //   override the projection omits would never reach the view at all,
        //   and a clear that leaves the key equal would never be undone.
        // Scenario: spec-first -- a phone claims one pane of a split, then the
        //   user takes it back at the Mac.
        var model = makeModel()
        let (plain, claimed) = splitPaneIds(&model)

        update(&model, .setPaneGridOverride(paneId: claimed, grid: grid(60, 30)))

        #expect(desiredPaneConfig(in: model)[claimed]?.gridOverride == grid(60, 30))
        #expect(desiredPaneConfig(in: model)[plain]?.gridOverride == nil)

        update(&model, .clearPaneGridOverride(paneId: claimed))

        #expect(desiredPaneConfig(in: model)[claimed]?.gridOverride == nil)
    }

    // MARK: - Accepted range

    @Test("the accepted range's endpoints are representable and everything outside is not")
    func onlyInRangeGridsAreRepresentable() {
        // Intent: an out-of-range grid has no value at all, so no ingress can
        //   store one and no clamp can quietly reshape a caller's request.
        // Why it exists: the range keeps every accepted grid representable
        //   identically by the PTY, the engine, and every replica.
        // Scenario: spec-first -- both ends of both axes, and one step past each.
        #expect(PaneGridOverride(columns: 2, rows: 1) != nil)
        #expect(PaneGridOverride(columns: 1024, rows: 1024) != nil)
        #expect(PaneGridOverride(columns: 1, rows: 1) == nil)
        #expect(PaneGridOverride(columns: 2, rows: 0) == nil)
        #expect(PaneGridOverride(columns: 1025, rows: 24) == nil)
        #expect(PaneGridOverride(columns: 80, rows: 1025) == nil)
    }

    // MARK: - Persistence

    @Test("a snapshot round-trip preserves an override, and an unclaimed pane writes no key")
    func roundTripPreservesTheOverride() throws {
        var model = makeModel()
        let (plain, claimed) = splitPaneIds(&model)
        update(&model, .setPaneGridOverride(paneId: claimed, grid: grid(60, 30)))

        let snapshot = toSnapshot(model)
        #expect(paneSnapshot(plain.rawValue.uuidString, in: snapshot)?.gridOverride == nil)

        let restored = try #require(validateAndBuild(snapshot))
        #expect(restored.pane(claimed)?.gridOverride == grid(60, 30))
        #expect(restored.pane(plain)?.gridOverride == nil)
    }

    @Test("a persisted override outside the accepted range restores as absent")
    func outOfRangePersistedOverrideRestoresAsAbsent() throws {
        // Intent: a hand-edited or corrupt override decodes to no override, so
        //   the pane launches at its slot-derived grid.
        // Why it exists: a clamped or trusted corrupt value would spawn the
        //   restored child at a grid no client ever asked for.
        // Scenario: spec-first -- a snapshot leaf carrying 99999 columns.
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
                  "gridOverride": { "columns": 99999, "rows": 30 }
                } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: json.data(using: .utf8)!)
        let model = try #require(validateAndBuild(initFile.model))
        let paneId = try #require(model.allPanes.first?.id)

        #expect(model.pane(paneId)?.gridOverride == nil)
    }
}
