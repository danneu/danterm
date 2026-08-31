// AppKit-side proof that autosplit measures the named tab's arranged layout,
// including a hidden and zoomed tab, before re-entering pure IPC dispatch.
import Cocoa
import DanTermProtocol
import Testing

@testable import DanTerm

@MainActor
struct AppRuntimeAutosplitTests {
    @Test("autosplit measures the named hidden tab and ignores zoom")
    func autosplitMeasuresNamedHiddenTabIgnoringZoom() throws {
        let ports = RecordingAppRuntimePorts()
        var model = AppModel(groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")])
        _ = update(&model, .createTabInSelectedGroup())
        let targetTabId = try #require(selectedTab(in: model)?.id)
        let targetPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .splitPane(
            paneId: targetPaneId,
            direction: .horizontal,
            background: true
        ))
        _ = update(&model, .toggleZoomPane(paneId: targetPaneId))
        _ = update(&model, .createTabInSelectedGroup())
        let visibleTabId = try #require(selectedTab(in: model)?.id)
        let runtime = makeCommandTestRuntime(ports, initialModel: model)
        defer { runtime.shutdown() }

        let targetContainer = SplitContainerView(
            rootNode: try #require(tabById(targetTabId, in: model)?.paneTree.root),
            zoomedPaneId: targetPaneId,
            wrapperLookup: { _ in nil },
            runtime: runtime,
            frame: NSRect(x: 0, y: 0, width: 250, height: 500)
        )
        targetContainer.isHidden = true
        let visibleContainer = SplitContainerView(
            rootNode: try #require(tabById(visibleTabId, in: model)?.paneTree.root),
            zoomedPaneId: nil,
            wrapperLookup: { _ in nil },
            runtime: runtime,
            frame: NSRect(x: 0, y: 0, width: 500, height: 250)
        )
        runtime.tabContainers = [targetTabId: targetContainer, visibleTabId: visibleContainer]

        runtime.perform(.resolveAutosplit(
            reqId: UUID(),
            caller: .local,
            tabId: targetTabId,
            launch: nil,
            background: true
        ))

        guard case .split(
            _,
            .horizontal,
            .split(_, let direction, _, _, _),
            _,
            _
        )? = tabById(targetTabId, in: runtime.model)?.paneTree.root else {
            Issue.record("expected the hidden target tab to split")
            return
        }
        #expect(direction == .vertical)
        #expect(runtime.model.selectedTabId == visibleTabId)
        #expect(tabById(targetTabId, in: runtime.model)?.paneTree.zoomedPaneId == targetPaneId)
    }
}
