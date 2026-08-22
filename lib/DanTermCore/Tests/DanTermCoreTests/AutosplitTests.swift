// Autosplit resolution and IPC bridge coverage. These tests pin geometry choice
// separately from the ordinary pane-split path that performs the mutation.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct AutosplitTests {
    @Test("longer dimension chooses the split axis", arguments: [
        (PaneLayoutRect(x: 0, y: 0, width: 400, height: 250), SplitNodeModel.Direction.horizontal),
        (PaneLayoutRect(x: 0, y: 0, width: 250, height: 400), SplitNodeModel.Direction.vertical),
        (PaneLayoutRect(x: 0, y: 0, width: 300, height: 300), SplitNodeModel.Direction.horizontal),
    ])
    func longerDimensionChoosesAxis(_ frame: PaneLayoutRect, _ direction: SplitNodeModel.Direction) throws {
        let paneId = PaneId(rawValue: UUID())
        let resolution = autosplitResolution(
            in: PaneLayout(placements: [paneId: .visible(frame)], dividers: [:]),
            metrics: .standard
        )

        #expect(resolution == AutosplitResolution(paneId: paneId, direction: direction))
    }

    @Test("largest pane below its axis threshold yields to a smaller splittable pane")
    func thresholdCanChooseSecondLargestPane() {
        let tooShort = PaneId(rawValue: UUID())
        let splittable = PaneId(rawValue: UUID())
        let minimum = PaneLayoutMetrics.standard.minimumPaneExtent
        let divider = PaneLayoutMetrics.standard.dividerThickness
        let threshold = minimum * 2 + divider
        let layout = PaneLayout(
            placements: [
                tooShort: .visible(PaneLayoutRect(x: 0, y: 0, width: threshold - 1, height: threshold - 1)),
                splittable: .visible(PaneLayoutRect(x: 0, y: 300, width: threshold, height: 50)),
            ],
            dividers: [:]
        )

        #expect(autosplitResolution(in: layout)?.paneId == splittable)
    }

    @Test("equal areas resolve toward top-left independent of dictionary order")
    func equalAreasResolveTowardTopLeft() {
        let topLeft = PaneId(rawValue: UUID())
        let bottomRight = PaneId(rawValue: UUID())
        let topLeftFrame = PaneLayoutRect(x: 0, y: 300, width: 300, height: 300)
        let bottomRightFrame = PaneLayoutRect(x: 300, y: 0, width: 300, height: 300)

        for frames in [
            [topLeft: topLeftFrame, bottomRight: bottomRightFrame],
            [bottomRight: bottomRightFrame, topLeft: topLeftFrame],
        ] {
            #expect(autosplitResolution(
                in: PaneLayout(placements: frames.mapValues(PanePlacement.visible), dividers: [:])
            )?.paneId == topLeft)
        }
    }

    @Test("a layout with no splittable pane has no resolution")
    func noSplittablePaneHasNoResolution() {
        let paneId = PaneId(rawValue: UUID())
        let hiddenPaneId = PaneId(rawValue: UUID())
        let layout = PaneLayout(
            placements: [
                paneId: .visible(PaneLayoutRect(x: 0, y: 0, width: 200, height: 200)),
                hiddenPaneId: .hidden,
            ],
            dividers: [:]
        )

        #expect(autosplitResolution(in: layout) == nil)
    }

    @Test("tab-targeted split only requests runtime measurement")
    func tabTargetedSplitOnlyRequestsMeasurement() throws {
        var model = makeModel()
        createTab(&model)
        let tabId = try #require(selectedTab(in: model)?.id)
        let before = model
        let requestId = UUID()
        let caller = IpcCallerIdentity.remote(nodeId: "phone", user: "dan", machineName: "iPhone")

        let commands = update(&model, .ipcRequest(
            reqId: requestId,
            caller: caller,
            request: .paneSplit(target: .tab(tabId), launch: nil, background: true)
        ))

        #expect(model == before)
        #expect(commands.count == 1)
        guard case .resolveAutosplit(let id, let commandCaller, let commandTab, _, let background) = commands[0] else {
            Issue.record("expected one autosplit measurement command")
            return
        }
        #expect(id == requestId)
        #expect(commandCaller == caller)
        #expect(commandTab == tabId)
        #expect(background)
    }

    @Test("unknown tab is refused before measurement")
    func unknownTabIsRefusedBeforeMeasurement() {
        var model = makeModel()
        createTab(&model)
        let before = model
        let requestId = UUID()

        let commands = update(&model, .ipcRequest(
            reqId: requestId,
            caller: .local,
            request: .paneSplit(target: .tab(TabId()), launch: nil, background: true)
        ))

        #expect(model == before)
        #expect(commands.count == 1)
        guard case .ipcError(let id, _, let message) = commands[0] else {
            Issue.record("expected an IPC refusal")
            return
        }
        #expect(id == requestId)
        #expect(message == "tab not found")
    }

    @Test("no autosplit candidate refuses without mutation")
    func noCandidateRefusesWithoutMutation() {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let before = model
        let requestId = UUID()

        let commands = update(&model, .autosplitResolved(
            reqId: requestId,
            caller: .local,
            tabId: tabId,
            resolution: nil,
            launch: nil,
            background: true
        ))

        #expect(model == before)
        #expect(commands.count == 1)
        guard case .ipcError(let id, let code, let message) = commands[0] else {
            Issue.record("expected an IPC refusal")
            return
        }
        #expect(id == requestId)
        #expect(code == -32602)
        #expect(message == "tab has no pane large enough to split")
    }

    @Test("resolved autosplit re-enters the ordinary deferred pane split")
    func resolvedAutosplitReentersOrdinarySplit() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        let paneId = tab.paneTree.focusedPaneId
        let requestId = UUID()

        let commands = update(&model, .ipcRequest(
            reqId: requestId,
            caller: .local,
            request: .paneSplit(
                target: .pane(paneId, direction: .vertical),
                launch: LaunchSpec(cmd: "pwd", cwd: "/tmp", title: "new"),
                background: true
            )
        ))

        #expect(commands.contains {
            if case .createSession(_, _, let cwd, let command, _) = $0 {
                return cwd == "/tmp" && command == "pwd"
            }
            return false
        })
        #expect(model.pendingSessionCreations.values.contains { $0.requestId == requestId })
        #expect(selectedTab(in: model)?.paneTree.focusedPaneId == paneId)

        let newSessionId = try #require(model.pendingSessionCreations.first?.key)
        let startCommands = update(&model, .sessionProcessStarted(sessionId: newSessionId))
        #expect(startCommands.count {
            if case .ipcReply(let id, _) = $0 { return id == requestId }
            return false
        } == 1)
        #expect(model.pendingSessionCreations.isEmpty)
    }

    @Test("resolved autosplit preserves zoom and applies focus policy", arguments: [true, false])
    func resolvedAutosplitPreservesZoomAndFocusPolicy(_ background: Bool) throws {
        var model = makeModel()
        createTab(&model)
        let originalPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .splitPane(
            paneId: originalPaneId,
            direction: .horizontal,
            background: true
        ))
        _ = update(&model, .toggleZoomPane(paneId: originalPaneId))
        let beforePaneIds = Set(model.allPaneIds)
        let tabId = try #require(selectedTab(in: model)?.id)

        _ = update(&model, .autosplitResolved(
            reqId: UUID(),
            caller: .local,
            tabId: tabId,
            resolution: AutosplitResolution(paneId: originalPaneId, direction: .vertical),
            launch: nil,
            background: background
        ))

        let newPaneId = try #require(Set(model.allPaneIds).subtracting(beforePaneIds).first)
        #expect(selectedTab(in: model)?.paneTree.isZoomed == true)
        #expect(selectedTab(in: model)?.paneTree.focusedPaneId == (background ? originalPaneId : newPaneId))
    }
}
