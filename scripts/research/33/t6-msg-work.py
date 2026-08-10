#!/usr/bin/env python3
"""Research doc 33, task T6: count the work one `Msg` costs the pure app runtime.

The app-runtime vertical has no instrument (`F8`): no ladder workload emits a `Msg`, so no
change to `update()` or to the reconcile sweep can read as anything but `equivalent`. This
is doc 21's answer applied to `H4` -- a purpose-built probe for a cost no workload contains.

It builds two binaries from the same probe source. The **counted** build copies
`lib/DanTermCore/Sources/DanTermCore` and `lib/DanTermProtocol/Sources/DanTermProtocol` into
a scratch directory, injects one counter increment at each site this task counts, and
compiles the copy as a single optimized module with the probe. The **timed** build compiles
the same probe against the same sources with no injections at all, because injecting
increments perturbs inlining and a timing taken from the counted build would mean nothing.

Reported per `Msg`, per model size: panes visited, `allPanes` walks, projection calls,
`containerShapeNode` allocations, `liveTabIds` set constructions -- and, from the separate
uninstrumented build, the wall-clock cost of one `update()` plus one sweep. The point of the
timing is that it is what lets the counts honestly say "negligible at the sizes one user
runs" rather than only "large in the abstract".

The core in the repo is never edited. Every injection is an exact-text anchor that must
match exactly once, so a source change that moves a site fails the run loudly instead of
silently miscounting.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
PROBE = HERE / "t6-msg-work-probe.swift"
COUNTERS = HERE / "t6-msg-work-counters.swift"
SOURCE_TREES = [
    ROOT / "lib" / "DanTermCore" / "Sources" / "DanTermCore",
    ROOT / "lib" / "DanTermProtocol" / "Sources" / "DanTermProtocol",
]

# (groups, tabs per group, panes per tab). The first two are what one user actually runs --
# the ledger's own "negligible at 3 tabs" case and a heavy day. The last two exist only so
# the shape of the growth is visible; nobody runs 480 panes.
LAYOUTS = [
    ("3-tabs", 1, 3, 1),
    ("8-tabs-2-panes", 1, 8, 2),
    ("24-tabs-4-panes", 2, 12, 4),
    ("60-tabs-8-panes", 3, 20, 8),
]

# (file, anchor, replacement). The anchor is the unmodified text at the site; the
# replacement is that same text with one counter increment added. Each anchor must occur
# exactly once in its file.
PATCHES = [
    # --- Tree walks -------------------------------------------------------------------
    (
        "Model.swift",
        "    var allPanes: [PaneModel] {\n"
        "        groups.flatMap { $0.tabs.flatMap { panesInNode($0.rootNode) } }\n",
        "    var allPanes: [PaneModel] {\n"
        "        t6Counters.allPanesWalks += 1\n"
        "        return groups.flatMap { $0.tabs.flatMap { panesInNode($0.rootNode) } }\n",
    ),
    (
        "Model.swift",
        "    func pane(_ id: PaneId) -> PaneModel? {\n"
        "        for group in groups {\n",
        "    func pane(_ id: PaneId) -> PaneModel? {\n"
        "        t6Counters.paneLookups += 1\n"
        "        for group in groups {\n",
    ),
    (
        "Model.swift",
        "    mutating func updatePane(_ id: PaneId, _ body: (inout PaneModel) -> Void) {\n"
        "        for gi in groups.indices {\n",
        "    mutating func updatePane(_ id: PaneId, _ body: (inout PaneModel) -> Void) {\n"
        "        t6Counters.updatePaneCalls += 1\n"
        "        for gi in groups.indices {\n",
    ),
    (
        "ModelOperations.swift",
        "func panesInNode(_ node: SplitNodeModel) -> [PaneModel] {\n"
        "  switch node {\n"
        "  case .leaf(let pane):\n"
        "    return [pane]\n",
        "func panesInNode(_ node: SplitNodeModel) -> [PaneModel] {\n"
        "  t6Counters.panesInNodeCalls += 1\n"
        "  switch node {\n"
        "  case .leaf(let pane):\n"
        "    t6Counters.panesInNodeLeaves += 1\n"
        "    return [pane]\n",
    ),
    (
        "ModelOperations.swift",
        "func paneInNode(_ node: SplitNodeModel, id: PaneId) -> PaneModel? {\n"
        "  switch node {\n",
        "func paneInNode(_ node: SplitNodeModel, id: PaneId) -> PaneModel? {\n"
        "  t6Counters.paneInNodeCalls += 1\n"
        "  switch node {\n",
    ),
    (
        "ModelOperations.swift",
        "func allPaneIds(_ node: SplitNodeModel) -> [PaneId] {\n"
        "  switch node {\n",
        "func allPaneIds(_ node: SplitNodeModel) -> [PaneId] {\n"
        "  t6Counters.allPaneIdsNodeCalls += 1\n"
        "  switch node {\n",
    ),
    (
        "ModelOperations.swift",
        "func updatePaneInNode(_ node: SplitNodeModel, id: PaneId, _ body: (inout PaneModel) -> Void) -> SplitNodeModel? {\n"
        "  switch node {\n",
        "func updatePaneInNode(_ node: SplitNodeModel, id: PaneId, _ body: (inout PaneModel) -> Void) -> SplitNodeModel? {\n"
        "  t6Counters.updatePaneInNodeCalls += 1\n"
        "  switch node {\n",
    ),
    # --- Set and shape construction ---------------------------------------------------
    (
        "ModelOperations.swift",
        "func liveTabIds(in model: AppModel) -> Set<TabId> {\n"
        "  var ids = Set<TabId>()\n",
        "func liveTabIds(in model: AppModel) -> Set<TabId> {\n"
        "  t6Counters.liveTabIdSets += 1\n"
        "  var ids = Set<TabId>()\n",
    ),
    (
        "ModelOperations.swift",
        "      ids.insert(tab.id)\n",
        "      t6Counters.liveTabIdInserts += 1\n"
        "      ids.insert(tab.id)\n",
    ),
    (
        "ModelOperations.swift",
        "func containerShapeNode(_ node: SplitNodeModel) -> ContainerShapeNode {\n"
        "  switch node {\n",
        "func containerShapeNode(_ node: SplitNodeModel) -> ContainerShapeNode {\n"
        "  t6Counters.containerShapeNodes += 1\n"
        "  switch node {\n",
    ),
    (
        "ModelOperations.swift",
        "func containerShape(of tab: TabModel) -> ContainerShape {\n"
        "  ContainerShape(\n",
        "func containerShape(of tab: TabModel) -> ContainerShape {\n"
        "  t6Counters.containerShapeCalls += 1\n"
        "  return ContainerShape(\n",
    ),
    (
        "ModelOperations.swift",
        "func unreadAlertTally(for model: AppModel) -> UnreadAlertTally {\n"
        "  var byPane: [PaneId: Int] = [:]\n",
        "func unreadAlertTally(for model: AppModel) -> UnreadAlertTally {\n"
        "  t6Counters.alertTallies += 1\n"
        "  var byPane: [PaneId: Int] = [:]\n",
    ),
    (
        "ModelOperations.swift",
        "private func sumUnread(in node: SplitNodeModel, byPane: [PaneId: Int]) -> Int {\n"
        "  switch node {\n",
        "private func sumUnread(in node: SplitNodeModel, byPane: [PaneId: Int]) -> Int {\n"
        "  t6Counters.sumUnreadCalls += 1\n"
        "  switch node {\n",
    ),
    (
        "ModelOperations.swift",
        "func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {  // core-purity: ambient-seam\n"
        "  guard path == home || path.hasPrefix(home + \"/\") else { return path }\n",
        "func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {  // core-purity: ambient-seam\n"
        "  t6Counters.abbreviateHomeCalls += 1\n"
        "  guard path == home || path.hasPrefix(home + \"/\") else { return path }\n",
    ),
    (
        "Model.swift",
        "    private var derivedChrome: (title: String, subtitle: String?) {\n"
        "        focusedPane.map { deriveTabChrome(from: $0) } ?? (\"Terminal\", nil)\n",
        "    private var derivedChrome: (title: String, subtitle: String?) {\n"
        "        t6Counters.derivedChromeCalls += 1\n"
        "        return focusedPane.map { deriveTabChrome(from: $0) } ?? (\"Terminal\", nil)\n",
    ),
    # --- The twelve pure projections the sweep runs ------------------------------------
    (
        "Projections.swift",
        "func desiredFocusBorders(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: BorderState] {\n"
        "  let selected = selectedTab(in: model)\n",
        "func desiredFocusBorders(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: BorderState] {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  let selected = selectedTab(in: model)\n",
    ),
    (
        "Projections.swift",
        "  for pane in model.allPanes {\n"
        "    result[pane.id] = BorderState(\n",
        "  for pane in model.allPanes {\n"
        "    t6Counters.paneKeyedProjectionEntries += 1\n"
        "    result[pane.id] = BorderState(\n",
    ),
    (
        "Projections.swift",
        "func desiredPaneToolbar(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: PaneToolbarRender] {\n"
        "  var result: [PaneId: PaneToolbarRender] = [:]\n",
        "func desiredPaneToolbar(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: PaneToolbarRender] {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  var result: [PaneId: PaneToolbarRender] = [:]\n",
    ),
    (
        "Projections.swift",
        "  for pane in model.allPanes {\n"
        "    result[pane.id] = PaneToolbarRender(\n",
        "  for pane in model.allPanes {\n"
        "    t6Counters.paneKeyedProjectionEntries += 1\n"
        "    result[pane.id] = PaneToolbarRender(\n",
    ),
    (
        "Projections.swift",
        "func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {\n"
        "  var result: [PaneId: PaneConfigKey] = [:]\n",
        "func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  var result: [PaneId: PaneConfigKey] = [:]\n",
    ),
    (
        "Projections.swift",
        "  for pane in model.allPanes {\n"
        "    result[pane.id] = PaneConfigKey(\n",
        "  for pane in model.allPanes {\n"
        "    t6Counters.paneKeyedProjectionEntries += 1\n"
        "    result[pane.id] = PaneConfigKey(\n",
    ),
    (
        "Projections.swift",
        "func desiredSearchOverlays(in model: AppModel) -> [PaneId: SearchOverlayRender] {\n"
        "  var result: [PaneId: SearchOverlayRender] = [:]\n",
        "func desiredSearchOverlays(in model: AppModel) -> [PaneId: SearchOverlayRender] {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  var result: [PaneId: SearchOverlayRender] = [:]\n",
    ),
    (
        "Projections.swift",
        "func desiredContainerShapes(in model: AppModel) -> [TabId: ContainerShape] {\n"
        "  var result: [TabId: ContainerShape] = [:]\n",
        "func desiredContainerShapes(in model: AppModel) -> [TabId: ContainerShape] {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  var result: [TabId: ContainerShape] = [:]\n",
    ),
    (
        "Projections.swift",
        "      result[tab.id] = containerShape(of: tab)\n",
        "      t6Counters.tabKeyedProjectionEntries += 1\n"
        "      result[tab.id] = containerShape(of: tab)\n",
    ),
    (
        "Projections.swift",
        "func desiredSidebar(in model: AppModel, tally: UnreadAlertTally) -> SidebarProjection {\n"
        "  let firstGroupId = model.groups.first?.id\n",
        "func desiredSidebar(in model: AppModel, tally: UnreadAlertTally) -> SidebarProjection {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  let firstGroupId = model.groups.first?.id\n",
    ),
    (
        "Projections.swift",
        "      tabs: group.tabs.map { tab in\n"
        "        SidebarTabProjection(\n",
        "      tabs: group.tabs.map { tab in\n"
        "        t6Counters.tabKeyedProjectionEntries += 1\n"
        "        return SidebarTabProjection(\n",
    ),
    (
        "Projections.swift",
        "func desiredWindowChrome(in model: AppModel, tally: UnreadAlertTally) -> WindowChromeProjection {\n"
        "  let tab = selectedTab(in: model)\n",
        "func desiredWindowChrome(in model: AppModel, tally: UnreadAlertTally) -> WindowChromeProjection {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  let tab = selectedTab(in: model)\n",
    ),
    (
        "Projections.swift",
        "func desiredSwitcher(in model: AppModel, tally: UnreadAlertTally) -> SwitcherProjection? {\n"
        "  guard\n",
        "func desiredSwitcher(in model: AppModel, tally: UnreadAlertTally) -> SwitcherProjection? {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  guard\n",
    ),
    (
        "Projections.swift",
        "func desiredQuitConfirmation(in model: AppModel) -> QuitConfirmationProjection? {\n"
        "  guard model.pendingConfirmation == .terminate else { return nil }\n",
        "func desiredQuitConfirmation(in model: AppModel) -> QuitConfirmationProjection? {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  guard model.pendingConfirmation == .terminate else { return nil }\n",
    ),
    (
        "Projections.swift",
        "func desiredPreferencesPanel(in model: AppModel) -> PreferencesPanelProjection? {\n"
        "    guard let draft = model.preferencesDraft else { return nil }\n",
        "func desiredPreferencesPanel(in model: AppModel) -> PreferencesPanelProjection? {\n"
        "    t6Counters.projectionCalls += 1\n"
        "    guard let draft = model.preferencesDraft else { return nil }\n",
    ),
    (
        "Projections.swift",
        "func desiredThemeBrowser(in model: AppModel) -> ThemeBrowserProjection {\n"
        "    ThemeBrowserProjection(\n",
        "func desiredThemeBrowser(in model: AppModel) -> ThemeBrowserProjection {\n"
        "    t6Counters.projectionCalls += 1\n"
        "    return ThemeBrowserProjection(\n",
    ),
    (
        "Projections.swift",
        "func sessionsToTearDown(liveSessionIds: Set<PaneId>, model: AppModel) -> Set<PaneId> {\n"
        "  liveSessionIds.subtracting(Set(model.allPaneIds))\n",
        "func sessionsToTearDown(liveSessionIds: Set<PaneId>, model: AppModel) -> Set<PaneId> {\n"
        "  t6Counters.projectionCalls += 1\n"
        "  return liveSessionIds.subtracting(Set(model.allPaneIds))\n",
    ),
]


def stage(scratch, instrumented):
    """Copy both source trees into one flat directory, optionally applying every injection."""
    sources = scratch / ("counted" if instrumented else "timed")
    sources.mkdir()
    for tree in SOURCE_TREES:
        for path in sorted(tree.glob("*.swift")):
            destination = sources / path.name
            if destination.exists():
                raise SystemExit(f"source file name collides across trees: {path.name}")
            text = path.read_text(encoding="utf-8")
            # The two targets become one module here, and a module may not import itself.
            text = text.replace("import DanTermProtocol\n", "")
            destination.write_text(text, encoding="utf-8")
    if not instrumented:
        return sources
    for name, anchor, replacement in PATCHES:
        path = sources / name
        text = path.read_text(encoding="utf-8")
        occurrences = text.count(anchor)
        if occurrences != 1:
            raise SystemExit(
                f"instrumentation anchor matched {occurrences} times in {name}; "
                "the core moved and this probe must be re-anchored:\n" + anchor
            )
        path.write_text(text.replace(anchor, replacement), encoding="utf-8")
    return sources


def build(scratch, sources, name):
    """Compile the probe, the counters, and one staged copy of the core as a single module."""
    # The probe holds top-level code, which Swift accepts only in a file named `main.swift`,
    # so each build gets its own directory rather than a name-mangled copy.
    home = scratch / f"{name}-build"
    home.mkdir()
    main = home / "main.swift"
    shutil.copyfile(PROBE, main)
    counters = home / "counters.swift"
    shutil.copyfile(COUNTERS, counters)
    binary = home / name
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-swift-version",
            "5",
            "-o",
            str(binary),
            str(main),
            str(counters),
            *(str(path) for path in sorted(sources.glob("*.swift"))),
        ],
        check=True,
    )
    return binary


def run(binary, mode, layouts, iterations):
    arguments = [str(binary), mode, str(iterations)]
    for name, groups, tabs, panes in layouts:
        arguments.append(f"{name}:{groups}:{tabs}:{panes}")
    result = subprocess.run(arguments, check=True, capture_output=True)
    return json.loads(result.stdout)


def merge(counted, timed):
    """Join the two runs on (layout, scenario). They run the same probe over the same model."""
    times = {
        (layout["name"], scenario["name"]): scenario
        for layout in timed["layouts"]
        for scenario in layout["scenarios"]
    }
    projections = {layout["name"]: layout["projectionNanos"] for layout in timed["layouts"]}
    for layout in counted["layouts"]:
        layout["projectionNanos"] = projections[layout["name"]]
        for scenario in layout["scenarios"]:
            match = times[(layout["name"], scenario["name"])]
            scenario["nanosPerMessage"] = match["nanosPerMessage"]
            scenario["nanosUpdate"] = match["nanosUpdate"]
    return counted


def render(report):
    lines = []
    for layout in report["layouts"]:
        lines.append(
            f"{layout['name']}: {layout['groups']} group(s), {layout['tabs']} tabs, "
            f"{layout['panes']} panes"
        )
        lines.append(
            f"  {'msg':<24}{'panes':>8}{'walks':>7}{'proj':>6}{'shapeNodes':>12}"
            f"{'liveTabIds':>12}{'chrome':>8}{'homeAbbr':>10}{'us/msg':>10}{'us/update':>11}"
        )
        for scenario in layout["scenarios"]:
            counters = scenario["counters"]
            lines.append(
                f"  {scenario['name']:<24}"
                f"{counters['panesInNodeLeaves']:>8}"
                f"{counters['allPanesWalks']:>7}"
                f"{counters['projectionCalls']:>6}"
                f"{counters['containerShapeNodes']:>12}"
                f"{counters['liveTabIdSets']:>12}"
                f"{counters['derivedChromeCalls']:>8}"
                f"{counters['abbreviateHomeCalls']:>10}"
                f"{scenario['nanosPerMessage'] / 1000.0:>10.2f}"
                f"{scenario['nanosUpdate'] / 1000.0:>11.2f}"
            )
        ranked = sorted(layout["projectionNanos"].items(), key=lambda pair: -pair[1])
        lines.append("  per-projection us, computed alone over the same model:")
        for name, nanos in ranked:
            lines.append(f"    {name:<26}{nanos / 1000.0:>9.2f}")
        lines.append("")
    return "\n".join(lines).rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--iterations", type=int, default=2000, help="timed messages per scenario"
    )
    parser.add_argument("--json", action="store_true", help="print the raw report")
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="t6-msg-work-") as directory:
        scratch = pathlib.Path(directory)
        counted_binary = build(scratch, stage(scratch, True), "t6-counted")
        timed_binary = build(scratch, stage(scratch, False), "t6-timed")
        counted = run(counted_binary, "count", LAYOUTS, arguments.iterations)
        timed = run(timed_binary, "time", LAYOUTS, arguments.iterations)
    report = merge(counted, timed)

    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
