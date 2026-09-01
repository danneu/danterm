// Measures one complete `update()` dispatch -- the matched arm plus the whole `defer` sweep --
// in the production optimization shape, across a tab count the sweep's work scales with. The
// Python driver compiles this file and DanTermCore as one module against an optimized
// DanTermProtocol dependency, with `-O` and without `-enable-testing`.
//
// The question is whether the unconditional sweep is a real per-message cost for the messages
// that arrive most often. The workload is therefore the highest-frequency message DanTerm
// dispatches (a session title report at 30-60 Hz) against a model whose only varying dimension
// is the tab count the sweep hashes and scans.
import Darwin
import Foundation

#if !REDUCER_DISPATCH_RELEASE_PROBE
#error("Use just reducer-dispatch-cost so the probe has its required build configuration")
#endif

/// The one model dimension that varies across the series: how many tabs the sweep must repair.
///
/// Group count is fixed so that only the per-tab work moves between measurements, and the
/// target pane always sits in the first tab of the first group so the arm's own session
/// lookup -- a linear scan -- costs the same at every size. What is left in the difference
/// between two sizes is the state-scaling work, which is what the decision rule reads.
struct ProbeLayout {
    let tabCount: Int

    static let groupCount = 4

    var tabsPerGroup: Int { tabCount / ProbeLayout.groupCount }
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

/// The fixture plus the identity of the one session every dispatch reports against.
struct ProbeFixture {
    var model: AppModel
    let sessionId: SessionId
    let tabCount: Int
}

/// The full alert feed the sweep scans on every message.
let alertFeedSize = 100

/// Returns a pane carrying a running session, which is what a title report can land on.
func makeProbePane(index: Int, ids: inout ProbeIdFactory) -> PaneModel {
    var session = SessionModel(id: SessionId(rawValue: ids.uuid()))
    session.processPhase = .running
    session.titleState = .declared("pane-\(index)")
    session.cwd = NSHomeDirectory() + "/reducer-dispatch/\(index)"
    session.lastCommand = "make pane-\(index)"

    var pane = PaneModel(id: PaneId(rawValue: ids.uuid()))
    pane.session = session
    pane.theme = "Nord"
    return pane
}

/// Builds a model of `layout.tabCount` single-pane tabs with a saturated alert feed.
///
/// Every alert belongs to a pane other than the selected tab's focused pane and stays unread,
/// so `reconcileFocusedPaneAlerts` scans the whole feed on every dispatch and changes nothing.
/// That keeps all 100k dispatches identical work on identical state -- the alternative, alerts
/// the first dispatch clears, would measure one draining pass and 99,999 cheaper ones.
func makeProbeFixture(_ layout: ProbeLayout) -> ProbeFixture {
    var ids = ProbeIdFactory()
    var groups: [GroupModel] = []
    var otherPaneIds: [PaneId] = []
    var targetSessionId: SessionId?
    var selectedTabId: TabId?

    var paneIndex = 0
    for groupIndex in 0..<ProbeLayout.groupCount {
        var tabs: [TabModel] = []
        for tabIndex in 0..<layout.tabsPerGroup {
            let pane = makeProbePane(index: paneIndex, ids: &ids)
            paneIndex += 1
            if targetSessionId == nil {
                targetSessionId = pane.session?.id
            } else {
                otherPaneIds.append(pane.id)
            }
            let tab = TabModel(
                id: TabId(rawValue: ids.uuid()),
                customTitle: "tab \(groupIndex)-\(tabIndex)",
                paneTree: PaneTree(root: .leaf(pane), focusedPaneId: pane.id),
                color: TabColor.allCases[(groupIndex + tabIndex) % TabColor.allCases.count]
            )
            if selectedTabId == nil { selectedTabId = tab.id }
            tabs.append(tab)
        }
        groups.append(GroupModel(
            id: GroupId(rawValue: ids.uuid()),
            name: "group \(groupIndex)",
            isCollapsed: false,
            tabs: tabs
        ))
    }

    // The feed's whole point is alerts the sweep scans but never clears, so a layout with no
    // pane besides the target would silently measure a different workload.
    precondition(!otherPaneIds.isEmpty, "the layout must leave a pane the alert feed can own")
    var model = AppModel(groups: groups, selectedTabId: selectedTabId)
    model.isAppActive = true
    var config = DanTermConfig.default
    config.alertClearMode = .focus
    model.config = config
    let raised = Date(timeIntervalSince1970: 1_800_000_000)
    model.alerts = (0..<alertFeedSize).map { index in
        AlertModel(
            id: AlertId(rawValue: ids.uuid()),
            kind: index.isMultiple(of: 2) ? .bell : .desktopNotification,
            paneId: otherPaneIds[index % otherPaneIds.count],
            title: DisplayLine("alert \(index)"),
            body: "alert body \(index)",
            createdAt: raised,
            isUnread: true
        )
    }

    return ProbeFixture(model: model, sessionId: targetSessionId!, tabCount: layout.tabCount)
}

/// Reads the target pane's declared title in constant time, so the coverage check that proves
/// each dispatch mutated the model cannot itself scale with the tab count being measured.
func targetTitle(in model: AppModel) -> String? {
    guard case .leaf(let pane) = model.groups[0].tabs[0].paneTree.root else { return nil }
    return pane.session?.titleState.claimed
}

/// Keeps the dispatch opaque to the loop optimizer while letting production code optimize.
@inline(never)
func dispatchTitleReport(_ model: inout AppModel, sessionId: SessionId, title: String) -> Int {
    update(&model, .sessionReport(sessionId: sessionId, report: .title(title))).count
}

/// Returns the conventional midpoint median for an even or odd non-empty sample.
func median(_ values: [UInt64]) -> UInt64 {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
    return sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
}

/// One tab count's timing beside the counts that prove the workload actually ran.
struct ProbeMeasurement {
    let tabCount: Int
    let sampleCount: Int
    let medianNanoseconds: UInt64
    let titleChangeCount: Int
    let commandCount: Int
    let alertCount: Int
    let recencyCount: Int
    let selectionIsNewestFocus: Bool

    /// Coverage is about the workload, never about the shape of the result.
    ///
    /// Deliberately no scaling self-check: whether the cost grows with the tab count is the
    /// question this probe was built to answer, so requiring growth before reading the answer
    /// would decide it in advance.
    var coverageIsValid: Bool {
        titleChangeCount == sampleCount
            && commandCount == 0
            && alertCount == alertFeedSize
            && recencyCount == tabCount
            && selectionIsNewestFocus
    }
}

/// Times individual dispatches and consumes every result the dispatch produced.
func measure(fixture: ProbeFixture, sampleCount: Int) -> ProbeMeasurement {
    var model = fixture.model
    // One warm-up dispatch stamps the selected tab's recency, so the timed dispatches all
    // see the same already-reconciled state a running app is in.
    _ = dispatchTitleReport(&model, sessionId: fixture.sessionId, title: "warm-up")

    var samples: [UInt64] = []
    samples.reserveCapacity(sampleCount)
    var titleChangeCount = 0
    var commandCount = 0
    var previousTitle = targetTitle(in: model)
    // Built up front: interpolating a title is a String allocation the reducer does not do,
    // and inside the timed window it would be charged to every dispatch.
    let titles = (0..<sampleCount).map { "title \($0)" }
    for index in 0..<sampleCount {
        let title = titles[index]
        let start = DispatchTime.now().uptimeNanoseconds
        let commands = dispatchTitleReport(&model, sessionId: fixture.sessionId, title: title)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        samples.append(elapsed)
        commandCount += commands
        let observed = targetTitle(in: model)
        if observed == title && observed != previousTitle { titleChangeCount += 1 }
        previousTitle = observed
    }
    return ProbeMeasurement(
        tabCount: fixture.tabCount,
        sampleCount: sampleCount,
        medianNanoseconds: median(samples),
        titleChangeCount: titleChangeCount,
        commandCount: commandCount,
        alertCount: model.alerts.count,
        recencyCount: tabsByRecency(in: model).count,
        selectionIsNewestFocus: model.focusClock != 0
            && model.selectedTabId.flatMap { tabById($0, in: model) }?.focusStamp == model.focusClock
    )
}

let sampleCount = 100_000
// Frozen by the plan before any result existed, from budget arithmetic rather than from data:
// at the 60 Hz worst case, 1000 ns/dispatch of state-scaling cost is 60 us/s, 0.006% of a core.
let boundNanoseconds: UInt64 = 1000
let smallestTabCount = 8
let largestTabCount = 128
let layouts = [smallestTabCount, 32, largestTabCount].map(ProbeLayout.init(tabCount:))
var measurements: [ProbeMeasurement] = []

print(
    "reducer-dispatch-cost build=-O,wmo enable_testing=false samples=\(sampleCount) "
        + "groups=\(ProbeLayout.groupCount) alerts=\(alertFeedSize) alert_clear_mode=focus "
        + "bound_ns=\(boundNanoseconds)"
)
for layout in layouts {
    let result = measure(fixture: makeProbeFixture(layout), sampleCount: sampleCount)
    measurements.append(result)
    print(
        "dispatch tabs=\(result.tabCount) samples=\(result.sampleCount) "
            + "median_ns=\(result.medianNanoseconds) title_changes=\(result.titleChangeCount) "
            + "commands=\(result.commandCount) alerts=\(result.alertCount) "
            + "recency=\(result.recencyCount) selection_newest=\(result.selectionIsNewestFocus)"
    )
}

guard measurements.allSatisfy({ $0.coverageIsValid }) else {
    print("verdict=not-measured reason=coverage-validation-failed")
    exit(2)
}

guard let smallest = measurements.first(where: { $0.tabCount == smallestTabCount }),
      let largest = measurements.first(where: { $0.tabCount == largestTabCount })
else {
    print("verdict=not-measured reason=decision-cells-missing")
    exit(2)
}

// Unsigned arithmetic: a largest-tab median at or below the smallest-tab median is a delta of
// zero, not a wrap-around, and it fails the rule like any other delta under the bound.
let delta = largest.medianNanoseconds > smallest.medianNanoseconds
    ? largest.medianNanoseconds - smallest.medianNanoseconds
    : 0
let fires = delta >= boundNanoseconds
print(
    "delta from_tabs=\(smallest.tabCount) to_tabs=\(largest.tabCount) delta_ns=\(delta) "
        + "bound_ns=\(boundNanoseconds) fires=\(fires)"
)
// Both outcomes are answers, so both exit 0. Only a probe that could not measure fails.
print("verdict=\(fires ? "sweep-is-a-per-message-cost" : "sweep-is-not-a-per-message-cost")")
exit(0)
