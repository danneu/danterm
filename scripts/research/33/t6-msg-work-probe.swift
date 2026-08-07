// Research doc 33, task T6: the per-`Msg` work probe for the pure app runtime.
//
// Built by `t6-msg-work.py`, which compiles this file as one module together with a staged
// copy of `lib/DanTermCore/Sources/DanTermCore` and `lib/DanTermProtocol/Sources/DanTermProtocol`.
// The staged copy is either instrumented (counter mode) or byte-identical to the repo
// (timing mode); this file is the same in both.
//
// What it restates, and why: `AppRuntime.reconcile()` lives in `app/`, which is AppKit and
// cannot be built headlessly. Its passes split cleanly into a pure projection and a thin
// AppKit executor, so the sweep below runs every pure half in `reconcile()`'s own order,
// against the same `ReconcilerCaches` discipline (each pass diffs against the value it last
// applied). The AppKit executors and `syncPaneVisibility` are the only omissions, and they
// are named in the finding. Nothing here is production code.
import Foundation

// MARK: - Deterministic model construction

/// UUIDs from a counter, so two runs of this probe build byte-identical models and the
/// counts below are a property of the code rather than of an id ordering.
struct IdFactory {
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

/// A layout to measure: how many groups, tabs per group, and panes per tab.
struct Layout {
    let name: String
    let groups: Int
    let tabsPerGroup: Int
    let panesPerTab: Int
}

/// Build a balanced split tree of `count` leaves, so a multi-pane tab has real interior
/// split nodes for the shape and tree walks to visit.
func buildTree(_ count: Int, _ ids: inout IdFactory) -> SplitNodeModel {
    precondition(count >= 1)
    if count == 1 {
        return .leaf(PaneModel(id: PaneId(rawValue: ids.uuid()), title: "zsh", cwd: "~/Code"))
    }
    let half = count / 2
    return .split(
        id: SplitId(rawValue: ids.uuid()),
        direction: half % 2 == 0 ? .horizontal : .vertical,
        first: buildTree(half, &ids),
        second: buildTree(count - half, &ids),
        ratio: 0.5
    )
}

func buildModel(_ layout: Layout, _ ids: inout IdFactory) -> AppModel {
    var groups: [GroupModel] = []
    for groupIndex in 0..<layout.groups {
        var tabs: [TabModel] = []
        for _ in 0..<layout.tabsPerGroup {
            let root = buildTree(layout.panesPerTab, &ids)
            tabs.append(TabModel(
                id: TabId(rawValue: ids.uuid()),
                customTitle: nil,
                focusedPaneId: allPaneIds(root)[0],
                rootNode: root
            ))
        }
        groups.append(GroupModel(
            id: GroupId(rawValue: ids.uuid()), name: "group \(groupIndex)", tabs: tabs))
    }
    var model = AppModel(groups: groups, selectedTabId: groups[0].tabs[0].id)
    model.mruOrder = groups.flatMap { $0.tabs.map(\.id) }
    return model
}

// MARK: - The pure half of AppRuntime.reconcile()

/// The projection caches `ReconcilerCaches` holds, restricted to the passes whose desired
/// value is pure. Each holds the last value its pass applied, exactly as in `app/`.
struct SweepCaches {
    var focusBorders: [PaneId: BorderState] = [:]
    var paneConfig: [PaneId: PaneConfigKey] = [:]
    var paneToolbar: [PaneId: PaneToolbarRender] = [:]
    var searchOverlay: [PaneId: SearchOverlayRender] = [:]
    var containerShape: [TabId: ContainerShape] = [:]
    var sidebar: SidebarProjection?
    var windowChrome: WindowChromeProjection?
    var switcher: SwitcherProjection?
    var quitConfirmation: QuitConfirmationProjection?
    var preferencesPanel: PreferencesPanelProjection?
    var themeBrowser: ThemeBrowserProjection?
}

/// Run every pure pass of `reconcile()`, in `reconcile()`'s order. `blackhole` receives one
/// value per pass so the optimizer cannot delete a projection whose AppKit executor is the
/// only thing that would have consumed it.
func sweep(
    _ model: AppModel,
    caches: inout SweepCaches,
    liveSessionIds: Set<PaneId>,
    blackhole: inout Int
) {
    // reconcileSessionExistence
    blackhole &+= sessionsToTearDown(liveSessionIds: liveSessionIds, model: model).count

    // reconcilePaneConfig
    applyDiff(desiredPaneConfig(in: model), &caches.paneConfig,
              apply: { _, key in blackhole &+= key.theme.count })

    // reconcileContainers
    let shapes = desiredContainerShapes(in: model)
    let ops = computeContainerOps(
        old: caches.containerShape, new: shapes, selectedTabId: model.selectedTabId)
    blackhole &+= chromeInvalidation(ops: ops, newShapes: shapes).count
    blackhole &+= containerOpsStrandVisible(ops: ops, previouslyVisibleTabId: model.selectedTabId) ? 1 : 0
    caches.containerShape = shapes

    let tally = unreadAlertTally(for: model)

    // reconcileFocusBorders
    applyDiff(desiredFocusBorders(in: model, tally: tally), &caches.focusBorders,
              apply: { _, state in blackhole &+= state.focused ? 1 : 0 })

    // reconcilePaneChrome
    applyDiff(desiredPaneToolbar(in: model, tally: tally), &caches.paneToolbar,
              apply: { _, render in blackhole &+= render.title.count })
    applyDiff(desiredSearchOverlays(in: model), &caches.searchOverlay,
              apply: { _, render in blackhole &+= render.needle.count },
              remove: { _ in blackhole &+= 1 })

    // reconcileSidebar
    let sidebar = desiredSidebar(in: model, tally: tally)
    let rawOps = computeSidebarRowOps(old: caches.sidebar, new: sidebar)
    let guarded = guardSidebarRenameOps(ops: rawOps, renameTarget: nil, new: sidebar)
    blackhole &+= guarded.ops.count
    caches.sidebar = advanceSidebarCache(
        old: caches.sidebar, new: sidebar, suppressedRenameTarget: nil)

    // reconcileWindowChrome
    let chrome = desiredWindowChrome(in: model, tally: tally)
    if caches.windowChrome != chrome {
        blackhole &+= chrome.windowTitle.count
        caches.windowChrome = chrome
    }

    // reconcileSwitcher
    let switcher = desiredSwitcher(in: model, tally: tally)
    if caches.switcher != switcher {
        blackhole &+= switcher?.rows.count ?? 0
        caches.switcher = switcher
    }

    // reconcileQuitConfirmation
    let quit = desiredQuitConfirmation(in: model)
    if caches.quitConfirmation != quit {
        blackhole &+= quit?.paneCount ?? 0
        caches.quitConfirmation = quit
    }

    // reconcilePreferencesPanel
    let preferences = desiredPreferencesPanel(in: model)
    if caches.preferencesPanel != preferences {
        blackhole &+= preferences?.themeText.count ?? 0
        caches.preferencesPanel = preferences
    }

    // reconcileAlertsPopover / reconcilePaneTodoPopover / reconcileTabTodoPopover all
    // project nil while their AppKit popover is closed, which is the steady state a
    // shell-driven title or progress message runs in, so their projections are not called.

    // reconcileThemeBrowser
    let browser = desiredThemeBrowser(in: model)
    if caches.themeBrowser != browser {
        blackhole &+= browser.currentThemeName?.count ?? 0
        caches.themeBrowser = browser
    }
}

// MARK: - Scenarios

/// One measured stimulus: a `Msg` built fresh per iteration, so a repeated message carries
/// a changing payload and the sweep produces a real diff rather than a no-op compare.
struct Scenario {
    let name: String
    /// The number of panes the message itself names -- the denominator the sweep's work is
    /// amplified against. 0 means the message is inherently model-wide.
    let namedPanes: Int
    let make: (AppModel, Int) -> Msg
}

func scenarios(for model: AppModel) -> [Scenario] {
    let firstPane = model.allPaneIds[0]
    let lastPane = model.allPaneIds[model.allPaneIds.count - 1]
    let tabIds = model.groups.flatMap { $0.tabs.map(\.id) }
    let splitIds = firstSplitIds(in: model)

    var result: [Scenario] = [
        // The 13 Hz shell-driven trio T23 is written against. OSC 0/2, OSC 7, OSC 9;4.
        Scenario(name: "sessionTitle", namedPanes: 1) { _, i in
            .sessionTitle(paneId: firstPane, title: "zsh \(i)")
        },
        Scenario(name: "sessionCwd", namedPanes: 1) { _, i in
            .sessionCwd(paneId: firstPane, cwd: "~/Code/dir\(i)")
        },
        Scenario(name: "sessionProgress", namedPanes: 1) { _, i in
            .sessionProgress(paneId: firstPane, state: .set(percent: UInt8(i % 101)))
        },
        // A background pane's bell: a pane-scoped message that also moves the alert tally
        // every sweep reads.
        Scenario(name: "sessionBell", namedPanes: 1) { _, _ in
            .sessionBell(paneId: lastPane)
        },
        // A pane click. Pane-scoped and structural in the focus sense only.
        Scenario(name: "paneBecameFirstResponder", namedPanes: 1) { model, i in
            let panes = allPaneIds(selectedTab(in: model)!.rootNode)
            return .paneBecameFirstResponder(paneId: panes[i % panes.count])
        },
        // A tab switch: genuinely model-wide, and the control for the pane-scoped rows.
        Scenario(name: "selectTab", namedPanes: 0) { _, i in
            .selectTab(id: tabIds[i % tabIds.count])
        },
    ]
    if let splitId = splitIds.first {
        // Live divider drag. `ContainerShape` drops ratios, so the whole sweep is an empty
        // diff by construction -- the pure cost with none of the apply.
        result.append(Scenario(name: "splitRatioChanged", namedPanes: 1) { _, i in
            .splitRatioChanged(splitId: splitId, ratio: 0.3 + CGFloat(i % 40) / 100.0)
        })
    }
    return result
}

/// Split ids of the selected tab's tree, so `splitRatioChanged` names a real divider.
func firstSplitIds(in model: AppModel) -> [SplitId] {
    func walk(_ node: SplitNodeModel) -> [SplitId] {
        switch node {
        case .leaf: return []
        case .split(let id, _, let first, let second, _): return [id] + walk(first) + walk(second)
        }
    }
    guard let tab = selectedTab(in: model) else { return [] }
    return walk(tab.rootNode)
}

// MARK: - Measurement

/// A model plus the sweep caches that have already converged on it, which is the state a
/// live app is in when a shell sends its next title update. Priming matters: an unprimed
/// cache makes every pass apply, which is a first-frame cost, not a steady-state one.
func primed(_ layout: Layout) -> (AppModel, SweepCaches, Set<PaneId>) {
    var ids = IdFactory()
    let model = buildModel(layout, &ids)
    var caches = SweepCaches()
    var blackhole = 0
    let sessions = Set(model.allPaneIds)
    sweep(model, caches: &caches, liveSessionIds: sessions, blackhole: &blackhole)
    sweep(model, caches: &caches, liveSessionIds: sessions, blackhole: &blackhole)
    return (model, caches, sessions)
}

func countScenario(_ layout: Layout, _ scenario: Scenario) -> [String: Int] {
    var (model, caches, sessions) = primed(layout)
    var blackhole = 0
    t6Counters = T6Counters()
    _ = update(&model, scenario.make(model, 0), env: .live)
    let afterUpdate = t6Counters
    sweep(model, caches: &caches, liveSessionIds: sessions, blackhole: &blackhole)
    let total = t6Counters
    if blackhole == Int.min { print("unreachable") }

    var report = fields(total)
    for (key, value) in fields(afterUpdate) {
        report["update_" + key] = value
    }
    return report
}

func fields(_ counters: T6Counters) -> [String: Int] {
    [
        "allPanesWalks": counters.allPanesWalks,
        "panesInNodeCalls": counters.panesInNodeCalls,
        "panesInNodeLeaves": counters.panesInNodeLeaves,
        "paneLookups": counters.paneLookups,
        "paneInNodeCalls": counters.paneInNodeCalls,
        "allPaneIdsNodeCalls": counters.allPaneIdsNodeCalls,
        "updatePaneCalls": counters.updatePaneCalls,
        "updatePaneInNodeCalls": counters.updatePaneInNodeCalls,
        "liveTabIdSets": counters.liveTabIdSets,
        "liveTabIdInserts": counters.liveTabIdInserts,
        "containerShapeCalls": counters.containerShapeCalls,
        "containerShapeNodes": counters.containerShapeNodes,
        "alertTallies": counters.alertTallies,
        "sumUnreadCalls": counters.sumUnreadCalls,
        "derivedChromeCalls": counters.derivedChromeCalls,
        "abbreviateHomeCalls": counters.abbreviateHomeCalls,
        "projectionCalls": counters.projectionCalls,
        "paneKeyedProjectionEntries": counters.paneKeyedProjectionEntries,
        "tabKeyedProjectionEntries": counters.tabKeyedProjectionEntries,
    ]
}

/// Time `iterations` messages, reporting the best of three passes. Best-of, not mean: this
/// is a single-process pure computation with no contention, so the minimum is the run least
/// disturbed by the scheduler, and a mean would report the disturbance.
func timeScenario(_ layout: Layout, _ scenario: Scenario, iterations: Int) -> (Double, Double) {
    var messageNanos = Double.greatestFiniteMagnitude
    var updateNanos = Double.greatestFiniteMagnitude
    for _ in 0..<3 {
        var (model, caches, sessions) = primed(layout)
        var blackhole = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            _ = update(&model, scenario.make(model, i), env: .live)
            sweep(model, caches: &caches, liveSessionIds: sessions, blackhole: &blackhole)
        }
        let mid = DispatchTime.now().uptimeNanoseconds
        var (updateModel, _, _) = primed(layout)
        for i in 0..<iterations {
            _ = update(&updateModel, scenario.make(updateModel, i), env: .live)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        if blackhole == Int.min { print("unreachable") }
        messageNanos = min(messageNanos, Double(mid - start) / Double(iterations))
        updateNanos = min(updateNanos, Double(end - mid) / Double(iterations))
    }
    return (messageNanos, updateNanos)
}

/// Time each pure projection on its own, over the primed model, so the sweep's cost can be
/// attributed to a pass rather than only totalled. Cache-free by construction: these are
/// pure functions of the model, and what is being measured is the cost of computing the
/// desired value, which the sweep pays before any diff can decide to discard it.
func timeProjections(_ layout: Layout, iterations: Int) -> [String: Double] {
    let (model, _, sessions) = primed(layout)
    var blackhole = 0

    func measure(_ name: String, _ body: () -> Int) -> (String, Double) {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { blackhole &+= body() }
            let end = DispatchTime.now().uptimeNanoseconds
            best = min(best, Double(end - start) / Double(iterations))
        }
        return (name, best)
    }

    let tally = unreadAlertTally(for: model)
    var results: [String: Double] = [:]
    let measurements = [
        measure("unreadAlertTally") { unreadAlertTally(for: model).total },
        measure("sessionsToTearDown") {
            sessionsToTearDown(liveSessionIds: sessions, model: model).count
        },
        measure("desiredPaneConfig") { desiredPaneConfig(in: model).count },
        measure("desiredContainerShapes") { desiredContainerShapes(in: model).count },
        measure("desiredFocusBorders") { desiredFocusBorders(in: model, tally: tally).count },
        measure("desiredPaneToolbar") { desiredPaneToolbar(in: model, tally: tally).count },
        measure("desiredSearchOverlays") { desiredSearchOverlays(in: model).count },
        measure("desiredSidebar") { desiredSidebar(in: model, tally: tally).groups.count },
        measure("desiredWindowChrome") {
            desiredWindowChrome(in: model, tally: tally).unreadCount
        },
        measure("desiredSwitcher") { desiredSwitcher(in: model, tally: tally)?.rows.count ?? 0 },
        measure("desiredQuitConfirmation") { desiredQuitConfirmation(in: model)?.paneCount ?? 0 },
        measure("desiredPreferencesPanel") { desiredPreferencesPanel(in: model) == nil ? 0 : 1 },
        measure("desiredThemeBrowser") {
            desiredThemeBrowser(in: model).currentThemeName?.count ?? 0
        },
    ]
    if blackhole == Int.min { print("unreachable") }
    for (name, nanos) in measurements { results[name] = nanos }
    return results
}

// MARK: - Driver

func encode(_ value: Any) -> String {
    switch value {
    case let string as String:
        return "\"" + string.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    case let int as Int:
        return String(int)
    case let double as Double:
        return String(format: "%.1f", double)
    case let dictionary as [String: Any]:
        return "{" + dictionary.keys.sorted().map { "\(encode($0)):\(encode(dictionary[$0]!))" }
            .joined(separator: ",") + "}"
    case let array as [Any]:
        return "[" + array.map(encode).joined(separator: ",") + "]"
    default:
        fatalError("unencodable value")
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(
        Data("usage: probe <count|time> <iterations> <name:groups:tabs:panes>...\n".utf8))
    exit(2)
}
let mode = arguments[1]
let iterations = Int(arguments[2])!
let layouts: [Layout] = arguments[3...].map { specification in
    let parts = specification.split(separator: ":")
    return Layout(
        name: String(parts[0]),
        groups: Int(parts[1])!,
        tabsPerGroup: Int(parts[2])!,
        panesPerTab: Int(parts[3])!
    )
}

var layoutReports: [Any] = []
for layout in layouts {
    var ids = IdFactory()
    let model = buildModel(layout, &ids)
    var scenarioReports: [Any] = []
    for scenario in scenarios(for: model) {
        var report: [String: Any] = ["name": scenario.name, "namedPanes": scenario.namedPanes]
        if mode == "count" {
            report["counters"] = countScenario(layout, scenario)
            report["nanosPerMessage"] = 0.0
            report["nanosUpdate"] = 0.0
        } else {
            let (message, only) = timeScenario(layout, scenario, iterations: iterations)
            report["counters"] = [String: Int]()
            report["nanosPerMessage"] = message
            report["nanosUpdate"] = only
        }
        scenarioReports.append(report)
    }
    let projectionNanos: [String: Double] =
        mode == "time" ? timeProjections(layout, iterations: iterations) : [:]
    layoutReports.append([
        "projectionNanos": projectionNanos,
        "name": layout.name,
        "groups": layout.groups,
        "tabs": layout.groups * layout.tabsPerGroup,
        "panes": layout.groups * layout.tabsPerGroup * layout.panesPerTab,
        "scenarios": scenarioReports,
    ] as [String: Any])
}
print(encode(["layouts": layoutReports] as [String: Any]))
