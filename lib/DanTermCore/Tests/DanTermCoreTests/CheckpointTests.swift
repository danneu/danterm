// Swift Testing coverage for checkpoint snapshot fidelity and the scrollback sidecar's codec
// and graft. Projection-derived scheduling behavior lives in CheckpointCaptureTests; this suite
// keeps the persisted codec contract and the sidecar graft independent of runtime disk I/O.
import Foundation
import Testing

@testable import DanTermCore

private func makeRestore(_ paneSnapshots: [PaneId: PaneSnapshot], model: AppModel) -> ValidatedAppRestore {
    ValidatedAppRestore(model: model, paneSnapshots: paneSnapshots)
}
private func paneSnap(_ id: PaneId, title: String, cwd: String? = nil, scrollback: String? = nil, theme: String? = nil) -> PaneSnapshot {
    PaneSnapshot(id: id, title: title, cwd: cwd, command: nil, scrollback: scrollback, theme: theme)
}

@Suite struct CheckpointTests {
    // MARK: - Snapshot fidelity

    @Test("toSnapshot does not persist isZoomed — restored tabs are always unzoomed")
    func toSnapshotDoesNotPersistIsZoomed() throws {
        // Intent: snapshot round-trip clears isZoomed; restored tabs
        //   are always unzoomed.
        // Why it exists: pins the transient-zoom rule for restore.
        // Scenario: spec-first restore unzoom.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))
        let tab = selectedTab(in: model)!
        #expect(tab.paneTree.isZoomed, "tab should be zoomed before snapshot")

        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        let restoredTab = selectedTab(in: restored)!
        #expect(!restoredTab.paneTree.isZoomed, "restored tab should not be zoomed")
    }

    // MARK: - Scrollback sidecar codec

    @Test("the sidecar round-trips pane text through its own file format")
    func sidecarRoundTripsPaneText() throws {
        // Intent: what `encodeScrollbackSidecar` writes is what `loadScrollbackSidecar`
        //   reads back, keyed by the same pane ids.
        // Why it exists: the sidecar is the only file the graft reads, and it carries no
        //   structure to cross-check its keys against, so a key that does not survive the
        //   round trip loses a pane's history with nothing else noticing.
        // Scenario: spec-first. Two panes' text is written and read back.
        let a = PaneId()
        let b = PaneId()

        let decoded = try #require(
            loadScrollbackSidecar(from: encodeScrollbackSidecar([a: "a text\n", b: "b text\n"]))
        )

        #expect(decoded == [a: "a text\n", b: "b text\n"])
    }

    @Test("a sidecar that does not decode, or carries another version, reads as absent")
    func unreadableSidecarReadsAsAbsent() throws {
        // Intent: corrupt bytes and a foreign version each report nil rather than a partial
        //   or adapted result.
        // Why it exists: DanTerm keeps no version-dispatch fork, and the loader's rule is
        //   "a bad sidecar costs the session its scrollback, never its structure" (plan I5).
        //   Both states have to reach the loader as the same "absent" answer for that to hold.
        // Scenario: spec-first. A truncated write, and a sidecar from another format version.
        #expect(loadScrollbackSidecar(from: Data("{ not json".utf8)) == nil)

        let foreign = try JSONSerialization.data(withJSONObject: [
            "version": scrollbackSidecarVersion + 1,
            "scrollback": [PaneId().rawValue.uuidString: "text\n"],
        ])
        #expect(loadScrollbackSidecar(from: foreign) == nil)
    }

    @Test("an entry whose key is not a pane id is dropped, and the rest survive")
    func sidecarDropsUnreadableKeys() throws {
        // Intent: one unusable key costs only its own entry.
        // Why it exists: the graft is defensive by id anyway, so failing the whole file over
        //   a single key would throw away scrollback the loader could still have used.
        // Scenario: spec-first. A hand-built sidecar holds one real pane id and one key that
        //   is not a UUID at all.
        let pane = PaneId()
        let mixed = try JSONSerialization.data(withJSONObject: [
            "version": scrollbackSidecarVersion,
            "scrollback": [pane.rawValue.uuidString: "kept\n", "not-a-uuid": "dropped\n"],
        ])

        #expect(loadScrollbackSidecar(from: mixed) == [pane: "kept\n"])
    }

    // MARK: - Sidecar graft (the session owns structure)

    @Test("the graft adds sidecar text by pane id and ignores panes the session does not hold")
    func graftAddsTextByIdAndIgnoresUnknownPanes() {
        // Intent: a pane the session holds gets its sidecar text; a sidecar entry for a pane
        //   the session does not hold contributes nothing (plan I6, PO6).
        // Why it exists: the sidecar is written on its own schedule, so it routinely predates
        //   the session file -- and after an empty-model quit it is deliberately stale. An
        //   entry for a closed pane must never resurrect that pane or reach the restore.
        // Scenario: spec-first. The session holds pane A; the sidecar holds A and closed B.
        let a = PaneId()
        let b = PaneId()
        let session = makeRestore([a: paneSnap(a, title: "kept", cwd: "/work")], model: makeModel())

        let grafted = graftSidecar(
            onto: session,
            scrollbackByPaneId: [a: "a text\n", b: "b text\n"]
        )

        #expect(grafted.paneSnapshots.count == 1)
        #expect(grafted.paneSnapshots[a]?.scrollback == "a text\n")
        #expect(grafted.paneSnapshots[a]?.title == "kept", "the session still owns pane metadata")
        #expect(grafted.paneSnapshots[a]?.cwd == "/work")
        #expect(grafted.paneSnapshots[b] == nil, "a pane only the sidecar knows about is ignored")
    }

    @Test("a pane the sidecar does not mention restores with nil scrollback")
    func graftLeavesUnmentionedPanesWithoutScrollback() {
        // Intent: an empty sidecar leaves the restore exactly as the session file described it.
        // Why it exists: a pane opened after the last sidecar write, and a first launch with
        //   no sidecar at all, both take this path (plan I6).
        // Scenario: spec-first. One pane, no sidecar entries.
        let pane = PaneId()
        let session = makeRestore([pane: paneSnap(pane, title: "fresh", cwd: "/fresh")], model: makeModel())

        let grafted = graftSidecar(onto: session, scrollbackByPaneId: [:])

        #expect(grafted.paneSnapshots.count == 1)
        #expect(grafted.paneSnapshots[pane]?.scrollback == nil)
        #expect(grafted.paneSnapshots[pane]?.title == "fresh")
        #expect(grafted.model.groups.count == session.model.groups.count)
    }
}
