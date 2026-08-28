// Measures complete light-checkpoint snapshot construction plus baseline comparison in the
// production optimization shape. The Python driver compiles this file and DanTermCore as one
// module against an optimized DanTermProtocol dependency, with `-O` and without
// `-enable-testing`.
import Darwin
import Foundation

#if !CHECKPOINT_PROJECTION_RELEASE_PROBE
#error("Use just checkpoint-projection-cost so the probe has its required build configuration")
#endif

/// The fixed model dimensions whose pane-count scaling validates the measurement.
struct ProbeLayout {
    let panesPerTab: Int

    var paneCount: Int { 4 * 4 * panesPerTab }
}

/// Mints stable UUIDs so fixture identity cannot add run-to-run input variation.
struct ProbeIdFactory {
    private var next: UInt64 = 1

    mutating func uuid() -> UUID {
        defer { next += 1 }
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = next
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Carries the fixture plus stable mutation targets for all three scenarios.
struct ProbeFixture {
    var model: AppModel
    let paneId: PaneId
    let splitId: SplitId
}

/// Returns a pane whose every persisted field has a non-default value.
func makeProbePane(
    groupIndex: Int,
    tabIndex: Int,
    paneIndex: Int,
    ids: inout ProbeIdFactory
) -> PaneModel {
    let paneId = PaneId(rawValue: ids.uuid())
    var session = SessionModel(id: SessionId(rawValue: ids.uuid()))
    session.processPhase = .running
    session.titleState = .declared("pane-\(groupIndex)-\(tabIndex)-\(paneIndex)")
    session.cwd = NSHomeDirectory() + "/projection-cost/\(groupIndex)/\(tabIndex)/\(paneIndex)"
    session.connection = .remote(identity: RemoteSession(user: "probe", host: "host"))
    session.lastCommand = "make pane-\(paneIndex)"
    session.lastAgentSession = AgentSession(kind: "codex", sessionId: "probe-\(paneIndex)")!

    var pane = PaneModel(id: paneId)
    pane.session = session
    pane.theme = "Nord"
    pane.fontSizeSteps = 2
    pane.gridOverride = PaneGridOverride(columns: 120, rows: 40)!
    pane.todos = [TodoItem(
        id: TodoId(rawValue: ids.uuid()),
        text: TodoText("pane todo \(paneIndex)")!,
        isDone: paneIndex.isMultiple(of: 2)
    )]
    return pane
}

/// Builds a balanced split tree and returns every leaf id in display order.
func makeProbeTree(
    panes: ArraySlice<PaneModel>,
    depth: Int,
    ids: inout ProbeIdFactory
) -> (node: SplitNodeModel, paneIds: [PaneId]) {
    precondition(!panes.isEmpty)
    if panes.count == 1 {
        let pane = panes.first!
        return (.leaf(pane), [pane.id])
    }
    let midpoint = panes.index(panes.startIndex, offsetBy: panes.count / 2)
    let first = makeProbeTree(panes: panes[..<midpoint], depth: depth + 1, ids: &ids)
    let second = makeProbeTree(panes: panes[midpoint...], depth: depth + 1, ids: &ids)
    return (
        .split(
            id: SplitId(rawValue: ids.uuid()),
            direction: depth.isMultiple(of: 2) ? .horizontal : .vertical,
            first: first.node,
            second: second.node,
            ratio: depth.isMultiple(of: 2) ? 0.4 : 0.6
        ),
        first.paneIds + second.paneIds
    )
}

/// Builds four groups of four tabs with the requested balanced pane count.
func makeProbeFixture(_ layout: ProbeLayout) -> ProbeFixture {
    var ids = ProbeIdFactory()
    var groups: [GroupModel] = []
    var targetPaneId: PaneId?
    var targetSplitId: SplitId?

    for groupIndex in 0..<4 {
        var tabs: [TabModel] = []
        for tabIndex in 0..<4 {
            let panes = (0..<layout.panesPerTab).map {
                makeProbePane(
                    groupIndex: groupIndex,
                    tabIndex: tabIndex,
                    paneIndex: $0,
                    ids: &ids
                )
            }
            let tree = makeProbeTree(panes: panes[...], depth: 0, ids: &ids)
            if targetPaneId == nil {
                targetPaneId = tree.paneIds[0]
                if case .split(let id, _, _, _, _) = tree.node { targetSplitId = id }
            }
            tabs.append(TabModel(
                id: TabId(rawValue: ids.uuid()),
                customTitle: "tab \(groupIndex)-\(tabIndex)",
                paneTree: PaneTree(root: tree.node, focusedPaneId: tree.paneIds.last!),
                color: TabColor.allCases[(groupIndex + tabIndex) % TabColor.allCases.count],
                todos: [TodoItem(
                    id: TodoId(rawValue: ids.uuid()),
                    text: TodoText("tab todo \(tabIndex)")!,
                    isDone: tabIndex.isMultiple(of: 2)
                )]
            ))
        }
        groups.append(GroupModel(
            id: GroupId(rawValue: ids.uuid()),
            name: "group \(groupIndex)",
            isCollapsed: true,
            tabs: tabs
        ))
    }

    return ProbeFixture(
        model: AppModel(groups: groups, selectedTabId: groups.last!.tabs.last!.id),
        paneId: targetPaneId!,
        splitId: targetSplitId!
    )
}

/// One projection-and-comparison case with its expected consumed equality result.
struct ProbeScenario {
    let name: String
    let model: AppModel
    let baseline: LightCheckpointProjection
    let expectsEqual: Bool
}

/// Makes persisted-title, persisted-ratio, and live-progress scenarios from one fixture.
func makeProbeScenarios(_ fixture: ProbeFixture) -> [ProbeScenario] {
    let baseline = LightCheckpointProjection(snapshot: toSnapshot(fixture.model))

    var titleModel = fixture.model
    titleModel.updatePane(fixture.paneId) { pane in
        guard let claimed = pane.session?.titleState.claimed else { return }
        pane.session?.titleState = .declared(claimed + " changed")
    }

    var ratioModel = fixture.model
    ratioModel.groups[0].tabs[0].paneTree.updateRatio(splitId: fixture.splitId, ratio: 0.7)

    var progressModel = fixture.model
    progressModel.updatePane(fixture.paneId) { $0.session?.progress = .set(percent: 50) }

    return [
        ProbeScenario(
            name: "persisted-title", model: titleModel, baseline: baseline, expectsEqual: false),
        ProbeScenario(
            name: "persisted-split-ratio", model: ratioModel,
            baseline: baseline, expectsEqual: false),
        ProbeScenario(
            name: "live-progress", model: progressModel, baseline: baseline, expectsEqual: true),
    ]
}

/// Keeps each operation opaque to the loop optimizer while allowing production code to optimize.
@inline(never)
func projectionEqualsBaseline(
    model: AppModel,
    baseline: LightCheckpointProjection
) -> Bool {
    LightCheckpointProjection(snapshot: toSnapshot(model)) == baseline
}

/// Returns the conventional midpoint median for an even or odd non-empty sample.
func median(_ values: [UInt64]) -> UInt64 {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
    return sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
}

/// One scenario's timing and the equality count that proves every result was consumed.
struct ProbeMeasurement {
    let paneCount: Int
    let scenario: String
    let sampleCount: Int
    let medianNanoseconds: UInt64
    let expectedEqual: Bool
    let equalCount: Int

    var consumedResultIsValid: Bool {
        equalCount == (expectedEqual ? sampleCount : 0)
    }
}

/// Measures individual complete projection comparisons and consumes every equality result.
func measure(
    paneCount: Int,
    scenario: ProbeScenario,
    sampleCount: Int
) -> ProbeMeasurement {
    var samples: [UInt64] = []
    samples.reserveCapacity(sampleCount)
    var equalCount = 0
    for _ in 0..<sampleCount {
        let start = DispatchTime.now().uptimeNanoseconds
        let isEqual = projectionEqualsBaseline(model: scenario.model, baseline: scenario.baseline)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        samples.append(elapsed)
        if isEqual { equalCount += 1 }
    }
    return ProbeMeasurement(
        paneCount: paneCount,
        scenario: scenario.name,
        sampleCount: sampleCount,
        medianNanoseconds: median(samples),
        expectedEqual: scenario.expectsEqual,
        equalCount: equalCount
    )
}

let sampleCount = 100_000
let limitNanoseconds: UInt64 = 417_000
let layouts = [4, 8, 16].map(ProbeLayout.init(panesPerTab:))
var measurements: [ProbeMeasurement] = []

print("checkpoint-projection-cost build=-O,wmo enable_testing=false samples=\(sampleCount) limit_ns=\(limitNanoseconds)")
for layout in layouts {
    let fixture = makeProbeFixture(layout)
    for scenario in makeProbeScenarios(fixture) {
        let result = measure(
            paneCount: layout.paneCount,
            scenario: scenario,
            sampleCount: sampleCount
        )
        measurements.append(result)
        print(
            "scenario=\(result.scenario) panes=\(result.paneCount) "
                + "samples=\(result.sampleCount) median_ns=\(result.medianNanoseconds) "
                + "expected_equal=\(result.expectedEqual) equal_count=\(result.equalCount)"
        )
    }
}

var valid = measurements.allSatisfy {
    $0.sampleCount == sampleCount && $0.consumedResultIsValid
}
for scenario in ["persisted-title", "persisted-split-ratio", "live-progress"] {
    let series = measurements.filter { $0.scenario == scenario }.sorted { $0.paneCount < $1.paneCount }
    for index in 1..<series.count {
        let smaller = series[index - 1]
        let larger = series[index]
        let scales = larger.medianNanoseconds * 2 >= smaller.medianNanoseconds * 3
        valid = valid && scales
        print(
            "scaling scenario=\(scenario) from=\(smaller.paneCount) to=\(larger.paneCount) "
                + "minimum=1.5x valid=\(scales)"
        )
    }
}

guard valid else {
    print("verdict=not-measured reason=coverage-validation-failed")
    exit(2)
}

let decisionMeasurements = measurements.filter { $0.paneCount == 128 }
let costPasses = decisionMeasurements.allSatisfy { $0.medianNanoseconds <= limitNanoseconds }
for result in decisionMeasurements {
    print(
        "cost scenario=\(result.scenario) median_ns=\(result.medianNanoseconds) "
            + "limit_ns=\(limitNanoseconds) pass=\(result.medianNanoseconds <= limitNanoseconds)"
    )
}
print("verdict=\(costPasses ? "pass" : "cost-limit-failed")")
exit(costPasses ? 0 : 1)
